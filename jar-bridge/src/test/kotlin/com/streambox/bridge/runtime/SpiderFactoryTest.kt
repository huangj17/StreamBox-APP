package com.streambox.bridge.runtime

import com.streambox.bridge.artifact.JarInspection
import com.streambox.bridge.artifact.JarPackageType
import com.streambox.bridge.artifact.PreparedArtifact
import kotlinx.coroutines.runBlocking
import java.io.File
import java.net.URLClassLoader
import java.nio.file.Files
import java.nio.file.Path
import java.util.jar.JarEntry
import java.util.jar.JarOutputStream
import javax.tools.ToolProvider
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class SpiderFactoryTest {
    @Test
    fun `factory initializes probes and returns an isolated spider wrapper`() = runBlocking {
        val artifact = compileSpiderJar(
            className = "AutoSpider",
            homeBody = "{\"class\":[]}",
        )
        val pool = SharedJarRuntimePool()
        val factory = SpiderFactory(
            runtimePool = pool,
            runtimeRoot = createTempDirectory("spider-runtime"),
            initTimeoutMs = 2_000,
            methodTimeoutMs = 2_000,
        )

        val wrapper = factory.create(
            key = "auto",
            name = "Automatic",
            artifact = artifact,
            className = "fixture.AutoSpider",
            ext = "secret-ext",
            generation = "candidate-1",
        )

        assertEquals("{\"class\":[]}", wrapper.homeContent(true).getOrThrow())
        wrapper.close()
        pool.close()
    }

    @Test
    fun `factory rejects an invalid probe and releases its runtime lease`() = runBlocking {
        val artifact = compileSpiderJar(className = "BadSpider", homeBody = "not-json")
        val factory = SpiderFactory(
            runtimePool = SharedJarRuntimePool(),
            runtimeRoot = createTempDirectory("bad-spider-runtime"),
        )

        val error = assertFailsWith<SpiderFactoryException> {
            factory.create(
                key = "bad",
                name = "Bad",
                artifact = artifact,
                className = "fixture.BadSpider",
                ext = "secret-ext",
                generation = "candidate-1",
            )
        }

        assertEquals("SPIDER_PROBE_INVALID", error.code)
    }
}

private fun compileSpiderJar(className: String, homeBody: String): PreparedArtifact {
    val root = createTempDirectory("compiled-spider")
    val sourceRoot = root.resolve("source/fixture")
    val classesRoot = root.resolve("classes")
    Files.createDirectories(sourceRoot)
    Files.createDirectories(classesRoot)
    val source = sourceRoot.resolve("$className.java")
    Files.writeString(
        source,
        """
        package fixture;
        import java.util.*;
        public class $className {
          public void init(Object context, String ext) {
            if (!"secret-ext".equals(ext)) throw new IllegalArgumentException("wrong ext");
          }
          public String homeContent(boolean filter) { return ${javaString(homeBody)}; }
          public String categoryContent(String tid, String pg, boolean filter, HashMap<String,String> ext) { return "{}"; }
          public String detailContent(List<String> ids) { return "{}"; }
          public String searchContent(String keyword, boolean quick) { return "{}"; }
          public String playerContent(String flag, String id, List<String> vipFlags) { return "{}"; }
        }
        """.trimIndent(),
    )
    val compiler = checkNotNull(ToolProvider.getSystemJavaCompiler())
    val result = compiler.run(null, null, null, "-d", classesRoot.toString(), source.toString())
    check(result == 0) { "fixture compilation failed" }
    val classFile = classesRoot.resolve("fixture/$className.class")
    val jar = root.resolve("$className.jar")
    JarOutputStream(Files.newOutputStream(jar)).use { output ->
        output.putNextEntry(JarEntry("fixture/$className.class"))
        Files.copy(classFile, output)
        output.closeEntry()
    }
    return PreparedArtifact(
        sha256 = "${className.lowercase()}-${Files.size(jar)}",
        path = jar,
        className = "fixture.$className",
        inspection = JarInspection(
            packageType = JarPackageType.JVM,
            entryCount = 1,
            uncompressedBytes = Files.size(classFile),
            classNames = setOf("fixture.$className"),
        ),
    )
}

private fun javaString(value: String): String = buildString {
    append('"')
    value.forEach { character ->
        when (character) {
            '\\' -> append("\\\\")
            '"' -> append("\\\"")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            else -> append(character)
        }
    }
    append('"')
}
