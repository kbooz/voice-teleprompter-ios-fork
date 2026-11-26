package com.olerast.suflyor.script

/** Canonical composition (NFC). JVM: java.text.Normalizer; iOS: Foundation. */
expect fun nfc(text: CharSequence): String

/** Canonical decomposition (NFD). */
expect fun nfd(text: CharSequence): String

/** Non-spacing, enclosing or spacing combining mark: what the normalizers strip after decomposing. */
fun Char.isAnyMark(): Boolean {
    val c = category
    return c == CharCategory.NON_SPACING_MARK || c == CharCategory.ENCLOSING_MARK || c == CharCategory.COMBINING_SPACING_MARK
}

/** java.lang.Character.isSpaceChar: Zs, Zl and Zp (unlike isWhitespace it includes the no-break space). */
fun Char.isSpaceSeparator(): Boolean {
    val c = category
    return c == CharCategory.SPACE_SEPARATOR || c == CharCategory.LINE_SEPARATOR || c == CharCategory.PARAGRAPH_SEPARATOR
}

/**
 * Lowercase with the Turkish rules (what String.lowercase(Locale("tr","TR")) does on the JVM): "I" -> "ı", "İ" -> "i",
 * and "I" followed by a combining dot above -> "i". Everything else lowers as usual. The other languages in use
 * (pt, es, de, fr, it, nl, sv, he, ar) have no locale-specific lowercase rules, so they call plain lowercase().
 */
fun String.lowercaseTr(): String {
    if (none { it == 'I' || it == 'İ' }) return lowercase()
    val sb = StringBuilder(length)
    var i = 0
    while (i < length) {
        val c = this[i]
        when {
            c == 'I' && i + 1 < length && this[i + 1] == '̇' -> { sb.append('i'); i++ }
            c == 'I' -> sb.append('ı')
            c == 'İ' -> sb.append('i')
            else -> sb.append(c.toString().lowercase())
        }
        i++
    }
    return sb.toString()
}
