package com.streambox.bridge.host

import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * 模拟 Android Context。
 * 仅实现 Spider 插件实际调用的方法。
 */
class MockContext(private val pluginKey: String) : android.content.Context() {

    private val prefsMap = ConcurrentHashMap<String, MockSharedPreferences>()
    private val cacheDir = File("data/$pluginKey/cache").apply { mkdirs() }
    private val filesDir = File("data/$pluginKey/files").apply { mkdirs() }

    fun getSharedPreferences(name: String, @Suppress("UNUSED_PARAMETER") mode: Int): MockSharedPreferences {
        return prefsMap.getOrPut(name) {
            MockSharedPreferences(File("data/$pluginKey/prefs/$name.json"))
        }
    }

    fun getCacheDir(): File = cacheDir

    fun getFilesDir(): File = filesDir

    fun getPackageName(): String = "com.streambox.bridge"

    fun getApplicationContext(): MockContext = this
}
