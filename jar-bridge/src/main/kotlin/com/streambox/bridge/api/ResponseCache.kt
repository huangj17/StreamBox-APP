package com.streambox.bridge.api

import java.util.concurrent.ConcurrentHashMap

/**
 * 简单 TTL 内存缓存：缓存 spider 返回的原始 JSON 字符串。
 *
 * 适用场景：首页同时打多个 rail 时，spider 单线程串行 + 重复请求让排尾的卡死。
 * 缓存 `?ac=class` 与 `?ac=detail&t=X&pg=Y` 这两类「全用户共享」的查询，
 * 60s 内同一查询直接走内存返回，跳过 spider 调用。
 *
 * 不缓存的：`?ac=detail&ids=...`（用户点详情时点哪个看哪个）、`?wd=...`（搜索）、
 * `/api/{key}/play`（每次请求需带新签名）。
 *
 * Sanitize 后处理（双 https 修复 / proxy host 改写）由 `respondResult` 在每次
 * 输出时执行，不写进缓存，避免不同客户端 Host 头串味。
 */
object ResponseCache {
    private const val DEFAULT_TTL_MS = 60_000L
    private const val MAX_ENTRIES = 256

    private data class Entry(val expiry: Long, val body: String)

    private val store = ConcurrentHashMap<String, Entry>()

    fun get(key: String): String? {
        val e = store[key] ?: return null
        if (System.currentTimeMillis() > e.expiry) {
            store.remove(key)
            return null
        }
        return e.body
    }

    fun put(key: String, body: String, ttlMs: Long = DEFAULT_TTL_MS) {
        // 简单粗暴的容量控制：超过上限清半（不 LRU，避免引依赖）
        if (store.size >= MAX_ENTRIES) {
            val toRemove = store.keys.take(MAX_ENTRIES / 2)
            toRemove.forEach { store.remove(it) }
        }
        store[key] = Entry(System.currentTimeMillis() + ttlMs, body)
    }

    fun clear() = store.clear()

    fun size(): Int = store.size
}
