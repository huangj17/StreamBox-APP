package com.streambox.bridge.api

import com.streambox.bridge.catalog.CatalogManager
import com.streambox.bridge.catalog.SourceHandler
import com.streambox.bridge.cms.CmsProxyException
import com.streambox.bridge.cms.CmsProxyService
import com.streambox.bridge.config.BridgeConfig
import com.streambox.bridge.security.GatewayDenial
import com.streambox.bridge.security.GatewayRequestGuard
import com.streambox.bridge.spider.SpiderManager
import com.streambox.bridge.spider.SpiderTimeoutException
import com.streambox.bridge.spider.SpiderUnavailableException
import io.ktor.http.*
import io.ktor.server.application.*
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import org.json.JSONObject
import org.slf4j.LoggerFactory
import java.nio.charset.StandardCharsets
import java.util.Base64
import java.util.HashMap

private val json = Json { prettyPrint = false }
private val routeLogger = LoggerFactory.getLogger("Routes")

/// 匹配 `"https://x.comhttps://y.com/...` 这种 spider 拼接两次 host 的脏 URL，
/// 捕获第二个 scheme 起的部分。仅在 JSON 字符串值（前面有 `"`）的位置生效，
/// 避免误伤含 https:// 的正文。
private val doubleSchemeRegex = Regex("\"https?://[^\"\\s]*?(https?://[^\"\\s]+)")
private val categoryRoutingParameters = setOf("ac", "t", "pg", "ids", "wd")
private val blockedSpiderExtendParameters = setOf("url", "host", "target", "gatewayurl", "apikey")
private var startTime = System.currentTimeMillis()

@Serializable
data class ApiSource(
    val key: String,
    val name: String,
    val api: String,
    val kind: String,
    val status: String,
    val searchable: Boolean,
)

@Serializable
data class ApiListResponse(
    val code: Int,
    val catalogVersion: String,
    val stale: Boolean,
    val sources: List<ApiSource>,
)

