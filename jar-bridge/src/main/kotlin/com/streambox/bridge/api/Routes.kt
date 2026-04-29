package com.streambox.bridge.api

import com.streambox.bridge.spider.SpiderManager
import com.streambox.bridge.spider.SpiderTimeoutException
import io.ktor.http.*
import io.ktor.server.application.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import org.slf4j.LoggerFactory
import java.util.Base64
import java.util.concurrent.TimeUnit

private val json = Json { prettyPrint = false }
private val routeLogger = LoggerFactory.getLogger("Routes")
private val httpClient = OkHttpClient.Builder()
    .connectTimeout(10, TimeUnit.SECONDS)
    .readTimeout(10, TimeUnit.SECONDS)
    .build()
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

            call.respondResult(result)
        }

        // 图片代理（处理需要特定 header 的图片 URL）
        get("/proxy") {
            val encodedUrl = call.request.queryParameters["url"]
                ?: return@get call.respond(HttpStatusCode.BadRequest)
            val encodedHeader = call.request.queryParameters["header"]

            try {
                val realUrl = String(Base64.getDecoder().decode(encodedUrl))
                val builder = Request.Builder().url(realUrl)

                // 解码并应用 header
                if (encodedHeader != null) {
                    try {
                        val headerJson = JSONObject(String(Base64.getDecoder().decode(encodedHeader)))
                        headerJson.keys().forEach { key ->
                            builder.addHeader(key, headerJson.getString(key))
                        }
                    } catch (_: Exception) {}
                }

                val response = httpClient.newCall(builder.build()).execute()
                val body = response.body?.bytes()
                if (body != null && response.isSuccessful) {
                    val contentType = response.header("Content-Type") ?: "image/jpeg"
                    call.respondBytes(body, ContentType.parse(contentType))
                } else {
                    call.respond(HttpStatusCode.BadGateway)
                }
            } catch (e: Exception) {
                call.respond(HttpStatusCode.InternalServerError)
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
                    val fixed = jsonStr.replace("http://127.0.0.1:-1", bridgeBase)
                    respondText(fixed, ContentType.Application.Json)
                } catch (_: Exception) {
                    respondError(502, "Invalid JSON response from plugin")
                }
            }
        },
        onFailure = { err ->
            val code = when (err) {
                is SpiderTimeoutException -> 504
                else -> 500
            }
            respondError(code, err.message?.take(200) ?: "Unknown error")
        }
    )
}

private suspend fun ApplicationCall.respondError(code: Int, msg: String) {
    val status = when (code) {
        400 -> HttpStatusCode.BadRequest
        404 -> HttpStatusCode.NotFound
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
