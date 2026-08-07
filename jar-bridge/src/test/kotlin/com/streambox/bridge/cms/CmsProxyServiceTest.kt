package com.streambox.bridge.cms

import com.streambox.bridge.catalog.SourceHandler
import com.streambox.bridge.security.RemoteTargetPolicy
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.runBlocking
import okhttp3.HttpUrl.Companion.toHttpUrl
import java.net.InetSocketAddress
import java.nio.charset.StandardCharsets
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class CmsProxyServiceTest {
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
    fun `class request probes class then list dialect and accepts a wrong content type`() =
        runBlocking {
            val queries = CopyOnWriteArrayList<String>()
            server.createContext("/api.php") { exchange ->
                val query = exchange.requestURI.rawQuery
                queries += query
                val body = if (query.contains("ac=class")) {
                    "{\"message\":\"unsupported\"}"
                } else {
                    "{\"class\":[]}"
                }
                val bytes = body.toByteArray(StandardCharsets.UTF_8)
                exchange.responseHeaders.add("Content-Type", "text/plain")
                exchange.sendResponseHeaders(200, bytes.size.toLong())
                exchange.responseBody.use { it.write(bytes) }
            }
            server.start()
            val target = "http://127.0.0.1:${server.address.port}/api.php".toHttpUrl()

            CmsProxyService().use { service ->
                val result = service.execute(
                    handler = SourceHandler.Cms(target),
                    catalogVersion = "v1",
                    entryKey = "cms",
                    query = listOf("ac" to "class"),
                )

                assertEquals("{\"class\":[]}", result)
                assertEquals(listOf("ac=class", "ac=list"), queries.toList())
            }
        }

    @Test
    fun `cms requests are rejected by the shared remote target policy`() = runBlocking {
        server.createContext("/api.php") { exchange ->
            exchange.sendResponseHeaders(200, -1)
            exchange.close()
        }
        server.start()
        val target = "http://127.0.0.1:${server.address.port}/api.php".toHttpUrl()

        CmsProxyService(remoteTargetPolicy = RemoteTargetPolicy()).use { service ->
            val error = assertFailsWith<CmsProxyException> {
                service.execute(
                    handler = SourceHandler.Cms(target),
                    catalogVersion = "v1",
                    entryKey = "cms",
                    query = listOf("ac" to "class"),
                )
            }

            assertEquals("REMOTE_TARGET_FORBIDDEN", error.code)
        }
    }

    @Test
    fun `cms response is rejected when it exceeds the configured limit`() = runBlocking {
        server.createContext("/api.php") { exchange ->
            val bytes = "{\"value\":\"${"x".repeat(128)}\"}".toByteArray(StandardCharsets.UTF_8)
            exchange.sendResponseHeaders(200, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        server.start()
        val target = "http://127.0.0.1:${server.address.port}/api.php".toHttpUrl()

        CmsProxyService(maxResponseBytes = 64).use { service ->
            val error = assertFailsWith<CmsProxyException> {
                service.execute(
                    handler = SourceHandler.Cms(target),
                    catalogVersion = "v1",
                    entryKey = "cms",
                    query = listOf("ac" to "class"),
                )
            }
            assertEquals("UPSTREAM_RESPONSE_TOO_LARGE", error.code)
        }
    }
}
