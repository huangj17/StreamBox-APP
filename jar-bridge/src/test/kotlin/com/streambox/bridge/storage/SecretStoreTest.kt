package com.streambox.bridge.storage

import java.nio.file.Files
import java.util.Base64
import kotlin.io.path.createTempDirectory
import kotlin.io.path.readBytes
import kotlin.io.path.writeBytes
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SecretStoreTest {
    @Test
    fun `secret is encrypted on disk and decrypts with the configured master key`() {
        val root = createTempDirectory("secret-store-test")
        val encodedKey = Base64.getEncoder().encodeToString(ByteArray(32) { it.toByte() })
        val store = SecretStore(
            root = root,
            secretKeyEnv = "TEST_SECRET_KEY",
            environment = mapOf("TEST_SECRET_KEY" to encodedKey),
        )

        val secret = store.write("{\"token\":\"plain-secret\"}")

        assertEquals("{\"token\":\"plain-secret\"}", store.read(secret.ref))
        val storedBytes = root.resolve("${secret.ref}.bin").readBytes()
        assertFalse(storedBytes.toString(Charsets.UTF_8).contains("plain-secret"))
        assertEquals(64, secret.extDigest.length)
        assertEquals(1, Files.list(root).use { it.count() })
    }

    @Test
    fun `unchanged digest reuses its existing secret reference`() {
        val root = createTempDirectory("secret-reuse-test")
        val store = SecretStore(root = root, environment = emptyMap())

        val first = store.write("same-ext")
        val second = store.write("same-ext", existing = first)

        assertEquals(first, second)
        assertEquals(2, Files.list(root).use { it.count() })
    }

    @Test
    fun `tampered ciphertext fails without exposing the secret`() {
        val root = createTempDirectory("secret-tamper-test")
        val store = SecretStore(root = root, environment = emptyMap())
        val secret = store.write("do-not-expose")
        val path = root.resolve("${secret.ref}.bin")
        val tampered = path.readBytes().also { it[it.lastIndex] = (it.last() + 1).toByte() }
        path.writeBytes(tampered)

        val error = assertFailsWith<SecretStoreException> { store.read(secret.ref) }

        assertEquals("SECRET_DECRYPT_FAILED", error.code)
        assertFalse(error.message.orEmpty().contains("do-not-expose"))
    }

    @Test
    fun `cleanup removes only unreferenced encrypted values`() {
        val root = createTempDirectory("secret-cleanup-test")
        val store = SecretStore(root = root, environment = emptyMap())
        val retained = store.write("retained")
        val obsolete = store.write("obsolete")

        assertEquals(1, store.deleteUnreferenced(setOf(retained.ref)))

        assertEquals("retained", store.read(retained.ref))
        assertTrue(Files.notExists(root.resolve("${obsolete.ref}.bin")))
    }

    @Test
    fun `wrong master key cannot decrypt an existing secret`() {
        val root = createTempDirectory("secret-wrong-key-test")
        val firstKey = Base64.getEncoder().encodeToString(ByteArray(32) { 1 })
        val secondKey = Base64.getEncoder().encodeToString(ByteArray(32) { 2 })
        val secret = SecretStore(
            root = root,
            secretKeyEnv = "KEY",
            environment = mapOf("KEY" to firstKey),
        ).write("sensitive")

        val wrongStore = SecretStore(
            root = root,
            secretKeyEnv = "KEY",
            environment = mapOf("KEY" to secondKey),
        )
        val error = assertFailsWith<SecretStoreException> { wrongStore.read(secret.ref) }

        assertEquals("SECRET_DECRYPT_FAILED", error.code)
        assertFalse(error.message.orEmpty().contains("sensitive"))
    }
}
