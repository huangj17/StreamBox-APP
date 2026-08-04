package com.streambox.bridge

import com.streambox.bridge.api.configureRoutes
import com.streambox.bridge.cms.CmsProxyService
import com.streambox.bridge.aggregator.AggregatorClient
import com.streambox.bridge.artifact.ArtifactStore
import com.streambox.bridge.catalog.CatalogManager
import com.streambox.bridge.catalog.ManualCatalogAdapter
import com.streambox.bridge.config.CatalogMode
import com.streambox.bridge.config.BridgeConfig
import com.streambox.bridge.config.ConfigValidator
import com.streambox.bridge.spider.SpiderManager
import com.streambox.bridge.runtime.SharedJarRuntimePool
import com.streambox.bridge.runtime.SpiderFactory
import com.streambox.bridge.security.RemoteTargetPolicy
import com.streambox.bridge.storage.CatalogSnapshotRestorer
import com.streambox.bridge.storage.AutomaticCatalogRestorer
import com.streambox.bridge.storage.CatalogSnapshotStore
import com.streambox.bridge.storage.SecretStore
import com.streambox.bridge.sync.SyncCoordinator
import com.streambox.bridge.sync.SyncScheduler
import io.ktor.http.*
import io.ktor.server.application.*
import io.ktor.server.engine.*
import io.ktor.server.netty.*
import io.ktor.server.plugins.calllogging.*
import io.ktor.server.plugins.swagger.*
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import org.slf4j.LoggerFactory
import org.slf4j.event.Level
import kotlinx.coroutines.runBlocking
import java.time.Instant
import java.nio.file.Path
import java.util.UUID

private val logger = LoggerFactory.getLogger("JarBridge")
private const val REQUEST_ID_HEADER = "X-Request-Id"
private val RequestIdPlugin = createApplicationPlugin(name = "RequestId") {
    onCall { call ->
        val incoming = call.request.headers[REQUEST_ID_HEADER]
            ?.takeIf { it.isNotBlank() && it.length <= 128 }
        call.response.headers.append(REQUEST_ID_HEADER, incoming ?: UUID.randomUUID().toString())
    }
}

fun main() {
    val config = BridgeConfig.load()
    ConfigValidator.validate(config)
    logger.info("JAR Bridge Service starting on {}:{}", config.server.host, config.server.port)

    val manager = SpiderManager(config)
    manager.loadAll()
    val manualCatalog = ManualCatalogAdapter.build(
        sources = manager.manualCatalogSources(),
        version = "manual-${System.currentTimeMillis()}",
        activatedAt = Instant.now(),
    )
    val snapshotStore = CatalogSnapshotStore(
        root = Path.of("data", "catalog"),
        retention = config.catalog.snapshotRetention,
    )
    val remoteTargetPolicy = RemoteTargetPolicy(
        allowedPrivateHosts = config.security.allowedPrivateHosts.toSet(),
        allowedPrivateCidrs = config.security.allowedPrivateCidrs.toSet(),
    )
    val aggregatorClient = if (
        config.aggregator.enabled && config.catalog.mode != CatalogMode.MANUAL
    ) {
        AggregatorClient(config.aggregator, remoteTargetPolicy = remoteTargetPolicy)
    } else {
        null
    }
    val secretStore = aggregatorClient?.let {
        SecretStore(
            root = Path.of("data", "secrets"),
            secretKeyEnv = config.security.secretKeyEnv,
        )
    }
    val runtimePool = aggregatorClient?.let { SharedJarRuntimePool() }
    val artifactStore = aggregatorClient?.let {
        ArtifactStore(
            root = Path.of("data"),
            remoteTargetPolicy = remoteTargetPolicy,
            maxJarBytes = config.artifacts.maxJarBytes,
            maxZipEntries = config.artifacts.maxZipEntries,
            downloadConcurrency = config.artifacts.downloadConcurrency,
        )
    }
    val spiderFactory = runtimePool?.let { pool ->
        SpiderFactory(
            runtimePool = pool,
            runtimeRoot = Path.of("data", "runtime"),
            initTimeoutMs = config.timeout,
            methodTimeoutMs = config.timeout,
        )
    }
    val recovered = snapshotStore.recover()
    val initialCatalog = if (
        recovered != null &&
        artifactStore != null &&
        spiderFactory != null &&
        secretStore != null
    ) {
        runBlocking {
            AutomaticCatalogRestorer.restore(
                recovered = recovered,
                manualCatalog = manualCatalog,
                artifactStore = artifactStore,
                spiderFactory = spiderFactory,
                secretStore = secretStore,
            )
        }
    } else {
        recovered?.let { snapshot -> CatalogSnapshotRestorer.restore(snapshot, manualCatalog) }
            ?: manualCatalog
    }
    val catalogManager = CatalogManager(
        initial = initialCatalog,
        retirementGraceMs = config.catalog.retirementGraceMs,
    )
    val cmsProxyService = CmsProxyService(remoteTargetPolicy = remoteTargetPolicy)
    val syncCoordinator = aggregatorClient?.let { source ->
        SyncCoordinator(
            source = source,
            catalogManager = catalogManager,
            snapshotStore = snapshotStore,
            manualCatalog = manualCatalog,
            aggregatorBaseUrl = checkNotNull(config.aggregator.baseUrl),
            secretStore = secretStore,
            artifactStore = artifactStore,
            spiderFactory = spiderFactory,
            statusPath = Path.of("data", "sync-status.json"),
        )
    }
    val syncScheduler = syncCoordinator?.let { coordinator ->
        SyncScheduler(
            interval = config.aggregator.syncInterval,
            trigger = {
                coordinator.synchronize()
                Unit
            },
        )
    }

    val server = embeddedServer(Netty, port = config.server.port, host = config.server.host) {
        module(
            manager = manager,
            catalogManager = catalogManager,
            syncCoordinator = syncCoordinator,
            syncScheduler = syncScheduler,
            config = config,
            cmsProxyService = cmsProxyService,
            closeables = listOfNotNull(aggregatorClient, artifactStore, runtimePool),
        )
    }

    Runtime.getRuntime().addShutdownHook(Thread {
        logger.info("Shutting down...")
        syncScheduler?.close()
        syncCoordinator?.close()
        catalogManager.close()
        artifactStore?.close()
        runtimePool?.close()
        aggregatorClient?.close()
        manager.shutdown()
        server.stop(1000, 2000)
    })

    server.start(wait = true)
}

