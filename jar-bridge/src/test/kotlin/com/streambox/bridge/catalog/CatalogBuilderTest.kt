package com.streambox.bridge.catalog

import com.streambox.bridge.aggregator.NormalizedAggregatorConfig
import com.streambox.bridge.aggregator.NormalizedAggregatorSite
import com.streambox.bridge.config.PluginConfig
import java.time.Instant
import java.util.HashMap
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CatalogBuilderTest {
    @Test
    fun `manual entry wins and the colliding aggregator entry is reported as shadowed`() {
        val activatedAt = Instant.parse("2026-08-04T00:00:00Z")
        val manualRuntime = BuilderSpiderRuntime("agg_cms", "Manual CMS Override")
        val manualCatalog = ManualCatalogAdapter.build(
            sources = listOf(
                ManualCatalogSource(
                    plugin = PluginConfig(
                        key = "agg_cms",
                        name = manualRuntime.name,
                        jar = "plugins/manual.jar",
                        className = "com.example.Manual",
                    ),
                    runtime = manualRuntime,
                ),
            ),
            version = "manual-v1",
            activatedAt = activatedAt,
        )
        val aggregator = NormalizedAggregatorConfig(
            spider = null,
            sites = listOf(builderSite("cms", "https://cms.example/api.php")),
            finalUrl = "https://aggregator.example/config.json",
            configDigest = "config-digest",
        )

        val result = CatalogBuilder.build(
            aggregator = aggregator,
            manualCatalog = manualCatalog,
            version = "candidate-v1",
            activatedAt = activatedAt,
        )

        assertEquals(listOf("agg_cms"), result.candidate.entries.keys.toList())
        assertEquals(SourceOrigin.CONFIG_YAML, result.candidate.entries.getValue("agg_cms").spec.origin)
        assertEquals(1, result.shadowed.size)
        assertEquals(EntryStatus.SHADOWED, result.shadowed.single().status)
        assertTrue(result.failed.isEmpty())
    }

    @Test
    fun `builder plans cms and jar entries while isolating invalid sources`() {
        val activatedAt = Instant.parse("2026-08-04T00:00:00Z")
        val cms = builderSite("cms", "https://cms.example/api.php")
        val jar = builderSite("jar", "csp_Demo").copy(
            jar = "https://jar.example/demo.jar",
            ext = "{\"token\":\"secret\"}",
        )
        val invalid = builderSite("broken", "csp_Broken").copy(jar = null)

        val result = CatalogBuilder.build(
            aggregator = NormalizedAggregatorConfig(
                spider = null,
                sites = listOf(cms, jar, invalid),
                finalUrl = "https://aggregator.example/config.json",
                configDigest = "config-digest",
            ),
            manualCatalog = ActiveCatalog.empty(),
            version = "candidate-v1",
            activatedAt = activatedAt,
        )

        val cmsEntry = result.candidate.entries.getValue("agg_cms")
        assertEquals(SourceKind.CMS, cmsEntry.spec.kind)
        assertEquals(EntryStatus.DISCOVERED, cmsEntry.status)
        assertNull(cmsEntry.handler)

        val jarEntry = result.candidate.entries.getValue("agg_jar")
        assertEquals(SourceKind.JAR, jarEntry.spec.kind)
        assertEquals("com.github.catvod.spider.Demo", jarEntry.spec.className)
        assertEquals("https://jar.example/demo.jar", jarEntry.spec.jar?.source)
        assertTrue(jarEntry.spec.extDigest?.matches(Regex("[0-9a-f]{64}")) == true)
        assertTrue(jarEntry.spec.specFingerprint.matches(Regex("[0-9a-f]{64}")))

        assertEquals(1, result.failed.size)
        assertEquals("broken", result.failed.single().upstreamKey)
        assertIs<SourceClassification.Invalid>(SourceClassifier.classify(invalid, null))
    }
}

private fun builderSite(key: String, api: String): NormalizedAggregatorSite =
    NormalizedAggregatorSite(
        key = key,
        name = key,
        type = 1,
        api = api,
        searchable = true,
        quickSearch = true,
        filterable = true,
        jar = null,
        ext = null,
    )

private class BuilderSpiderRuntime(
    override val key: String,
    override val name: String,
) : SpiderRuntime {
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

    override fun close() = Unit
}
