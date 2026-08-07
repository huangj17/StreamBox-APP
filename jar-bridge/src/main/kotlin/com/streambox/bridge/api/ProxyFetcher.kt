package com.streambox.bridge.api

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import okhttp3.Dns
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import com.streambox.bridge.security.isPublicRemoteAddress
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.UnknownHostException
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.TimeUnit
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

internal const val MAX_PROXY_RESPONSE_BYTES = 10 * 1024 * 1024
private const val MAX_REDIRECTS = 3
private const val PROXY_URL_TTL_SECONDS = 5 * 60L
private val proxySemaphore = Semaphore(16)
private val localProxyUrlRegex =
    Regex("""http://127\.0\.0\.1:-1/proxy\?([^"\\\s]+)""")
private val proxySigningKey = ByteArray(32).also(SecureRandom()::nextBytes)

internal data class ProxyPayload(
    val bytes: ByteArray,
    val contentType: String,
)

internal class UnsafeProxyTargetException(message: String) : IllegalArgumentException(message)
internal class ProxyResponseTooLargeException : IOException("Proxy response exceeds 10 MiB")

/**
 * Spider 返回的本地代理 URL 在发给客户端前按目标参数签名。签名只在当前 Bridge
 * 进程内有效，防止公开监听时被当作任意公网代理使用。
 */
internal fun authorizeLocalProxyUrls(json: String, bridgeBase: String): String =
    localProxyUrlRegex.replace(json) { match ->
        val query = match.groupValues[1]
        val parsed = "http://localhost/proxy?$query".toHttpUrlOrNull()
            ?: return@replace match.value
        val encodedUrl = parsed.queryParameter("url") ?: return@replace match.value
        val encodedHeader = parsed.queryParameter("header")
        val expiresAt = System.currentTimeMillis() / 1000 + PROXY_URL_TTL_SECONDS
        val signature = proxySignature(encodedUrl, encodedHeader, expiresAt)
        "$bridgeBase/proxy?$query&exp=$expiresAt&sig=$signature"
    }

internal fun isAuthorizedProxyRequest(
    encodedUrl: String,
    encodedHeader: String?,
    expiresAt: Long?,
    signature: String?,
    nowEpochSeconds: Long = System.currentTimeMillis() / 1000,
): Boolean {
    if (
        signature == null ||
        expiresAt == null ||
        expiresAt < nowEpochSeconds ||
        expiresAt > nowEpochSeconds + PROXY_URL_TTL_SECONDS
    ) return false
    return MessageDigest.isEqual(
        proxySignature(encodedUrl, encodedHeader, expiresAt).toByteArray(Charsets.US_ASCII),
        signature.toByteArray(Charsets.US_ASCII),
    )
}

private fun proxySignature(encodedUrl: String, encodedHeader: String?, expiresAt: Long): String {
    val mac = Mac.getInstance("HmacSHA256")
    mac.init(SecretKeySpec(proxySigningKey, "HmacSHA256"))
    val payload = "$encodedUrl\n${encodedHeader ?: ""}\n$expiresAt"
    return java.util.Base64.getUrlEncoder()
        .withoutPadding()
        .encodeToString(mac.doFinal(payload.toByteArray(Charsets.UTF_8)))
}

/**
 * OkHttp 在真正建立连接时使用这个 DNS 实现，避免“先校验、后解析”造成 DNS
 * rebinding。只要一个主机名解析到了非公网地址，就拒绝整个请求。
 */
internal object PublicAddressDns : Dns {
    override fun lookup(hostname: String): List<InetAddress> {
        val addresses = Dns.SYSTEM.lookup(hostname)
        if (addresses.isEmpty() || addresses.any { !isPublicAddress(it) }) {
            throw UnknownHostException("Proxy target does not resolve exclusively to public addresses")
        }
        return addresses
    }
}

private val proxyHttpClient = OkHttpClient.Builder()
    .dns(PublicAddressDns)
    .followRedirects(false)
    .followSslRedirects(false)
    .connectTimeout(10, TimeUnit.SECONDS)
    .readTimeout(10, TimeUnit.SECONDS)
    .callTimeout(15, TimeUnit.SECONDS)
    .build()

