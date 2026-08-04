package com.streambox.bridge.catalog

import com.streambox.bridge.aggregator.NormalizedAggregatorSite
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class CatalogKeyFactoryTest {
    @Test
    fun `sanitized key collisions receive deterministic order independent suffixes`() {
        val first = keySite(key = "A B", api = "https://one.example/api.php")
        val second = keySite(key = "A@B", api = "https://two.example/api.php")

        val forward = CatalogKeyFactory.allocate(listOf(first, second))
        val reversed = CatalogKeyFactory.allocate(listOf(second, first))

        val firstKey = forward.keyFor(first)
        val secondKey = forward.keyFor(second)
        assertTrue(firstKey.startsWith("agg_a_b_"))
        assertTrue(secondKey.startsWith("agg_a_b_"))
        assertNotEquals(firstKey, secondKey)
        assertEquals(firstKey, reversed.keyFor(first))
        assertEquals(secondKey, reversed.keyFor(second))
    }

    @Test
    fun `existing identity allocation remains stable when upstream order and collisions change`() {
        val existingSite = keySite(key = "CMS", api = "https://one.example/api.php")
        val existingIdentity = CatalogIdentity.from(existingSite)
        val newCollision = keySite(key = "cms", api = "https://two.example/api.php")

        val allocation = CatalogKeyFactory.allocate(
            sites = listOf(newCollision, existingSite),
            existing = mapOf(existingIdentity to "agg_cms"),
        )

        assertEquals("agg_cms", allocation.keyFor(existingSite))
        assertNotEquals("agg_cms", allocation.keyFor(newCollision))
    }
}

private fun keySite(key: String, api: String): NormalizedAggregatorSite =
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
