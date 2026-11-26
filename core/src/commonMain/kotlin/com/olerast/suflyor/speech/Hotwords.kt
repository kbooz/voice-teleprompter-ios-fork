package com.olerast.suflyor.speech

import com.olerast.suflyor.script.SpeechLang
import com.olerast.suflyor.script.TurkishNorm
import com.olerast.suflyor.script.WordNorm

/**
 * The hotwords string for sherpa-onnx ("/"-separated) from script words: only words every piece of which is in the
 * model's BPE vocabulary, at most 1500.
 * - Russian: the vocabulary is lowercase Cyrillic, so plain Cyrillic words of 4+ letters.
 * - English: LibriSpeech pieces are UPPER CASE Latin plus an apostrophe piece, so words of A–Z and "'" with 4+ letters.
 *   The words come normalized (ScriptModel.biasWords), so stop words, numbers and Cyrillic are already gone.
 * - Turkish: lowercase Turkish letters with 4+ letters, as TurkishNorm prints them. Unused until the Turkish model
 *   ships a BPE vocabulary (see [create]).
 */
fun hotwordList(lang: SpeechLang, words: List<String>): String {
    val usable = when (lang) {
        SpeechLang.RU -> words.asSequence()
            .map { it.lowercase() }
            .filter { w -> w.length >= 4 && w.all { it in 'а'..'я' || it == 'ё' } }
        SpeechLang.EN -> words.asSequence()
            .map { it.uppercase() }
            .filter { w -> w.count { it in 'A'..'Z' } >= 4 && w.all { it in 'A'..'Z' || it == '\'' } }
        SpeechLang.TR -> words.asSequence()
            .map { TurkishNorm.normalizeWord(it) }
            .filter { w -> w.length >= 4 && w.all { it in 'a'..'z' || it in "çğıöşü" } }
        SpeechLang.AR -> words.asSequence()
            .map { WordNorm.AR.normalizeWord(it) }
            .filter { w -> w.length >= 3 && w.all { ch -> ch in '\u0621'..'\u064A' } }
        // Speech packs ship no BPE vocabulary, so there is nothing to encode script words with.
        else -> emptySequence()
    }
    return usable.distinct().take(1500).joinToString("/")
}
