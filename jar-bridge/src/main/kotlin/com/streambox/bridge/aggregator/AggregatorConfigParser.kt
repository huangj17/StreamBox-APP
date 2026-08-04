package com.streambox.bridge.aggregator

import kotlinx.serialization.SerializationException
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.nio.charset.StandardCharsets
import java.security.MessageDigest

object AggregatorConfigParser {
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        explicitNulls = false
    }
    private val compactJson = Json {
        prettyPrint = false
        explicitNulls = false
    }

    fun parse(body: String, finalUrl: String): NormalizedAggregatorConfig {
        val baseUrl = finalUrl.toHttpUrlOrNull()
            ?: throw AggregatorSchemaException(
                code = "AGGREGATOR_FINAL_URL_INVALID",
                message = "Aggregator final URL is invalid",
            )
        val dto = try {
            json.decodeFromString<AggregatorConfigDto>(body)
        } catch (error: SerializationException) {
            throw AggregatorSchemaException(
                code = "AGGREGATOR_SCHEMA_INVALID",
                message = "Aggregator response does not match the expected object schema",
                cause = error,
            )
        } catch (error: IllegalArgumentException) {
            throw AggregatorSchemaException(
                code = "AGGREGATOR_SCHEMA_INVALID",
                message = "Aggregator response is not valid JSON",
                cause = error,
            )
        }

        return NormalizedAggregatorConfig(
            spider = dto.spider?.let { normalizeReference(it, baseUrl) },
            sites = dto.sites.map { site -> normalizeSite(site, baseUrl) },
            finalUrl = finalUrl,
            configDigest = digest(dto),
        )
    }

    private fun digest(dto: AggregatorConfigDto): String {
        val encoded = compactJson
            .encodeToJsonElement(AggregatorConfigDto.serializer(), dto)
            .let { it as JsonObject }
        val participating = JsonObject(
            buildMap {
                encoded["spider"]?.let { put("spider", it) }
                put("sites", encoded["sites"] ?: JsonArray(emptyList()))
            },
        ).canonicalized()
        val canonicalJson = compactJson.encodeToString(JsonElement.serializer(), participating)
        return MessageDigest
            .getInstance("SHA-256")
            .digest(canonicalJson.toByteArray(StandardCharsets.UTF_8))
            .joinToString(separator = "") { byte -> "%02x".format(byte) }
    }

    private fun normalizeSite(site: AggregatorSiteDto, baseUrl: HttpUrl): NormalizedAggregatorSite {
        val key = site.key?.trim().orEmpty()
        val api = site.api?.trim().orEmpty()
        return NormalizedAggregatorSite(
            key = key,
            name = site.name?.trim()?.takeIf(String::isNotEmpty) ?: key,
            type = site.type.intLikeOrNull(),
            api = normalizeApi(api, baseUrl),
            searchable = site.searchable.booleanLike(default = true),
            quickSearch = site.quickSearch.booleanLike(default = true),
            filterable = site.filterable.booleanLike(default = true),
            jar = site.jar?.let { normalizeReference(it, baseUrl) },
            ext = site.ext.normalizedExt(),
            extSupported = site.ext.isSupportedExt(),
        )
    }

    private fun normalizeApi(value: String, baseUrl: HttpUrl): String = when {
        value.startsWith("./") || value.startsWith("../") || value.startsWith("/") ->
            baseUrl.resolve(value)?.toString() ?: value
        else -> value
    }

    private fun normalizeReference(value: String, baseUrl: HttpUrl): String {
        val trimmed = value.trim()
        if (
            trimmed.startsWith("./") ||
            trimmed.startsWith("../") ||
            trimmed.startsWith("/")
        ) {
            return baseUrl.resolve(trimmed)?.toString() ?: trimmed
        }
        return trimmed
    }

    private fun JsonPrimitive?.intLikeOrNull(): Int? = this?.intOrNull
        ?: this?.contentOrNull?.toIntOrNull()

    private fun JsonPrimitive?.booleanLike(default: Boolean): Boolean {
        if (this == null) return default
        booleanOrNull?.let { return it }
        return when (contentOrNull?.trim()?.lowercase()) {
            "1", "true" -> true
            "0", "false" -> false
            else -> default
        }
    }

    private fun JsonElement?.normalizedExt(): String? = when (this) {
        null, JsonNull -> null
        is JsonPrimitive -> if (isString) content else compactJson.encodeToString(
            JsonElement.serializer(),
            this,
        )
        else -> compactJson.encodeToString(JsonElement.serializer(), canonicalized())
    }

    private fun JsonElement?.isSupportedExt(): Boolean = when (this) {
        null, JsonNull -> true
        is JsonPrimitive -> isString
        is JsonObject -> true
        else -> false
    }

    private fun JsonElement.canonicalized(): JsonElement = when (this) {
        is JsonObject -> JsonObject(
            entries
                .sortedBy(Map.Entry<String, JsonElement>::key)
                .associate { (key, value) -> key to value.canonicalized() },
        )
        is JsonArray -> JsonArray(map { it.canonicalized() })
        else -> this
    }
}
