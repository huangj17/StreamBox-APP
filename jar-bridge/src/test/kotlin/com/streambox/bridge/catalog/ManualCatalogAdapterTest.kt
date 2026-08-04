package com.streambox.bridge.catalog

import com.streambox.bridge.config.PluginConfig
import java.time.Instant
import java.util.HashMap
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class ManualCatalogAdapterTest {
    @Test
    fun `manual plugins keep their keys and api paths while hidden plugins stay private`() {
        val sources = listOf(
            manualSource(key = "visible", hidden = false),
            manualSource(key = "hidden", hidden = true),
        )

        val catalog = ManualCatalogAdapter.build(
            sources = sources,
            version = "manual-v1",
            activatedAt = Instant.parse("2026-08-04T00:00:00Z"),
        )
        val manager = CatalogManager(catalog)

        assertEquals(setOf("visible", "hidden"), catalog.entries.keys)
        assertEquals("/api/visible", catalog.entries.getValue("visible").spec.api)
        assertEquals(listOf("visible"), manager.listPublic().map { it.spec.key })
    }

    @Test
    fun `duplicate manual keys reject the candidate catalog`() {
        val duplicateSources = listOf(
            manualSource(key = "duplicate", hidden = false),
            manualSource(key = "duplicate", hidden = true),
        )

        val error = assertFailsWith<CatalogBuildException> {
            ManualCatalogAdapter.build(
                sources = duplicateSources,
                version = "manual-v1",
                activatedAt = Instant.parse("2026-08-04T00:00:00Z"),
            )
        }

        assertEquals(CatalogErrorCode.DUPLICATE_KEY, error.error.code)
    }
}

private fun manualSource(key: String, hidden: Boolean): ManualCatalogSource {
    val runtime = ManualTestSpiderLease(key = key, name = "Name $key")
    return ManualCatalogSource(
        plugin = PluginConfig(
            key = key,
            name = runtime.name,
            jar = "plugins/manual.jar",
            className = "com.example.$key",
            hidden = hidden,
        ),
        runtime = runtime,
    )
}

private class ManualTestSpiderLease(
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
