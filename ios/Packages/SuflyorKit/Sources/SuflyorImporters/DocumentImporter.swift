import Foundation
import SuflyorDomain
import UniformTypeIdentifiers

/// Imports any supported file or pasted text into an `ImportedDocument` (port of Kotlin `DocumentImporter`):
/// picks the importer by file content first (magic bytes), then by extension / content type. Markdown goes through the
/// shared core (`ScriptCoreProviding.parseMarkdown`), everything else is parsed here.
public struct DocumentImporter: Sendable {
    private let core: any ScriptCoreProviding

    public init(core: any ScriptCoreProviding) {
        self.core = core
    }

    /// Types offered in the file picker and the Share extension.
    public static var supportedContentTypes: [UTType] {
        let candidates: [UTType?] = [
            UTType.plainText,
            UTType.pdf,
            UTType.rtf,
            UTType.html,
            UTType("net.daringfireball.markdown"),
            UTType("org.openxmlformats.wordprocessingml.document"),
            UTType("org.oasis-open.opendocument.text"),
            UTType(filenameExtension: "docx"),
            UTType(filenameExtension: "odt"),
            UTType(filenameExtension: "md"),
            // A library backup (ScriptArchive) is a zip of Markdown files.
            UTType.zip,
        ]
        var seen = Set<String>()
        var result: [UTType] = []
        for case let type? in candidates where seen.insert(type.identifier).inserted { result.append(type) }
        return result
    }

    enum Kind: Equatable {
        case txt, markdown, docx, odt, rtf, html, pdf, legacyDoc, encryptedOffice, unknownZip
    }

    /// `fileName` gives the extension and the default title; `contentType` is the UTType identifier when known.
    public func importFile(data: Data, fileName: String, contentType: String?) throws(ImportError) -> ImportedDocument {
        let bytes = [UInt8](data)
        if bytes.isEmpty { throw .emptyFile }
        if bytes.count > ImportLimits.maxBytes { throw .fileTooBig(maxMb: ImportLimits.maxMb) }
        let name = Self.baseName(fileName)
        let title = Self.titleFrom(name) ?? L10n.text("common_untitled")
        let kind = Self.detect(data: data, bytes: bytes, fileName: name, contentType: contentType)
        // RTF and HTML carry pictures inline (hex, base64), so only plain text formats get the tighter limit;
        // their parsers skip the pictures in one linear pass and the extracted text is capped by maxChars.
        let limit: Int
        switch kind {
        case .txt, .markdown: limit = ImportLimits.maxTextBytes
        case .html: limit = ImportLimits.maxMarkupBytes
        default: limit = ImportLimits.maxBytes
        }
        if bytes.count > limit { throw .textFileTooBig }

        let doc: ImportedDocument
        switch kind {
        case .pdf: doc = try PdfImporter.extract(data, title: title)
        case .docx: doc = try DocxImporter.parse(data, title: title)
        case .odt: doc = try OdtImporter.parse(data, title: title)
        case .rtf: doc = try RtfImporter.parse(data, title: title)
        case .html: doc = HtmlImporter.parse(TextDecoding.decode(data), title: title)
        case .markdown: doc = parseMarkdown(TextDecoding.decode(data), title: title)
        case .txt: doc = PlainTextImporter.parse(try Self.requireText(TextDecoding.decode(data)), title: title)
        case .legacyDoc: throw .legacyDoc
        case .encryptedOffice: throw .encryptedOffice
        case .unknownZip: throw .unknownZip
        }
        if doc.isEmpty { throw .noText }
        return try Self.checkSize(doc)
    }

    /// Pasted or shared text. Markdown-looking text goes through the Markdown parser, anything else through the plain
    /// text rules. The result can be empty (blank text): the caller decides what to tell the user.
    public func importPastedText(_ text: String, title: String?) throws(ImportError) -> ImportedDocument {
        let name = title.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("import_title_clipboard")
        if text.utf16.count > ImportLimits.maxChars * 2 { throw .pastedTextTooLong }
        let doc = Self.looksLikeMarkdown(units(text))
            ? parseMarkdown(text, title: name)
            : PlainTextImporter.parse(text, title: name)
        return try Self.checkSize(doc)
    }

    // MARK: Internals

    func parseMarkdown(_ text: String, title: String) -> ImportedDocument {
        ImportedDocument(title: title, format: "Markdown", paragraphs: core.parseMarkdown(text, title: title))
    }