fun Application.module(
    manager: SpiderManager? = null,
    catalogManager: CatalogManager? = null,
    syncCoordinator: SyncCoordinator? = null,
    syncScheduler: SyncScheduler? = null,
    config: BridgeConfig? = null,
    environment: Map<String, String> = System.getenv(),
    cmsProxyService: CmsProxyService = CmsProxyService(),
    closeables: List<AutoCloseable> = emptyList(),
) {
    install(RequestIdPlugin)

    install(CallLogging) {
        level = Level.INFO
        format { call ->
            val status = call.response.status()
            val method = call.request.httpMethod.value
            val path = call.request.path()
            val duration = call.processingTimeMillis()
            val requestId = call.response.headers[REQUEST_ID_HEADER]
            val entryKey = call.parameters["key"]
            "$method $path → $status (${duration}ms) requestId=$requestId entryKey=$entryKey"
        }
    }

    val loadedConfig = config ?: if (manager == null && catalogManager == null) {
        BridgeConfig.load().also { ConfigValidator.validate(it) }
    } else {
        BridgeConfig()
    }
    val mgr = manager ?: SpiderManager(loadedConfig).also { it.loadAll() }
    val catalogs = catalogManager ?: CatalogManager(
        initial = ManualCatalogAdapter.build(
            sources = mgr.manualCatalogSources(),
            version = "manual-${System.currentTimeMillis()}",
            activatedAt = Instant.now(),
        ),
        retirementGraceMs = loadedConfig.catalog.retirementGraceMs,
    )
    monitor.subscribe(ApplicationStopped) {
        syncScheduler?.close()
        syncCoordinator?.close()
        catalogs.close()
        mgr.shutdown()
        closeables.forEach { closeable -> runCatching(closeable::close) }
    }
    monitor.subscribe(ApplicationStarted) {
        syncScheduler?.start()
    }
    configureRoutes(
        mgr,
        catalogs,
        syncCoordinator,
        loadedConfig,
        environment,
        cmsProxyService,
    )
    routing {
        // OpenAPI / Swagger UI 文档（/docs 与 /swagger 双 path 兼容）
        swaggerUI(path = "docs", swaggerFile = "openapi.yaml")
        swaggerUI(path = "swagger", swaggerFile = "openapi.yaml")
        // 访问根路径直接跳文档，避免裸 IP 看到 404
        get("/") {
            call.respondRedirect("/docs", permanent = false)
        }
    }
}
