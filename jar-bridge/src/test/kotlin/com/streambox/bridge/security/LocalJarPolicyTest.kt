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

    @Test
    fun `manual jar must match its configured sha256`() {
        val workspace = createTempDirectory("local-jar-hash")
        val plugins = workspace.resolve("plugins")
        Files.createDirectories(plugins)
        val jar = plugins.resolve("manual.jar")
        Files.writeString(jar, "trusted plugin")

        assertEquals(
            jar.toRealPath(),
            LocalJarPolicy.resolveAndVerify(
                jar,
                "3650e1b8e523884aedb26355f3365108349269db7bcc28e1eeb762d454812d60",
                plugins,
            ),
        )
        assertFailsWith<SecurityException> {
            LocalJarPolicy.resolveAndVerify(jar, "0".repeat(64), plugins)
        }
    }
}
