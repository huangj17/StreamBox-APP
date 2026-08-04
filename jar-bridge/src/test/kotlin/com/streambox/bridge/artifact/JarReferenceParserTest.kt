package com.streambox.bridge.artifact

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class JarReferenceParserTest {
    @Test
    fun `parser supports img prefix and normalizes declared md5`() {
        val parsed = JarReferenceParser.parse(
            " img+https://cdn.example/spider.jar;md5;ABCDEF0123456789ABCDEF0123456789 ",
        )

        assertEquals("img", parsed.prefix)
        assertEquals("https://cdn.example/spider.jar", parsed.url.toString())
        assertEquals("abcdef0123456789abcdef0123456789", parsed.declaredMd5)
    }

    @Test
    fun `parser resolves relative references against final aggregator url`() {
        val parsed = JarReferenceParser.parse(
            "../jar/spider.jar",
            baseUrl = "https://aggregator.example/config/root.json",
        )

        assertEquals("https://aggregator.example/jar/spider.jar", parsed.url.toString())
    }

    @Test
    fun `parser rejects non http schemes placeholders and invalid md5`() {
        listOf(
            "file:///tmp/spider.jar",
            "https://example/{{jar}}",
            "https://example/spider.jar;md5;bad",
        ).forEach { value ->
            assertFailsWith<JarReferenceException> { JarReferenceParser.parse(value) }
        }
    }
}
