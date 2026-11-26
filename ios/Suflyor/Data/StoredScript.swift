import Foundation
import SuflyorDomain
import SwiftData

/// One script in the library (Android: one JSON file in `filesDir/scripts`). Keeps the imported paragraphs, so
/// the layout settings can change later without re-importing.
@Model
final class StoredScript {
    @Attribute(.unique) var id: String
    var title: String
    /// Format code: "TXT", "DOCX", ..., or `ImportedDocument.formatText` / `formatSample`.
    var format: String
    /// JSON of `[ScriptParagraph]`.
    var paragraphsData: Data
    /// `ImportWarning.code`s, as on Android.
    var warningCodes: [String]
    /// A `SpeechLanguage` code, nil = follow the default in Settings.
    var speechLanguageCode: String?
    var createdAt: Date
    var updatedAt: Date
    /// Spoken words, counted with the rules of `wordsLanguageCode`.
    var wordCount: Int
    var wordsLanguageCode: String

    init(
        id: String,
        document: ImportedDocument,
        createdAt: Date,
        updatedAt: Date,
        wordCount: Int,
        wordsLanguage: SpeechLanguage
    ) {
        self.id = id
        self.title = document.title
        self.format = document.format
        self.paragraphsData = Self.encode(document.paragraphs)
        self.warningCodes = document.warnings.map(\.code)
        self.speechLanguageCode = document.speechLanguage?.code
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.wordCount = wordCount
        self.wordsLanguageCode = wordsLanguage.code
    }

    /// Replaces the content, keeping `id` and `createdAt`.
    func apply(_ document: ImportedDocument, updatedAt: Date, wordCount: Int, wordsLanguage: SpeechLanguage) {
        title = document.title
        format = document.format
        paragraphsData = Self.encode(document.paragraphs)
        warningCodes = document.warnings.map(\.code)
        speechLanguageCode = document.speechLanguage?.code
        self.updatedAt = updatedAt
        self.wordCount = wordCount
        wordsLanguageCode = wordsLanguage.code
    }

    func makeDocument() -> ImportedDocument {
        let paragraphs = (try? JSONDecoder().decode([ScriptParagraph].self, from: paragraphsData)) ?? []
        return ImportedDocument(
            title: title,
            format: format,
            paragraphs: paragraphs,
            // Codes saved by a newer version of the app are skipped.
            warnings: warningCodes.compactMap { ImportWarning(code: $0) },
            speechLanguage: SpeechLanguage(code: speechLanguageCode)
        )
    }

    private static func encode(_ paragraphs: [ScriptParagraph]) -> Data {
        (try? JSONEncoder().encode(paragraphs)) ?? Data("[]".utf8)
    }
}
