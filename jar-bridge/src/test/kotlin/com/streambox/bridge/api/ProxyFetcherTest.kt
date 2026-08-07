package com.streambox.bridge.api

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import java.net.InetAddress
import okhttp3.HttpUrl.Companion.toHttpUrl

class ProxyFetcherTest {
    @Test
    fun `rejects local private cgnat and unique-local addresses`() {
        listOf(
            "127.0.0.1",
            "10.0.0.1",
            "169.254.1.1",
            "192.168.1.1",
            "100.64.0.1",
            "192.0.2.1",
            "198.51.100.1",
            "203.0.113.1",
            "::1",
            "fc00::1",
            "2001:db8::1",
        ).forEach { raw ->
            assertFalse(isPublicAddress(InetAddress.getByName(raw)), raw)
        }
    }

    @Test
    fun `accepts public unicast addresses`() {
        assertTrue(isPublicAddress(InetAddress.getByName("8.8.8.8")))
        assertTrue(isPublicAddress(InetAddress.getByName("2606:4700:4700::1111")))
    }

    @Test
    fun `only rewritten plugin proxy urls receive a valid signature`() {
        val original =
            """{"pic":"http://127.0.0.1:-1/proxy?url=aHR0cHM6Ly9leGFtcGxlLmNvbS9hLmpwZw==&header=e30="}"""
        val rewritten = authorizeLocalProxyUrls(original, "http://bridge:9978")
        val url = Regex("http://bridge:9978/proxy[^\"]+")
            .find(rewritten)!!
            .value
            .toHttpUrl()

        val encodedUrl = url.queryParameter("url")!!
        val encodedHeader = url.queryParameter("header")
        val expiresAt = url.queryParameter("exp")?.toLong()
        val signature = url.queryParameter("sig")
        assertTrue(isAuthorizedProxyRequest(encodedUrl, encodedHeader, expiresAt, signature))
        assertFalse(
            isAuthorizedProxyRequest(
                "aHR0cDovLzEyNy4wLjAuMS8=",
                encodedHeader,
                expiresAt,
                signature,
            )
        )
        assertFalse(
            isAuthorizedProxyRequest(
                encodedUrl,
                encodedHeader,
                expiresAt,
                signature,
                nowEpochSeconds = checkNotNull(expiresAt) + 1,
            )
        )
    }
}
