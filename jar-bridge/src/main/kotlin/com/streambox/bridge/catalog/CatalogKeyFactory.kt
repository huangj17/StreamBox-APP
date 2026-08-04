package com.streambox.bridge.catalog

import com.streambox.bridge.aggregator.NormalizedAggregatorSite
import java.nio.charset.StandardCharsets
import java.security.MessageDigest

data class CatalogIdentity(
    val upstreamKey: String,
    val api: String,
    val jarReference: String?,
) {
    companion object {
        fun from(site: NormalizedAggregatorSite): CatalogIdentity = CatalogIdentity(
            upstreamKey = site.key,
            api = site.api,
            jarReference = site.jar,
        )
    }
}

data class CatalogKeyAllocation(
    val keys: Map<CatalogIdentity, String>,
) {
    fun keyFor(site: NormalizedAggregatorSite): String =
        checkNotNull(keys[CatalogIdentity.from(site)]) {
            "site was not part of this key allocation: ${site.key}"
        }
}

object CatalogKeyFactory {
    fun allocate(
        sites: List<NormalizedAggregatorSite>,
        existing: Map<CatalogIdentity, String> = emptyMap(),
    ): CatalogKeyAllocation {
        val identities = sites.map(CatalogIdentity::from)
        val bases = identities.associateWith { identity -> sanitize(identity.upstreamKey) }
        val collisionCounts = bases.values.groupingBy(String::lowercase).eachCount()
        val allocated = linkedMapOf<CatalogIdentity, String>()

        identities.forEach { identity ->
            val previous = existing[identity]
            if (!previous.isNullOrBlank() && previous !in allocated.values) {
                allocated[identity] = previous
                return@forEach
            }
            val base = checkNotNull(bases[identity])
            allocated[identity] = if (collisionCounts[base.lowercase()] == 1) {
                "agg_$base"
            } else {
                "agg_${base}_${identity.digest().take(8)}"
            }
        }
        return CatalogKeyAllocation(allocated)
    }

    private fun sanitize(upstreamKey: String): String {
        val normalized = upstreamKey
            .lowercase()
            .map { character ->
                if (character.isAsciiCatalogKeyCharacter()) character else '_'
            }
            .joinToString(separator = "")
            .replace(Regex("_+"), "_")
            .trim('_')
            .take(80)
        return normalized.ifBlank { "site" }
    }

    private fun Char.isAsciiCatalogKeyCharacter(): Boolean =
        this in 'a'..'z' || this in '0'..'9' || this == '_' || this == '-'

    private fun CatalogIdentity.digest(): String {
        val value = listOf(upstreamKey, api, jarReference.orEmpty()).joinToString("\u0000")
        return MessageDigest
            .getInstance("SHA-256")
            .digest(value.toByteArray(StandardCharsets.UTF_8))
            .joinToString(separator = "") { byte -> "%02x".format(byte) }
    }
}
