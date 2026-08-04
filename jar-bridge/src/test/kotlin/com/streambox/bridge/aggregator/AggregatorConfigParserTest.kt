package com.streambox.bridge.aggregator

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AggregatorConfigParserTest {
    @Test
    fun `parser normalizes tolerant tvbox fields relative urls and object ext`() {
        val body = checkNotNull(
            javaClass.getResource("/aggregator/config-v2.json"),
        ).readText()

        val parsed = AggregatorConfigParser.parse(
            body = body,
            finalUrl = "https://aggregator.example/config/root.json",
        )

        assertEquals(
            "https://aggregator.example/config/artifacts/global.jar;md5;0123456789abcdef0123456789abcdef",
            parsed.spider,
        )
        val relativeCms = parsed.sites.first { it.key == "cms_relative" }
        assertEquals("https://aggregator.example/config/cms/api.php", relativeCms.api)
        assertTrue(relativeCms.searchable)
        assertFalse(relativeCms.quickSearch)
        assertTrue(relativeCms.filterable)

        val objectExt = parsed.sites.first { it.key == "global_jar" }.ext
        assertEquals("{\"a\":1,\"z\":2}", objectExt)
        assertEquals(
            "https://aggregator.example/config/artifacts/site.jar",
            parsed.sites.first { it.key == "site_jar" }.jar,
        )
    }

    @Test
    fun `config digest ignores unknown fields and json object key order`() {
        val first = """
            {
              "unknown": 1,
              "sites": [{"key":"jar","api":"csp_Jar","ext":{"z":2,"a":1}}],
              "spider": "https://example.com/spider.jar"
            }
        """.trimIndent()
        val second = """
            {
              "spider": "https://example.com/spider.jar",
              "sites": [{"ext":{"a":1,"z":2},"api":"csp_Jar","key":"jar"}],
              "anotherUnknown": true
            }
        """.trimIndent()

        val firstParsed = AggregatorConfigParser.parse(first, "https://aggregator.example/config")
        val secondParsed = AggregatorConfigParser.parse(second, "https://aggregator.example/config")

        assertEquals(firstParsed.configDigest, secondParsed.configDigest)
    }
}
