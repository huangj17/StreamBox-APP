package com.streambox.bridge.catalog

import com.streambox.bridge.aggregator.NormalizedAggregatorSite
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

class SourceClassifierTest {
    @Test
    fun `classification uses api shape and jar availability instead of type alone`() {
        val httpType3 = site(key = "http", type = 3, api = "https://cms.example/api.php")
        val globalJar = site(key = "global", type = 3, api = "csp_Global")
        val siteJar = site(
            key = "site",
            type = 3,
            api = "com.example.SiteSpider",
            jar = "https://example.com/site.jar",
        )
        val missingJar = site(key = "missing", type = 3, api = "csp_Missing")

        assertIs<SourceClassification.Cms>(SourceClassifier.classify(httpType3, null))

        val global = assertIs<SourceClassification.Jar>(
            SourceClassifier.classify(globalJar, "https://example.com/global.jar"),
        )
        assertEquals("https://example.com/global.jar", global.jarReference)
        assertEquals("com.github.catvod.spider.Global", global.className)

        val local = assertIs<SourceClassification.Jar>(SourceClassifier.classify(siteJar, null))
        assertEquals("https://example.com/site.jar", local.jarReference)
        assertEquals("com.example.SiteSpider", local.className)

        val invalid = assertIs<SourceClassification.Invalid>(
            SourceClassifier.classify(missingJar, null),
        )
        assertEquals(ClassificationError.JAR_REFERENCE_MISSING, invalid.error)
    }

    @Test
    fun `blank upstream key is isolated even when api is otherwise valid`() {
        val blankKey = site(key = "", type = 1, api = "https://cms.example/api.php")

        val invalid = assertIs<SourceClassification.Invalid>(
            SourceClassifier.classify(blankKey, null),
        )

        assertEquals(ClassificationError.KEY_MISSING, invalid.error)
    }

    @Test
    fun `unsupported ext type is isolated per site`() {
        val unsupportedExt = site(
            key = "cms",
            type = 1,
            api = "https://cms.example/api.php",
        ).copy(ext = "[1,2]", extSupported = false)

        val invalid = assertIs<SourceClassification.Invalid>(
            SourceClassifier.classify(unsupportedExt, null),
        )

        assertEquals(ClassificationError.EXT_TYPE_UNSUPPORTED, invalid.error)
    }

    @Test
    fun `http cms does not depend on an unrelated global spider reference`() {
        val cms = site(key = "cms", type = 1, api = "https://cms.example/api.php")

        assertIs<SourceClassification.Cms>(
            SourceClassifier.classify(cms, "{{unresolved-global-spider}}"),
        )
    }
}

private fun site(
    key: String,
    type: Int?,
    api: String,
    jar: String? = null,
): NormalizedAggregatorSite = NormalizedAggregatorSite(
    key = key,
    name = key,
    type = type,
    api = api,
    searchable = true,
    quickSearch = true,
    filterable = true,
    jar = jar,
    ext = null,
)
