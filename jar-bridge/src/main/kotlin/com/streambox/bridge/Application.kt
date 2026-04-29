package com.streambox.bridge

import com.streambox.bridge.api.configureRoutes
import com.streambox.bridge.config.BridgeConfig
import com.streambox.bridge.spider.SpiderManager
import io.ktor.server.application.*
import io.ktor.server.engine.*
import io.ktor.server.netty.*
import io.ktor.server.plugins.calllogging.*
import io.ktor.server.plugins.swagger.*
import io.ktor.server.request.*
import io.ktor.server.routing.*
import org.slf4j.LoggerFactory
import org.slf4j.event.Level

private val logger = LoggerFactory.getLogger("JarBridge")

fun main() {
    val config = BridgeConfig.load()
    logger.info("JAR Bridge Service starting on {}:{}", config.server.host, config.server.port)

    val manager = SpiderManager(config)
    manager.loadAll()

    val server = embeddedServer(Netty, port = config.server.port, host = config.server.host) {
        module(manager)
    }

    Runtime.getRuntime().addShutdownHook(Thread {
        logger.info("Shutting down...")
        manager.shutdown()
        server.stop(1000, 2000)
    })

    server.start(wait = true)
}

fun Application.module(manager: SpiderManager? = null) {
    install(CallLogging) {
        level = Level.INFO
        format { call ->
            val status = call.response.status()
            val method = call.request.httpMethod.value
            val uri = call.request.uri
            val duration = call.processingTimeMillis()
            "$method $uri → $status (${duration}ms)"
        }
    }

    val mgr = manager ?: SpiderManager(BridgeConfig.load()).also { it.loadAll() }
    configureRoutes(mgr)
    routing {
        swaggerUI(path = "swagger", swaggerFile = "openapi.yaml")
    }
}
