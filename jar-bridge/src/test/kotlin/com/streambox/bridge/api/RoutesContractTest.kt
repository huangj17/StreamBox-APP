package com.streambox.bridge.api

import com.streambox.bridge.catalog.ActiveCatalog
import com.streambox.bridge.catalog.CatalogEntrySpec
import com.streambox.bridge.catalog.CatalogManager
import com.streambox.bridge.catalog.EntryStatus
import com.streambox.bridge.catalog.RuntimeEntry
import com.streambox.bridge.catalog.SourceHandler
import com.streambox.bridge.catalog.SourceKind
import com.streambox.bridge.catalog.SourceOrigin
import com.streambox.bridge.catalog.SpiderRuntime
import com.streambox.bridge.config.AdminConfig
import com.streambox.bridge.config.BridgeConfig
import com.streambox.bridge.aggregator.AggregatorFetchResult
import com.streambox.bridge.aggregator.AggregatorSource
import com.streambox.bridge.aggregator.FetchValidators
import com.streambox.bridge.module
import com.streambox.bridge.storage.CatalogSnapshotStore
import com.streambox.bridge.sync.SyncCoordinator
import com.sun.net.httpserver.HttpServer
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.server.testing.testApplication
import kotlinx.coroutines.CompletableDeferred
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.time.Instant
import java.net.InetSocketAddress
import java.nio.charset.StandardCharsets
import java.util.HashMap
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

class RoutesContractTest {
    @Test
    fun `api list exposes ready manual entries from the active catalog`() = testApplication {
        val runtime = ContractSpiderRuntime("manual", "Manual")
        val catalogManager = CatalogManager(
            ActiveCatalog(
                version = "manual-v1",
                activatedAt = Instant.parse("2026-08-04T00:00:00Z"),
                entries = mapOf("manual" to readyEntry(runtime)),
            ),
        )
        application {
            module(catalogManager = catalogManager)
        }

        val response = client.get("/api/list")
        val body = Json.parseToJsonElement(response.bodyAsText()).jsonObject
        val source = body.getValue("sources").jsonArray.single().jsonObject

        assertEquals(HttpStatusCode.OK, response.status)
        assertEquals(200, body.getValue("code").jsonPrimitive.content.toInt())
        assertEquals("manual", source.getValue("key").jsonPrimitive.content)
        assertEquals("Manual", source.getValue("name").jsonPrimitive.content)
        assertEquals("/api/manual", source.getValue("api").jsonPrimitive.content)
        assertEquals("manual", source.getValue("kind").jsonPrimitive.content)
        assertEquals("ready", source.getValue("status").jsonPrimitive.content)
        assertNotNull(response.headers["X-Request-Id"])
    }

    @Test
    fun `content endpoint executes the Spider runtime acquired from the catalog`() =
        testApplication {
            val runtime = ContractSpiderRuntime("manual", "Manual")
            val catalogManager = catalogManager(runtime)
            application {
                module(catalogManager = catalogManager)
            }

            val response = client.get("/api/manual?ac=class")
            val body = Json.parseToJsonElement(response.bodyAsText()).jsonObject

            assertEquals(HttpStatusCode.OK, response.status)
            assertEquals(0, body.getValue("class").jsonArray.size)
        }

    @Test
    fun `manual routes preserve v1 category detail search and play dispatch`() =
        testApplication {
            val catalogManager = catalogManager(ContractSpiderRuntime("manual", "Manual"))
            application {
                module(catalogManager = catalogManager)
            }

            val category = client.get("/api/manual?ac=detail&t=movie&pg=2")
            val detail = client.get("/api/manual?ac=detail&ids=video-1")
            val search = client.get("/api/manual?wd=keyword")
            val play = client.get("/api/manual/play?flag=line&id=https://media.example/video.m3u8")

            assertEquals("category", routeMarker(category.bodyAsText()))
            assertEquals("detail", routeMarker(detail.bodyAsText()))
            assertEquals("search", routeMarker(search.bodyAsText()))
            assertEquals("play", routeMarker(play.bodyAsText()))

            val badQuery = client.get("/api/manual?ac=detail")
            val badBody = Json.parseToJsonElement(badQuery.bodyAsText()).jsonObject
            assertEquals(HttpStatusCode.BadRequest, badQuery.status)
            assertEquals("BAD_QUERY", badBody.getValue("error").jsonPrimitive.content)
        }

    @Test
    fun `stopping the application releases active catalog runtimes`() {
        val runtime = ContractSpiderRuntime("manual", "Manual")

        testApplication {
            application {
                module(catalogManager = catalogManager(runtime))
            }
            client.get("/api/list")
        }

        assertEquals(1, runtime.closeCount)
    }

