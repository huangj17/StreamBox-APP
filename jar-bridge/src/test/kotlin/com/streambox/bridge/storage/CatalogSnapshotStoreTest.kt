package com.streambox.bridge.storage

import com.streambox.bridge.catalog.CatalogIdentity
import com.streambox.bridge.catalog.ActiveCatalog
import com.streambox.bridge.catalog.CatalogEntrySpec
import com.streambox.bridge.catalog.EntryStatus
import com.streambox.bridge.catalog.RuntimeEntry
import com.streambox.bridge.catalog.SourceHandler
import com.streambox.bridge.catalog.SourceKind
import com.streambox.bridge.catalog.SourceOrigin
import java.nio.file.Files
import java.time.Instant
import kotlin.io.path.createTempDirectory
import kotlin.io.path.writeText
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

class CatalogSnapshotStoreTest {
    @Test
    fun `commit publishes a recoverable version with its identity map`() {
        val root = createTempDirectory("snapshot-store-test")
        val store = CatalogSnapshotStore(root, retention = 2)
        val identity = CatalogIdentity("upstream", "https://cms.example/api.php", null)
        val snapshot = snapshot("v1")

        store.commit(snapshot, mapOf(identity to "agg_upstream"))
        val recovered = store.recover()

        assertEquals("v1", recovered?.snapshot?.catalogVersion)
        assertEquals("agg_upstream", recovered?.identityMap?.get(identity))
        assertTrue(Files.isRegularFile(root.resolve("versions/v1/catalog.json")))
        assertTrue(Files.isRegularFile(root.resolve("current.json")))
    }

    @Test
    fun `recovery falls back to previous when current pointer is corrupt`() {
        val root = createTempDirectory("snapshot-recovery-test")
        val store = CatalogSnapshotStore(root, retention = 2)
        store.commit(snapshot("v1"), emptyMap())
        store.commit(snapshot("v2"), emptyMap())
        root.resolve("current.json").writeText("not-json")

        val recovered = store.recover()

        assertEquals("v1", recovered?.snapshot?.catalogVersion)
        assertEquals(SnapshotRecoverySource.PREVIOUS, recovered?.source)
    }

    @Test
    fun `restorer rebuilds cms handlers while preserving manual override priority`() {
        val root = createTempDirectory("snapshot-restorer-test")
        val store = CatalogSnapshotStore(root, retention = 2)
        store.commit(snapshot("v1"), emptyMap())
        val manualEntry = RuntimeEntry(
            spec = CatalogEntrySpec(
                key = "agg_upstream",
                name = "Manual Override",
                kind = SourceKind.MANUAL,
                origin = SourceOrigin.CONFIG_YAML,
                api = "/api/agg_upstream",
                specFingerprint = "manual",
            ),
            status = EntryStatus.READY,
            handler = null,
        )
        val manual = ActiveCatalog(
            version = "manual",
            activatedAt = Instant.parse("2026-08-04T00:00:00Z"),
            entries = mapOf("agg_upstream" to manualEntry),
        )

        val restored = CatalogSnapshotRestorer.restore(store.recover()!!, manual)

        assertEquals("Manual Override", restored.entries.getValue("agg_upstream").spec.name)

        val cmsOnly = CatalogSnapshotRestorer.restore(store.recover()!!, ActiveCatalog.empty())
        val restoredCms = cmsOnly.entries.getValue("agg_upstream")
        assertEquals(EntryStatus.READY, restoredCms.status)
        assertIs<SourceHandler.Cms>(restoredCms.handler)
    }
}

private fun snapshot(version: String): CatalogSnapshot = CatalogSnapshot(
    catalogVersion = version,
    createdAt = Instant.parse("2026-08-04T00:00:00Z").toString(),
    activatedAt = Instant.parse("2026-08-04T00:00:01Z").toString(),
    aggregator = SnapshotAggregator(
        baseUrl = "https://aggregator.example/config.json",
        configDigest = "digest-$version",
    ),
    entries = listOf(
        SnapshotEntry(
            key = "agg_upstream",
            upstreamKey = "upstream",
            name = "Upstream",
            kind = SourceKind.CMS,
            origin = SourceOrigin.AGGREGATOR,
            api = "https://cms.example/api.php",
            status = EntryStatus.READY,
            specFingerprint = "fingerprint",
        ),
    ),
)
