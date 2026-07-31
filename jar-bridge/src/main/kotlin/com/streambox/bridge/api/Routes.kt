package com.streambox.bridge.api

import com.streambox.bridge.spider.SpiderManager
import com.streambox.bridge.spider.SpiderTimeoutException
import com.streambox.bridge.spider.SpiderUnavailableException
import io.ktor.http.*
import io.ktor.server.application.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.json.JSONObject
import org.slf4j.LoggerFactory
import java.util.Base64

private val json = Json { prettyPrint = false }
private val routeLogger = LoggerFactory.getLogger("Routes")

/// 匹配 `"https://x.comhttps://y.com/...` 这种 spider 拼接两次 host 的脏 URL，
/// 捕获第二个 scheme 起的部分。仅在 JSON 字符串值（前面有 `"`）的位置生效，
/// 避免误伤含 https:// 的正文。
private val doubleSchemeRegex = Regex("\"https?://[^\"\\s]*?(https?://[^\"\\s]+)")
private var startTime = System.currentTimeMillis()

@Serializable
data class ApiListResponse(val code: Int, val sources: List<com.streambox.bridge.spider.PluginInfo>)

fun Application.configureRoutes(manager: SpiderManager) {
    startTime = System.currentTimeMillis()

    routing {
        // 插件列表
        get("/api/list") {
            val sources = manager.listAll()
            call.respondText(
                json.encodeToString(ApiListResponse(code = 200, sources = sources)),
                ContentType.Application.Json
            )
        }

        // 健康检查
        get("/health") {
            call.respondText(buildHealthJson(manager), ContentType.Application.Json)
        }

        // 核心 API：CMS 兼容格式
        get("/api/{key}") {
            val key = call.parameters["key"]
                ?: return@get call.respondError(400, "Missing plugin key")
            val spider = manager.get(key)
                ?: return@get call.respondError(404, "Plugin not found: $key")

            val ac = call.request.queryParameters["ac"]
            val t = call.request.queryParameters["t"]
            val pg = call.request.queryParameters["pg"] ?: "1"
            val ids = call.request.queryParameters["ids"]
            val wd = call.request.queryParameters["wd"]

            // 缓存键：仅 ?ac=class（首页分类）和 ?ac=detail&t=X&pg=Y（分类页）走缓存。
            // detail by ids / search 不缓存（用户级查询）。
            val cacheKey: String? = when {
                ac == "class" || (ac == null && t == null && ids == null && wd == null) ->
                    "$key:class"
                t != null -> "$key:t=$t:pg=$pg"
                else -> null
            }

            // 命中缓存：跳过 spider 调用，直接进 respondResult 走 sanitize
            cacheKey?.let { ResponseCache.get(it) }?.let { cached ->
                call.respondResult(Result.success(cached))
                return@get
            }

            val result: Result<String> = when {
                ac == "class" || (ac == null && t == null && ids == null && wd == null) ->
                    spider.homeContent(filter = true)

                ac == "detail" && ids != null ->
                    spider.detailContent(ids.split(","))

                t != null ->
                    spider.categoryContent(t, pg, filter = true, hashMapOf())

                wd != null ->
                    spider.searchContent(wd, quick = false)

                else ->
                    Result.failure(IllegalArgumentException("Bad request parameters"))
            }

            // 仅成功且非空时写缓存（验证由 respondResult 兜底；若是 invalid JSON
            // 下次命中也会被 502，60s 后过期，acceptable）
            if (cacheKey != null) {
                result.onSuccess { jsonStr ->
                    if (jsonStr.isNotBlank()) ResponseCache.put(cacheKey, jsonStr)
                }
            }

            call.respondResult(result)
        }

        // 图片代理（处理需要特定 header 的图片 URL）
        get("/proxy") {
            val encodedUrl = call.request.queryParameters["url"]
                ?: return@get call.respond(HttpStatusCode.BadRequest)
            val encodedHeader = call.request.queryParameters["header"]
            val signature = call.request.queryParameters["sig"]
            if (!isAuthorizedProxyRequest(encodedUrl, encodedHeader, signature)) {
                return@get call.respondError(403, "Invalid or missing proxy signature")
            }

            try {
                val realUrl = String(Base64.getDecoder().decode(encodedUrl), Charsets.UTF_8)
                val headers = mutableMapOf<String, String>()

                // 解码并应用 header
                if (encodedHeader != null) {
                    try {
                        val headerJson = JSONObject(
                            String(Base64.getDecoder().decode(encodedHeader), Charsets.UTF_8)
                        )
                        headerJson.keys().forEach { key ->
                            headers[key] = headerJson.getString(key)
                        }
                    } catch (_: Exception) {}
                }

                val payload = fetchProxyImage(realUrl, headers)
                call.respondBytes(payload.bytes, ContentType.parse(payload.contentType))
            } catch (e: UnsafeProxyTargetException) {
                routeLogger.warn("Rejected unsafe proxy target: {}", e.message)
                call.respondError(400, e.message ?: "Unsafe proxy target")
            } catch (_: ProxyResponseTooLargeException) {
                call.respond(
                    HttpStatusCode.PayloadTooLarge,
                    """{"code":413,"msg":"Proxy response exceeds 10 MiB"}""",
                )
            } catch (e: Exception) {
                routeLogger.warn("Proxy request failed: {}", e.message)
                call.respondError(502, "Proxy upstream request failed")
            }
        }

        // 播放地址二次解析
        get("/api/{key}/play") {
            val key = call.parameters["key"]
                ?: return@get call.respondError(400, "Missing plugin key")
            val spider = manager.get(key)
                ?: return@get call.respondError(404, "Plugin not found: $key")

            val flag = call.request.queryParameters["flag"] ?: ""
            val id = call.request.queryParameters["id"] ?: ""

            val result = spider.playerContent(flag, id, emptyList())
            call.respondResult(result)
        }
    }
}

