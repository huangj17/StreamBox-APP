package com.streambox.bridge.artifact

import java.nio.file.Files
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.io.path.createTempFile
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class JarInspectorTest {
    @Test
    fun `inspector identifies jvm dex and mixed archives`() {
        val jvm = archive(mapOf("com/github/catvod/spider/Demo.class" to byteArrayOf(1, 2)))
        val dex = archive(mapOf("classes.dex" to byteArrayOf(0x64, 0x65, 0x78)))
        val mixed = archive(
            mapOf(
                "classes.dex" to byteArrayOf(1),
                "com/github/catvod/spider/Demo.class" to byteArrayOf(2),
            ),
        )

        assertEquals(JarPackageType.JVM, JarInspector.inspect(jvm).packageType)
        assertEquals(JarPackageType.DEX, JarInspector.inspect(dex).packageType)
        assertEquals(JarPackageType.MIXED, JarInspector.inspect(mixed).packageType)
        assertEquals(
            "com.github.catvod.spider.Demo",
            JarInspector.resolveClassName("csp_Demo", JarInspector.inspect(jvm)),
        )
    }

    @Test
    fun `inspector rejects path traversal excessive entries and missing target class`() {
        assertFailsWith<JarInspectionException> {
            JarInspector.inspect(archive(mapOf("../escape.class" to byteArrayOf(1))))
        }
        assertFailsWith<JarInspectionException> {
            JarInspector.inspect(
                archive(mapOf("a.class" to byteArrayOf(1), "b.class" to byteArrayOf(1))),
                maxEntries = 1,
            )
        }
        val inspection = JarInspector.inspect(archive(mapOf("Other.class" to byteArrayOf(1))))
        assertFailsWith<JarInspectionException> {
            JarInspector.resolveClassName("csp_Missing", inspection)
        }
    }
}

private fun archive(entries: Map<String, ByteArray>) = createTempFile("jar-inspector", ".jar").also {
    ZipOutputStream(Files.newOutputStream(it)).use { zip ->
        entries.forEach { (name, bytes) ->
            zip.putNextEntry(ZipEntry(name))
            zip.write(bytes)
            zip.closeEntry()
        }
    }
}
