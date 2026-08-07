package com.streambox.bridge.security

import com.streambox.bridge.config.SecurityConfig
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Semaphore

enum class GatewayDenial {
    UNAUTHORIZED,
    RATE_LIMITED,
    BUSY,
}

data class GatewayAccess(
    val permit: AutoCloseable? = null,
    val denial: GatewayDenial? = null,
)

/**
 * Gateway 的统一入口保护：常量时间 Token 校验、按连接端 IP 的令牌桶，
 * 以及跨全部 Spider/CMS/代理请求的并发上限。
 *
 * 不信任 X-Forwarded-For；需要代理时应由代理自身先限流，Gateway 仍以直连地址兜底。
 */
class GatewayRequestGuard(private val config: SecurityConfig) {
    private val concurrency = Semaphore(config.maxConcurrentRequests, true)
    private val buckets = ConcurrentHashMap<String, TokenBucket>()

    fun acquire(
        clientId: String,
        authorization: String?,
        apiKey: String?,
        authenticationRequired: Boolean = true,
    ): GatewayAccess {
        if (authenticationRequired && !isAuthorized(authorization, apiKey)) {
            return GatewayAccess(denial = GatewayDenial.UNAUTHORIZED)
        }
        val now = System.nanoTime()
        val bucket = buckets.computeIfAbsent(clientId) {
            TokenBucket(config.rateLimitBurst.toDouble(), now)
        }
        if (!bucket.tryConsume(now, config.rateLimitPerMinute, config.rateLimitBurst)) {
            return GatewayAccess(denial = GatewayDenial.RATE_LIMITED)
        }
        if (!concurrency.tryAcquire()) {
            return GatewayAccess(denial = GatewayDenial.BUSY)
        }
        if (buckets.size > MAX_CLIENT_BUCKETS) cleanup(now)
        return GatewayAccess(permit = AutoCloseable(concurrency::release))
    }

    private fun isAuthorized(authorization: String?, apiKey: String?): Boolean {
        if (!config.requireAuth) return true
        val expected = config.apiToken ?: return false
        val supplied = apiKey?.takeIf(String::isNotBlank)
            ?: authorization
                ?.takeIf { it.startsWith("Bearer ", ignoreCase = true) }
                ?.substringAfter(' ')
                ?.trim()
            ?: return false
        return MessageDigest.isEqual(
            expected.toByteArray(Charsets.UTF_8),
            supplied.toByteArray(Charsets.UTF_8),
        )
    }

    private fun cleanup(now: Long) {
        buckets.entries.removeIf { (_, bucket) -> now - bucket.lastSeenNanos > BUCKET_TTL_NANOS }
    }

    private class TokenBucket(initialTokens: Double, initialNanos: Long) {
        private var tokens = initialTokens
        @Volatile
        var lastSeenNanos: Long = initialNanos
            private set

        @Synchronized
        fun tryConsume(now: Long, perMinute: Int, burst: Int): Boolean {
            val elapsedMinutes = (now - lastSeenNanos).coerceAtLeast(0) / 60_000_000_000.0
            tokens = (tokens + elapsedMinutes * perMinute).coerceAtMost(burst.toDouble())
            lastSeenNanos = now
            if (tokens < 1.0) return false
            tokens -= 1.0
            return true
        }
    }

    private companion object {
        const val MAX_CLIENT_BUCKETS = 4096
        const val BUCKET_TTL_NANOS = 10L * 60 * 1_000_000_000
    }
}