private suspend fun ApplicationCall.respondResult(result: Result<String>) {
    result.fold(
        onSuccess = { jsonStr ->
            // 校验返回的 JSON 是否合法
            if (jsonStr.isBlank() || (!jsonStr.trimStart().startsWith("{") && !jsonStr.trimStart().startsWith("["))) {
                respondError(502, "Invalid response from plugin")
            } else {
                try {
                    Json.parseToJsonElement(jsonStr)
                    // 把 Spider 返回的本地 proxy URL 替换为 Bridge 实际地址
                    val hostHeader = request.headers["Host"] ?: "localhost:${request.local.localPort}"
                    val bridgeBase = "http://$hostHeader"
                    var fixed = authorizeLocalProxyUrls(jsonStr, bridgeBase)
                    fixed = fixed.replace("http://127.0.0.1:-1", bridgeBase)
                    // 修复部分 spider 拼接 host 时重复出现两个 https://（如 ysj/doll）
                    // 形如 "https://www.dmmiku.comhttps://img.dmmiku.com/..." → 取后段
                    fixed = doubleSchemeRegex.replace(fixed, "\"$1")
                    respondText(fixed, ContentType.Application.Json)
                } catch (_: Exception) {
                    respondError(502, "Invalid JSON response from plugin")
                }
            }
        },
        onFailure = { err ->
            val code = when (err) {
                is SpiderTimeoutException -> 504
                is SpiderUnavailableException -> 503
                else -> 500
            }
            respondError(code, err.message?.take(200) ?: "Unknown error")
        }
    )
}

private suspend fun ApplicationCall.respondError(code: Int, msg: String) {
    val status = when (code) {
        400 -> HttpStatusCode.BadRequest
        403 -> HttpStatusCode.Forbidden
        404 -> HttpStatusCode.NotFound
        502 -> HttpStatusCode.BadGateway
        503 -> HttpStatusCode.ServiceUnavailable
        504 -> HttpStatusCode.GatewayTimeout
        else -> HttpStatusCode.InternalServerError
    }
    respondText(
        """{"code":$code,"msg":"${msg.replace("\"", "\\\"")}"}""",
        ContentType.Application.Json,
        status
    )
}

private fun buildHealthJson(manager: SpiderManager): String {
    val uptimeMs = System.currentTimeMillis() - startTime
    val uptimeStr = formatUptime(uptimeMs)

    val details = manager.allKeys().map { key ->
        val spider = manager.get(key)
        val loadTime = manager.getLoadTime(key)
        val failedReason = manager.getFailedReason(key)
        if (spider != null) {
            """{"key":"$key","status":"ok","loadTime":"${loadTime ?: 0}ms"}"""
        } else {
            """{"key":"$key","status":"failed","error":"${failedReason?.take(100)?.replace("\"", "\\\"") ?: ""}"}"""
        }
    }

    return """{"status":"ok","uptime":"$uptimeStr","plugins":{"loaded":${manager.loadedCount()},"failed":${manager.failedCount()},"details":[${details.joinToString(",")}]}}"""
}

private fun formatUptime(ms: Long): String {
    val seconds = ms / 1000
    val minutes = seconds / 60
    val hours = minutes / 60
    return when {
        hours > 0 -> "${hours}h${minutes % 60}m"
        minutes > 0 -> "${minutes}m${seconds % 60}s"
        else -> "${seconds}s"
    }
}
