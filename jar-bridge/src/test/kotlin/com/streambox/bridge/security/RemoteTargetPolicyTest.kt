package com.streambox.bridge.security

import okhttp3.HttpUrl.Companion.toHttpUrl
import java.net.InetAddress
import kotlin.test.Test
import kotlin.test.assertFailsWith

class RemoteTargetPolicyTest {
    @Test
    fun `policy rejects loopback private link local and cloud metadata targets by default`() {
        val policy = RemoteTargetPolicy(
            resolver = HostResolver { host -> listOf(InetAddress.getByName(host)) },
        )

        listOf(
            "http://127.0.0.1/file.jar",
            "http://10.0.0.1/file.jar",
            "http://169.254.169.254/latest/meta-data",
        ).forEach { url ->
            assertFailsWith<RemoteTargetException> { policy.validate(url.toHttpUrl()) }
        }
    }

    @Test
    fun `explicit private host allowlist permits compose service targets`() {
        val policy = RemoteTargetPolicy(
            allowedPrivateHosts = setOf("aggregator"),
            resolver = HostResolver { listOf(InetAddress.getByName("172.18.0.2")) },
        )

        policy.validate("http://aggregator:5678/config".toHttpUrl())
    }

    @Test
    fun `explicit private cidr permits only addresses inside that network`() {
        val allowed = RemoteTargetPolicy(
            allowedPrivateCidrs = setOf("10.42.0.0/16"),
            resolver = HostResolver { listOf(InetAddress.getByName("10.42.3.9")) },
        )
        allowed.validate("http://internal.example/config".toHttpUrl())

        val rejected = RemoteTargetPolicy(
            allowedPrivateCidrs = setOf("10.42.0.0/16"),
            resolver = HostResolver { listOf(InetAddress.getByName("10.43.3.9")) },
        )
        assertFailsWith<RemoteTargetException> {
            rejected.validate("http://other.example/config".toHttpUrl())
        }
    }
}
