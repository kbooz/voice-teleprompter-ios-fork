import Foundation
import SuflyorDomain

// Ported from Android's ui/Messages.kt and the helpers of ui/Components.kt.

extension ImportError {
    /// No `default`: a new import error doesn't compile until it has a message.
    var message: String {
        switch self {
        case .emptyFile: L10n.text("import_error_empty_file")
        case .fileTooBig(let maxMb): L10n.text("import_error_file_too_big", maxMb)
        case .textFileTooBig: L10n.text("import_error_text_file_too_big")
        case .legacyDoc: L10n.text("import_error_legacy_doc")
        case .encryptedOffice: L10n.text("import_error_encrypted")
        case .unknownZip: L10n.text("import_error_unknown_zip")
        case .noText: L10n.text("import_error_no_text")
        case .notText: L10n.text("import_error_not_text")
        case .pastedTextTooLong: L10n.text("import_error_pasted_too_long")
        case .textTooLong(let kChars, let maxKChars):
            if let kChars {
                L10n.text("import_error_text_too_long_count", kChars, maxKChars)
            } else {
                L10n.text("import_error_text_too_long_max", maxKChars)
            }
        case .notRtf: L10n.text("import_error_not_rtf")
        case .zipTooManyFiles: L10n.text("import_error_zip_too_many_files")
        case .zipTooLarge: L10n.text("import_error_zip_too_large")
        case .unsafeDocument: L10n.text("import_error_unsafe")
        case .notDocx: L10n.text("import_error_not_docx")
        case .notOdt: L10n.text("import_error_not_odt")
        case .pdfUnsupported: L10n.text("import_error_pdf_unsupported")
        case .pdfPassword: L10n.text("import_error_pdf_password")
        case .pdfNoTextLayer: L10n.text("import_error_pdf_scan")
        case .cannotOpen: L10n.text("import_error_open_failed")
        }
    }
}

extension ImportWarning {
    var message: String {
        switch self {
        case .pdfParagraphsRebuilt: L10n.text("import_warning_pdf_paragraphs")
        // A plural: the String Catalog picks the form for `count`.
        case .docxTables(let count): L10n.text("import_warning_docx_tables", count)
        case .raw(let text): text
        }
    }
}

/// Format shown next to a script: typed and built-in scripts are translated, file formats (DOCX, PDF...) are not.
func formatLabel(_ format: String) -> String {
    switch format {
    case ImportedDocument.formatText: L10n.text("format_typed")
    case ImportedDocument.formatSample: L10n.text("format_sample")
    default: format
    }
}

/// "3 words", with the plural of the app's language.
func wordsLabel(_ count: Int) -> String {
    L10n.text("words_count", count)
}

/// "2:05".
func formatDuration(_ seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
}

/// Seconds to read `words` at `wpm`, rounded up: the same formula as `PreparedScript.durationSeconds(wpm:)`.
func readingSeconds(words: Int, wpm: Int) -> Int {
    wpm <= 0 ? 0 : (words * 60 + wpm - 1) / wpm
}

/// A language's name for running text, in the app's language: "Portuguese", "португальский".
func speechLanguageDisplayName(_ language: SpeechLanguage) -> String {
    let locale = Locale.current
    guard let name = locale.localizedString(forLanguageCode: language.code) else { return language.label }
    // Russian and Turkish write language names in lowercase in running text, like the built-in strings.
    let appLanguage = locale.language.languageCode?.identifier
    if appLanguage == "en" || appLanguage == "pt" {
        return name.prefix(1).uppercased() + name.dropFirst()
    }
    return name
}

/// "Portuguese" / "Português · Portuguese": the language's own name, plus the app-language name when it differs.
func speechLanguageTitle(_ language: SpeechLanguage) -> String {
    let name = speechLanguageDisplayName(language)
    return name.caseInsensitiveCompare(language.label) == .orderedSame ? language.label : "\(language.label) · \(name)"
}

extension ImportedDocument {
    /// The editor's Markdown-light text: `# heading`, `**emphasis**`, paragraphs separated by a blank line
    /// (Android: `ScriptDocument.toEditableText`).
    func toEditableText() -> String {
        paragraphs.map { paragraph -> String in
            switch paragraph.kind {
            case .heading:
                return "# " + paragraph.text
            case .body:
                // Emphasis ranges are UTF-16 offsets: cut through NSString, not Character indices.
                let text = paragraph.text as NSString
                var out = ""
                var last = 0
                for range in paragraph.emphasis.sorted(by: { $0.start < $1.start }) {
                    guard range.start >= last, range.end > range.start, range.end <= text.length else { continue }
                    out += text.substring(with: NSRange(location: last, length: range.start - last))
                    out += "**" + text.substring(with: range.nsRange) + "**"
                    last = range.end
                }
                out += text.substring(from: last)
                return out
            }
        }
        .joined(separator: "\n\n")
    }
}
