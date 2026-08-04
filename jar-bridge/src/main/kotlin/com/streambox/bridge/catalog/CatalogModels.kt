package com.streambox.bridge.catalog

import kotlinx.serialization.Serializable
import okhttp3.HttpUrl
import java.time.Instant
import java.util.HashMap

@Serializable
enum class SourceKind {
    CMS,
    JAR,
    MANUAL,
}

@Serializable
enum class SourceOrigin {
    AGGREGATOR,
    CONFIG_YAML,
}

@Serializable
enum class EntryStatus {
    DISCOVERED,
    PREPARING,
    READY,
    DEGRADED,
    FAILED,
    SHADOWED,
    DISABLED,
    RETIRING,
}

@Serializable
data class JarArtifactRef(
    val source: String,
    val declaredMd5: String? = null,
    val sha256: String? = null,
)

@Serializable
data class CatalogEntrySpec(
    val key: String,
    val upstreamKey: String? = null,
    val name: String,
    val kind: SourceKind,
    val origin: SourceOrigin,
    val api: String,
    val className: String? = null,
    val jar: JarArtifactRef? = null,
    val secretRef: String? = null,
    val extDigest: String? = null,
    val searchable: Boolean = true,
    val hidden: Boolean = false,
    val specFingerprint: String,
)

enum class CatalogErrorCode {
    DUPLICATE_KEY,
    CONFIG_INVALID,
    SOURCE_UNAVAILABLE,
}

data class CatalogError(
    val code: CatalogErrorCode,
    val message: String,
)

class CatalogBuildException(
    val error: CatalogError,
) : IllegalArgumentException(error.message)

enum class CmsDialect {
    CLASS,
    LIST,
    UNKNOWN,
}

interface SpiderRuntime : AutoCloseable {
    val key: String
    val name: String

    suspend fun homeContent(filter: Boolean): Result<String>

    suspend fun categoryContent(
        tid: String,
        page: String,
        filter: Boolean,
        extend: HashMap<String, String>,
    ): Result<String>

    suspend fun detailContent(ids: List<String>): Result<String>

    suspend fun searchContent(keyword: String, quick: Boolean): Result<String>

    suspend fun playerContent(flag: String, id: String, vipFlags: List<String>): Result<String>
}

sealed interface SourceHandler {
    data class Cms(
        val target: HttpUrl,
        val dialect: CmsDialect = CmsDialect.UNKNOWN,
    ) : SourceHandler

    data class Spider(
        val runtime: SpiderRuntime,
    ) : SourceHandler
}

data class RuntimeEntry(
    val spec: CatalogEntrySpec,
    val status: EntryStatus,
    val handler: SourceHandler?,
    val lastError: CatalogError? = null,
    val lastReadyAt: Instant? = null,
)

data class ActiveCatalog(
    val version: String,
    val activatedAt: Instant,
    val entries: Map<String, RuntimeEntry>,
) {
    companion object {
        fun empty(): ActiveCatalog = ActiveCatalog(
            version = "empty",
            activatedAt = Instant.EPOCH,
            entries = emptyMap(),
        )
    }
}

data class CatalogStatusView(
    val catalog: ActiveCatalog,
    val stale: Boolean,
)
