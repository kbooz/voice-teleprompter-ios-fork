import Foundation
import SuflyorDomain

/// Paragraphs inside paragraphs (text boxes) are real but shallow; a crafted file could nest millions.
private let maxNestedParagraphs = 32

/// Stops a small, highly compressed document from unpacking into hundreds of megabytes of text before the length
/// check runs: the whole import may not produce more than twice the script limit.
private final class CharBudget {
    private var left = ImportLimits.maxChars * 2

    func take(_ n: Int) throws(ImportError) {
        left -= n
        if left < 0 { throw .textTooLong(kChars: nil, maxKChars: ImportLimits.maxChars / 1000) }
    }
}

/// One open paragraph (or heading) while its runs are read.
private final class Frame {
    var builder = ParagraphBuilder()
    var kind = ScriptParagraph.Kind.body
    var style: String?
    var outline: Int?
}

/// DOCX (Word 2007+): paragraphs, headings (by style or outline level) and bold runs; skips deleted and struck text.
enum DocxImporter {
    private static let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    /// "Strict" OOXML, written by Word when saving as "Strict Open XML Document".
    private static let wStrict = "http://purl.oclc.org/ooxml/wordprocessingml/main"
    private static let mc = "http://schemas.openxmlformats.org/markup-compatibility/2006"

    private static func isW(_ uri: String) -> Bool { uri == w || uri == wStrict }

    /// Tracked formatting changes keep the *old* formatting inside; it must not override the current one.
    private static let formatChanges: Set<String> = [
        "rPrChange", "pPrChange", "sectPrChange", "tblPrChange", "trPrChange", "tcPrChange", "tblGridChange",
        "numberingChange", "tblPrExChange",
    ]

    static func parse(_ data: Data, title: String) throws(ImportError) -> ImportedDocument {
        let parts = try ZipReading.read(data, names: ["word/document.xml", "word/styles.xml"])
        guard let document = parts["word/document.xml"] else { throw .notDocx }
        var headingIDs: Set<String> = []
        if let styles = parts["word/styles.xml"] { headingIDs = try headingStyles(styles) }
        let handler = DocumentHandler(headingStyles: headingIDs)
        try Sax.parse(document, handler: handler)
        let warnings: [ImportWarning] = handler.tables > 0 ? [.docxTables(count: handler.tables)] : []
        return ImportedDocument(title: title, format: "DOCX", paragraphs: handler.paragraphs, warnings: warnings)
    }

    private static func attr(_ attrs: XmlAttributes, _ name: String) -> String? {
        attrs.value(w, name) ?? attrs.value(wStrict, name)
    }

    private static func isOn(_ attrs: XmlAttributes) -> Bool {
        guard let v = attr(attrs, "val") else { return true }
        return !["0", "false", "off", "none"].contains(v)
    }

    /// Style ids that are headings: "heading N" / "Title" by name, or with an outline level. Russian Word uses ids
    /// like "1".
    private static func headingStyles(_ data: Data) throws(ImportError) -> Set<String> {
        let handler = StylesHandler()
        try Sax.parse(data, handler: handler)
        return handler.result
    }

    private final class StylesHandler: XmlHandler {
        var result: Set<String> = []
        var id: String?
        var isHeading = false

        override func start(uri: String, local: String, attrs: XmlAttributes) throws(ImportError) {
            if !DocxImporter.isW(uri) { return }
            switch local {
            case "style":
                id = DocxImporter.attr(attrs, "type") == "paragraph" ? DocxImporter.attr(attrs, "styleId") : nil
                isHeading = false
            case "name":
                let name = DocxImporter.attr(attrs, "val")?.lowercased() ?? ""
                if name.hasPrefix("heading") || name == "title" || name.hasPrefix("заголовок") { isHeading = true }
            case "outlineLvl":
                if (DocxImporter.attr(attrs, "val").flatMap { Int($0) } ?? 9) < 9 { isHeading = true }
            default:
                break
            }
        }

        override func end(uri: String, local: String) throws(ImportError) {
            if DocxImporter.isW(uri), local == "style" {
                if let id, isHeading { result.insert(id) }
                id = nil
            }
        }
    }

    private final class DocumentHandler: XmlHandler {
        let headingStyles: Set<String>
        var paragraphs: [ScriptParagraph] = []
        var tables = 0

        private var stack: [Frame] = []
        private var inText = false
        private var inPPr = false
        private var runBold = false
        private var runStruck = false
        private var skipDepth = 0
        private var changeDepth = 0
        private var pDepth = 0
        private let budget = CharBudget()

        init(headingStyles: Set<String>) { self.headingStyles = headingStyles }

