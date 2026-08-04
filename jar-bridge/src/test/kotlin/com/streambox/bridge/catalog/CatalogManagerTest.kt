package com.streambox.bridge.catalog

import java.time.Instant
import java.util.HashMap
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class CatalogManagerTest {
    @Test
    fun `new catalog manager exposes an empty public catalog`() {
        val manager = CatalogManager()

        assertTrue(manager.listPublic().isEmpty())
    }

    @Test
    fun `activating a ready entry makes the new catalog publicly visible`() {
        val manager = CatalogManager()
        val entry = RuntimeEntry(
            spec = CatalogEntrySpec(
                key = "manual",
                name = "Manual",
                kind = SourceKind.MANUAL,
                origin = SourceOrigin.CONFIG_YAML,
                api = "/api/manual",
                className = "com.example.Manual",
                specFingerprint = "manual-fingerprint",
            ),
            status = EntryStatus.READY,
            handler = SourceHandler.Spider(TestSpiderRuntime("manual", "Manual")),
        )
        val next = ActiveCatalog(
            version = "manual-v1",
            activatedAt = Instant.parse("2026-08-04T00:00:00Z"),
            entries = linkedMapOf(entry.spec.key to entry),
        )

        manager.activate(next)

        assertEquals("manual-v1", manager.current().version)
        assertEquals(listOf("manual"), manager.listPublic().map { it.spec.key })
    }

    @Test
    fun `retired runtime stays open until an acquired request lease closes`() {
        val runtime = TestSpiderRuntime("manual", "Manual")
        val entry = RuntimeEntry(
            spec = CatalogEntrySpec(
                key = "manual",
                name = "Manual",
                kind = SourceKind.MANUAL,
                origin = SourceOrigin.CONFIG_YAML,
                api = "/api/manual",
                specFingerprint = "manual-v1",
            ),
            status = EntryStatus.READY,
            handler = SourceHandler.Spider(runtime),
        )
        val manager = CatalogManager(
            ActiveCatalog(
                version = "manual-v1",
                activatedAt = Instant.parse("2026-08-04T00:00:00Z"),
                entries = mapOf("manual" to entry),
            ),
        )

        val requestLease = assertNotNull(manager.acquire("manual"))
        manager.activate(
            ActiveCatalog(
                version = "manual-v2",
                activatedAt = Instant.parse("2026-08-04T00:01:00Z"),
                entries = emptyMap(),
            ),
        )

        assertEquals(0, runtime.closeCount)
        requestLease.close()
        requestLease.close()
        assertEquals(1, runtime.closeCount)
    }

    @Test
    fun `runtime reused by the next catalog is not retired with the old catalog`() {
        val runtime = TestSpiderRuntime("manual", "Manual")
        val firstEntry = runtimeEntry(runtime, fingerprint = "manual-v1")
        val manager = CatalogManager(
            ActiveCatalog(
                version = "manual-v1",
                activatedAt = Instant.parse("2026-08-04T00:00:00Z"),
                entries = mapOf("manual" to firstEntry),
            ),
        )
        val nextEntry = runtimeEntry(runtime, fingerprint = "manual-v1")

        manager.activate(
            ActiveCatalog(
                version = "manual-v2",
                activatedAt = Instant.parse("2026-08-04T00:01:00Z"),
                entries = mapOf("manual" to nextEntry),
            ),
        )

        assertEquals(0, runtime.closeCount)
        manager.close()
        assertEquals(1, runtime.closeCount)
    }

    @Test
    fun `closing catalog manager is idempotent and releases active runtimes`() {
        val runtime = TestSpiderRuntime("manual", "Manual")
        val entry = RuntimeEntry(
            spec = CatalogEntrySpec(
                key = "manual",
                name = "Manual",
                kind = SourceKind.MANUAL,
                origin = SourceOrigin.CONFIG_YAML,
                api = "/api/manual",
                specFingerprint = "manual-v1",
            ),
            status = EntryStatus.READY,
            handler = SourceHandler.Spider(runtime),
        )
        val manager = CatalogManager(
            ActiveCatalog(
                version = "manual-v1",
                activatedAt = Instant.parse("2026-08-04T00:00:00Z"),
                entries = mapOf("manual" to entry),
            ),
        )

        manager.close()
        manager.close()

        assertEquals(1, runtime.closeCount)
        assertTrue(manager.listPublic().isEmpty())
    }

    @Test
    fun `retirement grace expiry force closes a runtime with an active request`() {
        val scheduler = TestRetirementScheduler()
        val runtime = TestSpiderRuntime("manual", "Manual")
        val entry = RuntimeEntry(
            spec = CatalogEntrySpec(
                key = "manual",
                name = "Manual",
                kind = SourceKind.MANUAL,
                origin = SourceOrigin.CONFIG_YAML,
                api = "/api/manual",
                specFingerprint = "manual-v1",
            ),
            status = EntryStatus.READY,
            handler = SourceHandler.Spider(runtime),
        )
        val manager = CatalogManager(
            initial = ActiveCatalog(
                version = "manual-v1",
                activatedAt = Instant.parse("2026-08-04T00:00:00Z"),
                entries = mapOf("manual" to entry),
            ),
            retirementGraceMs = 30_000,
            scheduler = scheduler,
        )
        val requestLease = assertNotNull(manager.acquire("manual"))

        manager.activate(
            ActiveCatalog(
                version = "manual-v2",
                activatedAt = Instant.parse("2026-08-04T00:01:00Z"),
                entries = emptyMap(),
            ),
        )
        scheduler.runPending()

        assertEquals(1, runtime.closeCount)
        requestLease.close()
        assertEquals(1, runtime.closeCount)
    }
}

private fun runtimeEntry(runtime: SpiderRuntime, fingerprint: String): RuntimeEntry = RuntimeEntry(
    spec = CatalogEntrySpec(
        key = runtime.key,
        name = runtime.name,
        kind = SourceKind.MANUAL,
        origin = SourceOrigin.CONFIG_YAML,
        api = "/api/${runtime.key}",
        specFingerprint = fingerprint,
    ),
    status = EntryStatus.READY,
    handler = SourceHandler.Spider(runtime),
)

private class TestRetirementScheduler : RetirementScheduler {
    private data class PendingTask(
        val block: () -> Unit,
        var cancelled: Boolean = false,
    )

    private val tasks = mutableListOf<PendingTask>()

    override fun schedule(delayMs: Long, block: () -> Unit): RetirementTask {
        val task = PendingTask(block)
        tasks += task
        return RetirementTask { task.cancelled = true }
    }

    fun runPending() {
        tasks.toList().forEach { task ->
            if (!task.cancelled) task.block()
        }
        tasks.clear()
    }
}

private class TestSpiderRuntime(
    override val key: String,
    override val name: String,
) : SpiderRuntime {
    var closeCount: Int = 0
        private set

    override suspend fun homeContent(filter: Boolean): Result<String> = Result.success("{}")

    override suspend fun categoryContent(
        tid: String,
        page: String,
        filter: Boolean,
        extend: HashMap<String, String>,
    ): Result<String> = Result.success("{}")

    override suspend fun detailContent(ids: List<String>): Result<String> = Result.success("{}")

    override suspend fun searchContent(keyword: String, quick: Boolean): Result<String> =
        Result.success("{}")

    override suspend fun playerContent(
        flag: String,
        id: String,
        vipFlags: List<String>,
    ): Result<String> = Result.success("{}")

    override fun close() {
        closeCount += 1
    }
}
