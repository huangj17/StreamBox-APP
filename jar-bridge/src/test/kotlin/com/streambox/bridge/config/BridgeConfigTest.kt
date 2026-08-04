package com.streambox.bridge.config

import java.nio.file.Files
import java.time.Duration
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class BridgeConfigTest {
    @Test
    fun `loads v2 sections while preserving legacy settings`() {
        val directory = createTempDirectory("bridge-config-test")
        val configFile = directory.resolve("config.yml")
        Files.writeString(
            configFile,
            """
            server:
              port: 9988
            timeout: 12000
            aggregator:
              enabled: true
              baseUrl: "http://aggregator:5678"
              syncInterval: "PT10M"
            catalog:
              mode: "hybrid"
              snapshotRetention: 3
            artifacts:
              downloadConcurrency: 2
            security:
              allowedPrivateHosts:
                - "aggregator"
            admin:
              enabled: false
            plugins:
              - key: "manual"
                name: "Manual"
                jar: "plugins/manual.jar"
                class: "com.example.Manual"
            """.trimIndent(),
        )

        val config = BridgeConfig.load(configFile.toString())

        assertEquals(9988, config.server.port)
        assertEquals(12_000, config.timeout)
        assertTrue(config.aggregator.enabled)
        assertEquals("http://aggregator:5678", config.aggregator.baseUrl)
        assertEquals(CatalogMode.HYBRID, config.catalog.mode)
        assertEquals(3, config.catalog.snapshotRetention)
        assertEquals(2, config.artifacts.downloadConcurrency)
        assertEquals(listOf("aggregator"), config.security.allowedPrivateHosts)
        assertFalse(config.admin.enabled)
        assertEquals("manual", config.plugins.single().key)
    }

    @Test
    fun `rejects aggregator catalog mode without an enabled aggregator endpoint`() {
        val config = BridgeConfig(
            catalog = CatalogConfig(mode = CatalogMode.AGGREGATOR),
        )

        val error = assertFailsWith<ConfigValidationException> {
            ConfigValidator.validate(config, environment = emptyMap())
        }

        assertEquals("AGGREGATOR_CONFIG_REQUIRED", error.code)
    }

    @Test
    fun `rejects non-positive timeout retention size and concurrency limits`() {
        val invalidConfigs = listOf(
            BridgeConfig(timeout = 0),
            BridgeConfig(catalog = CatalogConfig(snapshotRetention = 0)),
            BridgeConfig(catalog = CatalogConfig(snapshotRetention = 1)),
            BridgeConfig(catalog = CatalogConfig(retirementGraceMs = 0)),
            BridgeConfig(aggregator = AggregatorConfig(syncInterval = Duration.ZERO)),
            BridgeConfig(aggregator = AggregatorConfig(connectTimeoutMs = 0)),
            BridgeConfig(aggregator = AggregatorConfig(readTimeoutMs = 0)),
            BridgeConfig(aggregator = AggregatorConfig(maxResponseBytes = 0)),
            BridgeConfig(artifacts = ArtifactConfig(maxJarBytes = 0)),
            BridgeConfig(artifacts = ArtifactConfig(cacheMaxBytes = 0)),
            BridgeConfig(artifacts = ArtifactConfig(downloadConcurrency = 0)),
            BridgeConfig(artifacts = ArtifactConfig(maxZipEntries = 0)),
        )

        invalidConfigs.forEach { config ->
            val error = assertFailsWith<ConfigValidationException> {
                ConfigValidator.validate(config, environment = emptyMap())
            }
            assertEquals("CONFIG_VALUE_NON_POSITIVE", error.code)
        }
    }

    @Test
    fun `requires admin token to come from the configured environment variable`() {
        val config = BridgeConfig(
            admin = AdminConfig(enabled = true, tokenEnv = "TEST_ADMIN_TOKEN"),
        )

        val error = assertFailsWith<ConfigValidationException> {
            ConfigValidator.validate(config, environment = emptyMap())
        }

        assertEquals("ADMIN_TOKEN_REQUIRED", error.code)
    }

    @Test
    fun `rejects a configured secret key that is not base64 encoded 32 bytes`() {
        val config = BridgeConfig(
            security = SecurityConfig(secretKeyEnv = "TEST_SECRET_KEY"),
        )

        val error = assertFailsWith<ConfigValidationException> {
            ConfigValidator.validate(
                config,
                environment = mapOf("TEST_SECRET_KEY" to "dG9vLXNob3J0"),
            )
        }

        assertEquals("SECRET_KEY_INVALID", error.code)
    }

    @Test
    fun `rejects aggregator custom headers that override transport headers`() {
        val config = BridgeConfig(
            aggregator = AggregatorConfig(
                headersFromEnv = mapOf("Host" to "TEST_HOST_HEADER"),
            ),
        )

        val error = assertFailsWith<ConfigValidationException> {
            ConfigValidator.validate(
                config,
                environment = mapOf("TEST_HOST_HEADER" to "example.invalid"),
            )
        }

        assertEquals("AGGREGATOR_HEADER_FORBIDDEN", error.code)
    }

    @Test
    fun `requires every configured aggregator custom header environment value`() {
        val config = BridgeConfig(
            aggregator = AggregatorConfig(
                headersFromEnv = mapOf("X-Api-Key" to "TEST_API_KEY"),
            ),
        )

        val error = assertFailsWith<ConfigValidationException> {
            ConfigValidator.validate(config, environment = emptyMap())
        }

        assertEquals("AGGREGATOR_HEADER_ENV_REQUIRED", error.code)
    }

    @Test
    fun `rejects an enabled aggregator with a malformed or non http endpoint`() {
        listOf("not-a-url", "file:///tmp/config.json").forEach { endpoint ->
            val error = assertFailsWith<ConfigValidationException> {
                ConfigValidator.validate(
                    BridgeConfig(
                        aggregator = AggregatorConfig(enabled = true, baseUrl = endpoint),
                    ),
                    environment = emptyMap(),
                )
            }
            assertEquals("AGGREGATOR_URL_INVALID", error.code)
        }
    }

    @Test
    fun `rejects malformed private cidr configuration`() {
        val error = assertFailsWith<ConfigValidationException> {
            ConfigValidator.validate(
                BridgeConfig(
                    security = SecurityConfig(allowedPrivateCidrs = listOf("10.0.0.0/99")),
                ),
                environment = emptyMap(),
            )
        }

        assertEquals("PRIVATE_CIDR_INVALID", error.code)
    }
}
