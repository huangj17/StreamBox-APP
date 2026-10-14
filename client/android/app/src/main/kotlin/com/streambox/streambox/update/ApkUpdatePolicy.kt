package com.streambox.streambox.update

import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipFile

data class ApkIdentity(
    val packageName: String,
    val versionName: String,
    val versionCode: Long,
    val certificates: Set<String>,
    val minSdk: Int = 1,
)

data class UpdateExpectation(
    val packageName: String,
    val versionName: String,
    val versionCode: Long,
    val size: Long,
    val sha256: String,
    val certificateSha256: String,
)

/** Android-independent checks, also exercised by the JVM unit tests. */
object ApkUpdatePolicy {
    const val MAX_APK_BYTES = 512L * 1024 * 1024

    fun verifyFile(root: File, file: File, expected: UpdateExpectation): File {
        val canonical = file.canonicalFile
        require(canonical.path.startsWith(root.canonicalPath + File.separator)) {
            "安装包必须位于应用更新缓存中"
        }
        require(canonical.isFile && canonical.extension == "apk") { "安装包不存在，请重新下载" }
        require(expected.size in 1..MAX_APK_BYTES && canonical.length() == expected.size) {
            "安装包大小校验失败，请重新下载"
        }
        require(expected.sha256.matches(Regex("[a-f0-9]{64}"))) { "安装包校验信息无效" }
        val hash = MessageDigest.getInstance("SHA-256")
        canonical.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                hash.update(buffer, 0, count)
            }
        }
        require(hex(hash.digest()) == expected.sha256) { "安装包校验失败，请重新下载" }
        return canonical
    }

    fun verifyIdentity(
        installed: ApkIdentity,
        archive: ApkIdentity,
        expected: UpdateExpectation,
        sdkInt: Int,
    ) {
        require(archive.packageName == installed.packageName && archive.packageName == expected.packageName) {
            "更新包与当前应用不匹配"
        }
        require(archive.versionCode == expected.versionCode && archive.versionName == expected.versionName) {
            "安装包版本与发布信息不一致"
        }
        require(archive.versionCode > installed.versionCode) { "只能安装比当前更新的版本" }
        require(archive.minSdk <= sdkInt) { "新版本不支持当前 Android 系统" }
        // The release workflow pins one persistent certificate. Key rotation is
        // intentionally unsupported until both publishing and update policy support it.
        require(archive.certificates == setOf(expected.certificateSha256) &&
            archive.certificates == installed.certificates) {
            "发布签名与当前应用不同，无法覆盖安装"
        }
    }

    fun verifyAbi(file: File, supportedAbis: List<String>) {
        val packaged = ZipFile(file).use { zip ->
            zip.entries().asSequence()
                .mapNotNull { Regex("lib/([^/]+)/libflutter\\.so").matchEntire(it.name)?.groupValues?.get(1) }
                .toSet()
        }
        require(supportedAbis.any { it in packaged }) { "安装包不支持当前设备架构" }
    }

    fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it.toInt() and 0xff) }
}
