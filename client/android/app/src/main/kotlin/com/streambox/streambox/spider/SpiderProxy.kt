package com.streambox.streambox.spider

import java.io.*
import java.net.*
import java.util.UUID
import java.util.concurrent.*

/** Loopback media transport only. Token and site scope are issued by the host. */
class SpiderProxy(private val invoke: (String, Map<String, String>) -> Array<*>) : AutoCloseable {
    private val server = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
    private val token = UUID.randomUUID().toString().replace("-", "")
    val origin = "http://127.0.0.1:${server.localPort}/spider/$token/"
    private val pool = ThreadPoolExecutor(4, 8, 30, TimeUnit.SECONDS, ArrayBlockingQueue(32))
    private val accept = Thread({
        while (!server.isClosed) {
            try {
                val socket = server.accept()
                try { pool.execute { serve(socket) } }
                catch (_: RejectedExecutionException) { socket.close() }
            } catch (_: IOException) { break }
        }
    }, "spider-media-proxy").apply { isDaemon = true; start() }

    private fun serve(socket: Socket) {
        socket.use {
            socket.soTimeout = 15_000
            val reader = socket.getInputStream().bufferedReader(Charsets.ISO_8859_1)
            val line = reader.readLine() ?: return
            if (line.length > 8192) return
            val parts = line.split(' ')
            if (parts.size != 3 || parts[0] !in setOf("GET", "HEAD")) { failure(socket, 405); return }
            val uri = runCatching { URI(parts[1]) }.getOrNull() ?: return
            val path = uri.path.split('/').filter(String::isNotEmpty)
            if (path.size < 5 || path[0] != "spider" || path[1] != token || path[2] != "site" || !path[3].matches(Regex("[a-f0-9]{64}"))) {
                failure(socket, 403); return
            }
            val headers = linkedMapOf<String, String>()
            var count = 0
            while (true) {
                val header = reader.readLine() ?: return
                if (header.isEmpty()) break
                if (++count > 64 || header.length > 8192) return
                val split = header.indexOf(':')
                if (split > 0) headers[header.substring(0, split).lowercase()] = header.substring(split + 1).trim()
            }
            val params = linkedMapOf<String, String>()
            uri.rawQuery?.split('&')?.forEach { pair ->
                val p = pair.split('=', limit = 2)
                params[URLDecoder.decode(p[0], "UTF-8")] = URLDecoder.decode(p.getOrElse(1) { "" }, "UTF-8")
            }
            params.putIfAbsent("headers", org.json.JSONObject(headers).toString())
            params["requestHeaders"] = org.json.JSONObject(headers).toString()
            headers["range"]?.let { params["range"] = it }
            try {
                val response = invoke(path[3], params)
                require(response.size >= 3)
                val status = response[0].toString().toInt()
                val mime = response[1].toString().replace("\r", "").replace("\n", "")
                var input = when (val body = response[2]) {
                    is InputStream -> body
                    is ByteArray -> ByteArrayInputStream(body)
                    is String -> ByteArrayInputStream(body.toByteArray())
                    else -> error("插件代理内容无效")
                }
                var rewrittenLength: Int? = null
                if (mime.lowercase().contains("mpegurl")) {
                    val buffer = ByteArrayOutputStream()
                    input.use { stream -> ArtifactStore.copyBounded(stream, buffer, 2L * 1024 * 1024) }
                    val text = rewritePlaylist(buffer.toString("UTF-8"), path[3], params)
                    val bytes = text.toByteArray(Charsets.UTF_8)
                    input = ByteArrayInputStream(bytes)
                    rewrittenLength = bytes.size
                }
                input.use {
                    val output = socket.getOutputStream()
                    val responseHeaders = (response.getOrNull(3) as? Map<*, *>) ?: emptyMap<String, String>()
                    val head = StringBuilder("HTTP/1.1 $status OK\r\nContent-Type: $mime\r\nConnection: close\r\n")
                    responseHeaders.forEach { (key, value) ->
                        val k = key.toString(); val v = value.toString()
                        if (k.lowercase() !in setOf("connection", "transfer-encoding", "content-type") &&
                            !(rewrittenLength != null && k.lowercase() in setOf("content-length", "content-encoding")) &&
                            !k.contains('\r') && !k.contains('\n') && !v.contains('\r') && !v.contains('\n')) head.append("$k: $v\r\n")
                    }
                    rewrittenLength?.let { head.append("Content-Length: $it\r\n") }
                    head.append("\r\n"); output.write(head.toString().toByteArray(Charsets.ISO_8859_1))
                    if (parts[0] == "GET") input.copyTo(output)
                    output.flush()
                }
            } catch (_: Throwable) { runCatching { failure(socket, 502) } }
        }
    }
    private fun rewritePlaylist(text: String, scope: String, params: Map<String, String>): String {
        val address = origin + "site/$scope"
        val aliases = Regex("http://(?:127\\.0\\.0\\.1|localhost):(?:9978|-1|${server.localPort})(?=/(?!spider/))")
        val base = params["url"]?.let { runCatching { URI(it) }.getOrNull() }
            ?.takeIf { it.scheme in setOf("http", "https") && it.host != null }
        fun reference(raw: String): String {
            val fixed = raw.replace(aliases, address)
            val uri = runCatching { URI(fixed) }.getOrNull() ?: return fixed
            if (uri.isAbsolute || base == null) return fixed
            val query = params.filterKeys { it !in setOf("requestHeaders", "range") }.toMutableMap()
            query["url"] = base.resolve(uri).toString()
            return "$address/proxy?" + query.entries.joinToString("&") {
                URLEncoder.encode(it.key, "UTF-8") + "=" + URLEncoder.encode(it.value, "UTF-8")
            }
        }
        return text.lineSequence().joinToString("\n") { line ->
            if (line.startsWith('#')) Regex("URI=\"([^\"]+)\"").replace(line) { "URI=\"${reference(it.groupValues[1])}\"" }
            else if (line.isBlank()) line else reference(line.trim())
        }
    }
    private fun failure(socket: Socket, status: Int) {
        socket.getOutputStream().write("HTTP/1.1 $status Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
    }
    override fun close() { server.close(); pool.shutdownNow(); accept.interrupt() }
}
