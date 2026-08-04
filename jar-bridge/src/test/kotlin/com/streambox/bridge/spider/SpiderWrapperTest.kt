package com.streambox.bridge.spider

import kotlinx.coroutines.runBlocking
import java.net.URLClassLoader
import kotlin.system.measureTimeMillis
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

class SpiderWrapperTest {
    @Test
    fun `timeout poisons plugin and later calls fail fast`() = runBlocking {
        val spider = SlowSpider()
        val wrapper = SpiderWrapper(
            key = "slow",
            name = "Slow",
            instance = spider,
            clazz = spider.javaClass,
            classLoader = URLClassLoader(emptyArray(), javaClass.classLoader),
            timeoutMs = 25,
        )

        try {
            assertIs<SpiderTimeoutException>(
                wrapper.homeVideoContent().exceptionOrNull()
            )
            val elapsed = measureTimeMillis {
                assertIs<SpiderUnavailableException>(
                    wrapper.homeVideoContent().exceptionOrNull()
                )
            }
            assertTrue(elapsed < 100, "poisoned plugin should fail fast")
        } finally {
            wrapper.close()
        }
    }

    @Test
    fun `close is idempotent and releases the classloader once`() {
        val spider = SlowSpider()
        val classLoader = CountingClassLoader()
        val wrapper = SpiderWrapper(
            key = "closable",
            name = "Closable",
            instance = spider,
            clazz = spider.javaClass,
            classLoader = classLoader,
        )

        wrapper.close()
        wrapper.close()

        assertEquals(1, classLoader.closeCalls)
    }
}

private class CountingClassLoader : URLClassLoader(emptyArray(), CountingClassLoader::class.java.classLoader) {
    var closeCalls: Int = 0
        private set

    override fun close() {
        closeCalls += 1
        super.close()
    }
}

private class SlowSpider {
    fun homeVideoContent(): String {
        Thread.sleep(500)
        return """{"list":[]}"""
    }
}
