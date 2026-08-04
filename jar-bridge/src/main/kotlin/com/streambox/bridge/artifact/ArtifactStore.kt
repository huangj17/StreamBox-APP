package com.streambox.bridge.artifact

import com.streambox.bridge.security.RemoteTargetException
import com.streambox.bridge.security.RemoteTargetPolicy
import com.streambox.bridge.security.PolicyDns
import com.streambox.bridge.storage.atomicWrite
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.InterruptedIOException
import java.nio.charset.StandardCharsets
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.PosixFilePermission
import java.security.MessageDigest
import java.time.Instant
import java.time.Duration
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import org.slf4j.LoggerFactory

data class PreparedArtifact(
    val sha256: String,
    val path: Path,
    val className: String,
    val inspection: JarInspection,
)

class ArtifactException(
    val code: String,
    message: String,
    cause: Throwable? = null,
) : RuntimeException(message, cause)

@Serializable
private data class ArtifactMetadata(
    val sourceUrl: String,
    val finalUrl: String,
    val declaredMd5: String? = null,
    val md5: String,
    val sha256: String,
    val size: Long,
    val etag: String? = null,
    val lastModified: String? = null,
    val checkedAt: String,
)

class ArtifactStore(
    private val root: Path,
    private val remoteTargetPolicy: RemoteTargetPolicy,
    private val maxJarBytes: Long = 100L * 1024 * 1024,
    private val maxZipEntries: Int = 50_000,
    downloadConcurrency: Int = 4,
    connectTimeoutMs: Long = 5_000,
    readTimeoutMs: Long = 30_000,
) : AutoCloseable {
    private val logger = LoggerFactory.getLogger(ArtifactStore::class.java)
    private val shaRoot = root.resolve("artifacts/sha256")
    private val metadataRoot = root.resolve("artifacts/metadata")
    private val tmpRoot = root.resolve("tmp")
    private val locks = ConcurrentHashMap<String, Mutex>()
    private val semaphore = Semaphore(downloadConcurrency)
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }
    private val client = OkHttpClient.Builder()
        .followRedirects(false)
        .followSslRedirects(false)
        .connectTimeout(connectTimeoutMs, TimeUnit.MILLISECONDS)
        .readTimeout(readTimeoutMs, TimeUnit.MILLISECONDS)
        .callTimeout(readTimeoutMs, TimeUnit.MILLISECONDS)
        .dns(PolicyDns(remoteTargetPolicy))
        .build()

    init {
        require(maxJarBytes > 0)
        require(maxZipEntries > 0)
        require(downloadConcurrency > 0)
        Files.createDirectories(shaRoot)
        Files.createDirectories(metadataRoot)
        Files.createDirectories(tmpRoot)
        cleanupTemporaryFiles()
    }

    suspend fun prepare(reference: JarReference, api: String): PreparedArtifact {
        val lockKey = "${reference.url}\u0000${reference.declaredMd5.orEmpty()}"
        val lock = locks.computeIfAbsent(lockKey) { Mutex() }
        return lock.withLock {
            findCached(reference)?.let { metadata ->
                return@withLock preparedFromMetadata(metadata, api)
            }
            semaphore.withPermit { download(reference, api) }
        }
    }

    fun loadCached(sha256: String, api: String): PreparedArtifact? {
        if (!sha256.matches(Regex("[0-9a-f]{64}"))) return null
        val metadata = runCatching {
            json.decodeFromString<ArtifactMetadata>(
                Files.readString(metadataRoot.resolve("$sha256.json")),
            )
        }.getOrNull() ?: return null
        if (metadata.sha256 != sha256) return null
        return runCatching { preparedFromMetadata(metadata, api) }.getOrNull()
    }

    fun requiresRevalidation(reference: JarReference): Boolean {
        if (reference.declaredMd5 != null) return false
        val metadata = metadataFor(reference) ?: return true
        return runCatching {
            Duration.between(Instant.parse(metadata.checkedAt), Instant.now()) >=
                MUTABLE_REFERENCE_REVALIDATION
        }.getOrDefault(true)
    }

    private suspend fun download(reference: JarReference, api: String): PreparedArtifact =
        withContext(Dispatchers.IO) {
            val temporary = tmpRoot.resolve("${UUID.randomUUID()}.part")
            try {
                var url = reference.url
                var redirects = 0
                while (true) {
                    remoteTargetPolicy.validate(url)
                    val request = Request.Builder()
                        .url(url)
                        .get()
                        .header("Accept", "application/java-archive, application/octet-stream")
                        .header("User-Agent", "StreamBox-Gateway/2.0.0")
                        .build()
                    client.newCall(request).execute().use { response ->
                        if (response.code in 300..399) {
                            if (redirects >= MAX_REDIRECTS) {
                                throw ArtifactException(
                                    "JAR_TOO_MANY_REDIRECTS",
                                    "JAR download exceeded $MAX_REDIRECTS redirects",
                                )
                            }
                            val location = response.header("Location")
                                ?: throw ArtifactException(
                                    "JAR_REDIRECT_INVALID",
                                    "JAR redirect is missing Location",
                                )
                            url = response.request.url.resolve(location)
                                ?: throw ArtifactException(
                                    "JAR_REDIRECT_INVALID",
                                    "JAR redirect Location is invalid",
                                )
                            redirects += 1
                            return@use
                        }
                        if (!response.isSuccessful) {
                            throw ArtifactException(
                                "JAR_HTTP_ERROR",
                                "JAR server returned HTTP ${response.code}",
                            )
                        }
                        val body = response.body
                            ?: throw ArtifactException("JAR_EMPTY_BODY", "JAR response is empty")
                        if (body.contentLength() > maxJarBytes) {
                            throw ArtifactException(
                                "JAR_TOO_LARGE",
                                "JAR exceeds the configured download size limit",
                            )
                        }
                        val md5 = MessageDigest.getInstance("MD5")
                        val sha256 = MessageDigest.getInstance("SHA-256")
                        var size = 0L
                        Files.newOutputStream(
                            temporary,
                            StandardOpenOption.CREATE_NEW,
                            StandardOpenOption.WRITE,
                        ).use { output ->
                            body.byteStream().use { input ->
                                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                                while (true) {
                                    val read = input.read(buffer)
                                    if (read < 0) break
                                    size += read
                                    if (size > maxJarBytes) {
                                        throw ArtifactException(
                                            "JAR_TOO_LARGE",
                                            "JAR exceeds the configured download size limit",
                                        )
                                    }
                                    md5.update(buffer, 0, read)
                                    sha256.update(buffer, 0, read)
                                    output.write(buffer, 0, read)
                                }
                            }
                        }
                        val actualMd5 = md5.digest().hex()
                        if (
                            reference.declaredMd5 != null &&
                            reference.declaredMd5 != actualMd5
                        ) {
                            throw ArtifactException(
                                "JAR_MD5_MISMATCH",
                                "Downloaded JAR does not match its declared MD5",
                            )
                        }
                        val actualSha256 = sha256.digest().hex()
                        val inspection = try {
                            JarInspector.inspect(temporary, maxEntries = maxZipEntries)
                        } catch (error: JarInspectionException) {
                            throw ArtifactException(error.code, error.message.orEmpty(), error)
                        }
                        val className = try {
                            JarInspector.resolveClassName(api, inspection)
                        } catch (error: JarInspectionException) {
                            throw ArtifactException(error.code, error.message.orEmpty(), error)
                        }
                        val target = shaRoot.resolve("$actualSha256.jar")
                        moveArtifact(temporary, target)
                        val metadata = ArtifactMetadata(
                            sourceUrl = reference.url.toString(),
                            finalUrl = url.toString(),
                            declaredMd5 = reference.declaredMd5,
                            md5 = actualMd5,
                            sha256 = actualSha256,
                            size = size,
                            etag = response.header("ETag"),
                            lastModified = response.header("Last-Modified"),
                            checkedAt = Instant.now().toString(),
                        )
                        atomicWrite(
                            metadataRoot.resolve("$actualSha256.json"),
                            json.encodeToString(metadata).toByteArray(StandardCharsets.UTF_8),
                        )
                        logger.info(
                            "prepared JAR artifact sha256={} size={} packageType={}",
                            actualSha256.take(16),
                            size,
                            inspection.packageType,
                        )
                        return@withContext PreparedArtifact(
                            sha256 = actualSha256,
                            path = target,
                            className = className,
                            inspection = inspection,
                        )
                    }
                }
                error("unreachable")
            } catch (error: ArtifactException) {
                throw error
            } catch (error: RemoteTargetException) {
                throw ArtifactException(error.code, error.message.orEmpty(), error)
            } catch (error: CancellationException) {
                throw error
            } catch (error: InterruptedIOException) {
                throw ArtifactException("JAR_DOWNLOAD_TIMEOUT", "JAR download timed out", error)
            } catch (error: Exception) {
                throw ArtifactException("JAR_DOWNLOAD_FAILED", "JAR download failed", error)
            } finally {
                Files.deleteIfExists(temporary)
            }
        }

    private fun findCached(reference: JarReference): ArtifactMetadata? {
        val metadata = metadataFor(reference) ?: return null
        val fresh = reference.declaredMd5 != null || runCatching {
            Duration.between(Instant.parse(metadata.checkedAt), Instant.now()) <
                MUTABLE_REFERENCE_REVALIDATION
        }.getOrDefault(false)
        return metadata.takeIf { fresh && Files.isRegularFile(shaRoot.resolve("${it.sha256}.jar")) }
    }

    private fun metadataFor(reference: JarReference): ArtifactMetadata? {
        if (!Files.isDirectory(metadataRoot)) return null
        return Files.list(metadataRoot).use { paths ->
            paths.filter { it.fileName.toString().endsWith(".json") }
                .map { path ->
                    runCatching {
                        json.decodeFromString<ArtifactMetadata>(Files.readString(path))
                    }.getOrNull()
                }
                .filter { metadata ->
                        metadata != null &&
                        metadata.sourceUrl == reference.url.toString() &&
                        metadata.declaredMd5 == reference.declaredMd5
                }
                .findFirst()
                .orElse(null)
        }
    }

    private fun preparedFromMetadata(metadata: ArtifactMetadata, api: String): PreparedArtifact {
        val path = shaRoot.resolve("${metadata.sha256}.jar")
        val inspection = try {
            JarInspector.inspect(path, maxEntries = maxZipEntries)
        } catch (error: JarInspectionException) {
            throw ArtifactException(error.code, error.message.orEmpty(), error)
        }
        val className = try {
            JarInspector.resolveClassName(api, inspection)
        } catch (error: JarInspectionException) {
            throw ArtifactException(error.code, error.message.orEmpty(), error)
        }
        return PreparedArtifact(metadata.sha256, path, className, inspection)
    }

    private fun moveArtifact(source: Path, target: Path) {
        if (Files.exists(target)) return
        try {
            Files.move(source, target, StandardCopyOption.ATOMIC_MOVE)
        } catch (_: AtomicMoveNotSupportedException) {
            Files.move(source, target)
        }
        runCatching {
            Files.setPosixFilePermissions(
                target,
                setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE),
            )
        }
    }

    private fun cleanupTemporaryFiles() {
        Files.list(tmpRoot).use { paths ->
            paths.filter { it.fileName.toString().endsWith(".part") }
                .forEach(Files::deleteIfExists)
        }
    }

    fun cleanupUnreferenced(referencedSha256: Set<String>): Int {
        var deleted = 0
        Files.list(shaRoot).use { paths ->
            paths.filter { path ->
                val name = path.fileName.toString()
                name.matches(Regex("[0-9a-f]{64}\\.jar")) &&
                    name.removeSuffix(".jar") !in referencedSha256
            }.forEach { path ->
                val sha256 = path.fileName.toString().removeSuffix(".jar")
                if (Files.deleteIfExists(path)) deleted += 1
                Files.deleteIfExists(metadataRoot.resolve("$sha256.json"))
            }
        }
        return deleted
    }

    override fun close() {
        client.dispatcher.executorService.shutdown()
        client.connectionPool.evictAll()
        client.cache?.close()
    }

    private fun ByteArray.hex(): String = joinToString(separator = "") { byte -> "%02x".format(byte) }

    private companion object {
        const val MAX_REDIRECTS = 3
        val MUTABLE_REFERENCE_REVALIDATION: Duration = Duration.ofHours(6)
    }
}
