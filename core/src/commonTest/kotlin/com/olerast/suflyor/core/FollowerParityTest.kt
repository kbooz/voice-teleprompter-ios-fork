package com.olerast.suflyor.core

import com.olerast.suflyor.JavaRandom
import com.olerast.suflyor.TrackerSimulation
import com.olerast.suflyor.script.ScriptModel
import com.olerast.suflyor.script.SpeechLang
import com.olerast.suflyor.track.ScriptTracker
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The state and arithmetic of Android's SessionEngine (onAsr, stepLine, moveTracker), copied statement by statement
 * with the Android-only parts (locks, epoch, Handler, settings, diagnostics) removed. CoreFollower must give the same
 * positions as this over any stream of recognizer updates and manual moves.
 */
private class AndroidReference(private val model: ScriptModel) {
    private val lang = model.lang
    private var tracker = ScriptTracker(model.tokens, model.lang)
    private val finalWords = ArrayDeque<String>()
    private var partialWords: List<String> = emptyList()
    private var displayPos = 0
    private var lastSpeechAt = 0L

    val position get() = tracker.position
    val size get() = tracker.size

    /** Returns (moved update or null, position, next token). */
    fun onAsr(text: String, isFinal: Boolean, voice: Boolean, leadWords: Int, now: Long): Triple<ScriptTracker.Update?, Int, Int> {
        val words = lang.words(text)
        var moved: ScriptTracker.Update? = null
        val pos: Int
        val next: Int
        if (!isFinal) lastSpeechAt = now
        run {
            if (isFinal) {
                words.forEach { finalWords.addLast(it) }
                while (finalWords.size > lang.history) finalWords.removeFirst()
                partialWords = emptyList()
            } else {
                partialWords = words
            }
            val before = tracker.position
            if (voice) {
                moved = tracker.onHypothesis(finalWords.toList() + partialWords)
            }
            pos = tracker.position
            if (pos < before) displayPos = pos
            val maxLead = if (voice) leadWords else 0
            val lead = if (voice && now - lastSpeechAt < 900L) maxLead else 0
            displayPos = maxOf(displayPos, minOf(pos + lead, tracker.size)).coerceAtMost(pos + maxLead)
            next = tracker.tokenIndexAt(displayPos)
        }
        return Triple(moved, pos, next)
    }

    /** Returns the new (position, next token), or null when Android's stepLine returns without moving. */
    fun stepLine(delta: Int): Pair<Int, Int>? {
        val target: Int
        run {
            val tokens = model.tokens
            val text = model.displayText
            val firsts = ArrayList<Int>()
            var lastLineStart = -1
            for ((i, t) in tokens.withIndex()) {
                if (!t.spoken) continue
                val lineStart = text.lastIndexOf('\n', t.start - 1) + 1
                if (lineStart != lastLineStart) {
                    firsts += i
                    lastLineStart = lineStart
                }
            }
            if (firsts.isEmpty()) return null
            val cur = tracker.nextTokenIndex()
            val line = firsts.indexOfLast { it <= cur }
            target = when {
                delta < 0 && line < 0 -> firsts[0]
                delta < 0 && firsts[line] < cur -> firsts[line]
                delta < 0 -> firsts[(line + delta).coerceAtLeast(0)]
                line + delta >= firsts.size -> return null
                else -> firsts[(line + delta).coerceAtLeast(0)]
            }
            if (target == cur) return null
        }
        return moveTracker { it.jumpToToken(target) }
    }

    fun moveTracker(action: (ScriptTracker) -> Unit): Pair<Int, Int> {
        run {
            action(tracker)
            finalWords.clear()
            partialWords = emptyList()
            displayPos = tracker.position
        }
        return tracker.position to tracker.nextTokenIndex()
    }
}

