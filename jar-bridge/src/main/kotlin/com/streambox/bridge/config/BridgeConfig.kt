package com.streambox.bridge.config

import org.yaml.snakeyaml.Yaml
import java.io.File
import java.time.Duration

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
    /// hidden=true 的插件照常加载并对外可访问，但不出现在 /api/list 中。
    /// 用途：让 StreamBox 客户端自动发现时不暴露，需要时由用户手动用 /api/{key} 链接添加。
    val hidden: Boolean = false,
)

data class AggregatorConfig(
    val enabled: Boolean = false,
    val baseUrl: String? = null,
    val tokenEnv: String? = null,
    val headersFromEnv: Map<String, String> = emptyMap(),
    val syncInterval: Duration = Duration.ofMinutes(15),
    val connectTimeoutMs: Long = 5_000,
    val readTimeoutMs: Long = 15_000,
    val maxResponseBytes: Long = 10L * 1024 * 1024,
)

enum class CatalogMode {
    MANUAL,
    AGGREGATOR,
    HYBRID,
}

data class CatalogConfig(
    val mode: CatalogMode = CatalogMode.MANUAL,
    val snapshotRetention: Int = 2,
    val retirementGraceMs: Long = 30_000,
    val allowEmpty: Boolean = false,
)

data class ArtifactConfig(
    val maxJarBytes: Long = 100L * 1024 * 1024,
    val cacheMaxBytes: Long = 2L * 1024 * 1024 * 1024,
    val downloadConcurrency: Int = 4,
    val maxZipEntries: Int = 50_000,
)

data class SecurityConfig(
    val secretKeyEnv: String = "BRIDGE_SECRET_KEY",
    val allowedPrivateHosts: List<String> = emptyList(),
    val allowedPrivateCidrs: List<String> = emptyList(),
)

data class AdminConfig(
    val enabled: Boolean = false,
    val tokenEnv: String = "BRIDGE_ADMIN_TOKEN",
)

