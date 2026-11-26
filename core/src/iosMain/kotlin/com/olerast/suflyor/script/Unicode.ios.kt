package com.olerast.suflyor.script

import kotlinx.cinterop.BetaInteropApi
import platform.Foundation.NSString
import platform.Foundation.create
import platform.Foundation.decomposedStringWithCanonicalMapping
import platform.Foundation.precomposedStringWithCanonicalMapping

// VERIFY: compiled with Kotlin/Native on Linux (klib only, not linked or run). The first Mac run of the common tests
// (iosSimulatorArm64Test) must confirm that NFC/NFD behave like java.text.Normalizer (the normalizers use both).
@OptIn(BetaInteropApi::class)
actual fun nfc(text: CharSequence): String = NSString.create(string = text.toString()).precomposedStringWithCanonicalMapping

@OptIn(BetaInteropApi::class)
actual fun nfd(text: CharSequence): String = NSString.create(string = text.toString()).decomposedStringWithCanonicalMapping
