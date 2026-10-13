package com.streambox.streambox.spider

import android.content.Context
import com.github.catvod.crawler.SpiderApi
import com.github.catvod.crawler.SpiderDebug
import org.json.JSONArray
import org.json.JSONObject
import java.lang.reflect.Modifier
import java.net.URLEncoder
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicInteger

/** Lazy per-site instances; shared bundles never share a site's ext or state. */
class SpiderRuntime(private val context: Context, private val artifacts: ArtifactStore = ArtifactStore(context)) : AutoCloseable {
    private val entries = ConcurrentHashMap<String, Entry>()
    private val initialized = mutableSetOf<String>()
    @Volatile private var playbackScope: String? = null
    private val resolver = WebResolver(context)
    private val proxy = SpiderProxy { key, params ->
        entries.values.firstOrNull { it.scope == key }?.proxy(params)
            ?: error("插件已释放，请重新选择内容")
    }
    val proxyOrigin get() = proxy.origin

    fun invoke(request: JSONObject): String {
        val site = request.getJSONObject("site")
        val method = request.getString("method")
        require(method in setOf("home", "category", "detail", "search", "play"))
        require(site.getString("api").matches(Regex("csp_[a-zA-Z0-9_.$]+"))) { "插件入口类无效" }
        val fingerprint = ArtifactStore.digest("SHA-256", site.toString().toByteArray())
        val entry = entries.computeIfAbsent(fingerprint) { create(site, fingerprint) }
        val params = request.optJSONObject("params") ?: JSONObject()
        val body = entry.call {
            when (method) {
                "home" -> entry.invoke("homeContent", params.optBoolean("filter", true))
                "category" -> entry.invoke("categoryContent", params.getString("tid"), params.optString("page", "1"),
                    params.optBoolean("filter", true), stringMap(params.optJSONObject("extend")))
                "detail" -> entry.invoke("detailContent", params.getJSONArray("ids").let { a -> (0 until a.length()).map(a::getString) })
                "search" -> entry.invoke("searchContent", params.getString("keyword"), params.optBoolean("quick", false))
                else -> entry.invoke("playerContent", params.optString("flag"), params.getString("id"),
                    site.optJSONObject("runtimeConfig")?.optJSONArray("flags")?.let { a -> (0 until a.length()).map(a::getString) } ?: emptyList<String>())
            } as? String ?: error("插件没有返回 JSON")
        }
        val json = JSONObject(body)
        if (method == "play") {
            resolvePlay(json, site, params)
            playbackScope = entry.scope
        }
        rewrite(json, entry.address)
        trimIdleEntries(entry)
        return json.toString()
    }

    private fun create(site: JSONObject, fingerprint: String): Entry {
        val bundle = artifacts.load(site.getString("jar"))
        val loader = bundle.loader
        // CatVod Init implementations cast this to Application and register
        // lifecycle callbacks; a ContextWrapper breaks their binary contract.
        val pluginContext = context.applicationContext
        synchronized(initialized) {
            if (bundle.digest !in initialized) {
                val init = try { loader.loadClass("com.github.catvod.spider.Init") } catch (_: ClassNotFoundException) { null }
                init?.methods?.firstOrNull { it.name == "init" && Modifier.isStatic(it.modifiers) && it.parameterTypes.size == 1 }
                    ?.invoke(null, pluginContext)
                initialized.add(bundle.digest)
            }
        }
        val suffix = site.getString("api").removePrefix("csp_")
        val name = if (suffix.contains('.')) suffix else "com.github.catvod.spider.$suffix"
        val instance = try { loader.loadClass(name).getDeclaredConstructor().newInstance() }
        catch (error: ClassNotFoundException) {
            val init = loader.loadClass("com.github.catvod.spider.Init")
            init.getMethod("getSpider", String::class.java).invoke(null, suffix) ?: throw error
        }
        val entry = Entry(instance, loader, fingerprint, proxy.origin + "site/$fingerprint")
        val api = object : SpiderApi {
            override fun getAddress(local: Boolean) = entry.address
            override fun getPort() = java.net.URI(proxy.origin).port.toString()
            override fun log(message: String) = SpiderDebug.log(message)
            override fun webParse(url: String, headers: String): String =
                resolver.resolve(url, runCatching { JSONObject(headers) }.getOrNull()).getString("url")
        }
        try {
          entry.call {
            instance.javaClass.methods.firstOrNull { it.name == "initApi" && it.parameterTypes.size == 1 }?.invoke(instance, api)
            runCatching { instance.javaClass.getField("siteKey").set(instance, site.optString("upstreamKey", site.getString("key"))) }
            val ext = site.opt("ext").let { if (it == null || it == JSONObject.NULL) "" else it.toString() }
            val init = instance.javaClass.methods.firstOrNull { it.name == "init" && it.parameterTypes.size == 2 }
            if (init != null) init.invoke(instance, pluginContext, ext)
            else instance.javaClass.methods.firstOrNull { it.name == "init" && it.parameterTypes.size == 1 }?.invoke(instance, pluginContext)
          }
          return entry
        } catch (error: Throwable) {
          entry.close(); throw error
        }
    }

