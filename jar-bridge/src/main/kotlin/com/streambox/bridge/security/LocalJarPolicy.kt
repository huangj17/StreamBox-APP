package com.streambox.bridge.security

import java.nio.file.Files
import java.nio.file.Path
import java.security.MessageDigest

object LocalJarPolicy {
    fun resolve(candidate: Path, pluginsRoot: Path = Path.of("plugins")): Path {
        val root = pluginsRoot.toAbsolutePath().normalize()
        val normalized = candidate.toAbsolutePath().normalize()
        if (!normalized.startsWith(root)) {
            throw SecurityException("Manual JAR path escapes the plugins root")
        }
        if (!Files.isRegularFile(normalized)) {
            throw IllegalArgumentException("Manual JAR does not exist")
        }
        val realRoot = root.toRealPath()
        val realCandidate = normalized.toRealPath()
        if (!realCandidate.startsWith(realRoot)) {
            throw SecurityException("Manual JAR symlink escapes the plugins root")
        }
        return realCandidate
    }

    fun resolveAndVerify(
        candidate: Path,
        expectedSha256: String,
        pluginsRoot: Path = Path.of("plugins"),
    ): Path {
        require(expectedSha256.matches(Regex("^[a-f0-9]{64}$"))) {
            "A lowercase SHA-256 digest is required for every plugin JAR"
        }
        val resolved = resolve(candidate, pluginsRoot)
        val digest = MessageDigest.getInstance("SHA-256")
        Files.newInputStream(resolved).use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        if (!MessageDigest.isEqual(
                actual.toByteArray(Charsets.US_ASCII),
                expectedSha256.toByteArray(Charsets.US_ASCII),
            )
        ) {
            throw SecurityException("Plugin JAR SHA-256 mismatch")
        }
        return resolved
    }
}
