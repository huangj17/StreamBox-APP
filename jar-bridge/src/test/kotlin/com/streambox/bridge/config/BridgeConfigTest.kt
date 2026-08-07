package com.streambox.bridge.config

import java.nio.file.Files
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class BridgeConfigTest {
    @Test
    fun `loads manual gateway settings and plugins`() {
        val configFile = createTempDirectory("bridge-config-test").resolve("config.yml")
        Files.writeString(
            configFile,
            """
            server:
              port: 9988
            timeout: 12000
            catalog:
              retirementGraceMs: 45000
            security:
              allowedPrivateHosts: ["cms.internal"]
            plugins:
              - key: "manual"
                name: "Manual"
                jar: "plugins/manual.jar"
                class: "com.example.Manual"
                hidden: true
            """.trimIndent(),
        )

        val config = BridgeConfig.load(configFile.toString())

        assertEquals(9988, config.server.port)
        assertEquals(12_000, config.timeout)
        assertEquals(45_000, config.catalog.retirementGraceMs)
        assertEquals(listOf("cms.internal"), config.security.allowedPrivateHosts)
        assertEquals("manual", config.plugins.single().key)
        assertEquals(true, config.plugins.single().hidden)
    }

    @Test
    fun `rejects non-positive timeout and retirement grace`() {
        listOf(
            BridgeConfig(timeout = 0),
            BridgeConfig(catalog = CatalogConfig(retirementGraceMs = 0)),
        ).forEach { config ->
            val error = assertFailsWith<ConfigValidationException> {
                ConfigValidator.validate(config)
            }
            assertEquals("CONFIG_VALUE_NON_POSITIVE", error.code)
        }
    }

    @Test
    fun `rejects malformed private cidr configuration`() {
        val error = assertFailsWith<ConfigValidationException> {
            ConfigValidator.validate(
                BridgeConfig(
                    security = SecurityConfig(allowedPrivateCidrs = listOf("10.0.0.0/99")),
                ),
            )
        }

        assertEquals("PRIVATE_CIDR_INVALID", error.code)
    }
}
