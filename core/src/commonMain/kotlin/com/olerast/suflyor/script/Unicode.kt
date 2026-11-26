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
 * and "I" directly followed by a combining dot above -> "i" (Java also accepts other marks in between; not handled).
 * The special letters are replaced first and the rest goes through plain lowercase(), so context rules stay intact.
 * The other languages in use (pt, es, de, fr, it, nl, sv, he, ar) have no locale-specific lowercase rules.
 */
fun String.lowercaseTr(): String {
    if (none { it == 'I' || it == '\u0130' }) return lowercase()
    val sb = StringBuilder(length)
    var i = 0
    while (i < length) {
        val c = this[i]
        when {
            c == 'I' && i + 1 < length && this[i + 1] == '\u0307' -> { sb.append('i'); i++ }
            c == 'I' -> sb.append('\u0131')
            c == '\u0130' -> sb.append('i')
            else -> sb.append(c)
        }
        i++
    }
    return sb.toString().lowercase()
}

/**
 * Same text as String.format("%.1f", x) with a dot decimal separator (no locale, no String.format in common code).
 * Java rounds half up on the decimal value; Float arguments are exact in a Double, so floor(x * 10 + 0.5) agrees.
 */
fun Float.format1(): String {
    val d = toDouble()
    if (d.isNaN() || d.isInfinite()) return d.toString()
    val negative = d < 0.0 || (d == 0.0 && 1.0 / d < 0.0)
    val scaled = kotlin.math.floor(kotlin.math.abs(d) * 10.0 + 0.5).toLong()
    return (if (negative) "-" else "") + (scaled / 10) + "." + (scaled % 10)
}
