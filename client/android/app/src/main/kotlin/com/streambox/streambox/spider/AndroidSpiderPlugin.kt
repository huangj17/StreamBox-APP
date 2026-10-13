package com.streambox.streambox.spider

import android.content.*
import android.os.*
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/** Channel -> private Android service. No external server or HTTP data API. */
class AndroidSpiderPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ServiceConnection {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private val pending = mutableMapOf<Int, MethodChannel.Result>()
    private val queued = mutableMapOf<Int, Bundle>()
    private val deadlines = mutableMapOf<Int, Runnable>()
    private var nextId = 0
    private var remote: Messenger? = null
    private var bound = false
    private val replies = Messenger(object : Handler(Looper.getMainLooper()) {
        override fun handleMessage(message: Message) {
            val id = message.arg1
            val result = pending.remove(id) ?: return
            deadlines.remove(id)?.let(main::removeCallbacks)
            val error = message.data.getString("error")
            if (error != null) { result.error("SPIDER_FAILED", error, null); return }
            val path = message.data.getString("file")
            val proxy = message.data.getString("proxyOrigin")
            io.execute {
                try {
                    val root = File(context.cacheDir, "spider-responses").canonicalFile
                    val file = File(path ?: "").canonicalFile
                    require(file.parentFile == root && file.length() <= MAX_RESPONSE_BYTES)
                    val text = file.readText()
                    file.delete()
                    main.post { result.success(mapOf("data" to text, "proxyOrigin" to proxy)) }
                } catch (_: Exception) {
                    main.post { result.error("SPIDER_FAILED", "插件响应无效，请重试", null) }
                }
            }
        }
    })

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.streambox/spider")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "invoke") { result.notImplemented(); return }
        val args = JSONObject(call.arguments as? Map<*, *> ?: emptyMap<String, Any>()).toString()
        if (args.toByteArray().size > 256 * 1024) {
            result.error("SPIDER_FAILED", "插件参数过大", null); return
        }
        val id = ++nextId
        pending[id] = result
        queued[id] = Bundle().apply { putString("request", args) }
        val timeout = Runnable {
            pending.remove(id)?.error("SPIDER_TIMEOUT", "插件响应超时，可重试或切换片源", null)
            queued.remove(id); deadlines.remove(id)
        }
        deadlines[id] = timeout
        main.postDelayed(timeout, 42_000)
        if (remote != null) dispatch(id) else if (!bound) {
            bound = context.bindService(Intent(context, SpiderService::class.java), this, Context.BIND_AUTO_CREATE)
            if (!bound) failAll("无法启动 Android 插件宿主")
        }
    }

    private fun dispatch(id: Int) {
        val data = queued.remove(id) ?: return
        try {
            remote?.send(Message.obtain(null, 1, id, 0).apply {
                this.data = data; replyTo = replies
            })
        } catch (_: RemoteException) { failAll("插件宿主已退出，可重新选择内容") }
    }
    override fun onServiceConnected(name: ComponentName, binder: IBinder) {
        remote = Messenger(binder)
        queued.keys.toList().forEach(::dispatch)
    }
    override fun onServiceDisconnected(name: ComponentName) {
        remote = null; failAll("插件宿主已重启，请重试")
    }
    private fun failAll(message: String) {
        pending.values.forEach { it.error("SPIDER_FAILED", message, null) }
        pending.clear(); queued.clear()
        deadlines.values.forEach(main::removeCallbacks); deadlines.clear()
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        failAll("插件宿主已关闭")
        if (bound) context.unbindService(this)
        bound = false; remote = null; io.shutdownNow()
    }
    companion object { const val MAX_RESPONSE_BYTES = 10L * 1024 * 1024 }
}
