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
    /// hidden=true 的插件照常加载并对外可访问，但不出现在 /api/list 中。
    /// 用途：让 StreamBox 客户端自动发现时不暴露，需要时由用户手动用 /api/{key} 链接添加。
    val hidden: Boolean = false,
)

data class BridgeConfig(
    val server: ServerConfig = ServerConfig(),
    val timeout: Long = 15_000,
    val logLevel: String = "INFO",
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
                plugins = pluginsList,
            )
        }
    }
}