        override func start(uri: String, local: String, attrs: XmlAttributes) throws(ImportError) {
            if uri == DocxImporter.mc, local == "Fallback" {
                skipDepth += 1
                return
            }
            if !DocxImporter.isW(uri) { return }
            if DocxImporter.formatChanges.contains(local) {
                changeDepth += 1
                return
            }
            if changeDepth > 0 { return }
            switch local {
            case "p":
                // Deeper paragraphs (only a crafted file nests them this far) join the innermost one.
                pDepth += 1
                if pDepth <= maxNestedParagraphs { stack.append(Frame()) }
            case "pPr":
                inPPr = true
            case "pStyle":
                if inPPr { stack.last?.style = DocxImporter.attr(attrs, "val") }
            case "outlineLvl":
                if inPPr { stack.last?.outline = DocxImporter.attr(attrs, "val").flatMap { Int($0) } }
            case "r":
                runBold = false
                runStruck = false
            case "b":
                if !inPPr { runBold = DocxImporter.isOn(attrs) }
            case "strike", "dstrike":
                if !inPPr { runStruck = DocxImporter.isOn(attrs) }
            case "t":
                inText = true
            case "tab", "br", "cr":
                if skipDepth == 0 { stack.last?.builder.append(" ") }
            case "noBreakHyphen":
                if skipDepth == 0 { stack.last?.builder.append("-") }
            case "del", "moveFrom":
                skipDepth += 1
            case "tbl":
                tables += 1
            default:
                break
            }
        }

        override func end(uri: String, local: String) throws(ImportError) {
            if uri == DocxImporter.mc, local == "Fallback" {
                skipDepth -= 1
                return
            }
            if !DocxImporter.isW(uri) { return }
            if DocxImporter.formatChanges.contains(local) {
                changeDepth -= 1
                return
            }
            if changeDepth > 0 { return }
            switch local {
            case "t":
                inText = false
            case "pPr":
                inPPr = false
            case "del", "moveFrom":
                skipDepth -= 1
            case "p":
                let wasDepth = pDepth
                pDepth -= 1
                if wasDepth > maxNestedParagraphs { return }
                guard let frame = stack.popLast() else { return }
                var heading = false
                if let style = frame.style {
                    heading = headingStyles.contains(style) || style.lowercased().hasPrefix("heading")
                }
                if let outline = frame.outline, outline < 9 { heading = true }
                if let p = frame.builder.build(kind: heading ? .heading : .body) { paragraphs.append(p) }
            default:
                break
            }
        }

        override func text(_ s: String) throws(ImportError) {
            if !inText || skipDepth > 0 || runStruck { return }
            try budget.take(s.utf16.count)
            stack.last?.builder.append(s, emphasized: runBold)
        }
    }
}

/// ODT (LibreOffice / Google Docs export): text:p and text:h, skipping footnotes, comments and tracked deletions.
enum OdtImporter {
    private static let textNS = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    private static let officeNS = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"

    static func parse(_ data: Data, title: String) throws(ImportError) -> ImportedDocument {
        guard let content = try ZipReading.read(data, names: ["content.xml"])["content.xml"] else { throw .notOdt }
        let handler = ContentHandler()
        try Sax.parse(content, handler: handler)
        return ImportedDocument(title: title, format: "ODT", paragraphs: handler.paragraphs)
    }

    private final class ContentHandler: XmlHandler {
        var paragraphs: [ScriptParagraph] = []
        private var stack: [Frame] = []
        private var skipDepth = 0
        private var depth = 0
        private let budget = CharBudget()

        /// Deleted text of tracked changes lives in text:tracked-changes; inserted text is already inline.
        private func skipped(_ uri: String, _ local: String) -> Bool {
            (uri == OdtImporter.textNS && (local == "note-body" || local == "tracked-changes")) ||
                (uri == OdtImporter.officeNS && local == "annotation")
        }

        override func start(uri: String, local: String, attrs: XmlAttributes) throws(ImportError) {
            if skipped(uri, local) {
                skipDepth += 1
            } else if uri == OdtImporter.textNS, local == "p" || local == "h" {
                depth += 1
                if depth <= maxNestedParagraphs {
                    let frame = Frame()
                    frame.kind = local == "h" ? .heading : .body
                    stack.append(frame)
                }
            } else if uri == OdtImporter.textNS, local == "s" || local == "tab" || local == "line-break" {
                if skipDepth == 0 { stack.last?.builder.append(" ") }
            }
        }

        override func end(uri: String, local: String) throws(ImportError) {
            if skipped(uri, local) {
                skipDepth -= 1
            } else if uri == OdtImporter.textNS, local == "p" || local == "h" {
                let wasDepth = depth
                depth -= 1
                if wasDepth > maxNestedParagraphs { return }
                guard let frame = stack.popLast() else { return }
                if let p = frame.builder.build(kind: frame.kind) { paragraphs.append(p) }
            }
        }

        override func text(_ s: String) throws(ImportError) {
            if skipDepth > 0 { return }
            try budget.take(s.utf16.count)
            stack.last?.builder.append(s)
        }
    }
}
