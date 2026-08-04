package com.streambox.bridge.runtime

import com.streambox.bridge.artifact.PreparedArtifact
import java.net.URLClassLoader
import java.util.concurrent.atomic.AtomicBoolean

fun interface JarClassLoaderFactory {
    fun create(artifact: PreparedArtifact): URLClassLoader
}

private data class RuntimeKey(
    val sha256: String,
    val generation: String,
)

class SharedJarRuntimePool(
    private val factory: JarClassLoaderFactory = JarClassLoaderFactory { artifact ->
        URLClassLoader(
            arrayOf(artifact.path.toUri().toURL()),
            SharedJarRuntimePool::class.java.classLoader,
        )
    },
) : AutoCloseable {
    private data class Entry(
        val classLoader: URLClassLoader,
        var references: Int,
    )

    private val lock = Any()
    private val entries = mutableMapOf<RuntimeKey, Entry>()
    private var closed = false

    fun acquire(artifact: PreparedArtifact, generation: String): SharedJarRuntimeLease {
        require(generation.isNotBlank())
        val key = RuntimeKey(artifact.sha256, generation)
        val entry = synchronized(lock) {
            check(!closed) { "runtime pool is closed" }
            entries[key]?.also { it.references += 1 }
                ?: Entry(factory.create(artifact), references = 1).also { entries[key] = it }
        }
        return SharedJarRuntimeLease(entry.classLoader) { release(key, entry) }
    }

    private fun release(key: RuntimeKey, expected: Entry) {
        val loader = synchronized(lock) {
            val entry = entries[key]
            if (entry !== expected) return@synchronized null
            entry.references -= 1
            if (entry.references > 0) return@synchronized null
            entries.remove(key)
            entry.classLoader
        }
        loader?.close()
    }

    override fun close() {
        val loaders = synchronized(lock) {
            if (closed) return
            closed = true
            entries.values.map(Entry::classLoader).also { entries.clear() }
        }
        loaders.forEach(URLClassLoader::close)
    }
}

class SharedJarRuntimeLease internal constructor(
    val classLoader: URLClassLoader,
    private val release: () -> Unit,
) : AutoCloseable {
    private val closed = AtomicBoolean(false)

    override fun close() {
        if (closed.compareAndSet(false, true)) release()
    }
}
