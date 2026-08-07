package com.streambox.bridge.config

import com.streambox.bridge.security.RemoteTargetPolicy

class ConfigValidationException(
    val code: String,
    message: String,
) : IllegalArgumentException(message)

object ConfigValidator {
    fun validate(config: BridgeConfig) {
        if (
            config.timeout <= 0 ||
            config.catalog.retirementGraceMs <= 0 ||
            config.security.rateLimitPerMinute <= 0 ||
            config.security.rateLimitBurst <= 0 ||
            config.security.maxConcurrentRequests <= 0 ||
            config.security.maxResponseBytes <= 0 ||
            config.security.maxQueryLength <= 0
        ) {
            throw ConfigValidationException(
                code = "CONFIG_VALUE_NON_POSITIVE",
                message = "timeouts, limits and concurrency values must be positive",
            )
        }
        val publicBase = runCatching { java.net.URI(config.server.publicBaseUrl) }.getOrNull()
        if (
            publicBase == null ||
            publicBase.scheme !in setOf("http", "https") ||
            publicBase.host.isNullOrBlank() ||
            publicBase.userInfo != null ||
            publicBase.query != null ||
            publicBase.fragment != null
        ) {
            throw ConfigValidationException(
                code = "PUBLIC_BASE_URL_INVALID",
                message = "server.publicBaseUrl must be an HTTP(S) origin without credentials, query or fragment",
            )
        }
        val publicHost = publicBase.host.lowercase()
        val isIpLiteral = publicHost.contains(':') ||
            publicHost.matches(Regex("^\\d{1,3}(\\.\\d{1,3}){3}$"))
        val isLoopbackBase = publicHost == "localhost" ||
            publicHost.endsWith(".localhost") ||
            (isIpLiteral && runCatching {
                java.net.InetAddress.getByName(publicHost).isLoopbackAddress
            }.getOrDefault(false))
        if (!isLoopbackBase && publicBase.scheme != "https") {
            throw ConfigValidationException(
                code = "REMOTE_GATEWAY_REQUIRES_HTTPS",
                message = "A remote server.publicBaseUrl must use HTTPS",
            )
        }
        if (!isLoopbackBase && !config.security.requireAuth) {
            throw ConfigValidationException(
                code = "REMOTE_GATEWAY_REQUIRES_AUTH",
                message = "A remote Gateway must enable security.requireAuth",
            )
        }
        if (config.security.requireAuth && config.security.apiToken.isNullOrBlank()) {
            throw ConfigValidationException(
                code = "API_TOKEN_REQUIRED",
                message = "BRIDGE_API_TOKEN must be set when security.requireAuth is enabled",
            )
        }
        config.security.apiToken?.let { token ->
            if (token.length < 32) {
                throw ConfigValidationException(
                    code = "API_TOKEN_TOO_SHORT",
                    message = "BRIDGE_API_TOKEN must contain at least 32 characters",
                )
            }
        }
        config.plugins.forEach { plugin ->
            if (!plugin.sha256.matches(Regex("^[a-f0-9]{64}$"))) {
                throw ConfigValidationException(
                    code = "PLUGIN_SHA256_REQUIRED",
                    message = "plugin '${plugin.key}' must declare a lowercase SHA-256 digest",
                )
            }
        }
        try {
            RemoteTargetPolicy(
                allowedPrivateHosts = config.security.allowedPrivateHosts.toSet(),
                allowedPrivateCidrs = config.security.allowedPrivateCidrs.toSet(),
            )
        } catch (_: IllegalArgumentException) {
            throw ConfigValidationException(
                code = "PRIVATE_CIDR_INVALID",
                message = "security.allowedPrivateCidrs contains an invalid CIDR",
            )
        }
    }
}
