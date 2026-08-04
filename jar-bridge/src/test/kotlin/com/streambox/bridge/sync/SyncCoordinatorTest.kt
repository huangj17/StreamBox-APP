package com.streambox.bridge.sync

import com.streambox.bridge.aggregator.AggregatorFetchResult
import com.streambox.bridge.aggregator.AggregatorSource
import com.streambox.bridge.aggregator.FetchValidators
import com.streambox.bridge.catalog.ActiveCatalog
import com.streambox.bridge.catalog.CatalogManager
import com.streambox.bridge.catalog.EntryStatus
import com.streambox.bridge.catalog.SourceHandler
import com.streambox.bridge.catalog.SourceKind
import com.streambox.bridge.storage.CatalogSnapshotStore
import com.streambox.bridge.storage.SecretStore
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import java.time.Instant
import java.nio.file.Files
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

class SyncCoordinatorTest {
    @Test
    fun `successful sync commits a snapshot before activating a ready cms entry`() = runBlocking {
        val root = createTempDirectory("sync-test")
        val manager = CatalogManager(ActiveCatalog.empty())
        val coordinator = SyncCoordinator(
            source = FixedAggregatorSource(
                """{"sites":[{"key":"cms","name":"CMS","api":"https://cms.example/api.php"}]}""",
            ),
            catalogManager = manager,
            snapshotStore = CatalogSnapshotStore(root.resolve("catalog")),
            manualCatalog = ActiveCatalog.empty(),
            aggregatorBaseUrl = "https://aggregator.example/config.json",
            clock = { Instant.parse("2026-08-04T00:00:00Z") },
        )

        val result = assertIs<SyncRunResult.Completed>(coordinator.synchronize())

        assertEquals(SyncPhase.SUCCEEDED, result.status.phase)
        assertEquals(0, result.status.consecutiveFailures)
        val entry = manager.current().entries.getValue("agg_cms")
        assertEquals(SourceKind.CMS, entry.spec.kind)
        assertEquals(EntryStatus.READY, entry.status)
        assertIs<SourceHandler.Cms>(entry.handler)
        assertEquals(manager.current().version, coordinator.lastSnapshot()?.snapshot?.catalogVersion)
        assertEquals(manager.current().version, result.status.currentCatalogVersion)
        assertEquals(1, result.status.diff.added)
        assertEquals(0, result.status.diff.failed)
        assertTrue(checkNotNull(result.status.durationMs) >= 0)
    }

    @Test
    fun `not modified refreshes sync health without creating a catalog version`() = runBlocking {
        val root = createTempDirectory("sync-304-test")
        val source = SequenceAggregatorSource(
            ArrayDeque(
                listOf(
                    AggregatorFetchResult.Fetched(
                        body = """{"sites":[{"key":"cms","api":"https://cms.example/api.php"}]}""",
                        finalUrl = "https://aggregator.example/config.json",
                        validators = FetchValidators(etag = "\"v1\""),
                    ),
                    AggregatorFetchResult.NotModified(
                        finalUrl = "https://aggregator.example/config.json",
                        validators = FetchValidators(etag = "\"v1\""),
                    ),
                ),
            ),
        )
        val manager = CatalogManager()
        val coordinator = SyncCoordinator(
            source = source,
            catalogManager = manager,
            snapshotStore = CatalogSnapshotStore(root.resolve("catalog")),
            manualCatalog = ActiveCatalog.empty(),
            aggregatorBaseUrl = "https://aggregator.example/config.json",
            clock = { Instant.parse("2026-08-04T00:00:00Z") },
        )
        assertIs<SyncRunResult.Completed>(coordinator.synchronize())
        val version = manager.current().version

        val second = assertIs<SyncRunResult.Completed>(coordinator.synchronize())

        assertEquals(false, second.activated)
        assertEquals(version, manager.current().version)
        assertEquals(0, second.status.consecutiveFailures)
    }

    @Test
    fun `repeated normalized digest does not create an equivalent catalog version`() = runBlocking {
        val root = createTempDirectory("sync-digest-test")
        val fetched = AggregatorFetchResult.Fetched(
            body = """{"sites":[{"key":"cms","api":"https://cms.example/api.php"}]}""",
            finalUrl = "https://aggregator.example/config.json",
            validators = FetchValidators(),
        )
        var now = Instant.parse("2026-08-04T00:00:00Z")
        val manager = CatalogManager()
        val coordinator = SyncCoordinator(
            source = SequenceAggregatorSource(ArrayDeque(listOf(fetched, fetched))),
            catalogManager = manager,
            snapshotStore = CatalogSnapshotStore(root.resolve("catalog")),
            manualCatalog = ActiveCatalog.empty(),
            aggregatorBaseUrl = "https://aggregator.example/config.json",
            clock = { now },
        )
        assertIs<SyncRunResult.Completed>(coordinator.synchronize())
        val firstVersion = manager.current().version
        now = Instant.parse("2026-08-04T00:10:00Z")

        val duplicate = assertIs<SyncRunResult.Completed>(coordinator.synchronize())

        assertEquals(false, duplicate.activated)
        assertEquals(firstVersion, manager.current().version)
    }

