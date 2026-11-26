import Foundation
import SuflyorDomain

/// Port of Kotlin `ParagraphBuilder`: accumulates the text runs of one paragraph, collapses whitespace, removes
/// invisible characters and remembers which characters were emphasized. Works in UTF-16 units so emphasis ranges
/// come out as the `TextRange` offsets the rest of the app expects.
struct ParagraphBuilder {
    private var chars: Units = []
    private var emphasized: [Bool] = []

    /// Each call is normalized to NFC on its own, as Android does (`Normalizer.normalize` per run).
    mutating func append(_ text: String, emphasized: Bool = false) {
        appendRaw(units(text.precomposedStringWithCanonicalMapping), emphasized: emphasized)
    }

    /// For text that may hold lone surrogates (RTF `\u` escapes), which a Swift String cannot represent.
    mutating func appendRaw(_ text: Units, emphasized flag: Bool = false) {
        for c in text {
            switch c {
            case 0x00AD, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF:
                continue
            case _ where isKotlinWhitespace(c):
                // Whitespace of every kind collapses into one plain space.
                if let last = chars.last, last != 0x20 {
                    chars.append(0x20)
                    emphasized.append(flag)
                }
            case _ where c < 0x20:
                continue
            default:
                chars.append(c)
                emphasized.append(flag)
            }
        }
    }

    var isBlank: Bool { isKotlinBlank(chars) }

    var isEmpty: Bool { chars.isEmpty }

    mutating func clear() {
        chars.removeAll(keepingCapacity: true)
        emphasized.removeAll(keepingCapacity: true)
    }

    func build(kind: ScriptParagraph.Kind = .body) -> ScriptParagraph? {
        var s = 0
        var e = chars.count
        while s < e, chars[s] == 0x20 { s += 1 }
        while e > s, chars[e - 1] == 0x20 { e -= 1 }
        if s >= e { return nil }
        var ranges: [TextRange] = []
        var runStart = -1
        var runEnd = -1
        for k in s..<e {
            if chars[k] == 0x20 { continue }
            if emphasized[k] {
                if runStart < 0 { runStart = k }
                runEnd = k
            } else if runStart >= 0 {
                ranges.append(TextRange(start: runStart - s, end: runEnd - s + 1))
                runStart = -1
            }
        }
        if runStart >= 0 { ranges.append(TextRange(start: runStart - s, end: runEnd - s + 1)) }
        return ScriptParagraph(text: string(chars[s..<e]), kind: kind, emphasis: ranges)
    }
}
