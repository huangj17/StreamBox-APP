package com.streambox.bridge.catalog

import com.streambox.bridge.aggregator.NormalizedAggregatorConfig
import com.streambox.bridge.aggregator.NormalizedAggregatorSite
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.time.Instant

data class CatalogBuildIssue(
    val key: String,
    val upstreamKey: String,
    val name: String,
    val status: EntryStatus,
    val error: ClassificationError? = null,
)

data class CatalogBuildResult(
    val candidate: ActiveCatalog,
    val shadowed: List<CatalogBuildIssue>,
    val failed: List<CatalogBuildIssue>,
    val identityMap: Map<CatalogIdentity, String>,
)

object CatalogBuilder {
    fun build(
        aggregator: NormalizedAggregatorConfig,
        manualCatalog: ActiveCatalog,
        version: String,
        activatedAt: Instant,
        existingIdentityMap: Map<CatalogIdentity, String> = emptyMap(),
    ): CatalogBuildResult {
        val allocation = CatalogKeyFactory.allocate(aggregator.sites, existingIdentityMap)
        val entries = LinkedHashMap(manualCatalog.entries)
        val shadowed = mutableListOf<CatalogBuildIssue>()
        val failed = mutableListOf<CatalogBuildIssue>()

        aggregator.sites.forEach { site ->
            val key = allocation.keyFor(site)
            val classification = SourceClassifier.classify(site, aggregator.spider)
            when (classification) {
                is SourceClassification.Invalid -> failed += issue(
                    site,
                    key,
                    EntryStatus.FAILED,
                    classification.error,
                )
                is SourceClassification.Unsupported -> failed += issue(
                    site,
                    key,
                    EntryStatus.FAILED,
                    classification.error,
                )
                is SourceClassification.Cms,
                is SourceClassification.Jar,
                -> {
                    if (entries.containsKey(key)) {
                        shadowed += issue(site, key, EntryStatus.SHADOWED)
                    } else {
                        entries[key] = plannedEntry(key, site, classification)
                    }
                }
            }
        }

        return CatalogBuildResult(
            candidate = ActiveCatalog(
                version = version,
                activatedAt = activatedAt,
                entries = entries,
            ),
            shadowed = shadowed,
            failed = failed,
            identityMap = allocation.keys,
        )
    }

    private fun plannedEntry(
        key: String,
        site: NormalizedAggregatorSite,
        classification: SourceClassification,
    ): RuntimeEntry {
        val kind: SourceKind
        val className: String?
        val jarReference: String?
        when (classification) {
            is SourceClassification.Cms -> {
                kind = SourceKind.CMS
                className = null
                jarReference = null
            }
            is SourceClassification.Jar -> {
                kind = SourceKind.JAR
                className = classification.className
                jarReference = classification.jarReference
            }
            else -> error("only valid classifications can create planned entries")
        }
        val extDigest = site.ext?.let(::sha256)
        val fingerprint = sha256(
            listOf(
                kind.name,
                site.key,
                site.api,
                jarReference.orEmpty(),
                extDigest.orEmpty(),
                className.orEmpty(),
            ).joinToString("\u0000"),
        )
        return RuntimeEntry(
            spec = CatalogEntrySpec(
                key = key,
                upstreamKey = site.key,
                name = site.name,
                kind = kind,
                origin = SourceOrigin.AGGREGATOR,
                api = site.api,
                className = className,
                jar = jarReference?.let { JarArtifactRef(source = it) },
                extDigest = extDigest,
                searchable = site.searchable,
                specFingerprint = fingerprint,
            ),
            status = EntryStatus.DISCOVERED,
            handler = null,
        )
    }

    private fun issue(
        site: NormalizedAggregatorSite,
        key: String,
        status: EntryStatus,
        error: ClassificationError? = null,
    ): CatalogBuildIssue = CatalogBuildIssue(
        key = key,
        upstreamKey = site.key,
        name = site.name,
        status = status,
        error = error,
    )

    private fun sha256(value: String): String = MessageDigest
        .getInstance("SHA-256")
        .digest(value.toByteArray(StandardCharsets.UTF_8))
        .joinToString(separator = "") { byte -> "%02x".format(byte) }
}
