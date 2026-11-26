package com.olerast.suflyor.script

import com.olerast.suflyor.JavaRandom
import java.io.File
import java.util.Locale
import kotlin.math.roundToInt
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Proves that the common-code replacements behave like the JVM APIs the Android code used. */
class JvmParityTest {
    private fun codePoints() = (0..0x10FFFF).asSequence()

    private fun expectedScript(cp: Int): UScript = when (Character.UnicodeScript.of(cp)) {
        Character.UnicodeScript.LATIN -> UScript.LATIN
        Character.UnicodeScript.CYRILLIC -> UScript.CYRILLIC
        Character.UnicodeScript.HAN -> UScript.HAN
        Character.UnicodeScript.HANGUL -> UScript.HANGUL
        Character.UnicodeScript.HEBREW -> UScript.HEBREW
        Character.UnicodeScript.ARABIC -> UScript.ARABIC
        else -> UScript.OTHER
    }

    @Test
    fun scriptTableMatchesJavaForEveryCodePoint() {
        var checked = 0
        for (cp in codePoints()) {
            // The JDK running the test may know a different Unicode version (17 -> 13, 21 -> 15): compare assigned code points.
            if (Character.getType(cp) == Character.UNASSIGNED.toInt()) continue
            checked++
            assertEquals(expectedScript(cp), UnicodeScripts.of(cp), "U+" + cp.toString(16).uppercase())
        }
        assertTrue(checked > 100_000)
    }

    @Test
    fun scriptOfCharAgreesWithCodePoint() {
        for (c in Char.MIN_VALUE..Char.MAX_VALUE) {
            if (c in '\uD800'..'\uDFFF') continue
            assertEquals(UnicodeScripts.of(c.code), UnicodeScripts.of(c))
        }
    }

    @Test
    fun turkishLowercaseMatchesJavaForEveryCodePoint() {
        val tr = Locale("tr", "TR")
        for (cp in codePoints()) {
            if (cp in 0xD800..0xDFFF) continue
            val s = String(Character.toChars(cp))
            assertEquals(s.lowercase(tr), s.lowercaseTr(), "U+" + cp.toString(16))
            // Neighbours matter in Turkish (dotted capital I + dot above) and for context rules (final sigma).
            val before = "I$s"
            assertEquals(before.lowercase(tr), before.lowercaseTr(), "I + U+" + cp.toString(16))
            val after = "${s}I"
            assertEquals(after.lowercase(tr), after.lowercaseTr(), "U+" + cp.toString(16) + " + I")
            val inWord = "A${s}Σ"
            assertEquals(inWord.lowercase(tr), inWord.lowercaseTr(), "A U+" + cp.toString(16) + " sigma")
        }
        for (w in listOf("ISPARTA", "İstanbul'da", "İ", "ILIK Iğdır", "DİYARBAKIR", "ΟΔΥΣΣΕΥΣ", "ǅ ǈ ǋ ǲ")) {
            assertEquals(w.lowercase(tr), w.lowercaseTr(), w)
        }
    }

    @Test
    fun otherLanguagesHaveNoLocaleSpecificLowercase() {
        // pt, es, de, fr, it, nl, sv, he, ar: plain lowercase() (Locale.ROOT) must equal their locale's result.
        val locales = listOf("pt-BR", "es", "de", "fr", "it", "nl", "sv", "he", "ar-EG").map { Locale.forLanguageTag(it) } +
            listOf(Locale.GERMAN, Locale.FRENCH, Locale.ITALIAN, Locale.ROOT)
        for (cp in codePoints()) {
            if (cp in 0xD800..0xDFFF) continue
            val s = String(Character.toChars(cp))
            val common = s.lowercase()
            assertEquals(s.lowercase(Locale.ROOT), common, "U+" + cp.toString(16))
            for (l in locales) assertEquals(s.lowercase(l), common, "U+" + cp.toString(16) + " in " + l)
        }
        for (w in listOf("ÀÉÎÕÜ", "STRASSE ẞ", "ÅNGSTRÖM", "I İ ı", "ΣΑΣ", "שָׁלוֹם", "النَّهَارْدَة", "Ǆ")) {
            for (l in locales) assertEquals(w.lowercase(l), w.lowercase(), w)
        }
    }

