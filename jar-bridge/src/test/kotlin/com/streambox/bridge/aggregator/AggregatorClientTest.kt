package com.streambox.bridge.aggregator

import com.streambox.bridge.config.AggregatorConfig
import com.streambox.bridge.security.RemoteTargetPolicy
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.runBlocking
import java.net.InetSocketAddress
import java.nio.charset.StandardCharsets
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs

class AggregatorClientTest {
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
    fun `fetch returns aggregator content and response validators`() = runBlocking {
        val content = """{"sites":[{"key":"cms","api":"https://cms.example/api.php"}]}"""
        server.createContext("/") { exchange ->
            val bytes = content.toByteArray(StandardCharsets.UTF_8)
            exchange.responseHeaders.add("Content-Type", "application/json")
            exchange.responseHeaders.add("ETag", "\"config-v1\"")
            exchange.responseHeaders.add("Last-Modified", "Tue, 04 Aug 2026 00:00:00 GMT")
            exchange.sendResponseHeaders(200, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        server.start()
        val baseUrl = "http://127.0.0.1:${server.address.port}/"

        AggregatorClient(
            config = AggregatorConfig(enabled = true, baseUrl = baseUrl),
            environment = emptyMap(),
        ).use { client ->
            val result = assertIs<AggregatorFetchResult.Fetched>(client.fetch())

            assertEquals(content, result.body)
            assertEquals("\"config-v1\"", result.validators.etag)
            assertEquals("Tue, 04 Aug 2026 00:00:00 GMT", result.validators.lastModified)
            assertEquals(baseUrl, result.finalUrl)
        }
    }

    @Test
    fun `conditional fetch returns not modified without a response body`() = runBlocking {
        server.createContext("/") { exchange ->
            assertEquals("\"config-v1\"", exchange.requestHeaders.getFirst("If-None-Match"))
            assertEquals(
                "Tue, 04 Aug 2026 00:00:00 GMT",
                exchange.requestHeaders.getFirst("If-Modified-Since"),
            )
            exchange.responseHeaders.add("ETag", "\"config-v1\"")
            exchange.sendResponseHeaders(304, -1)
            exchange.close()
        }
        server.start()
        val baseUrl = "http://127.0.0.1:${server.address.port}/"
        val previous = FetchValidators(
            etag = "\"config-v1\"",
            lastModified = "Tue, 04 Aug 2026 00:00:00 GMT",
        )

        AggregatorClient(
            config = AggregatorConfig(enabled = true, baseUrl = baseUrl),
            environment = emptyMap(),
        ).use { client ->
            val result = assertIs<AggregatorFetchResult.NotModified>(client.fetch(previous))

            assertEquals("\"config-v1\"", result.validators.etag)
            assertEquals(baseUrl, result.finalUrl)
        }
    }

    @Test
    fun `fetch aborts when the response body exceeds the configured limit`() = runBlocking {
        val content = "0123456789abcdef-too-large"
        server.createContext("/") { exchange ->
            val bytes = content.toByteArray(StandardCharsets.UTF_8)
            exchange.sendResponseHeaders(200, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        server.start()
        val baseUrl = "http://127.0.0.1:${server.address.port}/"

        AggregatorClient(
            config = AggregatorConfig(
                enabled = true,
                baseUrl = baseUrl,
                maxResponseBytes = 16,
            ),
            environment = emptyMap(),
        ).use { client ->
            val error = assertFailsWith<AggregatorFetchException> {
                client.fetch()
            }

            assertEquals("AGGREGATOR_RESPONSE_TOO_LARGE", error.code)
        }
    }

    @Test
    fun `fetch follows relative redirects and reports the final response url`() = runBlocking {
        server.createContext("/") { exchange ->
            exchange.responseHeaders.add("Location", "/step")
            exchange.sendResponseHeaders(302, -1)
            exchange.close()
        }
        server.createContext("/step") { exchange ->
            exchange.responseHeaders.add("Location", "/config")
            exchange.sendResponseHeaders(307, -1)
            exchange.close()
        }
        server.createContext("/config") { exchange ->
            val bytes = "{\"sites\":[]}".toByteArray(StandardCharsets.UTF_8)
            exchange.sendResponseHeaders(200, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        server.start()
        val baseUrl = "http://127.0.0.1:${server.address.port}/"

        AggregatorClient(
            config = AggregatorConfig(enabled = true, baseUrl = baseUrl),
            environment = emptyMap(),
        ).use { client ->
            val result = assertIs<AggregatorFetchResult.Fetched>(client.fetch())

            assertEquals("${baseUrl}config", result.finalUrl)
            assertEquals("{\"sites\":[]}", result.body)
        }
    }

    @Test
    fun `fetch reports a stable timeout error`() = runBlocking {
        server.createContext("/") { exchange ->
            Thread.sleep(200)
            exchange.sendResponseHeaders(200, 0)
            exchange.responseBody.close()
        }
        server.start()
        val baseUrl = "http://127.0.0.1:${server.address.port}/"

        AggregatorClient(
            config = AggregatorConfig(
                enabled = true,
                baseUrl = baseUrl,
                readTimeoutMs = 25,
            ),
            environment = emptyMap(),
        ).use { client ->
            val error = assertFailsWith<AggregatorFetchException> {
                client.fetch()
            }

            assertEquals("AGGREGATOR_TIMEOUT", error.code)
        }
    }

    @Test
    fun `fetch obtains bearer and custom headers only from environment variables`() = runBlocking {
        server.createContext("/") { exchange ->
            assertEquals("Bearer top-secret", exchange.requestHeaders.getFirst("Authorization"))
            assertEquals("tenant-42", exchange.requestHeaders.getFirst("X-Tenant"))
            val bytes = "{\"sites\":[]}".toByteArray(StandardCharsets.UTF_8)
            exchange.sendResponseHeaders(200, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        server.start()

        AggregatorClient(
            config = AggregatorConfig(
                enabled = true,
                baseUrl = "http://127.0.0.1:${server.address.port}/",
                tokenEnv = "AGGREGATOR_TOKEN",
                headersFromEnv = mapOf("X-Tenant" to "AGGREGATOR_TENANT"),
            ),
            environment = mapOf(
                "AGGREGATOR_TOKEN" to "top-secret",
                "AGGREGATOR_TENANT" to "tenant-42",
            ),
        ).use { client ->
            assertIs<AggregatorFetchResult.Fetched>(client.fetch())
        }
        Unit
    }

    @Test
    fun `fetch maps non successful responses to a stable error`() = runBlocking {
        server.createContext("/") { exchange ->
            exchange.sendResponseHeaders(503, -1)
            exchange.close()
        }
        server.start()

        AggregatorClient(
            config = AggregatorConfig(
                enabled = true,
                baseUrl = "http://127.0.0.1:${server.address.port}/",
            ),
            environment = emptyMap(),
        ).use { client ->
            val error = assertFailsWith<AggregatorFetchException> { client.fetch() }

            assertEquals("AGGREGATOR_HTTP_ERROR", error.code)
        }
    }

    @Test
    fun `fetch follows at most three redirects`() = runBlocking {
        server.createContext("/") { exchange ->
            val step = exchange.requestURI.path.removePrefix("/").toIntOrNull() ?: 0
            exchange.responseHeaders.add("Location", "/${step + 1}")
            exchange.sendResponseHeaders(302, -1)
            exchange.close()
        }
        server.start()

        AggregatorClient(
            config = AggregatorConfig(
                enabled = true,
                baseUrl = "http://127.0.0.1:${server.address.port}/0",
            ),
            environment = emptyMap(),
        ).use { client ->
            val error = assertFailsWith<AggregatorFetchException> { client.fetch() }

            assertEquals("AGGREGATOR_TOO_MANY_REDIRECTS", error.code)
        }
    }

    @Test
    fun `remote target policy rejects loopback by default`() = runBlocking {
        server.createContext("/") { exchange ->
            exchange.sendResponseHeaders(200, -1)
            exchange.close()
        }
        server.start()

        AggregatorClient(
            config = AggregatorConfig(
                enabled = true,
                baseUrl = "http://127.0.0.1:${server.address.port}/",
            ),
            environment = emptyMap(),
            remoteTargetPolicy = RemoteTargetPolicy(),
        ).use { client ->
            val error = assertFailsWith<AggregatorFetchException> { client.fetch() }

            assertEquals("REMOTE_TARGET_FORBIDDEN", error.code)
        }
    }

    @Test
    fun `cross origin redirect does not forward aggregator credentials`() = runBlocking {
        val redirected = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        try {
            server.createContext("/") { exchange ->
                exchange.responseHeaders.add(
                    "Location",
                    "http://127.0.0.1:${redirected.address.port}/config",
                )
                exchange.sendResponseHeaders(302, -1)
                exchange.close()
            }
            redirected.createContext("/config") { exchange ->
                assertEquals(null, exchange.requestHeaders.getFirst("Authorization"))
                assertEquals(null, exchange.requestHeaders.getFirst("X-Tenant"))
                val bytes = "{\"sites\":[]}".toByteArray(StandardCharsets.UTF_8)
                exchange.sendResponseHeaders(200, bytes.size.toLong())
                exchange.responseBody.use { it.write(bytes) }
            }
            server.start()
            redirected.start()

            AggregatorClient(
                config = AggregatorConfig(
                    enabled = true,
                    baseUrl = "http://127.0.0.1:${server.address.port}/",
                    tokenEnv = "TOKEN",
                    headersFromEnv = mapOf("X-Tenant" to "TENANT"),
                ),
                environment = mapOf("TOKEN" to "secret", "TENANT" to "tenant"),
                remoteTargetPolicy = RemoteTargetPolicy(setOf("127.0.0.1")),
            ).use { client ->
                assertIs<AggregatorFetchResult.Fetched>(client.fetch())
            }
        } finally {
            redirected.stop(0)
        }
        Unit
    }
}
