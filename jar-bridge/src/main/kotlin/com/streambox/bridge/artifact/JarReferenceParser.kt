package com.streambox.bridge.artifact

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

data class JarReference(
    val raw: String,
    val url: HttpUrl,
    val prefix: String? = null,
    val declaredMd5: String? = null,
)

class JarReferenceException(
    val code: String,
    message: String,
) : IllegalArgumentException(message)

object JarReferenceParser {
    fun parse(raw: String, baseUrl: String? = null): JarReference {
        val trimmed = raw.trim()
        if (trimmed.isBlank() || trimmed.contains("{{")) {
            throw JarReferenceException("JAR_REFERENCE_INVALID", "JAR reference is invalid")
        }
        val prefix = if (trimmed.startsWith("img+")) "img" else null
        val withoutPrefix = if (prefix != null) trimmed.removePrefix("img+") else trimmed
        val markerIndex = withoutPrefix.indexOf(MD5_MARKER, ignoreCase = true)
        val urlPart = if (markerIndex >= 0) withoutPrefix.substring(0, markerIndex) else withoutPrefix
        val declaredMd5 = if (markerIndex >= 0) {
            withoutPrefix.substring(markerIndex + MD5_MARKER.length)
                .trim()
                .lowercase()
                .also { digest ->
                    if (!digest.matches(MD5_PATTERN)) {
                        throw JarReferenceException(
                            "JAR_MD5_INVALID",
                            "Declared JAR MD5 must be 32 hexadecimal characters",
                        )
                    }
                }
        } else {
            null
        }
        val absolute = urlPart.trim().toHttpUrlOrNull()
            ?: baseUrl?.toHttpUrlOrNull()?.resolve(urlPart.trim())
            ?: throw JarReferenceException(
                "JAR_URL_INVALID",
                "JAR URL must be absolute HTTP(S) or resolvable against the Aggregator URL",
            )
        if (absolute.scheme !in setOf("http", "https")) {
            throw JarReferenceException("JAR_URL_INVALID", "JAR URL must use HTTP(S)")
        }
        return JarReference(
            raw = trimmed,
            url = absolute,
            prefix = prefix,
            declaredMd5 = declaredMd5,
        )
    }

    private const val MD5_MARKER = ";md5;"
    private val MD5_PATTERN = Regex("[0-9a-f]{32}")
}
