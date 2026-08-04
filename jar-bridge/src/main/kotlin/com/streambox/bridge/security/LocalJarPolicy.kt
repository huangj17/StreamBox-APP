package com.streambox.bridge.security

import java.nio.file.Files
import java.nio.file.Path

object LocalJarPolicy {
    fun resolve(candidate: Path, pluginsRoot: Path = Path.of("plugins")): Path {
        val root = pluginsRoot.toAbsolutePath().normalize()
        val normalized = candidate.toAbsolutePath().normalize()
        if (!normalized.startsWith(root)) {
            throw SecurityException("Manual JAR path escapes the plugins root")
        }
        if (!Files.isRegularFile(normalized)) {
            throw IllegalArgumentException("Manual JAR does not exist")
        }
        val realRoot = root.toRealPath()
        val realCandidate = normalized.toRealPath()
        if (!realCandidate.startsWith(realRoot)) {
            throw SecurityException("Manual JAR symlink escapes the plugins root")
        }
        return realCandidate
    }
}