internal suspend fun fetchProxyImage(
    rawUrl: String,
    headers: Map<String, String>,
): ProxyPayload = proxySemaphore.withPermit {
    withContext(Dispatchers.IO) {
        var url = validateProxyUrl(rawUrl)
        var requestHeaders = headers.filterKeys { it.lowercase() !in blockedForwardHeaders }

        repeat(MAX_REDIRECTS + 1) { redirectCount ->
            val requestBuilder = Request.Builder().url(url)
            requestHeaders.forEach(requestBuilder::addHeader)

            proxyHttpClient.newCall(requestBuilder.build()).execute().use { response ->
                if (response.isRedirect) {
                    if (redirectCount == MAX_REDIRECTS) {
                        throw IOException("Too many proxy redirects")
                    }
                    val location = response.header("Location")
                        ?: throw IOException("Redirect without Location")
                    val nextUrl = response.request.url.resolve(location)
                        ?: throw UnsafeProxyTargetException("Invalid redirect target")
                    val validated = validateProxyUrl(nextUrl.toString())
                    if (!sameOrigin(url, validated)) {
                        requestHeaders = requestHeaders.filterKeys {
                            it.lowercase() !in sensitiveForwardHeaders
                        }
                    }
                    url = validated
                    return@repeat
                }
                return@withContext readBoundedImage(response)
            }
        }

        throw IOException("Too many proxy redirects")
    }
}

private fun validateProxyUrl(rawUrl: String): HttpUrl {
    val url = rawUrl.toHttpUrlOrNull()
        ?: throw UnsafeProxyTargetException("Invalid proxy URL")
    if (url.scheme != "http" && url.scheme != "https") {
        throw UnsafeProxyTargetException("Only HTTP(S) proxy targets are allowed")
    }
    if (url.username.isNotEmpty() || url.password.isNotEmpty()) {
        throw UnsafeProxyTargetException("Proxy URL credentials are not allowed")
    }
    // 对 IP 字面量也在进入 OkHttp 前快速失败；连接时仍会由 PublicAddressDns 再校验。
    val resolved = try {
        InetAddress.getAllByName(url.host).toList()
    } catch (e: UnknownHostException) {
        throw UnsafeProxyTargetException("Proxy target cannot be resolved")
    }
    if (resolved.isEmpty() || resolved.any { !isPublicAddress(it) }) {
        throw UnsafeProxyTargetException("Private or reserved proxy targets are not allowed")
    }
    return url
}

internal fun isPublicAddress(address: InetAddress): Boolean {
    return isPublicRemoteAddress(address)
}

private fun readBoundedImage(response: Response): ProxyPayload {
    if (!response.isSuccessful) {
        throw IOException("Upstream returned HTTP ${response.code}")
    }
    val body = response.body ?: throw IOException("Empty proxy response")
    if (body.contentLength() > MAX_PROXY_RESPONSE_BYTES) {
        throw ProxyResponseTooLargeException()
    }

    val rawContentType = response.header("Content-Type")
        ?.substringBefore(';')
        ?.trim()
        ?.lowercase()
        ?: "application/octet-stream"
    if (!rawContentType.startsWith("image/") && rawContentType != "application/octet-stream") {
        throw IOException("Proxy endpoint only accepts image responses")
    }

    val output = ByteArrayOutputStream()
    body.byteStream().use { input ->
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        var total = 0
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            total += read
            if (total > MAX_PROXY_RESPONSE_BYTES) throw ProxyResponseTooLargeException()
            output.write(buffer, 0, read)
        }
    }
    return ProxyPayload(output.toByteArray(), rawContentType)
}

private fun sameOrigin(first: HttpUrl, second: HttpUrl): Boolean =
    first.scheme == second.scheme && first.host == second.host && first.port == second.port

private val blockedForwardHeaders = setOf(
    "connection",
    "content-length",
    "host",
    "proxy-authorization",
    "proxy-connection",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
)

private val sensitiveForwardHeaders = setOf("authorization", "cookie")
