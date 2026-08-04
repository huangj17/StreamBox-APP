package com.streambox.bridge.artifact

import java.nio.file.Files
import java.nio.file.Path
import java.util.zip.ZipException
import java.util.zip.ZipInputStream

enum class JarPackageType {
    JVM,
    DEX,
    MIXED,
    INVALID,
}

data class JarInspection(
    val packageType: JarPackageType,
    val entryCount: Int,
    val uncompressedBytes: Long,
    val classNames: Set<String>,
)

class JarInspectionException(
    val code: String,
    message: String,
    cause: Throwable? = null,
) : IllegalArgumentException(message, cause)

object JarInspector {
    fun inspect(
        path: Path,
        maxEntries: Int = 50_000,
        maxEntryBytes: Long = 64L * 1024 * 1024,
        maxTotalBytes: Long = 512L * 1024 * 1024,
    ): JarInspection {
        val header = Files.newInputStream(path).use { input -> input.readNBytes(4) }
        if (header.size < 4 || header[0] != 'P'.code.toByte() || header[1] != 'K'.code.toByte()) {
            throw JarInspectionException("JAR_FORMAT_INVALID", "Artifact is not a ZIP/JAR archive")
        }
        var count = 0
        var total = 0L
        var hasDex = false
        val classes = linkedSetOf<String>()
        try {
            ZipInputStream(Files.newInputStream(path)).use { zip ->
                while (true) {
                    val entry = zip.nextEntry ?: break
                    count += 1
                    if (count > maxEntries) {
                        throw JarInspectionException(
                            "JAR_TOO_MANY_ENTRIES",
                            "JAR contains more than $maxEntries entries",
                        )
                    }
                    validateEntryName(entry.name)
                    var entryBytes = 0L
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        val read = zip.read(buffer)
                        if (read < 0) break
                        entryBytes += read
                        total += read
                        if (entryBytes > maxEntryBytes || total > maxTotalBytes) {
                            throw JarInspectionException(
                                "JAR_EXPANDED_SIZE_EXCEEDED",
                                "JAR expanded content exceeds configured limits",
                            )
                        }
                    }
                    if (!entry.isDirectory) {
                        when {
                            entry.name.endsWith(".dex", ignoreCase = true) -> hasDex = true
                            entry.name.endsWith(".class", ignoreCase = true) -> {
                                classes += entry.name
                                    .removeSuffix(".class")
                                    .replace('/', '.')
                                    .replace('\\', '.')
                            }
                        }
                    }
                    zip.closeEntry()
                }
            }
        } catch (error: JarInspectionException) {
            throw error
        } catch (error: ZipException) {
            throw JarInspectionException("JAR_FORMAT_INVALID", "JAR archive is corrupt", error)
        }
        val type = when {
            hasDex && classes.isNotEmpty() -> JarPackageType.MIXED
            hasDex -> JarPackageType.DEX
            classes.isNotEmpty() -> JarPackageType.JVM
            else -> JarPackageType.INVALID
        }
        if (type == JarPackageType.INVALID) {
            throw JarInspectionException(
                "JAR_CONTENT_INVALID",
                "JAR contains neither JVM classes nor DEX content",
            )
        }
        return JarInspection(type, count, total, classes)
    }

    fun resolveClassName(api: String, inspection: JarInspection): String {
        if (inspection.packageType == JarPackageType.DEX) {
            throw JarInspectionException(
                "JAR_REQUIRES_CONVERSION",
                "DEX-only JAR requires conversion before JVM loading",
            )
        }
        if (inspection.packageType == JarPackageType.MIXED) {
            throw JarInspectionException(
                "JAR_MIXED_FORMAT_UNSUPPORTED",
                "Mixed DEX/JVM JAR is not eligible for automatic loading",
            )
        }
        val expected = if (api.startsWith("csp_")) {
            "com.github.catvod.spider.${api.removePrefix("csp_")}"
        } else {
            api
        }
        if (expected !in inspection.classNames) {
            throw JarInspectionException(
                "JAR_CLASS_NOT_FOUND",
                "Configured Spider class was not found in JAR",
            )
        }
        return expected
    }

    private fun validateEntryName(name: String) {
        val normalized = name.replace('\\', '/')
        if (
            normalized.startsWith('/') ||
            normalized.matches(Regex("^[A-Za-z]:/.*")) ||
            normalized.split('/').any { it == ".." }
        ) {
            throw JarInspectionException(
                "JAR_ENTRY_PATH_INVALID",
                "JAR contains an unsafe entry path",
            )
        }
    }
}
