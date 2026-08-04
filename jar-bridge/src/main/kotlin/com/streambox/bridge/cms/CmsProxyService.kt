package com.streambox.bridge.cms

import com.streambox.bridge.catalog.CmsDialect
import com.streambox.bridge.catalog.SourceHandler
import com.streambox.bridge.security.RemoteTargetException
import com.streambox.bridge.security.RemoteTargetPolicy
import com.streambox.bridge.security.PolicyDns
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Dispatcher
import okhttp3.Request
import java.io.InterruptedIOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

class CmsProxyException(
    val code: String,
    message: String,
    cause: Throwable? = null,
) : RuntimeException(message, cause)

class CmsProxyService(
    connectTimeoutMs: Long = 5_000,
    readTimeoutMs: Long = 15_000,
    callTimeoutMs: Long = 20_000,
    private val remoteTargetPolicy: RemoteTargetPolicy? = null,
) : AutoCloseable {
    private val dispatcher = Dispatcher().apply {
        maxRequests = 32
        maxRequestsPerHost = 8
    }
    private val client = OkHttpClient.Builder()
        .dispatcher(dispatcher)
        .followRedirects(false)
        .followSslRedirects(false)
        .connectTimeout(connectTimeoutMs, TimeUnit.MILLISECONDS)
        .readTimeout(readTimeoutMs, TimeUnit.MILLISECONDS)
        .callTimeout(callTimeoutMs, TimeUnit.MILLISECONDS)
        .apply {
            remoteTargetPolicy?.let { policy ->
                dns(PolicyDns(policy))
            }
        }
        .build()
    private val dialects = ConcurrentHashMap<String, CmsDialect>()
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun execute(
        handler: SourceHandler.Cms,
        catalogVersion: String,
        entryKey: String,
        query: List<Pair<String, String>>,
    ): String {
        val dialectKey = "$catalogVersion\u0000$entryKey\u0000${handler.target}"
        val isClassRequest = query.any { (name, value) ->
            name.equals("ac", ignoreCase = true) && value == "class"
        } || query.none { (name, _) -> name in BUSINESS_QUERY_NAMES }
        if (!isClassRequest) return request(handler.target, query).encoded

        return when (dialects[dialectKey] ?: handler.dialect) {
            CmsDialect.CLASS -> request(handler.target, query.withAc("class")).encoded
            CmsDialect.LIST -> request(handler.target, query.withAc("list")).encoded
            CmsDialect.UNKNOWN -> probeDialect(handler.target, query, dialectKey)
        }
    }

    private suspend fun probeDialect(
        target: HttpUrl,
        query: List<Pair<String, String>>,
        dialectKey: String,
    ): String {
        val classAttempt = runCatching { request(target, query.withAc("class")) }
        classAttempt.getOrNull()?.takeIf(CmsResponse::hasClasses)?.let { response ->
            dialects[dialectKey] = CmsDialect.CLASS
            return response.encoded
        }
        val listAttempt = request(target, query.withAc("list"))
        if (!listAttempt.hasClasses()) {
            throw CmsProxyException(
                code = "UPSTREAM_INVALID_JSON",
                message = "CMS classification response does not contain class data",
            )
        }
        dialects[dialectKey] = CmsDialect.LIST
        return listAttempt.encoded
    }

    private suspend fun request(
        target: HttpUrl,
        query: List<Pair<String, String>>,
    ): CmsResponse = withContext(Dispatchers.IO) {
        try {
            var url = buildTarget(target, query)
            var redirects = 0
            while (true) {
                remoteTargetPolicy?.validate(url)
                val request = Request.Builder()
                    .url(url)
                    .get()
                    .header("Accept", "application/json")
                    .header("User-Agent", "okhttp/3.12.0 StreamBox-Gateway/2.0.0")
                    .build()
                client.newCall(request).execute().use { response ->
                    if (response.code in 300..399) {
                        if (redirects >= MAX_REDIRECTS) {
                            throw CmsProxyException(
                                code = "UPSTREAM_TOO_MANY_REDIRECTS",
                                message = "CMS upstream exceeded $MAX_REDIRECTS redirects",
                            )
                        }
                        val location = response.header("Location")
                            ?: throw CmsProxyException(
                                code = "UPSTREAM_REDIRECT_INVALID",
                                message = "CMS redirect is missing Location",
                            )
                        url = response.request.url.resolve(location)
                            ?: throw CmsProxyException(
                                code = "UPSTREAM_REDIRECT_INVALID",
                                message = "CMS redirect Location is invalid",
                            )
                        redirects += 1
                        return@use
                    }
                    if (!response.isSuccessful) {
                        throw CmsProxyException(
                            code = "UPSTREAM_HTTP_ERROR",
                            message = "CMS upstream returned HTTP ${response.code}",
                        )
                    }
                    val body = response.body?.string().orEmpty()
                    if (body.isBlank()) {
                        throw CmsProxyException(
                            code = "UPSTREAM_INVALID_JSON",
                            message = "CMS upstream returned an empty body",
                        )
                    }
                    val parsed = try {
                        json.parseToJsonElement(body)
                    } catch (error: Exception) {
                        throw CmsProxyException(
                            code = "UPSTREAM_INVALID_JSON",
                            message = "CMS upstream returned invalid JSON",
                            cause = error,
                        )
                    }
                    val objectBody = parsed as? JsonObject
                        ?: throw CmsProxyException(
                            code = "UPSTREAM_INVALID_JSON",
                            message = "CMS upstream response must be a JSON object",
                        )
                    return@withContext CmsResponse(encoded = objectBody.toString(), body = objectBody)
                }
            }
            error("unreachable")
        } catch (error: CmsProxyException) {
            throw error
        } catch (error: RemoteTargetException) {
            throw CmsProxyException(
                code = error.code,
                message = "CMS target was rejected by remote target policy",
                cause = error,
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: InterruptedIOException) {
            throw CmsProxyException(
                code = "UPSTREAM_TIMEOUT",
                message = "CMS upstream request timed out",
                cause = error,
            )
        } catch (error: Exception) {
            throw CmsProxyException(
                code = "UPSTREAM_UNAVAILABLE",
                message = "CMS upstream request failed",
                cause = error,
            )
        }
    }

    private fun buildTarget(target: HttpUrl, query: List<Pair<String, String>>): HttpUrl {
        val allowed = query.filterNot { (name, _) -> name.lowercase() in RESERVED_QUERY_NAMES }
        val builder = target.newBuilder()
        allowed.map(Pair<String, String>::first).distinct().forEach(builder::removeAllQueryParameters)
        allowed.forEach { (name, value) -> builder.addQueryParameter(name, value) }
        return builder.build()
    }

    override fun close() {
        client.dispatcher.executorService.shutdown()
        client.connectionPool.evictAll()
        client.cache?.close()
    }

    private data class CmsResponse(
        val encoded: String,
        val body: JsonObject,
    ) {
        fun hasClasses(): Boolean = body["class"] != null
    }

    private fun List<Pair<String, String>>.withAc(value: String): List<Pair<String, String>> =
        filterNot { (name, _) -> name.equals("ac", ignoreCase = true) } + ("ac" to value)

    private companion object {
        const val MAX_REDIRECTS = 3
        val RESERVED_QUERY_NAMES = setOf("url", "host", "target", "gatewayurl", "apikey")
        val BUSINESS_QUERY_NAMES = setOf("ac", "t", "ids", "wd")
    }
}
