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
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.UnknownHostException
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.TimeUnit
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

internal const val MAX_PROXY_RESPONSE_BYTES = 10 * 1024 * 1024
private const val MAX_REDIRECTS = 3
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
        val signature = proxySignature(encodedUrl, encodedHeader)
        "$bridgeBase/proxy?$query&sig=$signature"
    }

internal fun isAuthorizedProxyRequest(
    encodedUrl: String,
    encodedHeader: String?,
    signature: String?,
): Boolean {
    if (signature == null) return false
    return MessageDigest.isEqual(
        proxySignature(encodedUrl, encodedHeader).toByteArray(Charsets.US_ASCII),
        signature.toByteArray(Charsets.US_ASCII),
    )
}

private fun proxySignature(encodedUrl: String, encodedHeader: String?): String {
    val mac = Mac.getInstance("HmacSHA256")
    mac.init(SecretKeySpec(proxySigningKey, "HmacSHA256"))
    val payload = "$encodedUrl\n${encodedHeader ?: ""}"
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
    if (
        address.isAnyLocalAddress ||
        address.isLoopbackAddress ||
        address.isLinkLocalAddress ||
        address.isSiteLocalAddress ||
        address.isMulticastAddress
    ) {
        return false
    }

    val bytes = address.address.map(Byte::toInt).map { it and 0xff }
    return when (address) {
        is Inet4Address -> {
            val first = bytes[0]
            val second = bytes[1]
            when {
                first == 0 -> false
                first == 100 && second in 64..127 -> false // CGNAT 100.64/10
                first == 192 && second == 0 && bytes[2] in setOf(0, 2) -> false
                first == 192 && second == 88 && bytes[2] == 99 -> false
                first == 198 && second in 18..19 -> false
                first == 198 && second == 51 && bytes[2] == 100 -> false
                first == 203 && second == 0 && bytes[2] == 113 -> false
                first >= 224 -> false
                else -> true
            }
        }

        is Inet6Address -> {
            val globalUnicast = bytes[0] in 0x20..0x3f // 2000::/3
            val uniqueLocal = bytes[0] and 0xfe == 0xfc
            val documentation =
                bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8
            globalUnicast && !uniqueLocal && !documentation
        }

        else -> false
    }
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
