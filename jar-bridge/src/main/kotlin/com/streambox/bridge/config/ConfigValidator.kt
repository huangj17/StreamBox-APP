package com.streambox.bridge.config

import com.streambox.bridge.security.RemoteTargetPolicy

class ConfigValidationException(
    val code: String,
    message: String,
) : IllegalArgumentException(message)

object ConfigValidator {
    fun validate(config: BridgeConfig) {
        if (config.timeout <= 0 || config.catalog.retirementGraceMs <= 0) {
            throw ConfigValidationException(
                code = "CONFIG_VALUE_NON_POSITIVE",
                message = "timeout and catalog.retirementGraceMs must be positive",
            )
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
