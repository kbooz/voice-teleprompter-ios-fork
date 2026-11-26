package com.olerast.suflyor.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SuflyorCoreTest {
    private fun body(text: String, emphasis: List<CoreRange> = emptyList()) = CoreParagraph(text, false, emphasis)

    private fun build(paragraphs: List<CoreParagraph>, lang: String = "en", phrase: Boolean = false) =
        SuflyorCore.buildScript("t", paragraphs, lang, phrase, 7)

    @Test
    fun offsetsAreUtf16AndEndExclusive() {
        // The emoji is a surrogate pair: two UTF-16 units, so "world" starts at 9, not 8.
        val script = build(listOf(body("Hello 😀 world", listOf(CoreRange(9, 14)))))
        assertEquals("Hello 😀 world", script.displayText)
        assertEquals(listOf(CoreToken(0, 5, true), CoreToken(9, 14, true)), script.tokens)
        for (t in script.tokens) assertTrue(script.displayText.substring(t.start, t.endExclusive).all { it.isLetter() })
        assertEquals(listOf(CoreRange(9, 14)), script.emphasis)
        assertEquals("world", script.displayText.substring(script.emphasis[0].start, script.emphasis[0].endExclusive))
    }

    @Test
    fun offsetsShiftWithTheParagraphSeparator() {
        val script = build(listOf(body("First one."), body("Second 😀 bold", listOf(CoreRange(10, 14)))))
        assertEquals("First one.\n\nSecond 😀 bold", script.displayText)
        val e = script.emphasis.single()
        assertEquals("bold", script.displayText.substring(e.start, e.endExclusive))
        assertEquals(12 + 10, e.start)
    }

    @Test
    fun supplementaryCharactersShiftLaterOffsetsByTwoUnits() {
        // U+20000 is one code point but two UTF-16 units; the importer drops it as a word (a lone surrogate is no
        // letter), as on Android, but every later offset still counts both units.
        val script = build(listOf(body("\uD840\uDC00你好")), "zh")
        assertEquals(listOf(CoreToken(2, 3, true), CoreToken(3, 4, true)), script.tokens)
    }

    @Test
    fun notesAndHeadingsAreNotSpoken() {
        val script = build(listOf(CoreParagraph("Intro", true, emptyList()), body("Say [pause here] this")))
        val spoken = script.tokens.filter { it.spoken }.map { script.displayText.substring(it.start, it.endExclusive) }
        assertEquals(listOf("Say", "this"), spoken)
        assertEquals(2, script.spokenWords)
        // The heading and the bracket note are both in notes (end exclusive: the "]" is included).
        val bracket = script.notes.last()
        assertEquals("[pause here]", script.displayText.substring(bracket.start, bracket.endExclusive))
    }

    @Test
    fun detectsTheLanguageOfSeveralScripts() {
        fun detect(text: String) = SuflyorCore.detectLanguage(listOf(body(text)))
        assertEquals("ru", detect("Привет, сегодня я расскажу про дроны."))
        assertEquals("en", detect("Hello everyone, today I will talk about drones and what they can do."))
        assertEquals("tr", detect("Merhaba arkadaşlar, bugün size drone seçmeyi anlatacağım."))
        assertEquals("zh", detect("大家好，今天我来告诉大家怎样挑选无人机。"))
        assertEquals("ko", detect("안녕하세요 여러분 오늘은 드론을 고르는 방법을 알려드릴게요"))
        assertEquals("he", detect("שלום לכולם היום אספר לכם על רחפנים"))
        assertEquals("ar", detect("أهلاً بيكم يا جماعة النهارده هنتكلم عن الدرون"))
        assertEquals("de", detect("Hallo zusammen, heute erzähle ich euch, wie man die erste Drohne und die Kamera auswählt und was der Preis ist."))
        // Headings are not counted; an empty script counts as Russian.
        assertEquals("ru", SuflyorCore.detectLanguage(listOf(CoreParagraph("Hello world", true, emptyList()))))
        assertEquals("ru", SuflyorCore.detectLanguage(emptyList()))
    }

    @Test
    fun unknownLanguageCodeFallsBackToRussian() {
        val script = build(listOf(body("Привет мир")), "xx")
        assertEquals("ru", script.langCode)
        assertEquals("en", build(listOf(body("Hello world")), "en").langCode)
    }

    @Test
    fun listsTheLanguages() {
        val langs = SuflyorCore.languages()
        assertEquals(listOf("ru", "en", "tr", "pt", "es", "de", "fr", "it", "nl", "sv", "he", "ar", "ko", "zh"), langs.map { it.code })
        assertEquals(setOf("ru", "en", "tr"), langs.filter { !it.needsPack }.map { it.code }.toSet())
        assertEquals("Русский", langs.first { it.code == "ru" }.label)
    }

    @Test
    fun parsesMarkdownIntoParagraphs() {
        val paragraphs = SuflyorCore.parseMarkdown("# Title\n\nHello **bold** world 😀 and ==marked==.", "doc")
        assertEquals(2, paragraphs.size)
        assertTrue(paragraphs[0].heading)
        assertEquals("Title", paragraphs[0].text)
        val p = paragraphs[1]
        assertFalse(p.heading)
        assertEquals("Hello bold world 😀 and marked.", p.text)
        assertEquals(listOf("bold", "marked"), p.emphasis.map { p.text.substring(it.start, it.endExclusive) })
    }

    @Test
    fun biasWordsAndHotwords() {
        val script = build(listOf(body("The photographer carried the camera through Yosemite.")))
        assertTrue("photographer" in script.biasWords())
        // English hotwords are UPPER CASE, "/"-separated.
        val hot = script.hotwords().split("/")
        assertTrue("PHOTOGRAPHER" in hot)
        assertEquals(build(listOf(body("x"))).hotwords(), "")
    }

    private val lines = listOf(
        "Today we will pick the first drone for travel videos.",
        "The main rule is simple, decide what you want to film.",
        "Landscapes need stabilization, sports need speed.",
    )

    private fun follower() = build(lines.map { body(it) }, "en", phrase = true).newFollower()

    @Test
    fun followerFollowsTheVoice() {
        val f = follower()
        var now = 0L
        var u = f.onRecognized("TODAY WE WILL", false, true, 0, now)
        now += 200
        assertTrue(u.moved)
        assertEquals(3, u.position)
        assertEquals("follow", u.reason)
        u = f.onRecognized("TODAY WE WILL PICK THE FIRST DRONE", true, true, 0, now)
        assertEquals(7, u.position)
        assertEquals(7, f.position)
        assertTrue(f.size > 7)
    }

    @Test
    fun followerLeadsWhileSpeakingAndSettlesWhenSilent() {
        val f = follower()
        val u = f.onRecognized("TODAY WE WILL", false, true, 2, 1000)
        assertEquals(3, u.position)
        // Two words of lead while the partial result is fresh: the display runs ahead of the tracker.
        // Every token of this script is spoken, so token index == spoken index.
        assertEquals(5, u.nextToken)
        val later = f.onRecognized("", true, true, 2, 5000)
        assertEquals(3, later.position)
        // The display never moves back by itself.
        assertEquals(5, later.nextToken)
    }

    @Test
    fun followerIsIdleWhenVoiceIsNotActive() {
        val f = follower()
        val u = f.onRecognized("TODAY WE WILL PICK", true, false, 3, 100)
        assertFalse(u.moved)
        assertEquals("idle", u.reason)
        assertEquals(0, u.position)
        assertEquals(0, f.position)
    }

    @Test
    fun manualMovesAreReportedAsManual() {
        val f = follower()
        f.onRecognized("TODAY WE WILL PICK THE", true, true, 0, 0)
        val forward = f.stepLine(1)
        assertNotNull(forward)
        assertEquals("manual", forward.reason)
        assertTrue(forward.moved)
        assertEquals(forward.position, f.position)
        val back = f.stepLine(-1)
        assertNotNull(back)
        assertTrue(back.position < forward.position)
        val restarted = f.restart()
        assertEquals(0, restarted.position)
        assertEquals("manual", restarted.reason)
        // Going back at the very start finds no other line; going past the last line stays too.
        assertNull(f.stepLine(-1))
        repeat(5) { f.stepLine(1) }
        assertNull(f.stepLine(1))
        val jump = f.jumpToToken(0)
        assertEquals(0, jump.position)
        assertTrue(jump.moved)
        assertFalse(f.jumpToToken(0).moved)
    }

    @Test
    fun stepLineOnAnEmptyScriptDoesNothing() {
        val f = build(emptyList()).newFollower()
        assertNull(f.stepLine(1))
        assertEquals(0, f.size)
    }
}