    private fun resolvePlay(result: JSONObject, site: JSONObject, params: JSONObject) {
        val value = result.opt("url")
        val url = when (value) {
            is String -> value
            is JSONArray -> if (value.length() >= 2) value.getString(1) else ""
            is JSONObject -> value.optJSONArray("values")?.optJSONObject(0)?.optString("v") ?: ""
            else -> ""
        }
        require(url.isNotBlank()) { "插件没有返回播放地址" }
        result.put("url", url)
        val needsParse = result.optInt("parse", 0) != 0 || result.optInt("jx", 0) != 0
        if (!needsParse) return
        val parsers = site.optJSONObject("runtimeConfig")?.optJSONArray("parses") ?: JSONArray()
        val candidates = (0 until parsers.length()).mapNotNull { parsers.optJSONObject(it) }.take(3)
        for (parser in candidates) {
            if (parser.optInt("type") != 1) continue
            try {
                val base = parser.getString("url")
                val endpoint = if (base.startsWith("./") || base.startsWith("../"))
                    java.net.URI(site.getString("configUrl")).resolve(base).toString() else base
                val headers = stringMap(parser.optJSONObject("ext")?.optJSONObject("header"))
                val connection = PluginNetwork.open(endpoint + URLEncoder.encode(url, "UTF-8"), headers)
                val output = java.io.ByteArrayOutputStream()
                connection.inputStream.use { ArtifactStore.copyBounded(it, output, 1024 * 1024) }
                connection.disconnect()
                val json = JSONObject(output.toString("UTF-8"))
                val resolved = if (json.opt("data") is JSONObject) json.getJSONObject("data") else json
                val media = resolved.optString("url")
                if (media.isBlank()) continue
                PluginNetwork.requirePublic(media)
                result.put("url", media).put("parse", 0).put("jx", 0)
                result.put("header", resolved.opt("header") ?: JSONObject(headers))
                return
            } catch (_: Exception) { /* Try the next declared parser. */ }
        }
        val sniffed = resolver.resolve(url, result.opt("header").let {
            if (it is JSONObject) it else if (it is String) runCatching { JSONObject(it) }.getOrNull() else null
        }, site.optString("click"))
        result.put("url", sniffed.getString("url")).put("header", sniffed.getJSONObject("header"))
            .put("parse", 0).put("jx", 0)
    }

    private fun rewrite(value: Any, address: String) {
        val port = java.net.URI(proxy.origin).port
        fun replace(s: String): String = s.replace(Regex("http://(?:127\\.0\\.0\\.1|localhost):(?:9978|-1|$port)(?=/(?!spider/))"), address)
        when (value) {
            is JSONObject -> value.keys().asSequence().toList().forEach { key ->
                val child = value.get(key)
                if (child is String) value.put(key, replace(child)) else rewrite(child, address)
            }
            is JSONArray -> (0 until value.length()).forEach { i ->
                val child = value.get(i)
                if (child is String) value.put(i, replace(child)) else rewrite(child, address)
            }
        }
    }

    private fun trimIdleEntries(current: Entry) {
        if (entries.size <= 16) return
        entries.entries.filter { it.value !== current && it.value.scope != playbackScope && it.value.active.get() == 0 }
            .sortedBy { it.value.usedAt }.take(entries.size - 16).forEach { (key, entry) ->
                if (entries.remove(key, entry)) entry.close()
            }
    }
    override fun close() { proxy.close(); entries.values.forEach(Entry::close); entries.clear() }

    private class Entry(val instance: Any, val loader: ClassLoader, val scope: String, val address: String) {
        val active = AtomicInteger()
        @Volatile var usedAt = System.currentTimeMillis()
        private val executor = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue(16))
        fun <T> call(block: () -> T): T {
            active.incrementAndGet(); usedAt = System.currentTimeMillis()
            var future: Future<T>? = null
            try {
                future = executor.submit(Callable {
                    Thread.currentThread().contextClassLoader = loader
                    block()
                })
                return future.get(25, TimeUnit.SECONDS)
            } catch (error: TimeoutException) {
                future?.cancel(true); throw error
            } finally { active.decrementAndGet() }
        }
        fun invoke(name: String, vararg args: Any): Any? {
            val method = instance.javaClass.methods.firstOrNull { it.name == name && it.parameterTypes.size == args.size }
                ?: error("插件缺少方法：$name")
            return method.invoke(instance, *args)
        }
        fun proxy(params: Map<String, String>): Array<*> = call {
            val own = instance.javaClass.methods.firstOrNull { it.name == "proxy" && it.parameterTypes.size == 1 }
            val result = own?.invoke(instance, params)
                ?: runCatching {
                    loader.loadClass("com.github.catvod.spider.Proxy").getMethod("proxy", Map::class.java).invoke(null, params)
                }.getOrNull()
                ?: loader.loadClass("com.github.catvod.spider.Init").getMethod("proxyInvoke", Map::class.java).invoke(null, params)
            result as? Array<*> ?: error("插件代理响应无效")
        }
        fun close() {
            runCatching { executor.execute { runCatching { invoke("destroy") } } }
            executor.shutdown()
        }
    }
    companion object {
        fun stringMap(json: JSONObject?): HashMap<String, String> = hashMapOf<String, String>().apply {
            json?.keys()?.forEach { key -> put(key, json.get(key).toString()) }
        }
    }
}
