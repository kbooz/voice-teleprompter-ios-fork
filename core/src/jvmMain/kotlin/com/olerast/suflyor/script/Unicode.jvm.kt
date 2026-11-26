package com.olerast.suflyor.script

import java.text.Normalizer

actual fun nfc(text: CharSequence): String = Normalizer.normalize(text, Normalizer.Form.NFC)

actual fun nfd(text: CharSequence): String = Normalizer.normalize(text, Normalizer.Form.NFD)
