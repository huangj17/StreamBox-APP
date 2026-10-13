package com.streambox.streambox.spider

import android.content.Context
import android.os.Process
import dalvik.system.DexClassLoader
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URI
import java.security.MessageDigest
import java.util.zip.ZipFile

data class ArtifactDeclaration(val url: String, val md5: String?) {
    companion object {
        fun parse(raw: String): ArtifactDeclaration {
            val parts = raw.split(';')
            require(parts.size == 1 || (parts.size == 3 && parts[1].lowercase() == "md5")) { "插件校验格式无效" }
            val uri = URI(parts[0])
            require(uri.scheme in setOf("http", "https") && !uri.host.isNullOrEmpty() && uri.userInfo == null && uri.fragment == null) { "插件地址必须为 HTTP(S)" }
            val md5 = parts.getOrNull(2)?.lowercase()
            require(md5 == null || md5.matches(Regex("[a-f0-9]{32}"))) { "插件 MD5 无效" }
            return ArtifactDeclaration(parts[0], md5)
        }
    }
}

data class PluginBundle(val loader: DexClassLoader, val file: File, val digest: String)

/** Read-only DEX cache, declared MD5 validation, and ABI-specific JNI extraction. */
class ArtifactStore(
    private val context: Context,
    private val fetch: (String) -> InputStream = { PluginNetwork.open(it).inputStream },
) {
    private val root = File(context.codeCacheDir, "spider").apply { mkdirs() }
    private val bundles = mutableMapOf<String, PluginBundle>()

    @Synchronized fun load(raw: String): PluginBundle {
        val spec = ArtifactDeclaration.parse(raw)
        val key = digest("SHA-256", raw.toByteArray())
        val folder = File(root, key).apply { mkdirs() }
        val archive = File(folder, "plugin.jar")
        val intact = archive.isFile && (spec.md5 == null || digestFile("MD5", archive) == spec.md5)
        val fresh = intact && (spec.md5 != null || System.currentTimeMillis() - archive.lastModified() < 30 * 60 * 1000)
        if (!fresh) {
            val temporary = File.createTempFile("download-", ".jar", folder)
            try {
                temporary.outputStream().use { output ->
                    check(temporary.setReadOnly()) { "无法保护插件缓存" }
                    fetch(spec.url).use { input -> copyBounded(input, output, 64L * 1024 * 1024) }
                }
                check(spec.md5 == null || digestFile("MD5", temporary) == spec.md5) { "插件 MD5 校验失败，未替换已保存版本" }
                ZipFile(temporary).use { zip ->
                    check(zip.getEntry("classes.dex") != null) { "插件不是 Android DEX 包" }
                    zip.entries().asSequence().filter { it.name.endsWith(".dex") }.forEach {
                        check(it.size in 1..(64L * 1024 * 1024)) { "插件 DEX 资源过大" }
                    }
                }
                android.system.Os.rename(temporary.path, archive.path)
            } catch (error: Throwable) {
                temporary.delete()
                // A pin mismatch must never silently activate another artifact.
                if (!archive.isFile || spec.md5 != null) throw error
            }
        }
        check(spec.md5 == null || digestFile("MD5", archive) == spec.md5) { "已保存插件的 MD5 校验失败" }
        val sha = digestFile("SHA-256", archive)
        bundles[sha]?.let { return it }
        val natives = File(folder, "native-$sha").apply { mkdirs() }
        ZipFile(archive).use { zip ->
            var nativeCount = 0
            var matchingCount = 0
            zip.entries().asSequence().filter { it.name.endsWith(".so") }.forEach { entry ->
                nativeCount++
                check(entry.size in 1..(16L * 1024 * 1024)) { "插件原生库过大" }
                val bytes = zip.getInputStream(entry).use { input ->
                    val buffer = java.io.ByteArrayOutputStream()
                    copyBounded(input, buffer, 16L * 1024 * 1024); buffer.toByteArray()
                }
                if (!matchesProcessAbi(bytes)) return@forEach
                matchingCount++
                val name = entry.name.substringAfterLast('/')
                check(name.matches(Regex("[a-zA-Z0-9_.-]+")))
                val file = File(natives, name)
                if (!file.exists()) file.outputStream().use { output ->
                    check(file.setReadOnly()); output.write(bytes)
                }
            }
            check(nativeCount == 0 || matchingCount > 0) { "插件没有当前 Android 设备需要的原生库" }
        }
        val loader = DexClassLoader(archive.path, folder.path, natives.path, SpiderRuntime::class.java.classLoader)
        return PluginBundle(loader, archive, sha).also { bundles[sha] = it }
    }

    companion object {
        fun digest(algorithm: String, bytes: ByteArray): String = MessageDigest.getInstance(algorithm)
            .digest(bytes).joinToString("") { "%02x".format(it) }
        private fun digestFile(algorithm: String, file: File): String {
            val digest = MessageDigest.getInstance(algorithm)
            file.inputStream().use { input ->
                val b = ByteArray(8192)
                while (true) { val n = input.read(b); if (n < 0) break; digest.update(b, 0, n) }
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }
        fun matchesProcessAbi(bytes: ByteArray, is64Bit: Boolean = Process.is64Bit()): Boolean {
            if (bytes.size < 20 || !bytes.copyOfRange(0, 4).contentEquals(byteArrayOf(0x7f, 69, 76, 70))) return false
            val machine = (bytes[18].toInt() and 255) or ((bytes[19].toInt() and 255) shl 8)
            return if (is64Bit) bytes[4].toInt() == 2 && machine == 183
                   else bytes[4].toInt() == 1 && machine == 40
        }
        fun copyBounded(input: InputStream, output: java.io.OutputStream, limit: Long) {
            val b = ByteArray(8192); var total = 0L
            while (true) {
                val n = input.read(b); if (n < 0) break
                total += n; check(total <= limit) { "插件资源超过大小限制" }
                output.write(b, 0, n)
            }
        }
    }
}

object PluginNetwork {
    fun requirePublic(raw: String): URI {
        val uri = URI(raw)
        require(uri.scheme in setOf("http", "https") && !uri.host.isNullOrEmpty() && uri.userInfo == null) { "插件网络地址无效" }
        require(InetAddress.getAllByName(uri.host).all { ip ->
            !ip.isAnyLocalAddress && !ip.isLoopbackAddress && !ip.isLinkLocalAddress && !ip.isSiteLocalAddress && !ip.isMulticastAddress &&
                !(ip.address.size == 4 && (ip.address[0].toInt() and 255) == 100 && (ip.address[1].toInt() and 255) in 64..127)
        }) { "插件资源不能访问本机或私网" }
        return uri
    }
    fun open(raw: String, headers: Map<String, String> = emptyMap()): HttpURLConnection {
        var uri = requirePublic(raw)
        repeat(6) {
            val connection = uri.toURL().openConnection() as HttpURLConnection
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 8_000; connection.readTimeout = 15_000
            headers.forEach { (k, v) -> connection.setRequestProperty(k, v) }
            val status = connection.responseCode
            if (status in 300..399) {
                val next = requirePublic(uri.resolve(connection.getHeaderField("Location") ?: "").toString())
                connection.disconnect()
                check(uri.scheme != "https" || next.scheme == "https") { "插件资源不能降级到 HTTP" }
                uri = next
            } else {
                check(status in 200..299) { "插件资源请求失败：HTTP $status" }
                return connection
            }
        }
        error("插件资源重定向过多")
    }
}
