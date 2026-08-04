package com.streambox.bridge.sync

import com.streambox.bridge.aggregator.AggregatorFetchResult
import com.streambox.bridge.aggregator.AggregatorSource
import com.streambox.bridge.aggregator.FetchValidators
import com.streambox.bridge.artifact.ArtifactStore
import com.streambox.bridge.catalog.ActiveCatalog
import com.streambox.bridge.catalog.CatalogManager
import com.streambox.bridge.catalog.EntryStatus
import com.streambox.bridge.catalog.SourceHandler
import com.streambox.bridge.runtime.SharedJarRuntimePool
import com.streambox.bridge.runtime.SpiderFactory
import com.streambox.bridge.security.RemoteTargetPolicy
import com.streambox.bridge.storage.CatalogSnapshotStore
import com.streambox.bridge.storage.AutomaticCatalogRestorer
import com.streambox.bridge.storage.SecretStore
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.runBlocking
import java.io.ByteArrayOutputStream
import java.net.InetSocketAddress
import java.nio.file.Files
import java.util.jar.JarEntry
import java.util.jar.JarOutputStream
import javax.tools.ToolProvider
import kotlin.io.path.createTempDirectory
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertSame

class AutomaticJarSyncTest {
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
    fun `bad jar update keeps the last ready runtime as degraded`() = runBlocking {
        val jar = automaticSpiderJar()
        server.createContext("/good.jar") { exchange ->
            exchange.sendResponseHeaders(200, jar.size.toLong())
            exchange.responseBody.use { it.write(jar) }
        }
        server.createContext("/bad.jar") { exchange ->
            val bytes = "not-a-jar".toByteArray()
            exchange.sendResponseHeaders(200, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        server.start()
        val root = createTempDirectory("automatic-jar-sync")
        val good = aggregatorBody("http://127.0.0.1:${server.address.port}/good.jar")
        val bad = aggregatorBody("http://127.0.0.1:${server.address.port}/bad.jar")
        val manager = CatalogManager(ActiveCatalog.empty())
        val artifactStore = ArtifactStore(
            root = root,
            remoteTargetPolicy = RemoteTargetPolicy(setOf("127.0.0.1")),
        )
        val pool = SharedJarRuntimePool()
        val secretStore = SecretStore(root.resolve("secrets"), environment = emptyMap())
        val coordinator = SyncCoordinator(
            source = JarSequenceSource(ArrayDeque(listOf(good, bad))),
            catalogManager = manager,
            snapshotStore = CatalogSnapshotStore(root.resolve("catalog")),
            manualCatalog = ActiveCatalog.empty(),
            aggregatorBaseUrl = "https://aggregator.example/config.json",
            secretStore = secretStore,
            artifactStore = artifactStore,
            spiderFactory = SpiderFactory(pool, root.resolve("runtime")),
        )

        assertIs<SyncRunResult.Completed>(coordinator.synchronize())
        val ready = manager.current().entries.getValue("agg_auto")
        assertEquals(EntryStatus.READY, ready.status)
        val runtime = assertIs<SourceHandler.Spider>(ready.handler).runtime
        assertEquals("{\"class\":[]}", runtime.homeContent(true).getOrThrow())

        assertIs<SyncRunResult.Completed>(coordinator.synchronize())
        val degraded = manager.current().entries.getValue("agg_auto")

        assertEquals(EntryStatus.DEGRADED, degraded.status)
        assertSame(runtime, assertIs<SourceHandler.Spider>(degraded.handler).runtime)
        artifactStore.close()
        manager.close()
        pool.close()
    }

    @Test
    fun `automatic jar restarts from the committed snapshot while aggregator is offline`() =
        runBlocking {
            val jar = automaticSpiderJar()
            server.createContext("/restart.jar") { exchange ->
                exchange.sendResponseHeaders(200, jar.size.toLong())
                exchange.responseBody.use { it.write(jar) }
            }
            server.start()
            val root = createTempDirectory("automatic-jar-restart")
            val sourceUrl = "http://127.0.0.1:${server.address.port}/restart.jar"
            val snapshotStore = CatalogSnapshotStore(root.resolve("catalog"))
            val secrets = SecretStore(root.resolve("secrets"), environment = emptyMap())
            val firstArtifacts = ArtifactStore(
                root = root,
                remoteTargetPolicy = RemoteTargetPolicy(setOf("127.0.0.1")),
            )
            val firstPool = SharedJarRuntimePool()
            val firstManager = CatalogManager()
            val coordinator = SyncCoordinator(
                source = JarSequenceSource(ArrayDeque(listOf(aggregatorBody(sourceUrl)))),
                catalogManager = firstManager,
                snapshotStore = snapshotStore,
                manualCatalog = ActiveCatalog.empty(),
                aggregatorBaseUrl = "https://aggregator.example/config.json",
                secretStore = secrets,
                artifactStore = firstArtifacts,
                spiderFactory = SpiderFactory(firstPool, root.resolve("runtime")),
            )
            assertIs<SyncRunResult.Completed>(coordinator.synchronize())
            val version = firstManager.current().version
            firstManager.close()
            firstPool.close()
            firstArtifacts.close()
            server.stop(0)

            val restoredPool = SharedJarRuntimePool()
            val restoredArtifacts = ArtifactStore(
                root = root,
                remoteTargetPolicy = RemoteTargetPolicy(),
            )
            val restored = AutomaticCatalogRestorer.restore(
                recovered = snapshotStore.recover()!!,
                manualCatalog = ActiveCatalog.empty(),
                artifactStore = restoredArtifacts,
                spiderFactory = SpiderFactory(restoredPool, root.resolve("runtime")),
                secretStore = secrets,
            )

            assertEquals(version, restored.version)
            val entry = restored.entries.getValue("agg_auto")
            assertEquals(EntryStatus.READY, entry.status)
            assertEquals(
                "{\"class\":[]}",
                assertIs<SourceHandler.Spider>(entry.handler)
                    .runtime.homeContent(true).getOrThrow(),
            )
            CatalogManager(restored).close()
            restoredPool.close()
            restoredArtifacts.close()
        }
}

private class JarSequenceSource(
    private val bodies: ArrayDeque<String>,
) : AggregatorSource {
    override suspend fun fetch(previous: FetchValidators?): AggregatorFetchResult =
        AggregatorFetchResult.Fetched(
            body = bodies.removeFirst(),
            finalUrl = "https://aggregator.example/config.json",
            validators = FetchValidators(),
        )
}

private fun aggregatorBody(jarUrl: String): String =
    """{"sites":[{"key":"auto","name":"Auto","api":"fixture.AutoSpider","jar":"$jarUrl","ext":"secret-ext"}]}"""

private fun automaticSpiderJar(): ByteArray {
    val root = createTempDirectory("automatic-spider-source")
    val sourceRoot = root.resolve("source/fixture")
    val classesRoot = root.resolve("classes")
    Files.createDirectories(sourceRoot)
    Files.createDirectories(classesRoot)
    val source = sourceRoot.resolve("AutoSpider.java")
    Files.writeString(
        source,
        """
        package fixture;
        import java.util.*;
        public class AutoSpider {
          public void init(Object context, String ext) {
            if (!"secret-ext".equals(ext)) throw new IllegalArgumentException("wrong ext");
          }
          public String homeContent(boolean filter) { return "{\"class\":[]}"; }
          public String categoryContent(String tid, String pg, boolean filter, HashMap<String,String> ext) { return "{\"list\":[]}"; }
          public String detailContent(List<String> ids) { return "{\"list\":[]}"; }
          public String searchContent(String keyword, boolean quick) { return "{\"list\":[]}"; }
          public String playerContent(String flag, String id, List<String> vipFlags) { return "{\"parse\":0,\"url\":\"" + id + "\"}"; }
        }
        """.trimIndent(),
    )
    val compiler = checkNotNull(ToolProvider.getSystemJavaCompiler())
    check(compiler.run(null, null, null, "-d", classesRoot.toString(), source.toString()) == 0)
    val output = ByteArrayOutputStream()
    JarOutputStream(output).use { jar ->
        jar.putNextEntry(JarEntry("fixture/AutoSpider.class"))
        Files.copy(classesRoot.resolve("fixture/AutoSpider.class"), jar)
        jar.closeEntry()
    }
    return output.toByteArray()
}
