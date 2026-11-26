package com.olerast.suflyor

import kotlin.math.abs
import kotlin.math.floor

// The tracker tests were written for JUnit 4 (message first). These wrappers keep their calls unchanged on kotlin.test.

fun assertEquals(expected: Any?, actual: Any?) = kotlin.test.assertEquals(expected, actual)

fun assertEquals(message: String, expected: Any?, actual: Any?) = kotlin.test.assertEquals(expected, actual, message)

fun assertTrue(condition: Boolean) = kotlin.test.assertTrue(condition)

fun assertTrue(message: String, condition: Boolean) = kotlin.test.assertTrue(condition, message)

fun assertFalse(condition: Boolean) = kotlin.test.assertFalse(condition)

fun assertFalse(message: String, condition: Boolean) = kotlin.test.assertFalse(condition, message)

/** "%.[digits]f" with a dot and half-up rounding, for the progress lines the simulations print. */
fun fmt(x: Double, digits: Int): String {
    var scale = 1L
    repeat(digits) { scale *= 10 }
    val scaled = floor(abs(x) * scale + 0.5).toLong()
    val frac = (scaled % scale).toString().padStart(digits, '0')
    return (if (x < 0) "-" else "") + (scaled / scale) + "." + frac
}

/**
 * java.util.Random's generator (48-bit LCG) for nextInt(bound), so the simulations draw the same numbers from the same
 * seeds as before the move to common code. A jvmTest compares it with the real class.
 */
class JavaRandom(seed: Long) {
    private var state = (seed xor MULTIPLIER) and MASK

    private fun next(bits: Int): Int {
        state = (state * MULTIPLIER + 0xBL) and MASK
        return (state ushr (48 - bits)).toInt()
    }

    fun nextInt(bound: Int): Int {
        require(bound > 0)
        var r = next(31)
        val m = bound - 1
        if (bound and m == 0) {
            r = ((bound.toLong() * r.toLong()) shr 31).toInt()
        } else {
            var u = r
            while (true) {
                r = u % bound
                if (u - r + m >= 0) break
                u = next(31)
            }
        }
        return r
    }

    private companion object {
        const val MULTIPLIER = 0x5DEECE66DL
        const val MASK = (1L shl 48) - 1
    }
}
