package com.streambox.bridge.storage

import com.streambox.bridge.artifact.ArtifactStore
import com.streambox.bridge.artifact.JarReferenceParser
import com.streambox.bridge.catalog.ActiveCatalog
import com.streambox.bridge.catalog.CatalogError
import com.streambox.bridge.catalog.CatalogErrorCode
import com.streambox.bridge.catalog.EntryStatus
import com.streambox.bridge.catalog.JarArtifactRef
import com.streambox.bridge.catalog.SourceHandler
import com.streambox.bridge.catalog.SourceKind
import com.streambox.bridge.catalog.SourceOrigin
import com.streambox.bridge.runtime.SpiderFactory
import java.time.Instant

object AutomaticCatalogRestorer {
    suspend fun restore(
        recovered: RecoveredCatalogSnapshot,
        manualCatalog: ActiveCatalog,
        artifactStore: ArtifactStore,
        spiderFactory: SpiderFactory,
        secretStore: SecretStore,
    ): ActiveCatalog {
        val base = CatalogSnapshotRestorer.restore(recovered, manualCatalog)
        val entries = base.entries.toMutableMap()
        recovered.snapshot.entries
            .filter { entry ->
                entry.kind == SourceKind.JAR &&
                    entry.origin == SourceOrigin.AGGREGATOR &&
                    entries[entry.key]?.spec?.origin != SourceOrigin.CONFIG_YAML
            }
            .forEach { stored ->
                val current = checkNotNull(entries[stored.key])
                entries[stored.key] = try {
                    val className = checkNotNull(stored.className)
                    val artifact = stored.jarSha256
                        ?.let { sha256 -> artifactStore.loadCached(sha256, className) }
                        ?: artifactStore.prepare(
                            JarReferenceParser.parse(checkNotNull(stored.jarSource)),
                            className,
                        )
                    val ext = stored.secretRef?.let(secretStore::read).orEmpty()
                    val runtime = spiderFactory.create(
                        key = stored.key,
                        name = stored.name,
                        artifact = artifact,
                        className = artifact.className,
                        ext = ext,
                        generation = recovered.snapshot.catalogVersion,
                    )
                    current.copy(
                        spec = current.spec.copy(
                            className = artifact.className,
                            jar = JarArtifactRef(
                                source = checkNotNull(stored.jarSource),
                                declaredMd5 = stored.jarMd5,
                                sha256 = artifact.sha256,
                            ),
                        ),
                        status = EntryStatus.READY,
                        handler = SourceHandler.Spider(runtime),
                        lastReadyAt = runCatching {
                            Instant.parse(recovered.snapshot.activatedAt)
                        }.getOrNull(),
                    )
                } catch (_: Exception) {
                    current.copy(
                        status = EntryStatus.FAILED,
                        handler = null,
                        lastError = CatalogError(
                            code = CatalogErrorCode.SOURCE_UNAVAILABLE,
                            message = "Automatic JAR could not be restored from its snapshot",
                        ),
                    )
                }
            }
        return base.copy(entries = entries)
    }
}