    @Test
    fun spaceSeparatorMatchesIsSpaceChar() {
        for (c in Char.MIN_VALUE..Char.MAX_VALUE) {
            assertEquals(Character.isSpaceChar(c), c.isSpaceSeparator(), "U+" + c.code.toString(16))
        }
    }

    @Test
    fun markCategoriesMatchGetType() {
        for (c in Char.MIN_VALUE..Char.MAX_VALUE) {
            val t = Character.getType(c)
            val java = t == Character.NON_SPACING_MARK.toInt() || t == Character.ENCLOSING_MARK.toInt() ||
                t == Character.COMBINING_SPACING_MARK.toInt()
            assertEquals(java, c.isAnyMark(), "U+" + c.code.toString(16))
        }
    }

    @Test
    fun format1MatchesStringFormat() {
        val rnd = java.util.Random(1)
        val samples = mutableListOf(0f, -0f, 0.05f, 0.25f, 0.35f, 0.45f, 1.45f, 2.5f, -0.04f, -0.05f, 9.95f, 99.95f, 1234.56f, 0.6f, 3.2f)
        repeat(20000) { samples += (rnd.nextFloat() - 0.3f) * 40f }
        for (x in samples) assertEquals("%.1f".format(Locale.ROOT, x), x.format1(), "$x")
    }

    @Test
    fun roundToIntMatchesMathRound() {
        val rnd = java.util.Random(2)
        val samples = mutableListOf(0.5f, 1.5f, 2.5f, -0.5f, -1.5f, 3.4999998f, 0f, 7f, 2.5666667f)
        repeat(20000) { samples += (rnd.nextFloat() - 0.2f) * 500f }
        for (x in samples) assertEquals(Math.round(x), x.roundToInt(), "$x")
    }

    @Test
    fun javaRandomMatchesJavaUtilRandom() {
        for (seed in longArrayOf(0, 1, 7, 42, -5, 123456789012L)) {
            val mine = JavaRandom(seed)
            val real = java.util.Random(seed)
            repeat(5000) {
                val bound = listOf(2, 3, 4, 10, 36, 100, 64, 1000, 7777)[it % 9]
                assertEquals(real.nextInt(bound), mine.nextInt(bound), "seed $seed draw $it")
            }
        }
    }

    @Test
    fun cjkWordRegexMatchesTheOriginalJavaPattern() {
        val originalHan = Regex("\\p{IsHan}|[\\p{L}\\p{N}&&[^\\p{IsHan}]]+")
        val originalHangul = Regex("\\p{IsHangul}|[\\p{L}\\p{N}&&[^\\p{IsHangul}]]+")
        val han = CharNorm.ZH.wordRegex
        val hangul = CharNorm.KO.wordRegex
        for (cp in codePoints()) {
            if (cp in 0xD800..0xDFFF || Character.getType(cp) == Character.UNASSIGNED.toInt()) continue
            val s = String(Character.toChars(cp))
            // The code point alone, between Latin letters, and next to a Han / Hangul unit.
            for (t in listOf(s, "a${s}b", "$s 中$s", "한${s}国 $s")) {
                assertEquals(originalHan.findAll(t).map { it.value }.toList(), han.findAll(t).map { it.value }.toList(), "han U+" + cp.toString(16) + " in " + t)
                assertEquals(originalHangul.findAll(t).map { it.value }.toList(), hangul.findAll(t).map { it.value }.toList(), "hangul U+" + cp.toString(16) + " in " + t)
            }
        }
    }

    @Test
    fun generatedPinyinTableEqualsTheTextFile() {
        val file = File("../tools/zh-pinyin/zh_pinyin.txt")
        val expected = file.readLines(Charsets.UTF_8).filter { it.isNotBlank() && !it.startsWith("#") }
        assertEquals(expected, ZhPinyinData.LINES.toList())
        // Every literal stays far below the 65,535-byte limit of a JVM string constant.
        assertTrue(ZhPinyinData.LINES.all { it.toByteArray(Charsets.UTF_8).size < 5000 })
        assertEquals("zhong", CharNorm.pinyinOf('中'))
    }

    @Test
    fun nfcAndNfdRoundTrip() {
        assertEquals("é", nfc("é"))
        assertEquals("é", nfd("é"))
        assertEquals("각", nfc(nfd("각")))
        assertEquals(3, nfd("각").length)
    }
}
