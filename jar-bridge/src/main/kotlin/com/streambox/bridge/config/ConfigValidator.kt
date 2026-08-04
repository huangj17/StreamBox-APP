package com.streambox.bridge.config

import java.util.Base64
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import com.streambox.bridge.security.RemoteTargetPolicy

class ConfigValidationException(
    val code: String,
    message: String,
) : IllegalArgumentException(message)

object ConfigValidator {
    private val forbiddenAggregatorHeaders = setOf(
        "host",
        "content-length",
        "connection",
        "authorization",
        "user-agent",
        "cookie",
        "proxy-authorization",
        "proxy-connection",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    )

    fun validate(
        config: BridgeConfig,
        environment: Map<String, String> = System.getenv(),
    ) {
        if (
            config.catalog.mode == CatalogMode.AGGREGATOR &&
            (!config.aggregator.enabled || config.aggregator.baseUrl.isNullOrBlank())
        ) {
            throw ConfigValidationException(
                code = "AGGREGATOR_CONFIG_REQUIRED",
                message = "catalog.mode=aggregator requires aggregator.enabled=true and baseUrl",
            )
        }
        if (config.catalog.snapshotRetention < 2) {
            throw ConfigValidationException(
                code = "CONFIG_VALUE_NON_POSITIVE",
                message = "catalog.snapshotRetention must be at least 2",
            )
        }
        if (config.aggregator.enabled) {
            val endpoint = config.aggregator.baseUrl?.toHttpUrlOrNull()
            if (endpoint == null || endpoint.scheme !in setOf("http", "https")) {
                throw ConfigValidationException(
                    code = "AGGREGATOR_URL_INVALID",
                    message = "enabled Aggregator requires a valid HTTP(S) baseUrl",
                )
            }
        }

        val positiveValues = mapOf(
            "timeout" to config.timeout,
            "catalog.snapshotRetention" to config.catalog.snapshotRetention.toLong(),
            "catalog.retirementGraceMs" to config.catalog.retirementGraceMs,
            "aggregator.connectTimeout" to config.aggregator.connectTimeoutMs,
            "aggregator.readTimeout" to config.aggregator.readTimeoutMs,
            "aggregator.maxResponseBytes" to config.aggregator.maxResponseBytes,
            "artifacts.maxJarBytes" to config.artifacts.maxJarBytes,
            "artifacts.cacheMaxBytes" to config.artifacts.cacheMaxBytes,
            "artifacts.downloadConcurrency" to config.artifacts.downloadConcurrency.toLong(),
            "artifacts.maxZipEntries" to config.artifacts.maxZipEntries.toLong(),
        )
        if (config.aggregator.syncInterval.isZero || config.aggregator.syncInterval.isNegative) {
            throw ConfigValidationException(
                code = "CONFIG_VALUE_NON_POSITIVE",
                message = "aggregator.syncInterval must be positive",
            )
        }
        positiveValues.entries.firstOrNull { (_, value) -> value <= 0 }?.let { (name, _) ->
            throw ConfigValidationException(
                code = "CONFIG_VALUE_NON_POSITIVE",
                message = "$name must be positive",
            )
        }

        if (
            config.admin.enabled &&
            environment[config.admin.tokenEnv].isNullOrBlank()
        ) {
            throw ConfigValidationException(
                code = "ADMIN_TOKEN_REQUIRED",
                message = "admin.enabled=true requires a non-empty ${config.admin.tokenEnv}",
            )
        }

        environment[config.security.secretKeyEnv]
            ?.takeIf(String::isNotBlank)
            ?.let { encodedKey ->
                val decodedKey = runCatching {
                    Base64.getDecoder().decode(encodedKey)
                }.getOrNull()
                if (decodedKey?.size != 32) {
                    throw ConfigValidationException(
                        code = "SECRET_KEY_INVALID",
                        message = "${config.security.secretKeyEnv} must be Base64 encoded 32 bytes",
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

        config.aggregator.headersFromEnv.keys
            .firstOrNull { it.lowercase() in forbiddenAggregatorHeaders }
            ?.let { header ->
                throw ConfigValidationException(
                    code = "AGGREGATOR_HEADER_FORBIDDEN",
                    message = "aggregator custom header cannot override $header",
                )
            }

        config.aggregator.headersFromEnv.entries
            .firstOrNull { (_, environmentName) ->
                environment[environmentName].isNullOrBlank()
            }
            ?.let { (header, environmentName) ->
                throw ConfigValidationException(
                    code = "AGGREGATOR_HEADER_ENV_REQUIRED",
                    message = "$header requires a non-empty $environmentName",
                )
            }
    }
}
