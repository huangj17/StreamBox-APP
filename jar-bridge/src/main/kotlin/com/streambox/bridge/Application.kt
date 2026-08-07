package com.streambox.bridge

import com.streambox.bridge.api.configureRoutes
import com.streambox.bridge.catalog.CatalogManager
import com.streambox.bridge.catalog.ManualCatalogAdapter
import com.streambox.bridge.cms.CmsProxyService
import com.streambox.bridge.config.BridgeConfig
import com.streambox.bridge.config.ConfigValidator
import com.streambox.bridge.security.RemoteTargetPolicy
import com.streambox.bridge.spider.SpiderManager
import io.ktor.server.application.*
import io.ktor.server.engine.embeddedServer
import io.ktor.server.netty.Netty
import io.ktor.server.plugins.calllogging.*
import io.ktor.server.plugins.swagger.swaggerUI
import io.ktor.server.request.*
import io.ktor.server.response.respondRedirect
import io.ktor.server.routing.get
import io.ktor.server.routing.routing
import org.slf4j.LoggerFactory
import org.slf4j.event.Level
import java.time.Instant
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
    logger.info("StreamBox Gateway starting on {}:{}", config.server.host, config.server.port)

    val manager = SpiderManager(config).also(SpiderManager::loadAll)
    val catalogManager = CatalogManager(
        initial = ManualCatalogAdapter.build(
            sources = manager.manualCatalogSources(),
            version = "manual-${System.currentTimeMillis()}",
            activatedAt = Instant.now(),
        ),
        retirementGraceMs = config.catalog.retirementGraceMs,
    )
    val remoteTargetPolicy = RemoteTargetPolicy(
        allowedPrivateHosts = config.security.allowedPrivateHosts.toSet(),
        allowedPrivateCidrs = config.security.allowedPrivateCidrs.toSet(),
    )
    val cmsProxyService = CmsProxyService(remoteTargetPolicy = remoteTargetPolicy)
    val server = embeddedServer(Netty, port = config.server.port, host = config.server.host) {
        module(
            manager = manager,
            catalogManager = catalogManager,
            config = config,
            cmsProxyService = cmsProxyService,
        )
    }

    Runtime.getRuntime().addShutdownHook(Thread {
        logger.info("Shutting down...")
        catalogManager.close()
        cmsProxyService.close()
        manager.shutdown()
        server.stop(1000, 2000)
    })
    server.start(wait = true)
}

fun Application.module(
    manager: SpiderManager? = null,
    catalogManager: CatalogManager? = null,
    config: BridgeConfig? = null,
    cmsProxyService: CmsProxyService = CmsProxyService(),
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
        BridgeConfig.load().also(ConfigValidator::validate)
    } else {
        BridgeConfig()
    }
    val mgr = manager ?: SpiderManager(loadedConfig).also(SpiderManager::loadAll)
    val catalogs = catalogManager ?: CatalogManager(
        initial = ManualCatalogAdapter.build(
            sources = mgr.manualCatalogSources(),
            version = "manual-${System.currentTimeMillis()}",
            activatedAt = Instant.now(),
        ),
        retirementGraceMs = loadedConfig.catalog.retirementGraceMs,
    )
    monitor.subscribe(ApplicationStopped) {
        catalogs.close()
        mgr.shutdown()
        cmsProxyService.close()
    }

    configureRoutes(mgr, catalogs, cmsProxyService)
    routing {
        swaggerUI(path = "docs", swaggerFile = "openapi.yaml")
        swaggerUI(path = "swagger", swaggerFile = "openapi.yaml")
        get("/") { call.respondRedirect("/docs", permanent = false) }
    }
}