class FollowerParityTest {
    private val tr = listOf(
        "Merhaba arkadaşlar, bugün size ilk dronunuzu nasıl seçeceğinizi anlatacağım.",
        "Temel kural basit: önce tam olarak neyi çekmek istediğinize karar verin, sonra kameraya bakın.",
        "Manzara çekiyorsanız stabilizasyon ve uçuş süresi daha önemlidir. Spor çekiyorsanız hız gerekir.",
        "Birinci model hafif ve katlanabilir, onu el bagajınıza koyabilirsiniz.",
        "İkinci model daha ağır, ama kamerası on bit çeker ve gün batımlarını çok daha iyi yakalar.",
    )
    private val zh = listOf(
        "大家好！今天我来告诉大家，怎样挑选第一架旅行拍摄用的无人机。",
        "最重要的规则很简单：先决定你到底想拍什么，然后再看相机。",
        "如果你拍风景，稳定性和飞行时间更重要。如果拍运动，需要速度和好的跟踪。",
        "第一款机型轻便可折叠，可以放进随身行李，不需要登记。",
    )

    private fun scripts(): List<Pair<SpeechLang, List<String>>> = listOf(
        SpeechLang.RU to TrackerSimulation.RU_SCRIPT,
        SpeechLang.EN to TrackerSimulation.EN_SCRIPT,
        SpeechLang.EN to TrackerSimulation.EN_SCRIPT_DIGITS,
        SpeechLang.AR to TrackerSimulation.AR_SCRIPT,
        SpeechLang.TR to tr,
        SpeechLang.ZH to zh,
    )

    private fun script(lang: SpeechLang, lines: List<String>, phrase: Boolean): CoreScript =
        SuflyorCore.buildScript("t", lines.map { CoreParagraph(it, false, emptyList()) }, lang.code, phrase, 7)

    private fun same(label: String, ref: ScriptTracker.Update?, refPos: Int, refNext: Int, got: CoreFollowUpdate, f: CoreFollower) {
        assertEquals(refPos, got.position, "$label position")
        assertEquals(refNext, got.nextToken, "$label nextToken")
        assertEquals(refPos, f.position, "$label follower position")
        assertEquals(refNext, f.nextToken, "$label follower nextToken")
        assertEquals(ref?.moved ?: false, got.moved, "$label moved")
        assertEquals(ref?.matches ?: 0, got.matches, "$label matches")
        assertEquals(ref?.score ?: 0f, got.score, "$label score")
        assertEquals(ref?.reason ?: "idle", got.reason, "$label reason")
    }

