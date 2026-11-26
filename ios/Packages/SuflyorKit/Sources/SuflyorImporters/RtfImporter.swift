import Foundation
import SuflyorDomain

/// A code page named by RTF (`\ansicpgN`, `\fcharsetN`): built-in tables for the single-byte ones, Core Foundation's
/// converters for the East Asian multi-byte ones.
enum RtfCodepage: Equatable {
    case single(SingleByteCodepage)
    /// CFStringEncoding value (kCFStringEncodingDOSJapanese 0x0420, DOSChineseSimplif 0x0421, DOSKorean 0x0422,
    /// DOSChineseTrad 0x0423, ShiftJIS 0x0A01).
    case cf(UInt32)

    func decode(_ bytes: [UInt8]) -> String {
        switch self {
        case .single(let table):
            return table.decode(bytes)
        case .cf(let cfEncoding):
            // Sample bytes for 932/936/949/950 decode correctly through Foundation.
            let ns = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            if let s = String(data: Data(bytes), encoding: String.Encoding(rawValue: ns)) { return s }
            return SingleByteCodepage.windows1252.decode(bytes)
        }
    }

    /// `\ansicpgN` -> code page (Java's `Charset.forName("windows-N")`); nil when unknown, which keeps the current one.
    static func forAnsiCodepage(_ n: Int) -> RtfCodepage? {
        switch n {
        case 1250: .single(.windows1250)
        case 1251: .single(.windows1251)
        case 1252: .single(.windows1252)
        case 1253: .single(.windows1253)
        case 1254: .single(.windows1254)
        case 1255: .single(.windows1255)
        case 1256: .single(.windows1256)
        case 1257: .single(.windows1257)
        case 1258: .single(.windows1258)
        case 874: .single(.windows874)
        case 932: .cf(0x0420)
        case 936: .cf(0x0421)
        case 949: .cf(0x0422)
        case 950: .cf(0x0423)
        default: nil
        }
    }

    /// RTF `\fcharsetN` numbers -> code pages (Cyrillic WordPad text is \fcharset204 even with \ansicpg1252).
    static func forFontCharset(_ n: Int) -> RtfCodepage? {
        switch n {
        case 128: .cf(0x0420)
        case 129: .cf(0x0422)
        case 134: .cf(0x0421)
        case 136: .cf(0x0423)
        case 161: .single(.windows1253)
        case 162: .single(.windows1254)
        case 163: .single(.windows1258)
        case 177: .single(.windows1255)
        case 178: .single(.windows1256)
        case 186: .single(.windows1257)
        case 204: .single(.windows1251)
        case 222: .single(.windows874)
        case 238: .single(.windows1250)
        default: nil
        }
    }
}

/// Minimal RTF reader (port of Kotlin `RtfImporter`): paragraphs, \b bold, \'hh bytes in the document code page,
/// \uN escapes; skips tables of fonts, pictures etc. It reads the file as Latin-1 bytes, one byte per character.
enum RtfImporter {
    private static let skipDestinations: Set<String> = [
        "fonttbl", "colortbl", "stylesheet", "info", "pict", "header", "footer", "headerl", "headerr", "headerf",
        "footerl", "footerr", "footerf", "object", "fldinst", "themedata", "colorschememapping", "latentstyles",
        "datastore", "xmlnstbl", "listtable", "listoverridetable", "rsidtbl", "generator", "filetbl", "revtbl",
        "footnote", "annotation", "bkmkstart", "bkmkend", "shppict", "nonshppict", "blipuid",
    ]

    private struct State {
        var skip: Bool
        var bold: Bool
        var uc: Int
        var font: Int
    }

    static func parse(_ data: Data, title: String) throws(ImportError) -> ImportedDocument {
        let src = [UInt8](data)
        let header = Array("{\\rtf".utf8)
        if src.count < header.count || Array(src[0..<header.count]) != header { throw .notRtf }

        var parser = Parser(src: src)
        parser.readFontTable()
        parser.run()
        return ImportedDocument(title: title, format: "RTF", paragraphs: parser.paragraphs)
    }

