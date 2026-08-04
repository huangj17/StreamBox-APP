package com.streambox.bridge.runtime

import com.streambox.bridge.artifact.PreparedArtifact
import com.streambox.bridge.host.MockContext
import com.streambox.bridge.spider.SpiderTimeoutException
import com.streambox.bridge.spider.SpiderWrapper
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import java.lang.reflect.InvocationTargetException
import java.nio.file.Path
import java.util.concurrent.Callable
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import org.slf4j.LoggerFactory

class SpiderFactoryException(
    val code: String,
    message: String,
    cause: Throwable? = null,
) : RuntimeException(message, cause)

class SpiderFactory(
    private val runtimePool: SharedJarRuntimePool,
    private val runtimeRoot: Path,
    private val initTimeoutMs: Long = 15_000,
    private val methodTimeoutMs: Long = 15_000,
) {
    private val logger = LoggerFactory.getLogger(SpiderFactory::class.java)
    suspend fun create(
        key: String,
        name: String,
        artifact: PreparedArtifact,
        className: String,
        ext: String,
        generation: String,
    ): SpiderWrapper {
        val runtimeLease = runtimePool.acquire(artifact, generation)
        var wrapper: SpiderWrapper? = null
        try {
            val clazz = runtimeLease.classLoader.loadClass(className)
            val instance = clazz.getDeclaredConstructor().newInstance()
            initialize(key, clazz, instance, ext)
            wrapper = SpiderWrapper(
                key = key,
                name = name,
                instance = instance,
                clazz = clazz,
                classLoader = runtimeLease,
                timeoutMs = methodTimeoutMs,
            )
            val probe = wrapper.homeContent(filter = true).getOrElse { error ->
                throw SpiderFactoryException(
                    code = "SPIDER_PROBE_FAILED",
                    message = "Spider activation probe failed",
                    cause = error,
                )
            }
            val parsed = runCatching { Json.parseToJsonElement(probe) }.getOrNull()
            if (parsed !is JsonObject && parsed !is JsonArray) {
                throw SpiderFactoryException(
                    code = "SPIDER_PROBE_INVALID",
                    message = "Spider activation probe returned invalid JSON",
                )
            }
            logger.info(
                "prepared Spider runtime key={} artifact={} generation={}",
                key,
                artifact.sha256.take(16),
                generation,
            )
            return wrapper
        } catch (error: SpiderFactoryException) {
            wrapper?.close() ?: runtimeLease.close()
            throw error
        } catch (error: Throwable) {
            wrapper?.close() ?: runtimeLease.close()
            throw SpiderFactoryException(
                code = "SPIDER_CREATE_FAILED",
                message = "Spider runtime could not be created",
                cause = unwrap(error),
            )
        }
    }

    private fun initialize(key: String, clazz: Class<*>, instance: Any, ext: String) {
        val context = MockContext(key, runtimeRoot.toFile())
        val initMethod = try {
            clazz.getMethod("init", android.content.Context::class.java, String::class.java)
        } catch (_: NoSuchMethodException) {
            clazz.getMethod("init", Any::class.java, String::class.java)
        }
        val executor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "spider-init-$key").apply { isDaemon = true }
        }
        try {
            val future = executor.submit(Callable { initMethod.invoke(instance, context, ext) })
            try {
                future.get(initTimeoutMs, TimeUnit.MILLISECONDS)
            } catch (error: TimeoutException) {
                future.cancel(true)
                throw SpiderFactoryException(
                    code = "SPIDER_INIT_TIMEOUT",
                    message = "Spider initialization timed out",
                    cause = SpiderTimeoutException("Spider '$key' init timed out"),
                )
            } catch (error: ExecutionException) {
                throw SpiderFactoryException(
                    code = "SPIDER_INIT_FAILED",
                    message = "Spider initialization failed",
                    cause = unwrap(error),
                )
            }
        } finally {
            executor.shutdownNow()
        }
    }

    private fun unwrap(error: Throwable): Throwable = when (error) {
        is ExecutionException -> error.cause?.let(::unwrap) ?: error
        is InvocationTargetException -> error.targetException?.let(::unwrap) ?: error
        else -> error
    }
}
