package com.streambox.bridge.aggregator

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive

@Serializable
data class AggregatorConfigDto(
    val spider: String? = null,
    val sites: List<AggregatorSiteDto> = emptyList(),
    val lives: JsonElement? = null,
    val parses: JsonElement? = null,
)

@Serializable
data class AggregatorSiteDto(
    val key: String? = null,
    val name: String? = null,
    val type: JsonPrimitive? = null,
    val api: String? = null,
    val searchable: JsonPrimitive? = null,
    val quickSearch: JsonPrimitive? = null,
    val filterable: JsonPrimitive? = null,
    val jar: String? = null,
    val ext: JsonElement? = null,
)

data class NormalizedAggregatorConfig(
    val spider: String?,
    val sites: List<NormalizedAggregatorSite>,
    val finalUrl: String,
    val configDigest: String,
)

data class NormalizedAggregatorSite(
    val key: String,
    val name: String,
    val type: Int?,
    val api: String,
    val searchable: Boolean,
    val quickSearch: Boolean,
    val filterable: Boolean,
    val jar: String?,
    val ext: String?,
    val extSupported: Boolean = true,
)

class AggregatorSchemaException(
    val code: String,
    message: String,
    cause: Throwable? = null,
) : IllegalArgumentException(message, cause)
