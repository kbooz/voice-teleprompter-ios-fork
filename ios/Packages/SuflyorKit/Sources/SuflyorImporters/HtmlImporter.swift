import Foundation
import SuflyorDomain

/// HTML / saved web pages / Google Docs HTML export (port of Kotlin `HtmlImporter`): block tags become paragraphs,
/// <b>/<strong> and bold spans become emphasis. Hand-written scanners instead of regexes keep every pass linear on
/// hostile input.
enum HtmlImporter {
    private static let removedBlocks = ["script", "style", "head", "noscript", "template"]

    private static let block: Set<String> = [
        "p", "div", "br", "li", "tr", "section", "article", "blockquote", "ul", "ol", "table", "hr",
        "header", "footer", "main", "aside", "nav", "dd", "dt", "pre", "figure", "figcaption",
        "h1", "h2", "h3", "h4", "h5", "h6",
    ]
    private static let headings: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]

    private static let named: [String: String] = [
        "nbsp": "\u{00A0}", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "laquo": "\u{00AB}", "raquo": "\u{00BB}", "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}",
        "shy": "\u{00AD}", "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "bdquo": "\u{201E}", "bull": "\u{2022}", "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
        "times": "\u{00D7}", "minus": "\u{2212}", "deg": "\u{00B0}",
    ]

    // MARK: Removing blocks

    /// Drops comments, declarations (<!DOCTYPE>, <?xml?>, Word's <![if ...]>) and script/style/head blocks in one
    /// linear pass.
    private struct Stripper {
        let html: Units
        var out: Units = []
        /// Searches start further and further right, so a remembered result stays valid until we pass it:
        /// a thousand unclosed "<script" or "<!" then cost one scan of the rest, not a thousand.
        var memo: [String: (from: Int, result: Int)] = [:]

        init(html: Units) {
            self.html = html
            out.reserveCapacity(html.count)
        }

        mutating func find(_ needle: String, from: Int) -> Int {
            if let m = memo[needle], from >= m.from, m.result == -1 || m.result >= from { return m.result }
            let r = html.find(needle, from: from, ignoreCase: true)
            memo[needle] = (from, r)
            return r
        }

        mutating func afterTag(_ from: Int) -> Int {
            let g = find(">", from: from)
            return g < 0 ? html.count : g + 1
        }

        mutating func run() -> Units {
            var i = 0
            while i < html.count {
                let lt = html.find(ch("<"), from: i)
                if lt < 0 {
                    out.append(contentsOf: html[i...])
                    break
                }
                out.append(contentsOf: html[i..<lt])
                if html.startsWith("<!--", at: lt) {
                    let end = html.find("-->", from: lt + 4)
                    i = end < 0 ? html.count : end + 3
                    out.append(0x20)
                    continue
                }
                if html.startsWith("<!", at: lt) || html.startsWith("<?", at: lt) {
                    i = afterTag(lt)
                    out.append(0x20)
                    continue
                }
                var blockName: String?
                for tag in HtmlImporter.removedBlocks {
                    let after = lt + tag.utf16.count + 1
                    if html.startsWith("<" + tag, at: lt, ignoreCase: true), after < html.count,
                       !isLetterOrDigit(html[after]) {
                        blockName = tag
                        break
                    }
                }
                if let blockName {
                    let end = find("</" + blockName, from: lt + 1)
                    // </head> is optional in HTML5: without it, the body starts the content.
                    if blockName == "head", end < 0 {
                        let body = find("<body", from: lt + 1)
                        if body >= 0 {
                            i = body
                            out.append(0x20)
                            continue
                        }
                    }
                    // Without a closing tag only the opening tag goes; the rest of the document stays.
                    i = end < 0 ? afterTag(lt) : afterTag(end)
                    out.append(0x20)
                    continue
                }
                out.append(ch("<"))
                i = lt + 1
            }
            return out
        }
    }

    // MARK: Parsing

    static func parse(_ html: String, title: String) -> ImportedDocument {
        let original = units(html)
        var stripper = Stripper(html: original)
        let src = stripper.run()

        var paragraphs: [ScriptParagraph] = []
        var pb = ParagraphBuilder()
        var kind = ScriptParagraph.Kind.body
        var boldDepth = 0
        var spanBold: [Bool] = []

        func flush() {
            if let p = pb.build(kind: kind) { paragraphs.append(p) }
            pb.clear()
            kind = .body
        }

        var last = 0
        var i = 0
        while i < src.count {
            guard src[i] == ch("<"), let tag = matchTag(src, at: i) else {
                i += 1
                continue
            }
            if i > last { pb.append(decode(string(src[last..<i])), emphasized: boldDepth > 0) }
            last = tag.end + 1
            i = last
            if block.contains(tag.name) {
                flush()
                if !tag.closing, headings.contains(tag.name) { kind = .heading }
            } else if tag.name == "b" || tag.name == "strong" {
                boldDepth = max(0, boldDepth + (tag.closing ? -1 : 1))
            } else if tag.name == "span" {
                if tag.closing {
                    if spanBold.popLast() == true { boldDepth = max(0, boldDepth - 1) }
                } else {
                    let bold = hasBoldStyle(src, tag.attrsStart, tag.end)
                    spanBold.append(bold)
                    if bold { boldDepth += 1 }
                }
            }
        }
        if last < src.count { pb.append(decode(string(src[last...])), emphasized: boldDepth > 0) }
        flush()

        let pageTitle = documentTitle(original)
        return ImportedDocument(title: pageTitle ?? title, format: "HTML", paragraphs: paragraphs)
    }

    private struct Tag {
        var closing: Bool
        var name: String
        var attrsStart: Int
        /// Index of the closing '>'.
        var end: Int
    }

    /// `<(/?)([a-zA-Z][a-zA-Z0-9]{0,30})([^<>]*)>` at `i`. The attribute run stops at the next '<', so an unclosed tag
    /// can't make the scan quadratic.
    private static func matchTag(_ s: Units, at i: Int) -> Tag? {
        var j = i + 1
        var closing = false
        if j < s.count, s[j] == ch("/") {
            closing = true
            j += 1
        }
        guard j < s.count, isAsciiLetter(s[j]) else { return nil }
        let nameStart = j
        j += 1
        while j < s.count, j - nameStart < 31, isAsciiLetter(s[j]) || isAsciiDigit(s[j]) { j += 1 }
        let nameEnd = j
        while j < s.count, s[j] != ch("<"), s[j] != ch(">") { j += 1 }
        guard j < s.count, s[j] == ch(">") else { return nil }
        return Tag(closing: closing, name: string(s[nameStart..<nameEnd]).lowercased(), attrsStart: nameEnd, end: j)
    }

    /// `font-weight\s*:\s*(bold|[6-9]00)`, case-insensitive, anywhere in the attributes.
    private static func hasBoldStyle(_ s: Units, _ from: Int, _ to: Int) -> Bool {
        let attrs = Array(s[from..<to])
        var start = 0
        while true {
            let p = attrs.find("font-weight", from: start, ignoreCase: true)
            if p < 0 { return false }
            var k = p + "font-weight".utf16.count
            func skipSpaces() { while k < attrs.count, isRegexSpace(attrs[k]) { k += 1 } }
            skipSpaces()
            if k < attrs.count, attrs[k] == ch(":") {
                k += 1
                skipSpaces()
                if attrs.startsWith("bold", at: k, ignoreCase: true) { return true }
                if k + 2 < attrs.count, attrs[k] >= ch("6"), attrs[k] <= ch("9"), attrs[k + 1] == ch("0"),
                   attrs[k + 2] == ch("0") {
                    return true
                }
            }
            start = p + 1
        }
    }

    /// Java regex `\s`.
    private static func isRegexSpace(_ u: UInt16) -> Bool { u == 0x20 || (u >= 9 && u <= 13) }

    /// `(?is)<title[^<>]{0,200}>([^<]{0,300})</title>` in the first 64 KB of the page.
    private static func documentTitle(_ html: Units) -> String? {
        let head = Array(html.prefix(64 * 1024))
        var from = 0
        while true {
            let p = head.find("<title", from: from, ignoreCase: true)
            if p < 0 { return nil }
            from = p + 1
            var k = p + 6
            var run = 0
            while k < head.count, run < 200, head[k] != ch("<"), head[k] != ch(">") {
                k += 1
                run += 1
            }
            guard k < head.count, head[k] == ch(">") else { continue }
            let textStart = k + 1
            var e = textStart
            while e < head.count, e - textStart < 300, head[e] != ch("<") { e += 1 }
            guard head.startsWith("</title>", at: e, ignoreCase: true) else { continue }
            let text = kotlinTrim(head[textStart..<e])
            return text.isEmpty ? nil : decode(string(text))
        }
    }

    // MARK: Entities

    /// Replaces `&name;`, `&#123;` and `&#x1F;` (the regex `&(#[xX]?[0-9a-fA-F]+|[a-zA-Z]+);`); unknown ones stay.
    static func decode(_ s: String) -> String {
        let u = units(s)
        if !u.contains(ch("&")) { return s }
        var out: Units = []
        out.reserveCapacity(u.count)
        var i = 0
        while i < u.count {
            guard u[i] == ch("&"), let m = matchEntity(u, at: i) else {
                out.append(u[i])
                i += 1
                continue
            }
            out.append(contentsOf: replacement(for: m.body) ?? Array(u[i...m.end]))
            i = m.end + 1
        }
        return string(out)
    }

    /// Returns the text between '&' and ';' and the index of ';'.
    private static func matchEntity(_ u: Units, at i: Int) -> (body: String, end: Int)? {
        var j = i + 1
        guard j < u.count else { return nil }
        if u[j] == ch("#") {
            j += 1
            if j + 1 < u.count, u[j] == ch("x") || u[j] == ch("X"), isHexDigit(u[j + 1]) { j += 1 }
            let digitsStart = j
            while j < u.count, isHexDigit(u[j]) { j += 1 }
            guard j > digitsStart, j < u.count, u[j] == ch(";") else { return nil }
        } else {
            let nameStart = j
            while j < u.count, isAsciiLetter(u[j]) { j += 1 }
            guard j > nameStart, j < u.count, u[j] == ch(";") else { return nil }
        }
        return (string(u[(i + 1)..<j]), j)
    }

    private static func replacement(for body: String) -> Units? {
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            return Int32(body.dropFirst(2), radix: 16).flatMap { codePoint(Int($0)) }
        }
        if body.hasPrefix("#") {
            return Int32(body.dropFirst(1)).flatMap { codePoint(Int($0)) }
        }
        return named[body].map(units)
    }

    /// Kotlin `String(Character.toChars(cp))`, with "" for what Java rejects (and for lone surrogates).
    private static func codePoint(_ cp: Int) -> Units {
        guard cp >= 0, cp <= 0x10FFFF, let scalar = Unicode.Scalar(UInt32(cp)) else { return [] }
        return units(String(Character(scalar)))
    }
}
