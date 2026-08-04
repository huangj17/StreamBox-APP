package com.streambox.bridge.aggregator

import com.streambox.bridge.config.AggregatorConfig
import com.streambox.bridge.security.RemoteTargetException
import com.streambox.bridge.security.RemoteTargetPolicy
import com.streambox.bridge.security.PolicyDns
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody
import java.io.ByteArrayOutputStream
import java.io.InterruptedIOException
import java.nio.charset.StandardCharsets
import java.util.concurrent.TimeUnit

class AggregatorClient(
    private val config: AggregatorConfig,
    private val environment: Map<String, String> = System.getenv(),
    private val remoteTargetPolicy: RemoteTargetPolicy? = null,
) : AggregatorSource, AutoCloseable {
    private val httpClient = OkHttpClient.Builder()
        .followRedirects(false)
        .followSslRedirects(false)
        .connectTimeout(config.connectTimeoutMs, TimeUnit.MILLISECONDS)
        .readTimeout(config.readTimeoutMs, TimeUnit.MILLISECONDS)
        .callTimeout(config.readTimeoutMs, TimeUnit.MILLISECONDS)
        .apply {
            remoteTargetPolicy?.let { policy ->
                dns(PolicyDns(policy))
            }
        }
        .build()

    override suspend fun fetch(previous: FetchValidators?): AggregatorFetchResult =
        withContext(Dispatchers.IO) {
            val baseUrl = config.baseUrl?.takeIf(String::isNotBlank)?.toHttpUrl()
                ?: throw AggregatorFetchException(
                    code = "AGGREGATOR_URL_MISSING",
                    message = "Aggregator baseUrl is required",
                )
            try {
                var currentUrl = baseUrl
                var redirects = 0
                while (true) {
                    remoteTargetPolicy?.validate(currentUrl)
                    val request = buildRequest(
                        currentUrl,
                        previous,
                        includeCredentials = sameOrigin(baseUrl, currentUrl),
                    )
                    httpClient.newCall(request).execute().use { response ->
                        if (response.code == 304) {
                            return@withContext response.notModified(previous)
                        }
                        if (response.code in 300..399) {
                            if (redirects >= MAX_REDIRECTS) {
                                throw AggregatorFetchException(
                                    code = "AGGREGATOR_TOO_MANY_REDIRECTS",
                                    message = "Aggregator exceeded $MAX_REDIRECTS redirects",
                                )
                            }
                            val location = response.header("Location")
                                ?: throw AggregatorFetchException(
                                    code = "AGGREGATOR_REDIRECT_INVALID",
                                    message = "Aggregator redirect is missing Location",
                                )
                            currentUrl = response.request.url.resolve(location)
                                ?: throw AggregatorFetchException(
                                    code = "AGGREGATOR_REDIRECT_INVALID",
                                    message = "Aggregator redirect Location is invalid",
                                )
                            redirects += 1
                            return@use
                        }
                        if (!response.isSuccessful) {
                            throw AggregatorFetchException(
                                code = "AGGREGATOR_HTTP_ERROR",
                                message = "Aggregator returned HTTP ${response.code}",
                            )
                        }
                        return@withContext response.fetched(previous, config.maxResponseBytes)
                    }
                }
                error("unreachable")
            } catch (error: AggregatorFetchException) {
                throw error
            } catch (error: RemoteTargetException) {
                throw AggregatorFetchException(
                    code = error.code,
                    message = "Aggregator target was rejected by remote target policy",
                    cause = error,
                )
            } catch (error: CancellationException) {
                throw error
            } catch (error: InterruptedIOException) {
                throw AggregatorFetchException(
                    code = "AGGREGATOR_TIMEOUT",
                    message = "Aggregator request timed out",
                    cause = error,
                )
            } catch (error: Exception) {
                throw AggregatorFetchException(
                    code = "AGGREGATOR_REQUEST_FAILED",
                    message = "Aggregator request failed: ${error.message}",
                    cause = error,
                )
            }
        }

    private fun buildRequest(
        url: HttpUrl,
        previous: FetchValidators?,
        includeCredentials: Boolean,
    ): Request {
        val requestBuilder = Request.Builder()
            .url(url)
            .get()
            .header("Accept", "application/json")
            .header("User-Agent", "StreamBox-Gateway/2.0.0")

        if (includeCredentials) {
            config.tokenEnv
                ?.let(environment::get)
                ?.takeIf(String::isNotBlank)
                ?.let { requestBuilder.header("Authorization", "Bearer $it") }
            config.headersFromEnv.forEach { (header, environmentName) ->
                environment[environmentName]
                    ?.takeIf(String::isNotBlank)
                    ?.let { requestBuilder.header(header, it) }
            }
        }
        previous?.etag?.let { requestBuilder.header("If-None-Match", it) }
        previous?.lastModified?.let { requestBuilder.header("If-Modified-Since", it) }
        return requestBuilder.build()
    }

    override fun close() {
        httpClient.dispatcher.executorService.shutdown()
        httpClient.connectionPool.evictAll()
        httpClient.cache?.close()
    }

    private companion object {
        const val MAX_REDIRECTS = 3
    }
}

private fun sameOrigin(first: HttpUrl, second: HttpUrl): Boolean =
    first.scheme == second.scheme && first.host == second.host && first.port == second.port

private fun Response.notModified(previous: FetchValidators?): AggregatorFetchResult.NotModified {
    val validators = validators(previous)
    return AggregatorFetchResult.NotModified(
        finalUrl = request.url.toString(),
        validators = validators,
    )
}

private fun Response.fetched(
    previous: FetchValidators?,
    maxResponseBytes: Long,
): AggregatorFetchResult.Fetched {
    val responseBody = body
        ?: throw AggregatorFetchException(
            code = "AGGREGATOR_EMPTY_BODY",
            message = "Aggregator returned an empty response body",
        )
    return AggregatorFetchResult.Fetched(
        body = responseBody.readLimited(maxResponseBytes),
        finalUrl = request.url.toString(),
        validators = validators(previous),
    )
}

private fun Response.validators(previous: FetchValidators?): FetchValidators = FetchValidators(
    etag = header("ETag") ?: previous?.etag,
    lastModified = header("Last-Modified") ?: previous?.lastModified,
)

private fun ResponseBody.readLimited(maxBytes: Long): String {
    if (contentLength() > maxBytes) {
        throw AggregatorFetchException(
            code = "AGGREGATOR_RESPONSE_TOO_LARGE",
            message = "Aggregator response exceeds $maxBytes bytes",
        )
    }
    val output = ByteArrayOutputStream()
    byteStream().use { input ->
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        var total = 0L
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            total += read
            if (total > maxBytes) {
                throw AggregatorFetchException(
                    code = "AGGREGATOR_RESPONSE_TOO_LARGE",
                    message = "Aggregator response exceeds $maxBytes bytes",
                )
            }
            output.write(buffer, 0, read)
        }
    }
    return output.toString(StandardCharsets.UTF_8)
}
