package com.olerast.suflyor.core

import com.olerast.suflyor.doc.MarkdownImporter
import com.olerast.suflyor.doc.Paragraph
import com.olerast.suflyor.doc.ScriptDocument
import com.olerast.suflyor.script.ScriptLayout
import com.olerast.suflyor.script.ScriptModel
import com.olerast.suflyor.script.SpeechLang
import com.olerast.suflyor.script.biasWords
import com.olerast.suflyor.speech.hotwordList
import com.olerast.suflyor.track.ScriptTracker

// Facade for Swift (Kotlin/Native Objective-C export): only String, Int, Float, Boolean, lists and these value types
// cross the boundary, so the Swift side never sees the tracker's internals.

/** UTF-16 offsets, end exclusive (Kotlin IntRange first..last becomes CoreRange(first, last + 1)). */
data class CoreRange(val start: Int, val endExclusive: Int)

data class CoreParagraph(val text: String, val heading: Boolean, val emphasis: List<CoreRange>)

data class CoreToken(val start: Int, val endExclusive: Int, val spoken: Boolean)

data class CoreLanguage(val code: String, val label: String, val needsPack: Boolean)

data class CoreFollowUpdate(
    val moved: Boolean,
    val position: Int,
    val nextToken: Int,
    val matches: Int,
    val score: Float,
    val reason: String,
)

object SuflyorCore {
    const val API_VERSION: Int = 1

    fun languages(): List<CoreLanguage> = SpeechLang.entries.map { CoreLanguage(it.code, it.label, it.isPack) }

    /** SpeechLang.detect on a document built from [paragraphs]; returns the SpeechLang code. */
    fun detectLanguage(paragraphs: List<CoreParagraph>): String =
        SpeechLang.detect(document("", paragraphs)).code

    /** MarkdownImporter.parse(text, title).paragraphs */
    fun parseMarkdown(text: String, title: String): List<CoreParagraph> =
        MarkdownImporter.parse(text, title).paragraphs.map { p ->
            CoreParagraph(
                p.text,
                p.kind == Paragraph.Kind.HEADING,
                p.emphasis.map { CoreRange(it.first, it.last + 1) },
            )
        }

    /** ScriptLayout.build(doc, phraseMode, maxWords, lang). Unknown langCode falls back to RU, as on Android. */
    fun buildScript(
        title: String,
        paragraphs: List<CoreParagraph>,
        langCode: String,
        phraseMode: Boolean,
        maxWords: Int,
    ): CoreScript {
        val lang = SpeechLang.fromCode(langCode) ?: SpeechLang.RU
        return CoreScript(ScriptLayout.build(document(title, paragraphs), phraseMode, maxWords, lang))
    }

    private fun document(title: String, paragraphs: List<CoreParagraph>) = ScriptDocument(
        title,
        ScriptDocument.FORMAT_TEXT,
        paragraphs.map { p ->
            Paragraph(
                p.text,
                if (p.heading) Paragraph.Kind.HEADING else Paragraph.Kind.BODY,
                // An empty or inverted range has no characters: dropped instead of becoming an empty IntRange.
                p.emphasis.filter { it.endExclusive > it.start }.map { it.start until it.endExclusive },
            )
        },
    )
}

class CoreScript internal constructor(internal val model: ScriptModel) {
    val title: String get() = model.title
    val langCode: String get() = model.lang.code
    val displayText: String get() = model.displayText
    val tokens: List<CoreToken> = model.tokens.map { CoreToken(it.start, it.end, it.spoken) }
    val emphasis: List<CoreRange> = model.emphasis.map { CoreRange(it.first, it.last + 1) }
    val notes: List<CoreRange> = model.notes.map { CoreRange(it.first, it.last + 1) }
    val spokenWords: Int get() = model.spokenWords

    fun biasWords(): List<String> = model.biasWords()

    fun hotwords(): String = hotwordList(model.lang, model.biasWords())

