import Foundation
import SuflyorDomain

/// Decodes text files of unknown encoding: BOMs, strict UTF-8, UTF-16 without BOM, then Cyrillic single-byte guesses.
/// Same order and heuristics as Kotlin `TextDecoding`.
enum TextDecoding {
    static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return String(decoding: bytes[3...], as: UTF8.self)
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
            return decodeUTF16(bytes[2...], littleEndian: true)
        }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            return decodeUTF16(bytes[2...], littleEndian: false)
        }
        if let s = utf16WithoutBom(bytes) { return s }
        if let s = strictUtf8(data, bytes) { return s }
        let cp1251 = SingleByteCodepage.windows1251.decode(bytes)
        let koi8 = SingleByteCodepage.koi8r.decode(bytes)
        return cyrillicScore(koi8) > cyrillicScore(cp1251) ? koi8 : cp1251
    }

    /// Lossy like Java: a broken pair or a dangling last byte becomes U+FFFD.
    static func decodeUTF16(_ bytes: ArraySlice<UInt8>, littleEndian: Bool) -> String {
        var out: Units = []
        out.reserveCapacity(bytes.count / 2 + 1)
        var i = bytes.startIndex
        while i + 1 < bytes.endIndex {
            let a = UInt16(bytes[i])
            let b = UInt16(bytes[i + 1])
            out.append(littleEndian ? (b << 8 | a) : (a << 8 | b))
            i += 2
        }
        if i < bytes.endIndex { out.append(0xFFFD) }
        return String(decoding: out, as: UTF16.self)
    }

    /// UTF-8 unless it clearly is not. A file cut in the middle of a character or with a few broken bytes is still
    /// UTF-8 (the bad spots become U+FFFD); single-byte Cyrillic text produces almost nothing but errors.
    private static func strictUtf8(_ data: Data, _ bytes: [UInt8]) -> String? {
        if let strict = String(data: data, encoding: .utf8) { return strict }
        let lenient = String(decoding: bytes, as: UTF8.self)
        var bad = 0
        var nonAscii = 0
        for u in lenient.utf16 {
            if u == 0xFFFD {
                bad += 1
            } else if u >= 0x80 {
                nonAscii += 1
            }
        }
        return bad * 50 <= nonAscii && bad <= 16 ? lenient : nil
    }

    /// In UTF-16 text (Latin or Cyrillic) every high byte is 0x00 or 0x04; single-byte encodings never look like that.
    private static func utf16WithoutBom(_ bytes: [UInt8]) -> String? {
        if bytes.count < 4 { return nil }
        let n = min(bytes.count, 4000) / 2 * 2
        var highEven = 0
        var highOdd = 0
        for i in 0..<n {
            let b = bytes[i]
            if b == 0 || b == 4 {
                if i % 2 == 0 { highEven += 1 } else { highOdd += 1 }
            }
        }
        let half = Double(n / 2)
        if Double(highOdd) > half * 0.7, Double(highEven) < half * 0.1 {
            return decodeUTF16(bytes[...], littleEndian: true)
        }
        if Double(highEven) > half * 0.7, Double(highOdd) < half * 0.1 {
            return decodeUTF16(bytes[...], littleEndian: false)
        }
        return nil
    }

    /// Frequent lowercase Russian letters score up, uppercase letters inside words score down.
    private static func cyrillicScore(_ s: String) -> Int {
        let common = Set("оеаинтсрвлкмдпу".unicodeScalars)
        var score = 0
        var prevLetter = false
        for scalar in s.unicodeScalars {
            if common.contains(scalar) { score += 2 }
            if scalar.value >= 0x0410 && scalar.value <= 0x042F && prevLetter { score -= 3 }
            prevLetter = isLetter(UInt16(truncatingIfNeeded: scalar.value)) && scalar.value <= 0xFFFF
        }
        return score
    }
}

enum PlainTextImporter {
    static func parse(_ text: String, title: String, format: String = "TXT") -> ImportedDocument {
        let src = text.normalizedNewlines
        let hasBlankLines = hasBlankLine(kotlinTrim(units(src)))
        var paragraphs: [ScriptParagraph] = []
        var pb = ParagraphBuilder()
        for line in src.linesKeepingEmpty {
            let lineUnits = units(line)
            if isKotlinBlank(lineUnits) {
                if let p = pb.build() { paragraphs.append(p) }
                pb.clear()
                continue
            }
            if hasBlankLines {
                // Blocks are separated by blank lines; single line breaks inside a block are soft wraps.
                pb.append(" ")
                pb.append(line)
            } else {
                // No blank lines at all: every line is its own paragraph (typical for notes apps).
                pb.append(line)
                if let p = pb.build() { paragraphs.append(p) }
                pb.clear()
            }
        }
        if let p = pb.build() { paragraphs.append(p) }
        return ImportedDocument(title: title, format: format, paragraphs: paragraphs)
    }

    /// Kotlin `Regex("\n[ \t ]*\n").containsMatchIn(text)`, linear.
    private static func hasBlankLine(_ text: Units) -> Bool {
        var i = 0
        while i < text.count {
            if text[i] == 0x0A {
                var j = i + 1
                while j < text.count, text[j] == 0x20 || text[j] == 0x09 || text[j] == 0xA0 { j += 1 }
                if j < text.count, text[j] == 0x0A { return true }
                // A run of blanks without a second newline can't start a match from inside it.
                i = max(i + 1, j)
            } else {
                i += 1
            }
        }
        return false
    }
}