    /** Replays reading sessions in the style of the stress tests (seeds 42 and 7): skips, retakes, off-script talk. */
    private fun replay(lang: SpeechLang, lines: List<String>, seed: Long, phrase: Boolean): Int {
        val core = script(lang, lines, phrase)
        val f = core.newFollower()
        val ref = AndroidReference(core.model)
        val spoken = core.model.tokens.filter { it.spoken }
        if (spoken.size < 30) return 0
        val rnd = JavaRandom(seed)
        val offTalk = listOf("so", "wait", "a", "second", "um")
        var now = 0L
        var updates = 0
        var step = 0
        fun surface(t: com.olerast.suflyor.script.Token) = core.model.displayText.substring(t.start, t.end)

        repeat(60) { segment ->
            val roll = rnd.nextInt(100)
            val lead = listOf(0, 1, 2, 3)[rnd.nextInt(4)]
            val voice = rnd.nextInt(100) < 92
            var truePos = (ref.position + 1).coerceIn(0, spoken.size - 8)
            when {
                roll < 50 -> Unit
                roll < 68 -> truePos = (truePos + 5 + rnd.nextInt(36)).coerceIn(0, spoken.size - 8)
                roll < 86 -> truePos = (truePos - 3 - rnd.nextInt(28)).coerceIn(0, spoken.size - 8)
                else -> {
                    // Off-script talk, then a manual move now and then: the same call on both sides.
                    for (w in offTalk.take(1 + rnd.nextInt(offTalk.size))) {
                        now += 150
                        val label = "$lang seed $seed seg $segment off-talk"
                        val (u, p, n) = ref.onAsr(w, false, voice, lead, now)
                        same(label, u, p, n, f.onRecognized(w, false, voice, lead, now), f)
                        updates++
                    }
                    val manual = rnd.nextInt(4)
                    val label = "$lang seed $seed seg $segment manual $manual"
                    val got: CoreFollowUpdate?
                    val expected: Pair<Int, Int>?
                    when (manual) {
                        0 -> { val tok = rnd.nextInt(core.model.tokens.size); expected = ref.moveTracker { it.jumpToToken(tok) }; got = f.jumpToToken(tok) }
                        1 -> { expected = ref.stepLine(1); got = f.stepLine(1) }
                        2 -> { expected = ref.stepLine(-1); got = f.stepLine(-1) }
                        else -> { expected = ref.moveTracker { it.reset(0) }; got = f.restart() }
                    }
                    assertEquals(expected == null, got == null, "$label null")
                    if (expected != null && got != null) {
                        assertEquals(expected.first, got.position, "$label position")
                        assertEquals(expected.second, got.nextToken, "$label nextToken")
                        assertEquals("manual", got.reason)
                    }
                    assertEquals(ref.position, f.position, "$label follower position")
                    updates++
                    return@repeat
                }
            }
            val words = spoken.subList(truePos, truePos + 8).map { surface(it) }
            // Growing partials, then the final result; some with a pause long enough to end the lead.
            for (k in 1..words.size) {
                now += if (rnd.nextInt(100) < 8) 1100L + rnd.nextInt(900) else 80L + rnd.nextInt(300)
                val text = if (lang == SpeechLang.ZH) words.take(k).joinToString("") else words.take(k).joinToString(" ")
                val label = "$lang seed $seed seg $segment partial $k step ${step++}"
                val (u, p, n) = ref.onAsr(text, false, voice, lead, now)
                same(label, u, p, n, f.onRecognized(text, false, voice, lead, now), f)
                updates++
            }
            now += 200
            val text = if (lang == SpeechLang.ZH) words.joinToString("") else words.joinToString(" ")
            val (u, p, n) = ref.onAsr(text, true, voice, lead, now)
            same("$lang seed $seed seg $segment final", u, p, n, f.onRecognized(text, true, voice, lead, now), f)
            updates++
        }
        return updates
    }

    @Test
    fun followerMatchesAndroidOnAsrOverReplayedSessions() {
        var total = 0
        for ((lang, lines) in scripts()) {
            for (seed in longArrayOf(42, 7)) {
                for (phrase in listOf(true, false)) total += replay(lang, lines, seed, phrase)
            }
        }
        assertTrue(total > 5000, "replayed $total updates")
    }

    @Test
    fun followerMatchesAndroidOnTheRussianGoldenReading() {
        // A straight read of the whole Russian script, word by word, as the golden test does: the same positions.
        val core = script(SpeechLang.RU, TrackerSimulation.RU_SCRIPT, true)
        val f = core.newFollower()
        val ref = AndroidReference(core.model)
        var now = 0L
        val spokenWords = core.model.tokens.filter { it.spoken }.map { core.model.displayText.substring(it.start, it.end) }
        val heard = ArrayList<String>()
        for (w in spokenWords) {
            heard += w
            now += 250
            val text = heard.takeLast(5).joinToString(" ")
            val (u, p, n) = ref.onAsr(text, false, true, 2, now)
            same("golden $w", u, p, n, f.onRecognized(text, false, true, 2, now), f)
        }
        assertEquals(f.size, f.position)
    }

    @Test
    fun paragraphKindsReachTheLayout() {
        // CoreParagraph.heading maps to Paragraph.Kind.HEADING: shown, not spoken.
        val core = SuflyorCore.buildScript("t", listOf(CoreParagraph("Chapter one", true, emptyList()), CoreParagraph("Body words here", false, emptyList())), "en", false, 7)
        assertEquals(3, core.model.tokens.count { it.spoken })
    }
}
