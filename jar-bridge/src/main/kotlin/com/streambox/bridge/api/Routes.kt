package com.streambox.bridge.api

import com.streambox.bridge.catalog.CatalogManager
import com.streambox.bridge.catalog.SourceHandler
import com.streambox.bridge.cms.CmsProxyException
import com.streambox.bridge.cms.CmsProxyService
import com.streambox.bridge.config.BridgeConfig
import com.streambox.bridge.spider.SpiderManager
import com.streambox.bridge.spider.SpiderTimeoutException
import com.streambox.bridge.spider.SpiderUnavailableException
import com.streambox.bridge.sync.SyncCoordinator
import com.streambox.bridge.sync.SyncStartResult
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
import java.security.MessageDigest
import java.time.Instant
import java.util.Base64

private val json = Json { prettyPrint = false }
private val routeLogger = LoggerFactory.getLogger("Routes")

/// 匹配 `"https://x.comhttps://y.com/...` 这种 spider 拼接两次 host 的脏 URL，
/// 捕获第二个 scheme 起的部分。仅在 JSON 字符串值（前面有 `"`）的位置生效，
/// 避免误伤含 https:// 的正文。
private val doubleSchemeRegex = Regex("\"https?://[^\"\\s]*?(https?://[^\"\\s]+)")
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
    syncCoordinator: SyncCoordinator? = null,
    config: BridgeConfig = BridgeConfig(),
    environment: Map<String, String> = System.getenv(),
    cmsProxyService: CmsProxyService = CmsProxyService(),
) {
    startTime = System.currentTimeMillis()
    val adminRateLimiter = AdminRateLimiter()
    monitor.subscribe(ApplicationStopped) { cmsProxyService.close() }

    routing {
        // 插件列表
        get("/api/list") {
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
                        stale = syncCoordinator?.status()?.isStale(
                            Instant.now(),
                            config.aggregator.syncInterval,
                        ) ?: false,
                        sources = sources,
                    ),
                ),
                ContentType.Application.Json
            )
        }

        // 健康检查
        get("/health") {
            val hasEntries = catalogManager.listPublic().isNotEmpty()
            val stale = syncCoordinator?.status()?.isStale(
                Instant.now(),
                config.aggregator.syncInterval,
            ) ?: false
            val health = when {
                !hasEntries -> "error"
                stale || (syncCoordinator?.status()?.consecutiveFailures ?: 0) > 0 -> "degraded"
                else -> "ok"
            }
            call.respondText(
                buildHealthJson(manager, catalogManager, syncCoordinator, health, stale),
                ContentType.Application.Json,
                if (health == "error") HttpStatusCode.ServiceUnavailable else HttpStatusCode.OK,
            )
        }

        get("/sync/status") {
            val coordinator = syncCoordinator
                ?: return@get call.respondApiError(
                    HttpStatusCode.Conflict,
                    "AGGREGATOR_NOT_CONFIGURED",
                    "Aggregator synchronization is not configured",
                )
            call.respondText(
                json.encodeToString(coordinator.status()),
                ContentType.Application.Json,
            )
        }

        post("/admin/sync") {
            val coordinator = syncCoordinator
                ?: return@post call.respondApiError(
                    HttpStatusCode.Conflict,
                    "AGGREGATOR_NOT_CONFIGURED",
                    "Aggregator synchronization is not configured",
                )
            if (!config.admin.enabled || !authorizedAdmin(call, config, environment)) {
                return@post call.respondApiError(
                    HttpStatusCode.Unauthorized,
                    "UNAUTHORIZED",
                    "Admin authorization failed",
                )
            }
            if (!adminRateLimiter.tryAcquire()) {
                return@post call.respondApiError(
                    HttpStatusCode.TooManyRequests,
                    "RATE_LIMITED",
                    "Admin sync rate limit exceeded",
                )
            }
            val allowEmpty = call.receiveText().contains(Regex("\"allowEmpty\"\\s*:\\s*true"))
            val result = coordinator.startAsync(allowEmpty = allowEmpty)
            val (jobId, alreadyRunning) = when (result) {
                is SyncStartResult.AlreadyRunning -> result.jobId to true
                is SyncStartResult.Started -> result.jobId to false
            }
            call.respondText(
                """{"jobId":"$jobId","alreadyRunning":$alreadyRunning}""",
                ContentType.Application.Json,
                HttpStatusCode.Accepted,
            )
        }

        // 核心 API：CMS 兼容格式
        get("/api/{key}") {
            val key = call.parameters["key"]
                ?: return@get call.respondError(400, "Missing plugin key")
            val lease = catalogManager.acquire(key)
                ?: return@get call.respondApiError(
                    HttpStatusCode.NotFound,
                    "SOURCE_NOT_FOUND",
                    "Source not found",
                )
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

                // 缓存键：仅 ?ac=class（首页分类）和 ?ac=detail&t=X&pg=Y（分类页）走缓存。
                // detail by ids / search 不缓存（用户级查询）。
                val cacheKey: String? = when {
                    operation == "class" ->
                        "${catalogManager.current().version}:$key:class"
                    operation == "category" ->
                        "${catalogManager.current().version}:$key:t=$t:pg=$pg"
                    else -> null
                }

                // 命中缓存：跳过 spider 调用，直接进 respondResult 走 sanitize
                cacheKey?.let { ResponseCache.get(it) }?.let { cached ->
                    call.respondResult(Result.success(cached))
                    return@get
                }

                val result: Result<String> = when (val handler = lease.handler) {
                    is SourceHandler.Spider -> when {
                        operation == "detail" ->
                            handler.runtime.detailContent(checkNotNull(ids).split(","))
                        operation == "category" ->
                            handler.runtime.categoryContent(checkNotNull(t), pg, true, hashMapOf())
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
                                query = call.request.queryParameters.entries().flatMap { (name, values) ->
                                    values.map { value -> name to value }
                                },
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
                        if (jsonStr.isNotBlank()) ResponseCache.put(cacheKey, jsonStr)
                    }
                }

                call.respondResult(result)
            } finally {
                lease.close()
            }
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
            val lease = catalogManager.acquire(key)
                ?: return@get call.respondApiError(
                    HttpStatusCode.NotFound,
                    "SOURCE_NOT_FOUND",
                    "Source not found",
                )
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
            }
        }
    }
}