    @Test
    fun `health is error for an empty catalog and ok for a ready manual catalog`() {
        testApplication {
            application { module(catalogManager = CatalogManager()) }
            assertEquals(HttpStatusCode.ServiceUnavailable, client.get("/health").status)
        }

        testApplication {
            application {
                module(catalogManager = catalogManager(ContractSpiderRuntime("manual", "Manual")))
            }
            val response = client.get("/health")
            val body = Json.parseToJsonElement(response.bodyAsText()).jsonObject
            assertEquals(HttpStatusCode.OK, response.status)
            assertEquals("ok", body.getValue("status").jsonPrimitive.content)
        }
    }

    @Test
    fun `cms catalog entry proxies content routes and resolves direct play locally`() {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/api.php") { exchange ->
            val query = exchange.requestURI.rawQuery.orEmpty()
            val route = when {
                query.contains("ids=") -> "detail"
                query.contains("t=") -> "category"
                query.contains("wd=") -> "search"
                else -> "class"
            }
            val body = if (route == "class") {
                "{\"route\":\"class\",\"class\":[]}"
            } else {
                "{\"route\":\"$route\",\"list\":[]}"
            }
            val bytes = body.toByteArray(StandardCharsets.UTF_8)
            exchange.sendResponseHeaders(200, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        server.start()
        try {
            testApplication {
                val cmsEntry = RuntimeEntry(
                    spec = CatalogEntrySpec(
                        key = "cms",
                        name = "CMS",
                        kind = SourceKind.CMS,
                        origin = SourceOrigin.AGGREGATOR,
                        api = "http://127.0.0.1:${server.address.port}/api.php",
                        specFingerprint = "cms-v1",
                    ),
                    status = EntryStatus.READY,
                    handler = SourceHandler.Cms(
                        okhttp3.HttpUrl.Builder()
                            .scheme("http")
                            .host("127.0.0.1")
                            .port(server.address.port)
                            .addPathSegment("api.php")
                            .build(),
                    ),
                )
                application {
                    module(
                        catalogManager = CatalogManager(
                            ActiveCatalog(
                                version = "cms-v1",
                                activatedAt = Instant.parse("2026-08-04T00:00:00Z"),
                                entries = mapOf("cms" to cmsEntry),
                            ),
                        ),
                    )
                }

                assertEquals("class", routeMarker(client.get("/api/cms?ac=class").bodyAsText()))
                assertEquals("category", routeMarker(client.get("/api/cms?t=movie&pg=2").bodyAsText()))
                assertEquals("detail", routeMarker(client.get("/api/cms?ac=detail&ids=v1").bodyAsText()))
                assertEquals("search", routeMarker(client.get("/api/cms?wd=word").bodyAsText()))
                val play = Json.parseToJsonElement(
                    client.get("/api/cms/play?id=https://media.example/video.m3u8").bodyAsText(),
                ).jsonObject
                assertEquals(0, play.getValue("parse").jsonPrimitive.content.toInt())
                assertEquals(
                    "https://media.example/video.m3u8",
                    play.getValue("url").jsonPrimitive.content,
                )
            }
        } finally {
            server.stop(0)
        }
    }

    @Test
    fun `sync status is public and admin sync requires the configured bearer token`() =
        testApplication {
            val source = CountingAggregatorSource()
            val manager = CatalogManager()
            val coordinator = SyncCoordinator(
                source = source,
                catalogManager = manager,
                snapshotStore = CatalogSnapshotStore(createTempDirectory("route-sync-test")),
                manualCatalog = ActiveCatalog.empty(),
                aggregatorBaseUrl = "https://aggregator.example/config.json",
            )
            application {
                module(
                    catalogManager = manager,
                    syncCoordinator = coordinator,
                    config = BridgeConfig(admin = AdminConfig(enabled = true, tokenEnv = "ADMIN")),
                    environment = mapOf("ADMIN" to "secret-token"),
                )
            }

            assertEquals(HttpStatusCode.OK, client.get("/sync/status").status)
            assertEquals(HttpStatusCode.Unauthorized, client.post("/admin/sync").status)
            val authorized = client.post("/admin/sync") {
                header(HttpHeaders.Authorization, "Bearer secret-token")
                setBody("{\"allowEmpty\":false}")
            }

            assertEquals(HttpStatusCode.Accepted, authorized.status)
            assertEquals(1, source.fetchCount)

            repeat(5) {
                assertEquals(
                    HttpStatusCode.Accepted,
                    client.post("/admin/sync") {
                        header(HttpHeaders.Authorization, "Bearer secret-token")
                        setBody("{\"allowEmpty\":false}")
                    }.status,
                )
            }
            assertEquals(
                HttpStatusCode.TooManyRequests,
                client.post("/admin/sync") {
                    header(HttpHeaders.Authorization, "Bearer secret-token")
                    setBody("{\"allowEmpty\":false}")
                }.status,
            )
        }

    @Test
    fun `admin sync returns before fetch completes and reuses the running job`() =
        testApplication {
            val source = RouteBlockingAggregatorSource()
            val manager = CatalogManager()
            val coordinator = SyncCoordinator(
                source = source,
                catalogManager = manager,
                snapshotStore = CatalogSnapshotStore(createTempDirectory("route-async-sync")),
                manualCatalog = ActiveCatalog.empty(),
                aggregatorBaseUrl = "https://aggregator.example/config.json",
            )
            application {
                module(
                    catalogManager = manager,
                    syncCoordinator = coordinator,
                    config = BridgeConfig(admin = AdminConfig(enabled = true, tokenEnv = "ADMIN")),
                    environment = mapOf("ADMIN" to "secret-token"),
                )
            }

            val first = client.post("/admin/sync") {
                header(HttpHeaders.Authorization, "Bearer secret-token")
                setBody("{\"allowEmpty\":false}")
            }
            assertEquals(HttpStatusCode.Accepted, first.status)
            source.started.await()
            val firstBody = Json.parseToJsonElement(first.bodyAsText()).jsonObject

            val duplicate = client.post("/admin/sync") {
                header(HttpHeaders.Authorization, "Bearer secret-token")
                setBody("{\"allowEmpty\":false}")
            }
            val duplicateBody = Json.parseToJsonElement(duplicate.bodyAsText()).jsonObject

            assertEquals(HttpStatusCode.Accepted, duplicate.status)
            assertEquals("true", duplicateBody.getValue("alreadyRunning").jsonPrimitive.content)
            assertEquals(
                firstBody.getValue("jobId").jsonPrimitive.content,
                duplicateBody.getValue("jobId").jsonPrimitive.content,
            )
            source.release.complete(Unit)
        }
}

private fun routeMarker(body: String): String = Json
    .parseToJsonElement(body)
    .jsonObject
    .getValue("route")
    .jsonPrimitive
    .content

private fun catalogManager(runtime: SpiderRuntime): CatalogManager = CatalogManager(
    ActiveCatalog(
        version = "manual-v1",
        activatedAt = Instant.parse("2026-08-04T00:00:00Z"),
        entries = mapOf(runtime.key to readyEntry(runtime)),
    ),
)

private fun readyEntry(runtime: SpiderRuntime): RuntimeEntry = RuntimeEntry(
    spec = CatalogEntrySpec(
        key = runtime.key,
        name = runtime.name,
        kind = SourceKind.MANUAL,
        origin = SourceOrigin.CONFIG_YAML,
        api = "/api/${runtime.key}",
        specFingerprint = "${runtime.key}-fingerprint",
    ),
    status = EntryStatus.READY,
    handler = SourceHandler.Spider(runtime),
)

private class ContractSpiderRuntime(
    override val key: String,
    override val name: String,
) : SpiderRuntime {
    var closeCount: Int = 0
        private set

    override suspend fun homeContent(filter: Boolean): Result<String> =
        Result.success("{\"class\":[]}")

    override suspend fun categoryContent(
        tid: String,
        page: String,
        filter: Boolean,
        extend: HashMap<String, String>,
    ): Result<String> = Result.success("{\"route\":\"category\",\"list\":[]}")

    override suspend fun detailContent(ids: List<String>): Result<String> =
        Result.success("{\"route\":\"detail\",\"list\":[]}")

    override suspend fun searchContent(keyword: String, quick: Boolean): Result<String> =
        Result.success("{\"route\":\"search\",\"list\":[]}")

    override suspend fun playerContent(
        flag: String,
        id: String,
        vipFlags: List<String>,
    ): Result<String> =
        Result.success("{\"route\":\"play\",\"parse\":0,\"url\":\"$id\"}")

    override fun close() {
        closeCount += 1
    }
}

private class CountingAggregatorSource : AggregatorSource {
    var fetchCount: Int = 0
        private set

    override suspend fun fetch(previous: FetchValidators?): AggregatorFetchResult {
        fetchCount += 1
        return AggregatorFetchResult.Fetched(
            body = "{\"sites\":[]}",
            finalUrl = "https://aggregator.example/config.json",
            validators = FetchValidators(),
        )
    }
}

private class RouteBlockingAggregatorSource : AggregatorSource {
    val started = CompletableDeferred<Unit>()
    val release = CompletableDeferred<Unit>()

    override suspend fun fetch(previous: FetchValidators?): AggregatorFetchResult {
        started.complete(Unit)
        release.await()
        return AggregatorFetchResult.Fetched(
            body = "{\"sites\":[{\"key\":\"cms\",\"api\":\"https://cms.example/api.php\"}]}",
            finalUrl = "https://aggregator.example/config.json",
            validators = FetchValidators(),
        )
    }
}
