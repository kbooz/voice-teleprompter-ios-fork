package com.olerast.suflyor

import com.olerast.suflyor.script.CharNorm
import com.olerast.suflyor.script.nfc
import com.olerast.suflyor.script.nfd
import kotlin.test.Test
import kotlin.test.assertEquals

/** Pins the platform behaviours the shims rely on (runs on JVM and on the iOS simulator). */
class PortabilityShimTest {
    @Test
    fun nfcComposesAndNfdDecomposes() {
        assertEquals("é", nfc("é"))
        assertEquals("é", nfd("é"))
        assertEquals("한", nfd("한"))
        assertEquals("한", nfc("한"))
        assertEquals("abc", nfc("abc"))
    }

    @Test
    fun hanRegexUnitsAfterNormalization() {
        // Kotlin/Native's regex engine does not match supplementary code points in a class (no \p{L} either), so
        // U+20000 is not a unit there; Java matches it and normalizeWord then drops it. Same words either way.
        val zh = CharNorm.ZH
        assertEquals(listOf("中"), zh.words("𠀀中"))
        assertEquals(listOf("a", "b", "中"), zh.words("a𠀀b中"))
        // The lookahead works: a Latin run stops at the next Han character.
        assertEquals(listOf("abc", "中", "def"), zh.words("abc中def"))
    }
}
