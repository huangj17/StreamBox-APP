package com.streambox.streambox

import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.net.TrafficStats
import android.os.Process
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.streambox/platform",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                // Dart 侧查询当前 Android 设备是否为 TV，用于切换 TV / 手机 UI
                "isTv" -> {
                    val uiModeManager =
                        getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
                    val isTv =
                        uiModeManager.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
                    result.success(isTv)
                }
                // 当前进程累计下载字节数，供 Dart 侧算网速（-1 / UNSUPPORTED 时返回 null）
                "rxBytes" -> {
                    val bytes = TrafficStats.getUidRxBytes(Process.myUid())
                    if (bytes == TrafficStats.UNSUPPORTED.toLong() || bytes < 0) {
                        result.success(null)
                    } else {
                        result.success(bytes)
                    }
                }
                // 仅播放页开启窗口级常亮；离开播放页后必须清除，不能污染整个 App 生命周期。
                "setKeepScreenOn" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    if (enabled) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