    /// Kotlin `Char.isLetter()` for a Latin-1 character.
    private static func isLatin1Letter(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0xAA || b == 0xB5 || b == 0xBA ||
            (b >= 0xC0 && b != 0xD7 && b != 0xF7)
    }

    private static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

    private struct Parser {
        let src: [UInt8]
        var paragraphs: [ScriptParagraph] = []
        var pb = ParagraphBuilder()
        var pendingBytes: [UInt8] = []
        var stack: [State] = []
        var state = State(skip: false, bold: false, uc: 1, font: -1)
        var skipChars = 0
        var groupStart = false
        var charset: RtfCodepage = .single(.windows1252)
        var fontCharsets: [Int: RtfCodepage] = [:]

        init(src: [UInt8]) { self.src = src }

        /// The font table sits at the start; map each font to the code page of its \fcharset.
        /// Port of `\\f(\d{1,9})[^;{}]{0,200}?\\fcharset(\d{1,9})`.
        mutating func readFontTable() {
            let marker = Array("\\fonttbl".utf8)
            guard let at = indexOf(marker, from: 0) else { return }
            let table = Array(src[at..<min(src.count, at + 64 * 1024)])
            let fcharset = Array("\\fcharset".utf8)
            var i = 0
            while i < table.count {
                guard table[i] == 0x5C, i + 2 < table.count, table[i + 1] == 0x66, isDigit(table[i + 2]) else {
                    i += 1
                    continue
                }
                var j = i + 2
                var digits = 0
                while j < table.count, isDigit(table[j]), digits < 9 {
                    j += 1
                    digits += 1
                }
                let fontNumber = Int(String(decoding: table[(i + 2)..<j], as: UTF8.self))
                // Lazy `[^;{}]{0,200}?` then \fcharset
                var t = j
                var found = -1
                while t - j <= 200 {
                    if matches(table, fcharset, at: t) {
                        found = t
                        break
                    }
                    if t >= table.count || table[t] == 0x3B || table[t] == 0x7B || table[t] == 0x7D { break }
                    t += 1
                }
                var k = found < 0 ? -1 : found + fcharset.count
                if k >= 0 {
                    let digitsStart = k
                    var n = 0
                    while k < table.count, isDigit(table[k]), n < 9 {
                        k += 1
                        n += 1
                    }
                    if n == 0 {
                        i += 1
                        continue
                    }
                    let charsetNumber = Int(String(decoding: table[digitsStart..<k], as: UTF8.self))
                    if let f = fontNumber, let c = charsetNumber, let cp = RtfCodepage.forFontCharset(c) {
                        fontCharsets[f] = cp
                    }
                    i = k
                } else {
                    i += 1
                }
            }
        }

        private func indexOf(_ needle: [UInt8], from: Int) -> Int? {
            var i = from
            while i + needle.count <= src.count {
                if matches(src, needle, at: i) { return i }
                i += 1
            }
            return nil
        }

        private func matches(_ hay: [UInt8], _ needle: [UInt8], at i: Int) -> Bool {
            if i < 0 || i + needle.count > hay.count { return false }
            for k in 0..<needle.count where hay[i + k] != needle[k] { return false }
            return true
        }

        private mutating func flushBytes() {
            if pendingBytes.isEmpty { return }
            let cs = fontCharsets[state.font] ?? charset
            if !state.skip { pb.append(cs.decode(pendingBytes), emphasized: state.bold) }
            pendingBytes.removeAll(keepingCapacity: true)
        }

        private mutating func emitText(_ text: String) {
            flushBytes()
            if !state.skip { pb.append(text, emphasized: state.bold) }
        }

        private mutating func endParagraph() {
            flushBytes()
            if let p = pb.build() { paragraphs.append(p) }
            pb.clear()
        }

        private static func hexValue(_ b: UInt8) -> Int? {
            switch b {
            case 0x30...0x39: Int(b) - 0x30
            case 0x41...0x46: Int(b) - 0x41 + 10
            case 0x61...0x66: Int(b) - 0x61 + 10
            default: nil
            }
        }

        /// Kotlin `String.toIntOrNull()` on an optional sign followed by digits.
        private static func intOrNil(_ bytes: ArraySlice<UInt8>) -> Int? {
            Int32(String(decoding: bytes, as: UTF8.self)).map { Int($0) }
        }