    fun newFollower(): CoreFollower = CoreFollower(this)
}

/**
 * ScriptTracker plus the word history and lead logic of Android's SessionEngine (onAsr, stepLine, moveTracker),
 * so both platforms follow the voice the same way. Not thread-safe.
 */
class CoreFollower internal constructor(script: CoreScript) {
    private val model = script.model
    private val lang = model.lang
    private val tracker = ScriptTracker(model.tokens, model.lang)

    private val finalWords = ArrayDeque<String>()
    private var partialWords: List<String> = emptyList()

    /** What the reader sees: the tracker position plus a small lead while speaking; never moves back by itself. */
    private var displayPos = 0
    private var lastSpeechAt = 0L

    val position: Int get() = tracker.position
    val nextToken: Int get() = tracker.tokenIndexAt(displayPos)
    val size: Int get() = tracker.size

    /** SessionEngine.onAsr without the epoch check (the Swift side drops stale results) and the diagnostics. */
    fun onRecognized(text: String, isFinal: Boolean, voiceActive: Boolean, leadWords: Int, nowMillis: Long): CoreFollowUpdate {
        val words = lang.words(text)
        if (!isFinal) lastSpeechAt = nowMillis
        if (isFinal) {
            words.forEach { finalWords.addLast(it) }
            while (finalWords.size > lang.history) finalWords.removeFirst()
            partialWords = emptyList()
        } else {
            partialWords = words
        }
        val before = tracker.position
        var moved: ScriptTracker.Update? = null
        if (voiceActive) {
            moved = tracker.onHypothesis(finalWords.toList() + partialWords)
        }
        val pos = tracker.position
        if (pos < before) displayPos = pos
        // The lead hides recognition latency while following the voice; it has no meaning when paused or timed.
        val maxLead = if (voiceActive) leadWords else 0
        val lead = if (voiceActive && nowMillis - lastSpeechAt < SPEAKING_MS) maxLead else 0
        displayPos = maxOf(displayPos, minOf(pos + lead, tracker.size)).coerceAtMost(pos + maxLead)
        val next = tracker.tokenIndexAt(displayPos)
        return CoreFollowUpdate(
            moved = moved?.moved ?: false,
            position = pos,
            nextToken = next,
            matches = moved?.matches ?: 0,
            score = moved?.score ?: 0f,
            reason = moved?.reason ?: "idle",
        )
    }

    /** Manual jump (tap on a word): the next expected word becomes the first spoken word at or after [tokenIndex]. */
    fun jumpToToken(tokenIndex: Int): CoreFollowUpdate = moveTracker { it.jumpToToken(tokenIndex) }

    /**
     * Moves by display lines. Only lines with spoken words count (headings and notes are skipped).
     * Back goes to the start of the current line first, then to the previous line; forward past the last line stays
     * (null, as for no spoken line at all).
     */
    fun stepLine(delta: Int): CoreFollowUpdate? {
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
        val target = when {
            delta < 0 && line < 0 -> firsts[0]
            delta < 0 && firsts[line] < cur -> firsts[line]
            delta < 0 -> firsts[(line + delta).coerceAtLeast(0)]
            line + delta >= firsts.size -> return null
            else -> firsts[(line + delta).coerceAtLeast(0)]
        }
        if (target == cur) return null
        return moveTracker { it.jumpToToken(target) }
    }

    fun restart(): CoreFollowUpdate = moveTracker { it.reset(0) }

    private fun moveTracker(action: (ScriptTracker) -> Unit): CoreFollowUpdate {
        val before = tracker.position
        action(tracker)
        finalWords.clear()
        partialWords = emptyList()
        val pos = tracker.position
        displayPos = pos
        return CoreFollowUpdate(pos != before, pos, tracker.nextTokenIndex(), 0, 0f, "manual")
    }

    companion object {
        /** After this long without a partial result the reader counts as silent and the lead drops to zero. */
        const val SPEAKING_MS = 900L
    }
}
