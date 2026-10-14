package com.streambox.streambox.update

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class ApkUpdatePolicyTest {
    private val certificate = "ab".repeat(32)
    private val installed = ApkIdentity("com.streambox.streambox", "0.4.0", 4, setOf(certificate), 23)
    private val archive = installed.copy(versionName = "0.4.1", versionCode = 5)
    private val expected = UpdateExpectation(archive.packageName, archive.versionName, 5, 3, "cd".repeat(32), certificate)

    private fun rejects(action: () -> Unit) {
        try { action(); fail("unsafe update accepted") } catch (_: IllegalArgumentException) {}
    }

    @Test fun acceptsOnlyNewerVersionsOfTheSameSignedApp() {
        ApkUpdatePolicy.verifyIdentity(installed, archive, expected, 30)
        rejects { ApkUpdatePolicy.verifyIdentity(installed, archive.copy(packageName = "other.app"), expected, 30) }
        rejects { ApkUpdatePolicy.verifyIdentity(installed, archive.copy(versionCode = 4), expected.copy(versionCode = 4), 30) }
        rejects { ApkUpdatePolicy.verifyIdentity(installed, archive.copy(versionName = "wrong"), expected, 30) }
        rejects { ApkUpdatePolicy.verifyIdentity(installed, archive.copy(certificates = setOf("ef".repeat(32))), expected, 30) }
        rejects { ApkUpdatePolicy.verifyIdentity(installed, archive.copy(minSdk = 31), expected, 30) }
    }

    @Test fun checksCanonicalPathExactSizeAndHash() {
        val directory = Files.createTempDirectory("apk-policy").toFile()
        try {
            val root = File(directory, "updates").apply { mkdirs() }
            val file = File(root, "update.apk").apply { writeBytes(byteArrayOf(1, 2, 3)) }
            val digest = ApkUpdatePolicy.hex(MessageDigest.getInstance("SHA-256").digest(file.readBytes()))
            val pinned = expected.copy(sha256 = digest)
            assertEquals(file.canonicalFile, ApkUpdatePolicy.verifyFile(root, file, pinned))
            rejects { ApkUpdatePolicy.verifyFile(root, file, pinned.copy(size = 4)) }
            rejects { ApkUpdatePolicy.verifyFile(root, file, expected) }
            val outside = File(directory, "outside.apk").apply { writeBytes(file.readBytes()) }
            rejects { ApkUpdatePolicy.verifyFile(root, outside, pinned) }
            val symlink = File(root, "linked.apk")
            Files.createSymbolicLink(symlink.toPath(), outside.toPath())
            rejects { ApkUpdatePolicy.verifyFile(root, symlink, pinned) }
        } finally { directory.deleteRecursively() }
    }

    @Test fun rejectsApksWithoutADeviceCompatibleFlutterEngine() {
        val file = Files.createTempFile("abi-policy", ".apk").toFile()
        try {
            ZipOutputStream(file.outputStream()).use { zip ->
                zip.putNextEntry(ZipEntry("lib/arm64-v8a/libflutter.so"))
                zip.write(byteArrayOf(1))
                zip.closeEntry()
            }
            ApkUpdatePolicy.verifyAbi(file, listOf("arm64-v8a"))
            rejects { ApkUpdatePolicy.verifyAbi(file, listOf("armeabi-v7a")) }
        } finally { file.delete() }
    }
}
