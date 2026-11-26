package com.olerast.suflyor.script

import kotlinx.cinterop.BetaInteropApi
import platform.Foundation.NSString
import platform.Foundation.create
import platform.Foundation.decomposedStringWithCanonicalMapping
import platform.Foundation.precomposedStringWithCanonicalMapping

// Checked on iosSimulatorArm64 (PortabilityShimTest): Foundation NFC/NFD match java.text.Normalizer for the cases the
// normalizers use (accents, Hangul syllables <-> jamo).
@OptIn(BetaInteropApi::class)
actual fun nfc(text: CharSequence): String = NSString.create(string = text.toString()).precomposedStringWithCanonicalMapping

@OptIn(BetaInteropApi::class)
actual fun nfd(text: CharSequence): String = NSString.create(string = text.toString()).decomposedStringWithCanonicalMapping
