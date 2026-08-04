package com.streambox.bridge.storage

import com.streambox.bridge.catalog.CatalogIdentity
import com.streambox.bridge.catalog.EntryStatus
import com.streambox.bridge.catalog.SourceKind
import com.streambox.bridge.catalog.SourceOrigin
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.FileTime

@Serializable
data class SnapshotAggregator(
    val baseUrl: String,
    val configDigest: String,
    val etag: String? = null,
    val lastModified: String? = null,
)

@Serializable
data class SnapshotEntry(
    val key: String,
    val upstreamKey: String? = null,
    val name: String,
    val kind: SourceKind,
    val origin: SourceOrigin,
    val api: String,
    val status: EntryStatus,
    val className: String? = null,
    val jarSource: String? = null,
    val jarMd5: String? = null,
    val jarSha256: String? = null,
    val secretRef: String? = null,
    val extDigest: String? = null,
    val searchable: Boolean = true,
    val hidden: Boolean = false,
    val specFingerprint: String,
)

@Serializable
data class CatalogSnapshot(
    val schemaVersion: Int = CURRENT_SCHEMA_VERSION,
    val catalogVersion: String,
    val createdAt: String,
    val activatedAt: String,
    val aggregator: SnapshotAggregator,
    val entries: List<SnapshotEntry>,
) {
    companion object {
        const val CURRENT_SCHEMA_VERSION = 1
    }
}

enum class SnapshotRecoverySource {
    CURRENT,
    PREVIOUS,
}

data class RecoveredCatalogSnapshot(
    val snapshot: CatalogSnapshot,
    val identityMap: Map<CatalogIdentity, String>,
    val source: SnapshotRecoverySource,
)

@Serializable
private data class SnapshotPointer(
    val schemaVersion: Int = CatalogSnapshot.CURRENT_SCHEMA_VERSION,
    val catalogVersion: String,
)

@Serializable
private data class IdentityMapFile(
    val schemaVersion: Int = CatalogSnapshot.CURRENT_SCHEMA_VERSION,
    val entries: List<IdentityMapEntry>,
)

@Serializable
private data class IdentityMapEntry(
    val upstreamKey: String,
    val api: String,
    val jarReference: String? = null,
    val catalogKey: String,
)