    /// File name without any folder part.
    static func baseName(_ fileName: String) -> String {
        String(fileName.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
    }

    /// `substringBeforeLast('.')`, blank -> nil.
    static func titleFrom(_ name: String) -> String? {
        let stem: String
        if let dot = name.lastIndex(of: ".") { stem = String(name[..<dot]) } else { stem = name }
        return isKotlinBlank(units(stem)) ? nil : stem
    }

    static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    static func detect(data: Data, bytes: [UInt8], fileName: String, contentType: String?) -> Kind {
        let ext = fileExtension(fileName)
        func starts(_ sig: [UInt8]) -> Bool { bytes.count >= sig.count && Array(bytes[0..<sig.count]) == sig }
        if starts([0x25, 0x50, 0x44, 0x46]) { return .pdf } // %PDF
        if starts([0xD0, 0xCF, 0x11, 0xE0]) { return isEncryptedOffice(bytes) ? .encryptedOffice : .legacyDoc }
        if starts([0x50, 0x4B, 0x03, 0x04]) {
            let names = ZipReading.entryNames(data)
            if names.contains("word/document.xml") { return .docx }
            if names.contains("content.xml") { return .odt }
            return .unknownZip
        }
        if starts([0x7B, 0x5C, 0x72, 0x74, 0x66]) { return .rtf } // {\rtf
        let mime = contentType.flatMap { UTType($0)?.preferredMIMEType }
        if ["md", "markdown", "mdown", "mkd"].contains(ext) || mime == "text/markdown" || mime == "text/x-markdown" ||
            contentType == "net.daringfireball.markdown" {
            return .markdown
        }
        if ["html", "htm", "xhtml"].contains(ext) || mime == "text/html" || contentType == "public.html" {
            return .html
        }
        // The first 512 bytes as ISO-8859-1 (one byte, one character), leading whitespace dropped.
        let head = bytes[0..<min(bytes.count, 512)].map { UInt16($0) }
        let rest = Array(head.drop(while: isKotlinWhitespace))
        if rest.startsWith("<!doctype html", at: 0, ignoreCase: true) || rest.startsWith("<html", at: 0, ignoreCase: true) {
            return .html
        }
        return .txt
    }

    /// Password-protected DOCX/XLSX are OLE2 containers with an "EncryptedPackage" stream (UTF-16LE name).
    static func isEncryptedOffice(_ bytes: [UInt8]) -> Bool {
        let marker = Array("EncryptedPackage".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let limit = min(bytes.count, 256 * 1024) - marker.count
        if limit < 0 { return false }
        var i = 0
        while i <= limit {
            if bytes[i] == marker[0] {
                var k = 1
                while k < marker.count, bytes[i + k] == marker[k] { k += 1 }
                if k == marker.count { return true }
            }
            i += 1
        }
        return false
    }

    /// A "text" file that is mostly control characters is a binary file with an unknown extension.
    static func requireText(_ text: String) throws(ImportError) -> String {
        let head = Array(text.utf16.prefix(8192))
        if head.isEmpty { return text }
        var controls = 0
        var hasNul = false
        for c in head {
            if c == 0 { hasNul = true }
            if c < 0x20, c != 0x0A, c != 0x0D, c != 0x09 { controls += 1 }
        }
        if hasNul || controls * 20 > head.count { throw .notText }
        return text
    }

    static func checkSize(_ doc: ImportedDocument) throws(ImportError) -> ImportedDocument {
        let chars = doc.paragraphs.reduce(0) { $0 + $1.text.utf16.count }
        if chars > ImportLimits.maxChars {
            throw .textTooLong(kChars: chars / 1000, maxKChars: ImportLimits.maxChars / 1000)
        }
        return doc
    }

    /// Kotlin `Regex("(?m)^(#{1,6} |[-*] |> )|\\*\\*[^*\\n]{1,500}\\*\\*")`, linear.
    static func looksLikeMarkdown(_ t: Units) -> Bool {
        func isLineTerminator(_ u: UInt16) -> Bool { u == 0x0A || u == 0x0D || u == 0x85 || u == 0x2028 || u == 0x2029 }
        var i = 0
        while i < t.count {
            // `^` in multiline mode: start of text, or after a line terminator (not between CR and LF).
            let atLineStart = i == 0 || (isLineTerminator(t[i - 1]) && !(t[i - 1] == 0x0D && t[i] == 0x0A))
            if atLineStart {
                var j = i
                while j < t.count, t[j] == ch("#"), j - i < 6 { j += 1 }
                if j > i, j < t.count, t[j] == 0x20 { return true }
                if i + 1 < t.count, t[i + 1] == 0x20, t[i] == ch("-") || t[i] == ch("*") || t[i] == ch(">") {
                    return true
                }
            }
            if t[i] == ch("*"), i + 1 < t.count, t[i + 1] == ch("*") {
                var j = i + 2
                while j < t.count, j - (i + 2) < 500, t[j] != ch("*"), t[j] != 0x0A { j += 1 }
                if j > i + 2, j + 1 < t.count, t[j] == ch("*"), t[j + 1] == ch("*") { return true }
            }
            i += 1
        }
        return false
    }
}