fun Application.configureRoutes(
    manager: SpiderManager,
    catalogManager: CatalogManager,
    config: BridgeConfig,
    cmsProxyService: CmsProxyService = CmsProxyService(),
) {
    startTime = System.currentTimeMillis()
    monitor.subscribe(ApplicationStopped) { cmsProxyService.close() }

    val requestGuard = GatewayRequestGuard(config.security)
    val publicBaseUrl = config.server.publicBaseUrl.trimEnd('/')
    val maxResponseBytes = config.security.maxResponseBytes

    routing {
        // 容器编排只需要最小存活信号；不暴露插件加载错误和运行时细节。
        get("/health/live") {
            call.respondText("{\"status\":\"ok\"}", ContentType.Application.Json)
        }

        // 插件列表
        get("/api/list") {
            val permit = call.acquireGatewayPermit(requestGuard, config) ?: return@get
            try {
            val sources = catalogManager.listPublic().map { entry ->
                ApiSource(
                    key = entry.spec.key,
                    name = entry.spec.name,
                    api = "/api/${entry.spec.key}",
                    kind = entry.spec.kind.name.lowercase(),
                    status = entry.status.name.lowercase(),
                    searchable = entry.spec.searchable,
                )
            }
            call.respondText(
                json.encodeToString(
                    ApiListResponse(
                        code = 200,
                        catalogVersion = catalogManager.current().version,
                        stale = false,
                        sources = sources,
                    ),
                ),
                ContentType.Application.Json
            )
            } finally {
                permit.close()
            }
        }

        // 健康检查
        get("/health") {
            val permit = call.acquireGatewayPermit(requestGuard, config) ?: return@get
            try {
            val hasEntries = catalogManager.listPublic().isNotEmpty()
            val health = if (hasEntries) "ok" else "error"
            call.respondText(
                buildHealthJson(manager, catalogManager, health),
                ContentType.Application.Json,
                if (health == "error") HttpStatusCode.ServiceUnavailable else HttpStatusCode.OK,
            )
            } finally {
                permit.close()
            }
        }

        // 核心 API：CMS 兼容格式
        get("/api/{key}") {
            val permit = call.acquireGatewayPermit(requestGuard, config) ?: return@get
            val key = call.parameters["key"]
                ?: run {
                    permit.close()
                    return@get call.respondError(400, "Missing plugin key")
                }
            val lease = catalogManager.acquire(key)
                ?: run {
                    permit.close()
                    return@get call.respondApiError(
                        HttpStatusCode.NotFound,
                        "SOURCE_NOT_FOUND",
                        "Source not found",
                    )
                }
            try {
                val ac = call.request.queryParameters["ac"]
                val t = call.request.queryParameters["t"]
                val pg = call.request.queryParameters["pg"] ?: "1"
                val ids = call.request.queryParameters["ids"]
                val wd = call.request.queryParameters["wd"]
                val operation = when {
                    ac == "detail" && ids != null -> "detail"
                    t != null -> "category"
                    wd != null -> "search"
                    ac == "class" || (ac == null && ids == null) -> "class"
                    else -> return@get call.respondApiError(
                        HttpStatusCode.BadRequest,
                        "BAD_QUERY",
                        "Unsupported content query",
                    )
                }
                val queryEntries = call.request.queryParameters.entries().flatMap { (name, values) ->
                    values.map { value -> name to value }
                }
                val categoryExtend = HashMap<String, String>().apply {
                    queryEntries.forEach { (name, value) ->
                        val normalized = name.lowercase()
                        if (normalized !in categoryRoutingParameters &&
                            normalized !in blockedSpiderExtendParameters
                        ) {
                            put(name, value)
                        }
                    }
                }

                // 缓存键：仅 ?ac=class（首页分类）和分类页走缓存。分类页必须包含
                // 完整规范化查询，避免 year/area/lang 等筛选之间互相污染。
                // detail by ids / search 不缓存（用户级查询）。
                val cacheKey: String? = when {
                    operation == "class" ->
                        "${catalogManager.current().version}:$key:class"
                    operation == "category" ->
                        "${catalogManager.current().version}:$key:category:${canonicalQuery(queryEntries)}"
                    else -> null
                }

                // 命中缓存：跳过 spider 调用，直接进 respondResult 走 sanitize
                cacheKey?.let { ResponseCache.get(it) }?.let { cached ->
                    call.respondResult(Result.success(cached), publicBaseUrl, maxResponseBytes)
                    return@get
                }

                val result: Result<String> = when (val handler = lease.handler) {
                    is SourceHandler.Spider -> when {
                        operation == "detail" ->
                            handler.runtime.detailContent(checkNotNull(ids).split(","))
                        operation == "category" ->
                            handler.runtime.categoryContent(checkNotNull(t), pg, true, categoryExtend)
                        operation == "search" ->
                            handler.runtime.searchContent(checkNotNull(wd), quick = false)
                        else -> handler.runtime.homeContent(filter = true)
                    }
                    is SourceHandler.Cms -> try {
                        Result.success(
                            cmsProxyService.execute(
                                handler = handler,
                                catalogVersion = catalogManager.current().version,
                                entryKey = key,
                                query = queryEntries,
                            ),
                        )
                    } catch (error: CmsProxyException) {
                        return@get call.respondCmsError(error)
                    }
                }

                // 仅成功且非空时写缓存（验证由 respondResult 兜底；若是 invalid JSON
                // 下次命中也会被 502，60s 后过期，acceptable）
                if (cacheKey != null) {
                    result.onSuccess { jsonStr ->
                        if (jsonStr.isNotBlank() && jsonStr.utf8Size() <= maxResponseBytes) {
                            ResponseCache.put(cacheKey, jsonStr)
                        }
                    }
                }

                call.respondResult(result, publicBaseUrl, maxResponseBytes)
            } finally {
                lease.close()
                permit.close()
            }
        }

        // 图片代理（处理需要特定 header 的图片 URL）
        get("/proxy") {
            // URL 自带进程级 HMAC capability；图片加载器无法附加 Gateway Bearer Token。
            val permit = call.acquireGatewayPermit(
                requestGuard,
                config,
                authenticationRequired = false,
            ) ?: return@get
            try {
            val encodedUrl = call.request.queryParameters["url"]
                ?: return@get call.respond(HttpStatusCode.BadRequest)
            val encodedHeader = call.request.queryParameters["header"]
            val expiresAt = call.request.queryParameters["exp"]?.toLongOrNull()
            val signature = call.request.queryParameters["sig"]
            if (!isAuthorizedProxyRequest(encodedUrl, encodedHeader, expiresAt, signature)) {
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
            } finally {
                permit.close()
            }
        }

        // 播放地址二次解析
        get("/api/{key}/play") {
            val permit = call.acquireGatewayPermit(requestGuard, config) ?: return@get
            val key = call.parameters["key"]
                ?: run {
                    permit.close()
                    return@get call.respondError(400, "Missing plugin key")
                }
            val lease = catalogManager.acquire(key)
                ?: run {
                    permit.close()
                    return@get call.respondApiError(
                        HttpStatusCode.NotFound,
                        "SOURCE_NOT_FOUND",
                        "Source not found",
                    )
                }
            try {
                val flag = call.request.queryParameters["flag"] ?: ""
                val id = call.request.queryParameters["id"]
                    ?.takeIf(String::isNotBlank)
                    ?: return@get call.respondApiError(
                        HttpStatusCode.BadRequest,
                        "BAD_QUERY",
                        "id is required",
                    )

                when (val handler = lease.handler) {
                    is SourceHandler.Spider ->
                        call.respondSpiderPlayResult(
                            handler.runtime.playerContent(flag, id, emptyList()),
                            publicBaseUrl,
                            maxResponseBytes,
                        )
                    is SourceHandler.Cms -> {
                        if (id.toHttpUrlOrNull() == null) {
                            return@get call.respondApiError(
                                HttpStatusCode.BadRequest,
                                "PLAY_RESOLUTION_UNSUPPORTED",
                                "CMS play id must be an HTTP(S) URL",
                            )
                        }
                        call.respondText(
                            json.encodeToString(
                                CmsPlayResponse(parse = 0, url = id, header = emptyMap()),
                            ),
                            ContentType.Application.Json,
                        )
                    }
                }
            } finally {
                lease.close()
                permit.close()
            }
        }
    }
}

@Serializable
private data class CmsPlayResponse(
    val parse: Int,
    val url: String,
    val header: Map<String, String>,
)

private suspend fun ApplicationCall.respondResult(
    result: Result<String>,
    publicBaseUrl: String,
    maxResponseBytes: Long,
) {
    result.fold(
        onSuccess = { jsonStr ->
            // 校验返回的 JSON 是否合法
            if (jsonStr.utf8Size() > maxResponseBytes) {
                respondError(502, "Plugin response exceeds configured size limit")
            } else if (jsonStr.isBlank() || (!jsonStr.trimStart().startsWith("{") && !jsonStr.trimStart().startsWith("["))) {
                respondError(502, "Invalid response from plugin")
            } else {
                try {
                    Json.parseToJsonElement(jsonStr)
                    // 把 Spider 返回的本地 proxy URL 替换为 Bridge 实际地址
                    var fixed = authorizeLocalProxyUrls(jsonStr, publicBaseUrl)
                    fixed = fixed.replace("http://127.0.0.1:-1", publicBaseUrl)
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

private fun canonicalQuery(entries: List<Pair<String, String>>): String = entries
    .filterNot { (name, _) -> name.equals("ac", ignoreCase = true) }
    .sortedWith(compareBy<Pair<String, String>>({ it.first }, { it.second }))
    .joinToString("|") { (name, value) -> "${name.length}:$name=${value.length}:$value" }

private fun String.utf8Size(): Long = toByteArray(StandardCharsets.UTF_8).size.toLong()

private suspend fun ApplicationCall.respondSpiderPlayResult(
    result: Result<String>,
    publicBaseUrl: String,
    maxResponseBytes: Long,
) {
    result.getOrNull()?.let { body ->
        val parse = runCatching { JSONObject(body).optInt("parse", 0) }.getOrDefault(0)
        if (parse != 0) {
            respondApiError(
                HttpStatusCode.BadGateway,
                "PLAY_RESOLUTION_UNSUPPORTED",
                "Web page play resolution is not supported",
            )
            return
        }
    }
    respondResult(result, publicBaseUrl, maxResponseBytes)
}

private suspend fun ApplicationCall.acquireGatewayPermit(
    guard: GatewayRequestGuard,
    config: BridgeConfig,
    authenticationRequired: Boolean = true,
): AutoCloseable? {
    if (request.queryString().length > config.security.maxQueryLength) {
        respondApiError(HttpStatusCode.PayloadTooLarge, "QUERY_TOO_LARGE", "Query string is too large")
        return null
    }
    val access = guard.acquire(
        clientId = request.local.remoteHost,
        authorization = request.headers[HttpHeaders.Authorization],
        apiKey = request.headers["X-API-Key"],
        authenticationRequired = authenticationRequired,
    )
    access.permit?.let { return it }
    when (access.denial) {
        GatewayDenial.UNAUTHORIZED -> {
            response.headers.append(HttpHeaders.WWWAuthenticate, "Bearer")
            respondApiError(HttpStatusCode.Unauthorized, "UNAUTHORIZED", "Authentication required")
        }
        GatewayDenial.RATE_LIMITED -> {
            response.headers.append(HttpHeaders.RetryAfter, "60")
            respondApiError(HttpStatusCode.TooManyRequests, "RATE_LIMITED", "Too many requests")
        }
        GatewayDenial.BUSY -> {
            response.headers.append(HttpHeaders.RetryAfter, "1")
            respondApiError(HttpStatusCode.ServiceUnavailable, "GATEWAY_BUSY", "Gateway is busy")
        }
        null -> respondApiError(HttpStatusCode.InternalServerError, "GUARD_ERROR", "Request guard failed")
    }
    return null
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

private suspend fun ApplicationCall.respondCmsError(error: CmsProxyException) {
    val status = when (error.code) {
        "UPSTREAM_TIMEOUT" -> HttpStatusCode.GatewayTimeout
        "UPSTREAM_INVALID_JSON", "UPSTREAM_HTTP_ERROR", "UPSTREAM_UNAVAILABLE" ->
            HttpStatusCode.BadGateway
        "UPSTREAM_RESPONSE_TOO_LARGE" -> HttpStatusCode.PayloadTooLarge
        "REMOTE_TARGET_FORBIDDEN", "REMOTE_SCHEME_FORBIDDEN", "REMOTE_DNS_FAILED" ->
            HttpStatusCode.BadGateway
        else -> HttpStatusCode.InternalServerError
    }
    respondApiError(status, error.code, error.message ?: "CMS upstream request failed")
}

private suspend fun ApplicationCall.respondApiError(
    status: HttpStatusCode,
    error: String,
    message: String,
) {
    val requestId = response.headers["X-Request-Id"].orEmpty()
    val safeMessage = message.replace("\\", "\\\\").replace("\"", "\\\"")
    respondText(
        """{"code":${status.value},"error":"$error","message":"$safeMessage","requestId":"$requestId"}""",
        ContentType.Application.Json,
        status,
    )
}

private fun buildHealthJson(
    manager: SpiderManager,
    catalogManager: CatalogManager,
    health: String,
): String {
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

    val catalog = catalogManager.current()
    val ready = catalog.entries.values.count { it.status.name == "READY" }
    val degraded = catalog.entries.values.count { it.status.name == "DEGRADED" }
    val failed = catalog.entries.values.count { it.status.name == "FAILED" }
    return """{"status":"$health","version":"2.0.0","uptime":"$uptimeStr","catalog":{"version":"${catalog.version}","stale":false,"ready":$ready,"degraded":$degraded,"failed":$failed},"plugins":{"loaded":${manager.loadedCount()},"unavailable":${manager.failedCount()},"details":[${details.joinToString(",")}]}}"""
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
