package com.streambox.bridge.storage

import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermission
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

data class SecretRecord(
    val ref: String,
    val extDigest: String,
)

class SecretStoreException(
    val code: String,
    message: String,
    cause: Throwable? = null,
) : IllegalStateException(message, cause)

class SecretStore(
    private val root: Path,
    secretKeyEnv: String = "BRIDGE_SECRET_KEY",
    environment: Map<String, String> = System.getenv(),
    private val secureRandom: SecureRandom = SecureRandom(),
) {
    private val key: ByteArray

    init {
        Files.createDirectories(root)
        key = environment[secretKeyEnv]
            ?.takeIf(String::isNotBlank)
            ?.let(::decodeMasterKey)
            ?: loadOrCreateLocalKey()
    }

    fun write(value: String, existing: SecretRecord? = null): SecretRecord {
        val digest = digest(value)
        if (
            existing?.extDigest == digest &&
            Files.isRegularFile(secretPath(existing.ref))
        ) {
            return existing
        }

        val ref = UUID.randomUUID().toString()
        val nonce = ByteArray(NONCE_BYTES).also(secureRandom::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.ENCRYPT_MODE,
            SecretKeySpec(key, "AES"),
            GCMParameterSpec(GCM_TAG_BITS, nonce),
        )
        val encrypted = cipher.doFinal(value.toByteArray(StandardCharsets.UTF_8))
        val payload = ByteBuffer.allocate(MAGIC.size + 1 + nonce.size + encrypted.size)
            .put(MAGIC)
            .put(FORMAT_VERSION)
            .put(nonce)
            .put(encrypted)
            .array()
        atomicWrite(secretPath(ref), payload)
        return SecretRecord(ref = ref, extDigest = digest)
    }

    fun read(ref: String): String {
        val path = secretPath(ref)
        val payload = try {
            Files.readAllBytes(path)
        } catch (error: Exception) {
            throw SecretStoreException(
                code = "SECRET_NOT_FOUND",
                message = "Secret is unavailable",
                cause = error,
            )
        }
        if (
            payload.size < MAGIC.size + 1 + NONCE_BYTES + GCM_TAG_BYTES ||
            !payload.copyOfRange(0, MAGIC.size).contentEquals(MAGIC) ||
            payload[MAGIC.size] != FORMAT_VERSION
        ) {
            throw SecretStoreException(
                code = "SECRET_FORMAT_INVALID",
                message = "Secret data has an invalid format",
            )
        }
        val nonceStart = MAGIC.size + 1
        val nonce = payload.copyOfRange(nonceStart, nonceStart + NONCE_BYTES)
        val encrypted = payload.copyOfRange(nonceStart + NONCE_BYTES, payload.size)
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                Cipher.DECRYPT_MODE,
                SecretKeySpec(key, "AES"),
                GCMParameterSpec(GCM_TAG_BITS, nonce),
            )
            String(cipher.doFinal(encrypted), StandardCharsets.UTF_8)
        } catch (error: AEADBadTagException) {
            throw SecretStoreException(
                code = "SECRET_DECRYPT_FAILED",
                message = "Secret could not be decrypted",
                cause = error,
            )
        }
    }

    fun deleteUnreferenced(referenced: Set<String>): Int {
        if (!Files.isDirectory(root)) return 0
        var deleted = 0
        Files.list(root).use { paths ->
            paths.filter { path ->
                path.fileName.toString().endsWith(".bin") &&
                    path.fileName.toString().removeSuffix(".bin") !in referenced
            }.forEach { path ->
                if (Files.deleteIfExists(path)) deleted += 1
            }
        }
        return deleted
    }

    private fun loadOrCreateLocalKey(): ByteArray {
        val keyPath = root.resolve("master.key")
        if (Files.exists(keyPath)) {
            return decodeMasterKey(Files.readString(keyPath, StandardCharsets.US_ASCII).trim())
        }
        val generated = ByteArray(KEY_BYTES).also(secureRandom::nextBytes)
        atomicWrite(
            keyPath,
            Base64.getEncoder().encodeToString(generated).toByteArray(StandardCharsets.US_ASCII),
        )
        runCatching {
            Files.setPosixFilePermissions(
                keyPath,
                setOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE),
            )
        }
        return generated
    }

    private fun decodeMasterKey(value: String): ByteArray {
        val decoded = try {
            Base64.getDecoder().decode(value)
        } catch (error: IllegalArgumentException) {
            throw SecretStoreException(
                code = "SECRET_KEY_INVALID",
                message = "Secret master key must be valid Base64",
                cause = error,
            )
        }
        if (decoded.size != KEY_BYTES) {
            throw SecretStoreException(
                code = "SECRET_KEY_INVALID",
                message = "Secret master key must decode to $KEY_BYTES bytes",
            )
        }
        return decoded
    }

    private fun secretPath(ref: String): Path {
        if (!ref.matches(Regex("[0-9a-fA-F-]{36}"))) {
            throw SecretStoreException(
                code = "SECRET_REF_INVALID",
                message = "Secret reference is invalid",
            )
        }
        return root.resolve("$ref.bin")
    }

    companion object {
        private val MAGIC = byteArrayOf('S'.code.toByte(), 'B'.code.toByte(), 'S'.code.toByte(), 'E'.code.toByte())
        private const val FORMAT_VERSION: Byte = 1
        private const val KEY_BYTES = 32
        private const val NONCE_BYTES = 12
        private const val GCM_TAG_BITS = 128
        private const val GCM_TAG_BYTES = GCM_TAG_BITS / 8

        fun digest(value: String): String = MessageDigest
            .getInstance("SHA-256")
            .digest(value.toByteArray(StandardCharsets.UTF_8))
            .joinToString(separator = "") { byte -> "%02x".format(byte) }
    }
}
