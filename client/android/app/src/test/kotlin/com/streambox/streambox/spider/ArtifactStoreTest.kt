package com.streambox.streambox.spider

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

class ArtifactStoreTest {
    @Test fun parsesPinnedArtifactRegardlessOfExtension() {
        val spec = ArtifactDeclaration.parse("https://example.com/plugin.jpg;md5;0123456789ABCDEF0123456789ABCDEF")
        assertEquals("https://example.com/plugin.jpg", spec.url)
        assertEquals("0123456789abcdef0123456789abcdef", spec.md5)
    }
    @Test fun rejectsInvalidArtifactDeclarations() {
        listOf("file:///tmp/a.jar", "https://user:pass@example.com/a.jar", "https://example.com/a.jar;md5;wrong")
            .forEach { raw ->
                try { ArtifactDeclaration.parse(raw); fail("accepted $raw") }
                catch (_: IllegalArgumentException) {}
            }
    }
    @Test fun acceptsOnlyNativeLibrariesMatchingProcessArchitecture() {
        fun elf(bits: Int, machine: Int) = ByteArray(20).apply {
            this[0] = 0x7f; this[1] = 69; this[2] = 76; this[3] = 70
            this[4] = bits.toByte(); this[18] = machine.toByte(); this[19] = (machine shr 8).toByte()
        }
        assertTrue(ArtifactStore.matchesProcessAbi(elf(2,183), true))
        assertFalse(ArtifactStore.matchesProcessAbi(elf(1,40), true))
        assertTrue(ArtifactStore.matchesProcessAbi(elf(1,40), false))
        assertFalse(ArtifactStore.matchesProcessAbi(elf(2,62), true))
    }
    @Test fun enforcesLimitWhileStreamingUnknownLengthContent() {
        val output = ByteArrayOutputStream()
        try { ArtifactStore.copyBounded(ByteArrayInputStream(ByteArray(50)), output, 20); fail("unbounded copy") }
        catch (_: IllegalStateException) { assertEquals(0, output.size()) }
    }
}
