package com.streambox.bridge.catalog

import com.streambox.bridge.config.PluginConfig
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.time.Instant

data class ManualCatalogSource(
    val plugin: PluginConfig,
    val runtime: SpiderRuntime?,
    val failure: CatalogError? = null,
)

object ManualCatalogAdapter {
    fun build(
        sources: List<ManualCatalogSource>,
        version: String,
        activatedAt: Instant,
    ): ActiveCatalog {
        sources.groupingBy { it.plugin.key }
            .eachCount()
            .entries
            .firstOrNull { (_, count) -> count > 1 }
            ?.let { (key, _) ->
                throw CatalogBuildException(
                    CatalogError(
                        code = CatalogErrorCode.DUPLICATE_KEY,
                        message = "duplicate catalog key: $key",
                    ),
                )
            }
        val entries = linkedMapOf<String, RuntimeEntry>()
        sources.forEach { source ->
            val plugin = source.plugin
            val extDigest = sha256(plugin.ext)
            val specFingerprint = sha256(
                listOf(
                    SourceKind.MANUAL.name,
                    plugin.key,
                    plugin.jar,
                    plugin.className,
                    extDigest,
                    plugin.hidden.toString(),
                ).joinToString(separator = "\u0000"),
            )
            val handler = source.runtime?.let { SourceHandler.Spider(it) }
            entries[plugin.key] = RuntimeEntry(
                spec = CatalogEntrySpec(
                    key = plugin.key,
                    name = plugin.name,
                    kind = SourceKind.MANUAL,
                    origin = SourceOrigin.CONFIG_YAML,
                    api = "/api/${plugin.key}",
                    className = plugin.className,
                    jar = JarArtifactRef(source = plugin.jar),
                    extDigest = extDigest,
                    hidden = plugin.hidden,
                    specFingerprint = specFingerprint,
                ),
                status = if (handler == null) EntryStatus.FAILED else EntryStatus.READY,
                handler = handler,
                lastError = source.failure,
                lastReadyAt = if (handler == null) null else activatedAt,
            )
        }
        return ActiveCatalog(
            version = version,
            activatedAt = activatedAt,
            entries = entries,
        )
    }

    private fun sha256(value: String): String = MessageDigest
        .getInstance("SHA-256")
        .digest(value.toByteArray(StandardCharsets.UTF_8))
        .joinToString(separator = "") { byte -> "%02x".format(byte) }
}
