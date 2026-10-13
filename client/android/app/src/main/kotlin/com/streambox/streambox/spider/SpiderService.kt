package com.streambox.streambox.spider

import android.app.Service
import android.content.Intent
import android.os.*
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeoutException

/** Separate process contains JNI crashes and allows stuck plugins to restart. */
class SpiderService : Service() {
    private val workers = Executors.newFixedThreadPool(4)
    private val watchdog = Executors.newSingleThreadScheduledExecutor()
    private lateinit var runtime: SpiderRuntime
    private val inbox = Messenger(object : Handler(Looper.getMainLooper()) {
        override fun handleMessage(message: Message) {
            if (message.what != 1) return
            val id = message.arg1
            val reply = message.replyTo ?: return
            val request = message.data.getString("request") ?: return
            val completed = java.util.concurrent.atomic.AtomicBoolean(false)
            val deadline = object : Runnable {
                override fun run() {
                    if (!completed.compareAndSet(false, true)) return
                    runCatching {
                        reply.send(Message.obtain(null, 2, id, 0).apply {
                            data = Bundle().apply { putString("error", "插件加载超时，宿主将重启，请重试") }
                        })
                    }
                    watchdog.schedule({ Process.killProcess(Process.myPid()) }, 250, java.util.concurrent.TimeUnit.MILLISECONDS)
                }
            }
            val timeout = watchdog.schedule(deadline, 35, java.util.concurrent.TimeUnit.SECONDS)
            workers.execute {
                val response = Bundle()
                var restart = false
                try {
                    val data = runtime.invoke(JSONObject(request))
                    require(data.toByteArray().size <= AndroidSpiderPlugin.MAX_RESPONSE_BYTES)
                    val folder = File(cacheDir, "spider-responses").apply { mkdirs() }
                    val file = File.createTempFile("reply-", ".json", folder)
                    file.writeText(data)
                    response.putString("file", file.absolutePath)
                    response.putString("proxyOrigin", runtime.proxyOrigin)
                } catch (error: Throwable) {
                    val cause = generateSequence(error) { it.cause }.last()
                    restart = cause is TimeoutException
                    response.putString("error", when (cause) {
                        is NoClassDefFoundError, is ClassNotFoundException -> "插件缺少所需宿主组件：${cause.message?.take(140)}"
                        is UnsatisfiedLinkError -> "插件原生库与当前 Android 设备不兼容"
                        is TimeoutException -> "插件执行超时，宿主将重启，可重试或切换片源"
                        else -> cause.message?.take(200) ?: "插件执行失败，可重试或切换片源"
                    })
                }
                timeout.cancel(false)
                if (!completed.compareAndSet(false, true)) {
                    response.getString("file")?.let { File(it).delete() }
                    return@execute
                }
                try { reply.send(Message.obtain(null, 2, id, 0).apply { this.data = response }) }
                catch (_: RemoteException) {
                    response.getString("file")?.let { File(it).delete() }
                }
                if (restart) watchdog.schedule({ Process.killProcess(Process.myPid()) }, 250, java.util.concurrent.TimeUnit.MILLISECONDS)
            }
        }
    })
    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= 28) android.webkit.WebView.setDataDirectorySuffix("spider")
        File(cacheDir, "spider-responses").listFiles()?.forEach(File::delete)
        runtime = SpiderRuntime(applicationContext)
    }
    override fun onBind(intent: Intent): IBinder = inbox.binder
    override fun onDestroy() {
        runtime.close(); workers.shutdownNow(); watchdog.shutdownNow(); super.onDestroy()
    }
}
