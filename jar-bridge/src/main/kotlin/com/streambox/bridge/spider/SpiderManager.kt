package com.streambox.bridge.spider

import com.streambox.bridge.config.BridgeConfig
import com.streambox.bridge.config.PluginConfig
import com.streambox.bridge.host.MockContext
import kotlinx.serialization.Serializable
import org.slf4j.LoggerFactory
import java.io.File
import java.net.URLClassLoader
import java.util.concurrent.ConcurrentHashMap

@Serializable
data class PluginInfo(
    val key: String,
    val name: String,
    val api: String,
)

class SpiderManager(private val config: BridgeConfig) {

    private val logger = LoggerFactory.getLogger(SpiderManager::class.java)
    private val spiders = ConcurrentHashMap<String, SpiderWrapper>()

    // 记录加载耗时，用于健康检查
    private val loadTimes = ConcurrentHashMap<String, Long>()
    private val failedPlugins = ConcurrentHashMap<String, String>()

    fun loadAll() {
        for (plugin in config.plugins) {
            try {
                val start = System.currentTimeMillis()
                load(plugin)
                val elapsed = System.currentTimeMillis() - start
                loadTimes[plugin.key] = elapsed
                logger.info("Loaded plugin: {} ({}) in {}ms", plugin.key, plugin.name, elapsed)
            } catch (e: Throwable) {
                failedPlugins[plugin.key] = e.message ?: "Unknown error"
                logger.error("Failed to load plugin: {}", plugin.key, e)
            }
        }
        logger.info("SpiderManager: {}/{} plugins loaded", spiders.size, config.plugins.size)
    }

    private fun load(plugin: PluginConfig) {
        val jarFile = File(plugin.jar)
        require(jarFile.exists()) { "JAR not found: ${plugin.jar}" }

        val classLoader = URLClassLoader(
            arrayOf(jarFile.toURI().toURL()),
            this::class.java.classLoader
        )

        val clazz = classLoader.loadClass(plugin.className)
        val spider = clazz.getDeclaredConstructor().newInstance()

        // 反射调用 init(Context, String) 或 init(Object, String)
        val context = MockContext(plugin.key)
        val initMethod = try {
            clazz.getMethod("init", android.content.Context::class.java, String::class.java)
        } catch (_: NoSuchMethodException) {
            clazz.getMethod("init", Any::class.java, String::class.java)
        }
        initMethod.invoke(spider, context, plugin.ext)

        spiders[plugin.key] = SpiderWrapper(
            key = plugin.key,
            name = plugin.name,
            instance = spider,
            clazz = clazz,
            classLoader = classLoader,
            timeoutMs = config.timeout,
        )
    }

    fun get(key: String): SpiderWrapper? = spiders[key]

    /// 返回对外公开（即非 hidden）的插件列表，供 StreamBox 客户端自动发现。
    /// hidden=true 的插件不在此列出，但 /api/{key} 直接访问仍可用。
    fun listAll(): List<PluginInfo> = config.plugins
        .filter { spiders.containsKey(it.key) && !it.hidden }
        .map { PluginInfo(key = it.key, name = it.name, api = "/api/${it.key}") }

    fun loadedCount(): Int = spiders.size
    fun failedCount(): Int = failedPlugins.size
    fun getLoadTime(key: String): Long? = loadTimes[key]
    fun getFailedReason(key: String): String? = failedPlugins[key]
    fun allKeys(): Set<String> = spiders.keys + failedPlugins.keys

    fun shutdown() {
        spiders.values.forEach { it.close() }
        spiders.clear()
        logger.info("SpiderManager shutdown complete")
    }
}
