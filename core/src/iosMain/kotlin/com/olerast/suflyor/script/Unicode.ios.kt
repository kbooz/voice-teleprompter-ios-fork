package com.olerast.suflyor.script

import kotlinx.cinterop.BetaInteropApi
import kotlinx.cinterop.ExperimentalForeignApi
import platform.Foundation.NSString
import platform.Foundation.decomposedStringWithCanonicalMapping
import platform.Foundation.precomposedStringWithCanonicalMapping

// VERIFY: not compiled on Linux. Kotlin String bridges to NSString with `as NSString` on Kotlin/Native, and the two
// Foundation properties return the canonical (NFC / NFD) forms; confirm the imports and the opt-ins on the first Mac build.
@OptIn(BetaInteropApi::class, ExperimentalForeignApi::class)
actual fun nfc(text: CharSequence): String = (text.toString() as NSString).precomposedStringWithCanonicalMapping

// VERIFY: same bridging as nfc.
@OptIn(BetaInteropApi::class, ExperimentalForeignApi::class)
actual fun nfd(text: CharSequence): String = (text.toString() as NSString).decomposedStringWithCanonicalMapping
