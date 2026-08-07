package com.streambox.bridge.config

import org.yaml.snakeyaml.Yaml
import java.io.File

data class ServerConfig(
    val port: Int = 9978,
    val host: String = "127.0.0.1",
    val publicBaseUrl: String = "http://127.0.0.1:9978",
    val enableDocs: Boolean = false,
)

data class PluginConfig(
    val key: String,
    val name: String,
    val jar: String,
    val className: String,
    val sha256: String = "",
    val ext: String = "",
    val hidden: Boolean = false,
)

data class CatalogConfig(
    val retirementGraceMs: Long = 30_000,
)

data class SecurityConfig(
    val allowedPrivateHosts: List<String> = emptyList(),
    val allowedPrivateCidrs: List<String> = emptyList(),
    val requireAuth: Boolean = false,
    val apiToken: String? = null,
    val rateLimitPerMinute: Int = 120,
    val rateLimitBurst: Int = 30,
    val maxConcurrentRequests: Int = 32,
    val maxResponseBytes: Long = 10L * 1024 * 1024,
    val maxQueryLength: Int = 4096,
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
                    sha256 = map["sha256"]?.toString()?.lowercase() ?: "",
                    ext = map["ext"]?.toString() ?: "",
                    hidden = (map["hidden"] as? Boolean) ?: false,
                )
            }.orEmpty()

            return BridgeConfig(
                server = ServerConfig(
                    port = System.getenv("BRIDGE_PORT")?.toIntOrNull()
                        ?: (serverMap?.get("port") as? Number)?.toInt()
                        ?: 9978,
                    host = System.getenv("BRIDGE_HOST")
                        ?: serverMap?.get("host")?.toString()
                        ?: "127.0.0.1",
                    publicBaseUrl = System.getenv("BRIDGE_PUBLIC_BASE_URL")
                        ?: serverMap?.get("publicBaseUrl")?.toString()
                        ?: "http://127.0.0.1:9978",
                    enableDocs = System.getenv("BRIDGE_ENABLE_DOCS").asBoolean()
                        ?: serverMap?.get("enableDocs").asBoolean()
                        ?: false,
                ),
                timeout = (raw["timeout"] as? Number)?.toLong() ?: 15_000,
                logLevel = raw["logLevel"]?.toString() ?: "INFO",
                catalog = CatalogConfig(
                    retirementGraceMs = catalogMap["retirementGraceMs"].asLong(30_000),
                ),
                security = SecurityConfig(
                    allowedPrivateHosts = securityMap["allowedPrivateHosts"].asStringList(),
                    allowedPrivateCidrs = securityMap["allowedPrivateCidrs"].asStringList(),
                    requireAuth = System.getenv("BRIDGE_REQUIRE_AUTH").asBoolean()
                        ?: securityMap["requireAuth"].asBoolean()
                        ?: false,
                    apiToken = System.getenv("BRIDGE_API_TOKEN")
                        ?.takeIf(String::isNotBlank),
                    rateLimitPerMinute = securityMap["rateLimitPerMinute"].asInt(120),
                    rateLimitBurst = securityMap["rateLimitBurst"].asInt(30),
                    maxConcurrentRequests = securityMap["maxConcurrentRequests"].asInt(32),
                    maxResponseBytes = securityMap["maxResponseBytes"].asLong(10L * 1024 * 1024),
                    maxQueryLength = securityMap["maxQueryLength"].asInt(4096),
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

private fun Any?.asInt(default: Int): Int = (this as? Number)?.toInt()
    ?: toString().toIntOrNull()
    ?: default

private fun Any?.asBoolean(): Boolean? = when (this) {
    is Boolean -> this
    is String -> when (lowercase()) {
        "true", "1", "yes" -> true
        "false", "0", "no" -> false
        else -> null
    }
    else -> null
}

private fun Any?.asStringList(): List<String> = (this as? List<*>)
    ?.mapNotNull { it?.toString() }
    .orEmpty()