data class BridgeConfig(
    val server: ServerConfig = ServerConfig(),
    val timeout: Long = 15_000,
    val logLevel: String = "INFO",
    val aggregator: AggregatorConfig = AggregatorConfig(),
    val catalog: CatalogConfig = CatalogConfig(),
    val artifacts: ArtifactConfig = ArtifactConfig(),
    val security: SecurityConfig = SecurityConfig(),
    val admin: AdminConfig = AdminConfig(),
    val plugins: List<PluginConfig> = emptyList(),
) {
    companion object {
        fun load(path: String = "config.yml"): BridgeConfig {
            val file = File(path)
            if (!file.exists()) {
                return BridgeConfig()
            }

            val yaml = Yaml()
            val raw = yaml.load<Map<String, Any>>(file.readText()) ?: return BridgeConfig()

            val serverMap = raw["server"] as? Map<*, *>
            val server = ServerConfig(
                port = (serverMap?.get("port") as? Number)?.toInt() ?: 9978,
                host = serverMap?.get("host")?.toString() ?: "0.0.0.0",
            )

            val timeout = (raw["timeout"] as? Number)?.toLong() ?: 15_000
            val logLevel = raw["logLevel"]?.toString() ?: "INFO"

            val aggregatorMap = raw["aggregator"].asMap()
            val aggregator = AggregatorConfig(
                enabled = aggregatorMap["enabled"].asBoolean(default = false),
                baseUrl = aggregatorMap["baseUrl"]?.toString(),
                tokenEnv = aggregatorMap["tokenEnv"]?.toString(),
                headersFromEnv = aggregatorMap["headersFromEnv"].asStringMap(),
                syncInterval = aggregatorMap["syncInterval"]?.toString()
                    ?.let(Duration::parse)
                    ?: Duration.ofMinutes(15),
                connectTimeoutMs = aggregatorMap["connectTimeout"].asLong(5_000),
                readTimeoutMs = aggregatorMap["readTimeout"].asLong(15_000),
                maxResponseBytes = aggregatorMap["maxResponseBytes"].asLong(10L * 1024 * 1024),
            )

            val catalogMap = raw["catalog"].asMap()
            val catalog = CatalogConfig(
                mode = catalogMap["mode"]?.toString()
                    ?.uppercase()
                    ?.let(CatalogMode::valueOf)
                    ?: CatalogMode.MANUAL,
                snapshotRetention = catalogMap["snapshotRetention"].asInt(2),
                retirementGraceMs = catalogMap["retirementGraceMs"].asLong(30_000),
                allowEmpty = catalogMap["allowEmpty"].asBoolean(default = false),
            )

            val artifactMap = raw["artifacts"].asMap()
            val artifacts = ArtifactConfig(
                maxJarBytes = artifactMap["maxJarBytes"].asLong(100L * 1024 * 1024),
                cacheMaxBytes = artifactMap["cacheMaxBytes"].asLong(2L * 1024 * 1024 * 1024),
                downloadConcurrency = artifactMap["downloadConcurrency"].asInt(4),
                maxZipEntries = artifactMap["maxZipEntries"].asInt(50_000),
            )

            val securityMap = raw["security"].asMap()
            val security = SecurityConfig(
                secretKeyEnv = securityMap["secretKeyEnv"]?.toString() ?: "BRIDGE_SECRET_KEY",
                allowedPrivateHosts = securityMap["allowedPrivateHosts"].asStringList(),
                allowedPrivateCidrs = securityMap["allowedPrivateCidrs"].asStringList(),
            )

            val adminMap = raw["admin"].asMap()
            val admin = AdminConfig(
                enabled = adminMap["enabled"].asBoolean(default = false),
                tokenEnv = adminMap["tokenEnv"]?.toString() ?: "BRIDGE_ADMIN_TOKEN",
            )

            val pluginsList = (raw["plugins"] as? List<*>)?.mapNotNull { item ->
                val map = item as? Map<*, *> ?: return@mapNotNull null
                val key = map["key"]?.toString() ?: return@mapNotNull null
                val name = map["name"]?.toString() ?: key
                val jar = map["jar"]?.toString() ?: return@mapNotNull null
                val className = map["class"]?.toString() ?: return@mapNotNull null
                val ext = map["ext"]?.toString() ?: ""
                val hidden = (map["hidden"] as? Boolean) ?: false
                PluginConfig(
                    key = key,
                    name = name,
                    jar = jar,
                    className = className,
                    ext = ext,
                    hidden = hidden,
                )
            } ?: emptyList()

            return BridgeConfig(
                server = server,
                timeout = timeout,
                logLevel = logLevel,
                aggregator = aggregator,
                catalog = catalog,
                artifacts = artifacts,
                security = security,
                admin = admin,
                plugins = pluginsList,
            )
        }
    }
}

private fun Any?.asMap(): Map<*, *> = this as? Map<*, *> ?: emptyMap<Any, Any>()

private fun Any?.asBoolean(default: Boolean): Boolean = when (this) {
    is Boolean -> this
    is String -> toBooleanStrictOrNull() ?: default
    is Number -> toInt() != 0
    else -> default
}

private fun Any?.asLong(default: Long): Long = (this as? Number)?.toLong()
    ?: toString().toLongOrNull()
    ?: default

private fun Any?.asInt(default: Int): Int = (this as? Number)?.toInt()
    ?: toString().toIntOrNull()
    ?: default

private fun Any?.asStringMap(): Map<String, String> = (this as? Map<*, *>)
    ?.mapNotNull { (key, value) ->
        val stringKey = key?.toString() ?: return@mapNotNull null
        val stringValue = value?.toString() ?: return@mapNotNull null
        stringKey to stringValue
    }
    ?.toMap()
    ?: emptyMap()

private fun Any?.asStringList(): List<String> = (this as? List<*>)
    ?.mapNotNull { it?.toString() }
    ?: emptyList()
