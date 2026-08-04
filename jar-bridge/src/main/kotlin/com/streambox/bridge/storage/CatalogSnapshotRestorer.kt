package com.streambox.bridge.storage

import com.streambox.bridge.catalog.ActiveCatalog
import com.streambox.bridge.catalog.CatalogEntrySpec
import com.streambox.bridge.catalog.EntryStatus
import com.streambox.bridge.catalog.JarArtifactRef
import com.streambox.bridge.catalog.RuntimeEntry
import com.streambox.bridge.catalog.SourceHandler
import com.streambox.bridge.catalog.SourceKind
import com.streambox.bridge.catalog.SourceOrigin
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.time.Instant

object CatalogSnapshotRestorer {
    fun restore(
        recovered: RecoveredCatalogSnapshot,
        manualCatalog: ActiveCatalog,
    ): ActiveCatalog {
        val snapshot = recovered.snapshot
        val entries = linkedMapOf<String, RuntimeEntry>()
        snapshot.entries
            .filter { it.origin == SourceOrigin.AGGREGATOR }
            .forEach { stored -> entries[stored.key] = stored.restore() }
        entries.putAll(manualCatalog.entries)
        return ActiveCatalog(
            version = snapshot.catalogVersion,
            activatedAt = runCatching { Instant.parse(snapshot.activatedAt) }
                .getOrDefault(Instant.EPOCH),
            entries = entries,
        )
    }

    private fun SnapshotEntry.restore(): RuntimeEntry {
        val spec = CatalogEntrySpec(
            key = key,
            upstreamKey = upstreamKey,
            name = name,
            kind = kind,
            origin = origin,
            api = api,
            className = className,
            jar = jarSource?.let {
                JarArtifactRef(source = it, declaredMd5 = jarMd5, sha256 = jarSha256)
            },
            secretRef = secretRef,
            extDigest = extDigest,
            searchable = searchable,
            hidden = hidden,
            specFingerprint = specFingerprint,
        )
        if (kind == SourceKind.CMS) {
            val target = api.toHttpUrlOrNull()
            if (target != null) {
                return RuntimeEntry(
                    spec = spec,
                    status = EntryStatus.READY,
                    handler = SourceHandler.Cms(target),
                )
            }
        }
        return RuntimeEntry(
            spec = spec,
            status = EntryStatus.FAILED,
            handler = null,
        )
    }
}