    @Test
    fun `invalid upstream response leaves the active catalog unchanged`() = runBlocking {
        val root = createTempDirectory("sync-failure-test")
        val source = SequenceAggregatorSource(
            ArrayDeque(
                listOf(
                    AggregatorFetchResult.Fetched(
                        body = """{"sites":[{"key":"cms","api":"https://cms.example/api.php"}]}""",
                        finalUrl = "https://aggregator.example/config.json",
                        validators = FetchValidators(),
                    ),
                    AggregatorFetchResult.Fetched(
                        body = "not-json",
                        finalUrl = "https://aggregator.example/config.json",
                        validators = FetchValidators(),
                    ),
                ),
            ),
        )
        val manager = CatalogManager()
        val coordinator = SyncCoordinator(
            source = source,
            catalogManager = manager,
            snapshotStore = CatalogSnapshotStore(root.resolve("catalog")),
            manualCatalog = ActiveCatalog.empty(),
            aggregatorBaseUrl = "https://aggregator.example/config.json",
            clock = { Instant.parse("2026-08-04T00:00:00Z") },
        )
        assertIs<SyncRunResult.Completed>(coordinator.synchronize())
        val version = manager.current().version

        val failure = assertIs<SyncRunResult.Failed>(coordinator.synchronize())

        assertEquals(version, manager.current().version)
        assertEquals(1, failure.status.consecutiveFailures)
        assertEquals("AGGREGATOR_SCHEMA_INVALID", failure.status.lastErrorCode)
    }

    @Test
    fun `concurrent sync request observes the running job instead of queueing`() = runBlocking {
        val source = BlockingAggregatorSource()
        val coordinator = SyncCoordinator(
            source = source,
            catalogManager = CatalogManager(),
            snapshotStore = CatalogSnapshotStore(createTempDirectory("sync-single-flight")),
            manualCatalog = ActiveCatalog.empty(),
            aggregatorBaseUrl = "https://aggregator.example/config.json",
        )
        val first = async { coordinator.synchronize() }
        source.started.await()

        val duplicate = assertIs<SyncRunResult.AlreadyRunning>(coordinator.synchronize())
        source.release.complete(Unit)

        assertTrue(duplicate.jobId.isNotBlank())
        assertIs<SyncRunResult.Completed>(first.await())
        Unit
    }

    @Test
    fun `background sync reserves a job immediately and remains single flight`() = runBlocking {
        val source = BlockingAggregatorSource()
        val coordinator = SyncCoordinator(
            source = source,
            catalogManager = CatalogManager(),
            snapshotStore = CatalogSnapshotStore(createTempDirectory("sync-background")),
            manualCatalog = ActiveCatalog.empty(),
            aggregatorBaseUrl = "https://aggregator.example/config.json",
        )

        val started = assertIs<SyncStartResult.Started>(coordinator.startAsync())
        val duplicate = assertIs<SyncStartResult.AlreadyRunning>(coordinator.startAsync())

        assertTrue(started.jobId.isNotBlank())
        assertEquals(started.jobId, duplicate.jobId)
        source.started.await()
        assertTrue(coordinator.status().running)
        source.release.complete(Unit)
        while (coordinator.status().running) {
            kotlinx.coroutines.yield()
        }
        coordinator.close()
    }

    @Test
    fun `jar ext is stored by secret reference and reused without snapshot plaintext`() = runBlocking {
        val root = createTempDirectory("sync-secret-test")
        val body = """{"sites":[{"key":"jar","api":"csp_Demo","jar":"https://jar.example/demo.jar","ext":{"token":"plain-secret"}}]}"""
        val fetched = AggregatorFetchResult.Fetched(
            body = body,
            finalUrl = "https://aggregator.example/config.json",
            validators = FetchValidators(),
        )
        val manager = CatalogManager()
        val snapshotStore = CatalogSnapshotStore(root.resolve("catalog"))
        val coordinator = SyncCoordinator(
            source = SequenceAggregatorSource(ArrayDeque(listOf(fetched, fetched))),
            catalogManager = manager,
            snapshotStore = snapshotStore,
            manualCatalog = ActiveCatalog.empty(),
            aggregatorBaseUrl = "https://aggregator.example/config.json",
            secretStore = SecretStore(root.resolve("secrets"), environment = emptyMap()),
            clock = { Instant.parse("2026-08-04T00:00:00Z") },
        )

        assertIs<SyncRunResult.Completed>(coordinator.synchronize())
        val firstRef = manager.current().entries.getValue("agg_jar").spec.secretRef
        assertIs<SyncRunResult.Completed>(coordinator.synchronize())

        assertEquals(firstRef, manager.current().entries.getValue("agg_jar").spec.secretRef)
        assertEquals(
            1,
            Files.list(root.resolve("secrets")).use { paths ->
                paths.filter { it.fileName.toString().endsWith(".bin") }.count()
            },
        )
        val snapshotPath = root.resolve("catalog/versions/${manager.current().version}/catalog.json")
        assertTrue(!Files.readString(snapshotPath).contains("plain-secret"))
    }
}

private class FixedAggregatorSource(
    private val body: String,
) : AggregatorSource {
    override suspend fun fetch(previous: FetchValidators?): AggregatorFetchResult =
        AggregatorFetchResult.Fetched(
            body = body,
            finalUrl = "https://aggregator.example/config.json",
            validators = FetchValidators(etag = "\"v1\""),
        )
}

private class SequenceAggregatorSource(
    private val results: ArrayDeque<AggregatorFetchResult>,
) : AggregatorSource {
    override suspend fun fetch(previous: FetchValidators?): AggregatorFetchResult =
        results.removeFirst()
}

private class BlockingAggregatorSource : AggregatorSource {
    val started = CompletableDeferred<Unit>()
    val release = CompletableDeferred<Unit>()

    override suspend fun fetch(previous: FetchValidators?): AggregatorFetchResult {
        started.complete(Unit)
        release.await()
        return AggregatorFetchResult.Fetched(
            body = "{\"sites\":[]}",
            finalUrl = "https://aggregator.example/config.json",
            validators = FetchValidators(),
        )
    }
}
