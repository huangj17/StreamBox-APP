package com.streambox.streambox.spider

import android.app.Activity
import android.app.Instrumentation
import android.content.*
import android.os.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Runs in a real Android runtime without a third-party source or backend. */
class HostInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }
    override fun onStart() {
        val summary = Bundle()
        var runtime: SpiderRuntime? = null
        try {
            val bytes = context.assets.open("test-spider.jar").use { it.readBytes() }
            val md5 = ArtifactStore.digest("MD5", bytes)
            val declaration = "https://fixture.example/test-spider.jar;md5;$md5"
            val store = ArtifactStore(targetContext) { ByteArrayInputStream(bytes) }
            runtime = SpiderRuntime(targetContext, store)
            fun site(key: String, label: String) = JSONObject()
                .put("key", key).put("identity", "jar:fixture#$key").put("api", "csp_FixtureSpider")
                .put("configUrl", "https://fixture.example/box.json").put("jar", declaration)
                .put("ext", JSONObject().put("label", label))
            fun request(site: JSONObject, method: String, params: JSONObject = JSONObject()) =
                JSONObject().put("site", site).put("method", method).put("params", params)
            val first = site("one", "AAAA")
            val second = site("two", "BBBB")
            val home = JSONObject(runtime.invoke(request(first, "home")))
            check(home.getJSONArray("class").getJSONObject(0).getString("type_name") == "AAAA")
            val other = JSONObject(runtime.invoke(request(second, "home")))
            check(other.getJSONArray("class").getJSONObject(0).getString("type_name") == "BBBB")
            val search = JSONObject(runtime.invoke(request(first, "search", JSONObject().put("keyword", "test"))))
            check(search.getJSONArray("list").getJSONObject(0).getString("vod_name") == "AAAA")
            val detail = JSONObject(runtime.invoke(request(first, "detail", JSONObject().put("ids", JSONArray().put("episode")))))
            check(detail.getJSONArray("list").getJSONObject(0).getString("vod_play_url").contains("https://example.com/watch/episode"))
            val play = JSONObject(runtime.invoke(request(first, "play", JSONObject().put("flag", "HD").put("id", "https://example.com/watch/episode"))))
            repeat(20) { i -> runtime.invoke(request(site("extra-$i", "CCCC"), "home")) }
            // Browsing/searching other plugins must not retire an active proxy.
            val connection = URL(play.getString("url")).openConnection() as HttpURLConnection
            connection.connectTimeout = 3000; connection.readTimeout = 3000
            connection.setRequestProperty("Range", "bytes=0-3")
            check(connection.responseCode == 206)
            check(connection.inputStream.bufferedReader().use { it.readText() } == "AAAA")
            connection.disconnect()
            val playlistUrl = play.getString("url").replace("do=fixture", "do=playlist&url=https%3A%2F%2Fexample.com%2Fpath%2Fmaster.m3u8")
            val playlist = URL(playlistUrl).openStream().bufferedReader().use { it.readText() }
            check(!playlist.contains(":9978"))
            check(playlist.contains("relative.ts"))
            check(playlist.contains("%2Fpath%2Frelative.ts"))
            val segment = playlist.lineSequence().first { it.startsWith("http") }
            check(URL(segment).openStream().bufferedReader().use { it.readText() } == "AAAA")
            val forbidden = URL(runtime.proxyOrigin.replace(Regex("/spider/[a-f0-9]+/"), "/spider/wrong/") + "site/no/proxy").openConnection() as HttpURLConnection
            check(forbidden.responseCode == 403); forbidden.disconnect()
            try {
                store.load("https://fixture.example/bad.jar;md5;00000000000000000000000000000000")
                error("incorrect MD5 accepted")
            } catch (expected: IllegalStateException) { check(expected.message!!.contains("MD5")) }

            // A second process uses the pinned, read-only fixture cache and the
            // real Messenger / temporary-response-file protocol.
            val bound = CountDownLatch(1)
            var remote: Messenger? = null
            val service = object : ServiceConnection {
                override fun onServiceConnected(name: ComponentName, binder: IBinder) { remote = Messenger(binder); bound.countDown() }
                override fun onServiceDisconnected(name: ComponentName) {}
            }
            check(targetContext.bindService(Intent(targetContext, SpiderService::class.java), service, Context.BIND_AUTO_CREATE))
            try {
                check(bound.await(10, TimeUnit.SECONDS))
                val received = CountDownLatch(1)
                var reply: Bundle? = null
                val receiver = Messenger(object : Handler(Looper.getMainLooper()) {
                    override fun handleMessage(message: Message) { reply = message.data; received.countDown() }
                })
                remote!!.send(Message.obtain(null, 1, 100, 0).apply {
                    data = Bundle().apply { putString("request", request(first, "home").toString()) }
                    replyTo = receiver
                })
                check(received.await(15, TimeUnit.SECONDS))
                check(reply!!.getString("error") == null) { reply!!.getString("error") ?: "IPC failed" }
                val file = File(reply!!.getString("file")!!)
                check(JSONObject(file.readText()).getJSONArray("class").getJSONObject(0).getString("type_name") == "AAAA")
                file.delete()
                check(reply!!.getString("proxyOrigin")!!.startsWith("http://127.0.0.1:"))
            } finally { targetContext.unbindService(service) }
            summary.putString("stream", "OK: DEX loading, ext isolation, data/play resolution, Range proxy after cache eviction, HLS link rewriting, token rejection, MD5 validation, private-process IPC\n")
            finish(Activity.RESULT_OK, summary)
        } catch (error: Throwable) {
            summary.putString("stream", "FAILED: ${android.util.Log.getStackTraceString(error)}\n")
            finish(Activity.RESULT_CANCELED, summary)
        } finally { runtime?.close() }
    }
}
