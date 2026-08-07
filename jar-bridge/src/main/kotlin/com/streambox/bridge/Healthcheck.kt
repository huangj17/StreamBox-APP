package com.streambox.bridge

import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.time.Duration
import kotlin.system.exitProcess

/** Docker health command implemented in Java so the runtime image needs no shell or curl. */
object Healthcheck {
    @JvmStatic
    fun main(args: Array<String>) {
        val port = System.getenv("BRIDGE_PORT")?.toIntOrNull() ?: 9978
        val status = runCatching {
            val request = HttpRequest.newBuilder(URI("http://127.0.0.1:$port/health/live"))
                .timeout(Duration.ofSeconds(2))
                .GET()
                .build()
            HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(2))
                .build()
                .send(request, HttpResponse.BodyHandlers.discarding())
                .statusCode()
        }.getOrDefault(500)
        exitProcess(if (status == 200) 0 else 1)
    }
}
