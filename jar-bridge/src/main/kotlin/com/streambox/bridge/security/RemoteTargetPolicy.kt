package com.streambox.bridge.security

import okhttp3.HttpUrl
import okhttp3.Dns
import okhttp3.HttpUrl.Companion.toHttpUrl
import java.net.InetAddress
import java.net.Inet4Address
import java.net.Inet6Address

fun interface HostResolver {
    fun resolve(host: String): List<InetAddress>
}

class RemoteTargetException(
    val code: String,
    message: String,
) : SecurityException(message)

class RemoteTargetPolicy(
    allowedPrivateHosts: Set<String> = emptySet(),
    allowedPrivateCidrs: Set<String> = emptySet(),
    private val resolver: HostResolver = HostResolver { host ->
        InetAddress.getAllByName(host).toList()
    },
) {
    private val privateHostAllowlist = allowedPrivateHosts.map(String::lowercase).toSet()
    private val privateCidrAllowlist = allowedPrivateCidrs.map(::parseCidr)

    fun validate(url: HttpUrl): List<InetAddress> {
        if (url.scheme !in setOf("http", "https")) {
            throw RemoteTargetException("REMOTE_SCHEME_FORBIDDEN", "Remote URL must use HTTP(S)")
        }
        if (url.username.isNotEmpty() || url.password.isNotEmpty()) {
            throw RemoteTargetException(
                "REMOTE_CREDENTIALS_FORBIDDEN",
                "Remote URL must not contain credentials",
            )
        }
        val addresses = try {
            resolver.resolve(url.host)
        } catch (error: Exception) {
            throw RemoteTargetException("REMOTE_DNS_FAILED", "Remote host could not be resolved")
        }
        if (addresses.isEmpty()) {
            throw RemoteTargetException("REMOTE_DNS_FAILED", "Remote host resolved to no addresses")
        }
        if (
            url.host.lowercase() !in privateHostAllowlist &&
            addresses.any { address ->
                !isPublicRemoteAddress(address) &&
                    privateCidrAllowlist.none { cidr -> cidr.contains(address) }
            }
        ) {
            throw RemoteTargetException(
                "REMOTE_TARGET_FORBIDDEN",
                "Remote host resolves to a private or reserved address",
            )
        }
        return addresses
    }

    private data class Cidr(
        val network: ByteArray,
        val prefixBits: Int,
    ) {
        fun contains(address: InetAddress): Boolean {
            val candidate = address.address
            if (candidate.size != network.size) return false
            val completeBytes = prefixBits / 8
            val remainingBits = prefixBits % 8
            for (index in 0 until completeBytes) {
                if (candidate[index] != network[index]) return false
            }
            if (remainingBits == 0) return true
            val mask = (0xff shl (8 - remainingBits)) and 0xff
            return (candidate[completeBytes].toInt() and mask) ==
                (network[completeBytes].toInt() and mask)
        }
    }

    private fun parseCidr(value: String): Cidr {
        val parts = value.split('/', limit = 2)
        require(parts.size == 2) { "private CIDR must include a prefix length" }
        require(parts[0].matches(Regex("[0-9a-fA-F:.]+"))) { "private CIDR must be numeric" }
        val address = InetAddress.getByName(parts[0]).address
        val prefix = parts[1].toIntOrNull()
            ?: throw IllegalArgumentException("private CIDR prefix is invalid")
        require(prefix in 0..(address.size * 8)) { "private CIDR prefix is out of range" }
        return Cidr(address, prefix)
    }
}

class PolicyDns(
    private val policy: RemoteTargetPolicy,
) : Dns {
    override fun lookup(hostname: String): List<InetAddress> =
        policy.validate("https://$hostname/".toHttpUrl())
}

fun isPublicRemoteAddress(address: InetAddress): Boolean {
    if (
        address.isAnyLocalAddress ||
        address.isLoopbackAddress ||
        address.isLinkLocalAddress ||
        address.isSiteLocalAddress ||
        address.isMulticastAddress
    ) {
        return false
    }
    val bytes = address.address.map(Byte::toInt).map { it and 0xff }
    return when (address) {
        is Inet4Address -> when {
            bytes[0] == 0 -> false
            bytes[0] == 100 && bytes[1] in 64..127 -> false
            bytes[0] == 192 && bytes[1] == 0 && bytes[2] in setOf(0, 2) -> false
            bytes[0] == 192 && bytes[1] == 88 && bytes[2] == 99 -> false
            bytes[0] == 198 && bytes[1] in 18..19 -> false
            bytes[0] == 198 && bytes[1] == 51 && bytes[2] == 100 -> false
            bytes[0] == 203 && bytes[1] == 0 && bytes[2] == 113 -> false
            bytes[0] >= 224 -> false
            else -> true
        }
        is Inet6Address -> {
            val globalUnicast = bytes[0] in 0x20..0x3f
            val uniqueLocal = bytes[0] and 0xfe == 0xfc
            val documentation =
                bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8
            globalUnicast && !uniqueLocal && !documentation
        }
        else -> false
    }
}