class CatalogSnapshotStore(
    private val root: Path,
    private val retention: Int = 2,
) {
    private val commitLock = Any()
    private val json = Json {
        prettyPrint = true
        ignoreUnknownKeys = true
        explicitNulls = false
    }

    init {
        require(retention >= 2) { "snapshot retention must be at least 2" }
        Files.createDirectories(root.resolve("versions"))
    }

    fun commit(snapshot: CatalogSnapshot, identityMap: Map<CatalogIdentity, String>) {
        require(snapshot.schemaVersion == CatalogSnapshot.CURRENT_SCHEMA_VERSION) {
            "unsupported catalog snapshot schema"
        }
        require(snapshot.catalogVersion.matches(VERSION_PATTERN)) { "invalid catalog version" }
        synchronized(commitLock) {
            val versionDirectory = root.resolve("versions").resolve(snapshot.catalogVersion)
            Files.createDirectories(versionDirectory)
            val identityFile = identityMap.toFile()
            atomicJson(versionDirectory.resolve("catalog.json"), snapshot)
            atomicJson(versionDirectory.resolve("identity-map.json"), identityFile)

            val current = root.resolve("current.json")
            if (Files.isRegularFile(current)) {
                atomicWrite(root.resolve("previous.json"), Files.readAllBytes(current))
            }
            atomicJson(root.resolve("identity-map.json"), identityFile)
            atomicJson(current, SnapshotPointer(catalogVersion = snapshot.catalogVersion))
            cleanupVersions()
        }
    }

    fun recover(): RecoveredCatalogSnapshot? = synchronized(commitLock) {
        recoverFrom(root.resolve("current.json"), SnapshotRecoverySource.CURRENT)
            ?: recoverFrom(root.resolve("previous.json"), SnapshotRecoverySource.PREVIOUS)
    }

    fun retainedSnapshots(): List<CatalogSnapshot> = synchronized(commitLock) {
        listOfNotNull(
            recoverFrom(root.resolve("current.json"), SnapshotRecoverySource.CURRENT)?.snapshot,
            recoverFrom(root.resolve("previous.json"), SnapshotRecoverySource.PREVIOUS)?.snapshot,
        ).distinctBy(CatalogSnapshot::catalogVersion)
    }

    private fun recoverFrom(
        pointerPath: Path,
        source: SnapshotRecoverySource,
    ): RecoveredCatalogSnapshot? = runCatching {
        val pointer = decode<SnapshotPointer>(pointerPath)
        require(pointer.schemaVersion == CatalogSnapshot.CURRENT_SCHEMA_VERSION)
        require(pointer.catalogVersion.matches(VERSION_PATTERN))
        val versionDirectory = root.resolve("versions").resolve(pointer.catalogVersion)
        val snapshot = decode<CatalogSnapshot>(versionDirectory.resolve("catalog.json"))
        require(snapshot.schemaVersion == CatalogSnapshot.CURRENT_SCHEMA_VERSION)
        require(snapshot.catalogVersion == pointer.catalogVersion)
        val identityFile = decode<IdentityMapFile>(versionDirectory.resolve("identity-map.json"))
        require(identityFile.schemaVersion == CatalogSnapshot.CURRENT_SCHEMA_VERSION)
        RecoveredCatalogSnapshot(
            snapshot = snapshot,
            identityMap = identityFile.entries.associate { entry ->
                CatalogIdentity(
                    upstreamKey = entry.upstreamKey,
                    api = entry.api,
                    jarReference = entry.jarReference,
                ) to entry.catalogKey
            },
            source = source,
        )
    }.getOrNull()

    private fun cleanupVersions() {
        val versionsRoot = root.resolve("versions")
        val protected = listOf("current.json", "previous.json").mapNotNull { name ->
            runCatching { decode<SnapshotPointer>(root.resolve(name)).catalogVersion }.getOrNull()
        }.toSet()
        val directories = Files.list(versionsRoot).use { stream ->
            stream.filter(Files::isDirectory)
                .sorted(
                    compareByDescending<Path> {
                        runCatching { Files.getLastModifiedTime(it) }
                            .getOrDefault(FileTime.fromMillis(0))
                    },
                )
                .toList()
        }
        val keep = protected + directories.take(retention).map { it.fileName.toString() }
        directories.filter { it.fileName.toString() !in keep }.forEach(::deleteVersionDirectory)
    }

    private fun deleteVersionDirectory(directory: Path) {
        Files.list(directory).use { paths -> paths.forEach(Files::deleteIfExists) }
        Files.deleteIfExists(directory)
    }

    private inline fun <reified T> decode(path: Path): T {
        if (!Files.isRegularFile(path)) throw SerializationException("snapshot file missing")
        return json.decodeFromString(Files.readString(path, StandardCharsets.UTF_8))
    }

    private inline fun <reified T> atomicJson(path: Path, value: T) {
        atomicWrite(path, json.encodeToString(value).toByteArray(StandardCharsets.UTF_8))
    }

    private fun Map<CatalogIdentity, String>.toFile(): IdentityMapFile = IdentityMapFile(
        entries = entries
            .sortedBy(Map.Entry<CatalogIdentity, String>::value)
            .map { (identity, catalogKey) ->
                IdentityMapEntry(
                    upstreamKey = identity.upstreamKey,
                    api = identity.api,
                    jarReference = identity.jarReference,
                    catalogKey = catalogKey,
                )
            },
    )

    private companion object {
        val VERSION_PATTERN = Regex("[A-Za-z0-9._-]{1,128}")
    }
}
