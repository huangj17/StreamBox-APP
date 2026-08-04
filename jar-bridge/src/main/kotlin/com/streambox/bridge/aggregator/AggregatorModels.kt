package com.streambox.bridge.aggregator

data class FetchValidators(
    val etag: String? = null,
    val lastModified: String? = null,
)

sealed interface AggregatorFetchResult {
    val finalUrl: String
    val validators: FetchValidators

    data class Fetched(
        val body: String,
        override val finalUrl: String,
        override val validators: FetchValidators,
    ) : AggregatorFetchResult

    data class NotModified(
        override val finalUrl: String,
        override val validators: FetchValidators,
    ) : AggregatorFetchResult
}

interface AggregatorSource {
    suspend fun fetch(previous: FetchValidators? = null): AggregatorFetchResult
}

class AggregatorFetchException(
    val code: String,
    message: String,
    cause: Throwable? = null,
) : RuntimeException(message, cause)
