package com.streambox.bridge.host

import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * 模拟 Android SharedPreferences。
 * 内存 HashMap 做读取缓存，JSON 文件做持久化。
 */
class MockSharedPreferences(private val file: File) {

    private val data = ConcurrentHashMap<String, Any?>()

    init {
        if (file.exists()) {
            try {
                val json = JSONObject(file.readText())
                json.keys().forEach { key -> data[key] = json.get(key) }
            } catch (_: Exception) {
            }
        }
    }

    fun getString(key: String, defValue: String?): String? =
        data[key]?.toString() ?: defValue

    fun getInt(key: String, defValue: Int): Int =
        (data[key] as? Number)?.toInt() ?: defValue

    fun getLong(key: String, defValue: Long): Long =
        (data[key] as? Number)?.toLong() ?: defValue

    fun getBoolean(key: String, defValue: Boolean): Boolean =
        data[key] as? Boolean ?: defValue

    fun contains(key: String): Boolean = data.containsKey(key)

    fun getAll(): Map<String, *> = HashMap(data)

    fun edit(): Editor = Editor()

    inner class Editor {
        private val pending = HashMap<String, Any?>()
        private val removals = mutableSetOf<String>()
        private var clear = false

        fun putString(key: String, value: String?): Editor {
            pending[key] = value; return this
        }

        fun putInt(key: String, value: Int): Editor {
            pending[key] = value; return this
        }

        fun putLong(key: String, value: Long): Editor {
            pending[key] = value; return this
        }

        fun putBoolean(key: String, value: Boolean): Editor {
            pending[key] = value; return this
        }

        fun remove(key: String): Editor {
            removals.add(key); return this
        }

        fun clear(): Editor {
            clear = true; return this
        }

        fun apply() {
            commit()
        }

        fun commit(): Boolean {
            if (clear) data.clear()
            removals.forEach { data.remove(it) }
            data.putAll(pending)
            return try {
                file.parentFile?.mkdirs()
                file.writeText(JSONObject(data as Map<*, *>).toString(2))
                true
            } catch (_: Exception) {
                false
            }
        }
    }
}
