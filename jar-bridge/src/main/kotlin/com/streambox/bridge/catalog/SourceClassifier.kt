package com.streambox.bridge.catalog

import com.streambox.bridge.aggregator.NormalizedAggregatorSite
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

enum class ClassificationError {
    KEY_MISSING,
    API_MISSING,
    JAR_REFERENCE_MISSING,
    PLACEHOLDER_UNRESOLVED,
    EXT_TYPE_UNSUPPORTED,
    JAVASCRIPT_UNSUPPORTED,
    PYTHON_UNSUPPORTED,
    SOURCE_KIND_UNSUPPORTED,
}

sealed interface SourceClassification {
    val site: NormalizedAggregatorSite

    data class Cms(
        override val site: NormalizedAggregatorSite,
    ) : SourceClassification

    data class Jar(
        override val site: NormalizedAggregatorSite,
        val jarReference: String,
        val className: String,
    ) : SourceClassification

    data class Unsupported(
        override val site: NormalizedAggregatorSite,
        val error: ClassificationError,
    ) : SourceClassification

    data class Invalid(
        override val site: NormalizedAggregatorSite,
        val error: ClassificationError,
    ) : SourceClassification
}

object SourceClassifier {
    private val javaClassName = Regex(
        "^[A-Za-z_$][A-Za-z0-9_$]*(?:\\.[A-Za-z_$][A-Za-z0-9_$]*)+$",
    )

    fun classify(
        site: NormalizedAggregatorSite,
        globalSpider: String?,
    ): SourceClassification {
        val api = site.api.trim()
        val jar = site.jar?.takeIf(String::isNotBlank)
            ?: globalSpider?.takeIf(String::isNotBlank)
        val isJarApi = api.startsWith("csp_") || javaClassName.matches(api)

        return when {
            site.key.isBlank() -> SourceClassification.Invalid(site, ClassificationError.KEY_MISSING)
            api.isBlank() -> SourceClassification.Invalid(site, ClassificationError.API_MISSING)
            !site.extSupported -> SourceClassification.Invalid(
                site,
                ClassificationError.EXT_TYPE_UNSUPPORTED,
            )
            hasPlaceholder(api) || (isJarApi && hasPlaceholder(jar)) -> SourceClassification.Invalid(
                site,
                ClassificationError.PLACEHOLDER_UNRESOLVED,
            )
            api.startsWith("csp_") && jar != null -> SourceClassification.Jar(
                site = site,
                jarReference = jar,
                className = "com.github.catvod.spider.${api.removePrefix("csp_")}",
            )
            javaClassName.matches(api) && jar != null -> SourceClassification.Jar(
                site = site,
                jarReference = jar,
                className = api,
            )
            api.startsWith("py_") -> SourceClassification.Unsupported(
                site,
                ClassificationError.PYTHON_UNSUPPORTED,
            )
            api.startsWith("js_") -> SourceClassification.Unsupported(
                site,
                ClassificationError.JAVASCRIPT_UNSUPPORTED,
            )
            api.toHttpUrlOrNull()?.encodedPath?.endsWith(".js", ignoreCase = true) == true ->
                SourceClassification.Unsupported(site, ClassificationError.JAVASCRIPT_UNSUPPORTED)
            api.toHttpUrlOrNull() != null -> SourceClassification.Cms(site)
            jar == null -> SourceClassification.Invalid(
                site,
                ClassificationError.JAR_REFERENCE_MISSING,
            )
            else -> SourceClassification.Unsupported(
                site,
                ClassificationError.SOURCE_KIND_UNSUPPORTED,
            )
        }
    }

    private fun hasPlaceholder(value: String?): Boolean = value?.contains("{{") == true
}