private class AdminRateLimiter(
    private val limit: Int = 6,
    private val windowMs: Long = 60_000,
) {
    private val lock = Any()
    private val attempts = ArrayDeque<Long>()

    fun tryAcquire(nowMs: Long = System.currentTimeMillis()): Boolean = synchronized(lock) {
        while (attempts.firstOrNull()?.let { nowMs - it >= windowMs } == true) {
            attempts.removeFirst()
        }
        if (attempts.size >= limit) return@synchronized false
        attempts.addLast(nowMs)
        true
    }
}

@Serializable
private data class CmsPlayResponse(
    val parse: Int,
    val url: String,
    val header: Map<String, String>,
)

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

private suspend fun ApplicationCall.respondSpiderPlayResult(result: Result<String>) {
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
    respondResult(result)
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

private fun authorizedAdmin(
    call: ApplicationCall,
    config: BridgeConfig,
    environment: Map<String, String>,
): Boolean {
    val expected = environment[config.admin.tokenEnv]?.toByteArray(Charsets.UTF_8) ?: return false
    val supplied = call.request.headers[HttpHeaders.Authorization]
        ?.removePrefix("Bearer ")
        ?.takeIf { it != call.request.headers[HttpHeaders.Authorization] }
        ?.toByteArray(Charsets.UTF_8)
        ?: return false
    return MessageDigest.isEqual(expected, supplied)
}

private fun buildHealthJson(
    manager: SpiderManager,
    catalogManager: CatalogManager,
    syncCoordinator: SyncCoordinator?,
    health: String,
    stale: Boolean,
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
    val sync = syncCoordinator?.status()
    val aggregatorStatus = when {
        syncCoordinator == null -> "disabled"
        (sync?.consecutiveFailures ?: 0) > 0 -> "unreachable"
        else -> "ok"
    }
    return """{"status":"$health","version":"2.0.0","uptime":"$uptimeStr","catalog":{"version":"${catalog.version}","stale":$stale,"ready":$ready,"degraded":$degraded,"failed":$failed},"aggregator":{"status":"$aggregatorStatus","lastAttemptAt":${jsonString(sync?.lastAttemptAt)},"lastSuccessAt":${jsonString(sync?.lastSuccessAt)},"consecutiveFailures":${sync?.consecutiveFailures ?: 0}},"plugins":{"loaded":${manager.loadedCount()},"unavailable":${manager.failedCount()},"details":[${details.joinToString(",")}]}}"""
}

private fun jsonString(value: String?): String = value
    ?.replace("\\", "\\\\")
    ?.replace("\"", "\\\"")
    ?.let { "\"$it\"" }
    ?: "null"

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
