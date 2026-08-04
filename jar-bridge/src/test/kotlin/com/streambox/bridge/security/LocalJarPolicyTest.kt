package com.streambox.bridge.security

import java.nio.file.Files
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class LocalJarPolicyTest {
    @Test
    fun `manual jar must remain inside the configured plugins root`() {
        val workspace = createTempDirectory("local-jar-policy")
        val plugins = workspace.resolve("plugins")
        Files.createDirectories(plugins)
        val allowed = plugins.resolve("manual.jar")
        Files.write(allowed, byteArrayOf(1))

        assertEquals(allowed.toRealPath(), LocalJarPolicy.resolve(allowed, plugins))
        assertFailsWith<SecurityException> {
            LocalJarPolicy.resolve(workspace.resolve("outside.jar"), plugins)
        }
    }
}