        mutating func run() {
            let n = src.count
            var i = 0
            while i < n {
                let c = src[i]
                if c == 0x7B { // {
                    flushBytes()
                    stack.append(state)
                    groupStart = true
                    i += 1
                    continue
                } else if c == 0x7D { // }
                    flushBytes()
                    if let top = stack.popLast() { state = top }
                    i += 1
                } else if c == 0x5C, i + 1 < n { // backslash
                    let next = src[i + 1]
                    if next == 0x27, i + 3 < n { // \'hh
                        let hi = Self.hexValue(src[i + 2])
                        let lo = Self.hexValue(src[i + 3])
                        i += 4
                        if skipChars > 0 {
                            skipChars -= 1
                        } else if let hi, let lo, !state.skip {
                            pendingBytes.append(UInt8(hi * 16 + lo))
                        }
                    } else if next == 0x2A { // \*
                        state.skip = true
                        i += 2
                    } else if next == 0x5C || next == 0x7B || next == 0x7D {
                        emitText(String(UnicodeScalar(next)))
                        i += 2
                    } else if next == 0x7E { // \~
                        emitText(" ")
                        i += 2
                    } else if next == 0x2D || next == 0x5F { // \- \_
                        if next == 0x5F { emitText("-") }
                        i += 2
                    } else if next == 0x0A || next == 0x0D {
                        endParagraph()
                        i += 2
                    } else if RtfImporter.isLatin1Letter(next) {
                        i = controlWord(at: i)
                    } else {
                        i += 2
                    }
                } else if c == 0x0D || c == 0x0A {
                    i += 1
                } else {
                    if skipChars > 0 {
                        skipChars -= 1
                    } else if !state.skip {
                        pendingBytes.append(c)
                    }
                    i += 1
                }
                groupStart = false
            }
            endParagraph()
        }

        /// Handles the control word at `i` (a backslash followed by a letter) and returns the next index.
        private mutating func controlWord(at i: Int) -> Int {
            let n = src.count
            var j = i + 1
            while j < n, RtfImporter.isLatin1Letter(src[j]) { j += 1 }
            let word = String(decoding: src[(i + 1)..<j], as: UTF8.self)
            var k = j
            if k < n, src[k] == 0x2D || RtfImporter.isDigit(src[k]) {
                k += 1
                while k < n, RtfImporter.isDigit(src[k]) { k += 1 }
            }
            let param = Self.intOrNil(src[j..<k])
            if k < n, src[k] == 0x20 { k += 1 }
            if groupStart, RtfImporter.skipDestinations.contains(word) { state.skip = true }
            switch word {
            case "par", "line", "sect", "page", "row":
                endParagraph()
            case "cell", "tab", "emspace", "enspace":
                emitText(" ")
            case "b":
                flushBytes()
                state.bold = param != 0
            case "plain":
                flushBytes()
                state.bold = false
            case "f":
                if let param, !state.skip {
                    flushBytes()
                    state.font = param
                }
            case "deff":
                if let param, state.font < 0 { state.font = param }
            case "uc":
                state.uc = param ?? 1
            case "u":
                if let param {
                    // Kotlin `Int.toChar()` keeps the low 16 bits; a surrogate half stays a lone unit.
                    let code = param < 0 ? param + 65536 : param
                    let unit = UInt16(truncatingIfNeeded: code)
                    flushBytes()
                    if !state.skip {
                        if let scalar = Unicode.Scalar(unit) {
                            pb.append(String(Character(scalar)), emphasized: state.bold)
                        } else {
                            pb.appendRaw([unit], emphasized: state.bold)
                        }
                    }
                    skipChars = state.uc
                }
            case "ansicpg":
                if let param, let cp = RtfCodepage.forAnsiCodepage(param) { charset = cp }
            case "emdash":
                emitText("\u{2014}")
            case "endash":
                emitText("\u{2013}")
            case "lquote", "rquote":
                emitText("'")
            case "ldblquote", "rdblquote":
                emitText("\"")
            case "bullet":
                emitText("\u{2022}")
            default:
                break
            }
            return k
        }
    }
}
