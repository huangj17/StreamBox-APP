package com.streambox.bridge.runtime

import com.streambox.bridge.artifact.JarInspection
import com.streambox.bridge.artifact.JarPackageType
import com.streambox.bridge.artifact.PreparedArtifact
import java.net.URLClassLoader
import kotlin.io.path.createTempFile
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotSame
import kotlin.test.assertSame

class SharedJarRuntimePoolTest {
    @Test
    fun `same sha and generation share one loader until the final lease closes`() {
        val factory = CountingLoaderFactory()
        val pool = SharedJarRuntimePool(factory)
        val artifact = artifact("a".repeat(64))

        val first = pool.acquire(artifact, generation = "candidate-1")
        val second = pool.acquire(artifact, generation = "candidate-1")

        assertSame(first.classLoader, second.classLoader)
        assertEquals(1, factory.created.size)
        first.close()
        assertEquals(0, factory.created.single().closeCount)
        second.close()
        assertEquals(1, factory.created.single().closeCount)
    }

    @Test
    fun `new generation receives an isolated classloader`() {
        val factory = CountingLoaderFactory()
        val pool = SharedJarRuntimePool(factory)
        val artifact = artifact("b".repeat(64))

        val old = pool.acquire(artifact, generation = "candidate-1")
        val next = pool.acquire(artifact, generation = "candidate-2")

        assertNotSame(old.classLoader, next.classLoader)
        old.close()
        next.close()
        assertEquals(listOf(1, 1), factory.created.map { it.closeCount })
    }
}

private fun artifact(sha: String) = PreparedArtifact(
    sha256 = sha,
    path = createTempFile("runtime-pool", ".jar"),
    className = "com.example.Spider",
    inspection = JarInspection(JarPackageType.JVM, 1, 1, setOf("com.example.Spider")),
)

private class CountingLoaderFactory : JarClassLoaderFactory {
    val created = mutableListOf<CountingRuntimeClassLoader>()

    override fun create(artifact: PreparedArtifact): URLClassLoader =
        CountingRuntimeClassLoader().also(created::add)
}

private class CountingRuntimeClassLoader : URLClassLoader(emptyArray()) {
    var closeCount = 0
        private set

    override fun close() {
        closeCount += 1
        super.close()
    }
}
