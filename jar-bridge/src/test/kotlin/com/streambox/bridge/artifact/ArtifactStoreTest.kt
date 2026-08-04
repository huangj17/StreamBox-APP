package com.streambox.bridge.artifact

import com.streambox.bridge.security.RemoteTargetPolicy
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.runBlocking
import java.io.ByteArrayOutputStream
import java.net.InetSocketAddress
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicInteger
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class ArtifactStoreTest {
    private lateinit var server: HttpServer

    @BeforeTest
    fun startServer() {
        server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
    }

    @AfterTest
    fun stopServer() {
        server.stop(0)
    }

    @Test
    fun `prepare downloads inspects and content addresses a jvm jar then reuses it`() = runBlocking {
        val requests = AtomicInteger()
        val jar = jvmJarBytes()
        server.createContext("/demo.jar") { exchange ->
            requests.incrementAndGet()
            exchange.sendResponseHeaders(200, jar.size.toLong())
            exchange.responseBody.use { it.write(jar) }
        }
        server.start()
        val root = createTempDirectory("artifact-store-test")
        val reference = JarReferenceParser.parse(
            "http://127.0.0.1:${server.address.port}/demo.jar",
        )

        ArtifactStore(
            root = root,
            remoteTargetPolicy = RemoteTargetPolicy(setOf("127.0.0.1")),
        ).use { store ->
            val first = store.prepare(reference, "csp_Demo")
            val second = store.prepare(reference, "csp_Demo")

            assertEquals(first.sha256, second.sha256)
            assertEquals("com.github.catvod.spider.Demo", first.className)
            assertEquals(JarPackageType.JVM, first.inspection.packageType)
            assertTrue(Files.isRegularFile(first.path))
            assertTrue(first.path.toString().contains("artifacts/sha256/${first.sha256}.jar"))
            assertEquals(1, requests.get())
        }
    }

    @Test
    fun `declared md5 mismatch fails and removes partial downloads`() = runBlocking {
        val jar = jvmJarBytes()
        server.createContext("/bad.jar") { exchange ->
            exchange.sendResponseHeaders(200, jar.size.toLong())
            exchange.responseBody.use { it.write(jar) }
        }
        server.start()
        val root = createTempDirectory("artifact-md5-test")
        val reference = JarReferenceParser.parse(
            "http://127.0.0.1:${server.address.port}/bad.jar;md5;00000000000000000000000000000000",
        )

        ArtifactStore(
            root = root,
            remoteTargetPolicy = RemoteTargetPolicy(setOf("127.0.0.1")),
        ).use { store ->
            val error = assertFailsWith<ArtifactException> {
                store.prepare(reference, "csp_Demo")
            }

            assertEquals("JAR_MD5_MISMATCH", error.code)
            assertEquals(0, Files.list(root.resolve("tmp")).use { it.count() })
        }
    }

    @Test
    fun `cleanup never removes protected snapshot artifacts`() {
        val root = createTempDirectory("artifact-cleanup-test")
        val shaRoot = root.resolve("artifacts/sha256")
        Files.createDirectories(shaRoot)
        val retained = "a".repeat(64)
        val obsolete = "b".repeat(64)
        Files.write(shaRoot.resolve("$retained.jar"), byteArrayOf(1))
        Files.write(shaRoot.resolve("$obsolete.jar"), byteArrayOf(2))

        ArtifactStore(
            root = root,
            remoteTargetPolicy = RemoteTargetPolicy(),
        ).use { store ->
            assertEquals(1, store.cleanupUnreferenced(setOf(retained)))
        }

        assertTrue(Files.isRegularFile(shaRoot.resolve("$retained.jar")))
        assertTrue(Files.notExists(shaRoot.resolve("$obsolete.jar")))
    }
}

private fun jvmJarBytes(): ByteArray = ByteArrayOutputStream().use { output ->
    ZipOutputStream(output).use { zip ->
        zip.putNextEntry(ZipEntry("com/github/catvod/spider/Demo.class"))
        zip.write(byteArrayOf(0xCA.toByte(), 0xFE.toByte()))
        zip.closeEntry()
    }
    output.toByteArray()
}
