package com.streambox.bridge.config

import org.yaml.snakeyaml.Yaml
import java.io.File

data class ServerConfig(
    val port: Int = 9978,
    val host: String = "0.0.0.0",
)

data class PluginConfig(
    val key: String,
    val name: String,
    val jar: String,
    val className: String,
    val ext: String = "",
    val hidden: Boolean = false,
)

data class CatalogConfig(
    val retirementGraceMs: Long = 30_000,
)

data class SecurityConfig(
    val allowedPrivateHosts: List<String> = emptyList(),
    val allowedPrivateCidrs: List<String> = emptyList(),
)

data class BridgeConfig(
    val server: ServerConfig = ServerConfig(),
    val timeout: Long = 15_000,
    val logLevel: String = "INFO",
    val catalog: CatalogConfig = CatalogConfig(),
    val security: SecurityConfig = SecurityConfig(),
    val plugins: List<PluginConfig> = emptyList(),
) {
    companion object {
        fun load(path: String = "config.yml"): BridgeConfig {
            val file = File(path)
            if (!file.exists()) return BridgeConfig()

            val raw = Yaml().load<Map<String, Any>>(file.readText()) ?: return BridgeConfig()
            val serverMap = raw["server"] as? Map<*, *>
            val catalogMap = raw["catalog"].asMap()
            val securityMap = raw["security"].asMap()
            val plugins = (raw["plugins"] as? List<*>)?.mapNotNull { item ->
                val map = item as? Map<*, *> ?: return@mapNotNull null
                val key = map["key"]?.toString() ?: return@mapNotNull null
                val jar = map["jar"]?.toString() ?: return@mapNotNull null
                val className = map["class"]?.toString() ?: return@mapNotNull null
                PluginConfig(
                    key = key,
                    name = map["name"]?.toString() ?: key,
                    jar = jar,
                    className = className,
                    ext = map["ext"]?.toString() ?: "",
                    hidden = (map["hidden"] as? Boolean) ?: false,
                )
            }.orEmpty()

            return BridgeConfig(
                server = ServerConfig(
                    port = (serverMap?.get("port") as? Number)?.toInt() ?: 9978,
                    host = serverMap?.get("host")?.toString() ?: "0.0.0.0",
                ),
                timeout = (raw["timeout"] as? Number)?.toLong() ?: 15_000,
                logLevel = raw["logLevel"]?.toString() ?: "INFO",
                catalog = CatalogConfig(
                    retirementGraceMs = catalogMap["retirementGraceMs"].asLong(30_000),
                ),
                security = SecurityConfig(
                    allowedPrivateHosts = securityMap["allowedPrivateHosts"].asStringList(),
                    allowedPrivateCidrs = securityMap["allowedPrivateCidrs"].asStringList(),
                ),
                plugins = plugins,
            )
        }
    }
}

private fun Any?.asMap(): Map<*, *> = this as? Map<*, *> ?: emptyMap<Any, Any>()

private fun Any?.asLong(default: Long): Long = (this as? Number)?.toLong()
    ?: toString().toLongOrNull()
    ?: default

private fun Any?.asStringList(): List<String> = (this as? List<*>)
    ?.mapNotNull { it?.toString() }
    .orEmpty()
