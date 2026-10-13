package com.streambox.streambox.spider

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.*
import org.json.JSONObject
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/** Off-screen WebView stays out of the TV focus tree; disposal is unconditional. */
class WebResolver(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private val gate = java.util.concurrent.Semaphore(1)
    fun resolve(url: String, headers: JSONObject?, click: String = ""): JSONObject {
        check(Looper.myLooper() != Looper.getMainLooper()) { "网页解析需在后台执行" }
        PluginNetwork.requirePublic(url)
        check(gate.tryAcquire(2, TimeUnit.SECONDS)) { "网页解析忙，请重试" }
        val result = CompletableFuture<JSONObject>()
        var view: WebView? = null
        try {
            main.post {
                try {
                    val web = WebView(context); view = web
                    web.settings.javaScriptEnabled = true
                    web.settings.domStorageEnabled = true
                    web.settings.allowFileAccess = false
                    web.settings.allowContentAccess = false
                    web.settings.mediaPlaybackRequiresUserGesture = false
                    web.webViewClient = object : WebViewClient() {
                        override fun shouldInterceptRequest(v: WebView, request: WebResourceRequest): WebResourceResponse? {
                            val media = request.url.toString()
                            if (Regex("(?i)\\.(m3u8|mp4|flv)(?:[?#]|$)").containsMatchIn(media)) {
                                val h = JSONObject(request.requestHeaders)
                                CookieManager.getInstance().getCookie(media)?.let { h.put("Cookie", it) }
                                result.complete(JSONObject().put("url", media).put("header", h))
                            }
                            return null
                        }
                        override fun onPageFinished(v: WebView, address: String) {
                            if (click.isNotBlank()) v.evaluateJavascript(click, null)
                        }
                        override fun onReceivedError(v: WebView, request: WebResourceRequest, error: WebResourceError) {
                            if (request.isForMainFrame) result.completeExceptionally(IllegalStateException("网页解析失败，可切换线路"))
                        }
                    }
                    web.loadUrl(url, SpiderRuntime.stringMap(headers))
                } catch (error: Throwable) { result.completeExceptionally(error) }
            }
            return result.get(18, TimeUnit.SECONDS)
        } finally {
            main.post { view?.let { it.stopLoading(); it.loadUrl("about:blank"); it.destroy() } }
            gate.release()
        }
    }
}
