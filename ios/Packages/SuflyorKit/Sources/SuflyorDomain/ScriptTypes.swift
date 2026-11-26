import Foundation

/// A range of UTF-16 code units: `start` inclusive, `end` exclusive.
///
/// Kotlin strings are indexed in UTF-16 code units, so every offset that crosses the Kotlin/Swift boundary (emphasis,
/// notes, token positions in `PreparedScript.displayText`) uses this unit. Convert with `NSRange` or
/// `String.utf16` views, never with `String.Index` offsets on characters.
public struct TextRange: Codable, Hashable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public var length: Int { end - start }
    public var nsRange: NSRange { NSRange(location: start, length: end - start) }
    public func contains(_ offset: Int) -> Bool { offset >= start && offset < end }
}

/// One paragraph of an imported script (Kotlin: `doc.Paragraph`).
public struct ScriptParagraph: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case heading
        case body
    }

    public var text: String
    public var kind: Kind
    /// Emphasized character ranges of `text` (bold in DOCX/MD/RTF, ==highlight== in Obsidian), in UTF-16 units.
    public var emphasis: [TextRange]

    public init(text: String, kind: Kind = .body, emphasis: [TextRange] = []) {
        self.text = text
        self.kind = kind
        self.emphasis = emphasis
    }
}

/// Something to check after an import, shown under the script. Stored by `code`, exactly as Android stores it.
public enum ImportWarning: Hashable, Sendable {
    case pdfParagraphsRebuilt
    /// DOCX tables come out as their cells in reading order.
    case docxTables(count: Int)
    /// A warning saved by an old Android version as a sentence: shown as it is.
    case raw(String)

    public var code: String {
        switch self {
        case .pdfParagraphsRebuilt: "pdf_paragraphs"
        case .docxTables(let count): "docx_tables:\(count)"
        case .raw(let text): "raw:\(text)"
        }
    }

    /// Nil for a code this version doesn't know (saved by a newer one).
    public init?(code: String) {
        if code == "pdf_paragraphs" {
            self = .pdfParagraphsRebuilt
        } else if code.hasPrefix("docx_tables:"), let n = Int(code.dropFirst("docx_tables:".count)) {
            self = .docxTables(count: n)
        } else if code.hasPrefix("raw:") {
            self = .raw(String(code.dropFirst("raw:".count)))
        } else {
            return nil
        }
    }
}

/// Why an import failed (Kotlin: `doc.ImportError`). The UI turns a case into text with `L10n`.
public enum ImportError: Error, Hashable, Sendable {
    case emptyFile
    case fileTooBig(maxMb: Int)
    case textFileTooBig
    case legacyDoc
    case encryptedOffice
    case unknownZip
    case noText
    case notText
    case pastedTextTooLong
    /// `kChars` is known when the whole text was extracted, nil when extraction stopped early at the limit.
    case textTooLong(kChars: Int?, maxKChars: Int)
    case notRtf
    case zipTooManyFiles
    case zipTooLarge
    case unsafeDocument
    case notDocx
    case notOdt
    case pdfUnsupported
    case pdfPassword
    case pdfNoTextLayer
    /// The app handing the document over gave nothing to read.
    case cannotOpen
}

/// Result of importing any file (Kotlin: `doc.ScriptDocument`).
public struct ImportedDocument: Hashable, Sendable {
    /// `format` of scripts that don't come from a file; shown translated.
    public static let formatText = "TEXT"
    public static let formatSample = "SAMPLE"

    public var title: String
    /// The same format codes the Android importers write ("TXT", "Markdown", "DOCX", "PDF", ...).
    public var format: String
    public var paragraphs: [ScriptParagraph]
    public var warnings: [ImportWarning]
    /// Speech language chosen for this script; nil follows the default in Settings.
    public var speechLanguage: SpeechLanguage?

    public init(
        title: String,
        format: String,
        paragraphs: [ScriptParagraph],
        warnings: [ImportWarning] = [],
        speechLanguage: SpeechLanguage? = nil
    ) {
        self.title = title
        self.format = format
        self.paragraphs = paragraphs
        self.warnings = warnings
        self.speechLanguage = speechLanguage
    }

    public var isEmpty: Bool {
        paragraphs.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// Speech languages the tracker understands (Kotlin: `script.SpeechLang`, same codes and labels).
public enum SpeechLanguage: String, CaseIterable, Codable, Hashable, Sendable {
    case ru, en, tr, pt, es, de, fr, it, nl, sv, he, ar, ko, zh

    public var code: String { rawValue }

    /// The language's own name, as on Android.
    public var label: String {
        switch self {
        case .ru: "Русский"
        case .en: "English"
        case .tr: "Türkçe"
        case .pt: "Português"
        case .es: "Español"
        case .de: "Deutsch"
        case .fr: "Français"
        case .it: "Italiano"
        case .nl: "Nederlands"
        case .sv: "Svenska"
        case .he: "עברית"
        case .ar: "العربية (مصر)"
        case .ko: "한국어"
        case .zh: "中文"
        }
    }

    /// Models the Android full APK bundles; on iOS they may be bundled too (full build) or come as packs (lite).
    public var hasBundledModelOnAndroid: Bool { self == .ru || self == .en || self == .tr }

    public init?(code: String?) {
        guard let code, let lang = SpeechLanguage(rawValue: code) else { return nil }
        self = lang
    }
}
