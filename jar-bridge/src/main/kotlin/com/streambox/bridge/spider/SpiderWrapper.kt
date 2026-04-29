package com.streambox.bridge.spider

import org.slf4j.LoggerFactory
import java.net.URLClassLoader
import java.util.HashMap
import java.util.concurrent.Callable
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * 单个 Spider 实例的线程安全封装。
 * 使用单线程 Executor 串行化调用，带超时保护。
 */
class SpiderWrapper(
    val key: String,
    val name: String,
    private val instance: Any,
    private val clazz: Class<*>,
    private val classLoader: URLClassLoader,
    private val timeoutMs: Long = 15_000,
) : AutoCloseable {

    private val logger = LoggerFactory.getLogger("SpiderWrapper[$key]")

    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "spider-$key").apply { isDaemon = true }
    }

    private fun <T> invoke(methodName: String, block: () -> T): Result<T> {
        val start = System.currentTimeMillis()
        return try {
            val future = executor.submit(Callable { block() })
            val result = future.get(timeoutMs, TimeUnit.MILLISECONDS)
            val elapsed = System.currentTimeMillis() - start
            logger.debug("{} completed in {}ms", methodName, elapsed)
            Result.success(result)
        } catch (e: TimeoutException) {
            val elapsed = System.currentTimeMillis() - start
            logger.warn("{} timed out after {}ms", methodName, elapsed)
            Result.failure(SpiderTimeoutException("Plugin '$key' method '$methodName' timed out after ${timeoutMs}ms"))
        } catch (e: ExecutionException) {
            val elapsed = System.currentTimeMillis() - start
            logger.error("{} failed after {}ms", methodName, elapsed, e.cause)
            Result.failure(e.cause ?: e)
        } catch (e: Exception) {
            logger.error("{} unexpected error", methodName, e)
            Result.failure(e)
        }
    }

    fun homeContent(filter: Boolean): Result<String> = invoke("homeContent") {
        val m = clazz.getMethod("homeContent", Boolean::class.javaPrimitiveType)
        m.invoke(instance, filter) as? String ?: "{}"
    }

    fun homeVideoContent(): Result<String> = invoke("homeVideoContent") {
        val m = clazz.getMethod("homeVideoContent")
        m.invoke(instance) as? String ?: "{\"list\":[]}"
    }

    fun categoryContent(
        tid: String,
        pg: String,
        filter: Boolean,
        extend: HashMap<String, String>,
    ): Result<String> = invoke("categoryContent") {
        val m = clazz.getMethod(
            "categoryContent",
            String::class.java, String::class.java,
            Boolean::class.javaPrimitiveType, HashMap::class.java
        )
        m.invoke(instance, tid, pg, filter, extend) as? String ?: "{}"
    }

    fun detailContent(ids: List<String>): Result<String> = invoke("detailContent") {
        val m = clazz.getMethod("detailContent", List::class.java)
        m.invoke(instance, ids) as? String ?: "{}"
    }

    fun playerContent(flag: String, id: String, vipFlags: List<String>): Result<String> =
        invoke("playerContent") {
            val m = clazz.getMethod(
                "playerContent",
                String::class.java, String::class.java, List::class.java
            )
            m.invoke(instance, flag, id, vipFlags) as? String ?: "{}"
        }

    fun searchContent(key: String, quick: Boolean): Result<String> = invoke("searchContent") {
        val m = clazz.getMethod("searchContent", String::class.java, Boolean::class.javaPrimitiveType)
        m.invoke(instance, key, quick) as? String ?: "{\"list\":[]}"
    }

    override fun close() {
        executor.shutdownNow()
        try {
            classLoader.close()
        } catch (_: Exception) {
        }
        logger.info("Plugin closed")
    }
}
