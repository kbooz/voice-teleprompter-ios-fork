import Foundation
import Observation
import SuflyorDomain
import SwiftData

/// The library of scripts and the current one (Android: `ScriptRepository`). Everything runs on the main actor, where
/// the SwiftData main context lives; scripts are small, so a fetch per action is cheap.
@MainActor @Observable
final class LibraryStore {
    /// What the list shows. Reading the paragraphs is left to `document(id:)`.
    struct Summary: Identifiable, Hashable {
        var id: String
        var title: String
        var format: String
        var words: Int
        var updatedAt: Date
    }

    private(set) var items: [Summary] = []
    private(set) var currentID: String?
    private(set) var current: ImportedDocument?
    /// The current script laid out with the current settings; also what the session follows.
    private(set) var prepared: PreparedScript?
    /// Set when a save failed; the UI shows it and clears it.
    var saveError: String?

    /// Hands every new layout of the current script to the session.
    @ObservationIgnored var onPrepared: (@MainActor (PreparedScript) -> Void)?

    /// Keeps the store alive: a `ModelContext` holds its container only weakly, so without this reference the
    /// container is freed once `AppEnvironment.init` returns and the next fetch traps inside SwiftData.
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let core: any ScriptCoreProviding
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let defaults: UserDefaults
    private static let currentKey = "suflyor.currentScriptID"

    init(
        container: ModelContainer,
        core: any ScriptCoreProviding,
        settings: SettingsStore,
        defaults: UserDefaults = .standard
    ) {
        self.container = container
        self.context = container.mainContext
        self.core = core
        self.settingsStore = settings
        self.defaults = defaults
        reload()
        if items.isEmpty { seedSample() }
        recountStale()
        let saved = defaults.string(forKey: Self.currentKey)
        let start = items.first { $0.id == saved }?.id ?? items.first?.id
        if let start { select(start) }
    }

    // MARK: - Reading

    func document(id: String) -> ImportedDocument? {
        if id == currentID, let current { return current }
        return fetch(id)?.makeDocument()
    }

    /// Every script, newest first: what a backup archive holds.
    func allDocuments() -> [ImportedDocument] {
        items.compactMap { document(id: $0.id) }
    }

    // MARK: - Changing

    @discardableResult
    func select(_ id: String) -> Bool {
        guard let row = fetch(id) else { return false }
        currentID = id
        defaults.set(id, forKey: Self.currentKey)
        current = row.makeDocument()
        relayout()
        return true
    }

    /// Adds a script and makes it current. Returns its id, or nil when it could not be saved (`saveError` says why).
    func add(_ document: ImportedDocument) -> String? {
        guard let id = insert(document, at: Date()) else { return nil }
        reload()
        select(id)
        return id
    }

    /// Adds several scripts (a restored backup) without changing the current one. Later files get older timestamps,
    /// so the archive's order is kept at the top of the library. Returns how many were saved.
    func addAll(_ documents: [ImportedDocument]) -> Int {
        let now = Date()
        var saved = 0
        for (index, document) in documents.enumerated() {
            let date = now.addingTimeInterval(-Double(index) * 0.001)
            if insert(document, at: date) != nil { saved += 1 }
        }
        reload()
        return saved
    }

    func update(_ id: String, with document: ImportedDocument) {
        guard let row = fetch(id) else { return }
        let (words, language) = countWords(document)
        row.apply(document, updatedAt: Date(), wordCount: words, wordsLanguage: language)
        guard save() else { return }
        reload()
        if id == currentID {
            current = document
            relayout()
        }
    }

    /// A copy next to the original, for trying another version of the text. Returns the copy's id.
    func duplicate(_ id: String) -> String? {
        guard var copy = document(id: id) else { return nil }
        copy.title = L10n.text("script_copy_title", copy.title)
        return add(copy)
    }

    func delete(_ id: String) {
        if let row = fetch(id) {
            context.delete(row)
            guard save() else { return }
        }
        reload()
        if items.isEmpty { seedSample() }
        if id == currentID {
            if let next = items.first?.id {
                select(next)
            } else {
                // Storage is broken: show something from memory rather than nothing.
                currentID = nil
                current = sampleDocument()
                relayout()
            }
        }
    }

    /// One script's speech language, nil = follow the default in Settings.
    func setSpeechLanguage(_ id: String, to language: SpeechLanguage?) {
        guard var document = document(id: id), document.speechLanguage != language else { return }
        document.speechLanguage = language
        update(id, with: document)
    }

    /// Rebuilds the layout of the current script after the layout settings change.
    func relayout() {
        guard let document = current else {
            prepared = nil
            return
        }
        let s = settingsStore.settings
        let script = core.prepare(
            title: document.title,
            paragraphs: document.paragraphs,
            language: s.resolvedLanguage(for: document, core: core),
            phraseMode: s.phraseMode,
            maxWords: s.maxWords
        )
        prepared = script
        onPrepared?(script)
    }

    /// After the speech language setting changes: the library word counts follow it (the rules of "don't" differ).
    func recountAll() {
        recountStale()
        reload()
    }

    // MARK: - Storage

    private func fetch(_ id: String) -> StoredScript? {
        var descriptor = FetchDescriptor<StoredScript>(predicate: #Predicate<StoredScript> { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func reload() {
        let descriptor = FetchDescriptor<StoredScript>(sortBy: [SortDescriptor(\StoredScript.updatedAt, order: .reverse)])
        do {
            items = try context.fetch(descriptor).map {
                Summary(id: $0.id, title: $0.title, format: $0.format, words: $0.wordCount, updatedAt: $0.updatedAt)
            }
        } catch {
            Journal.shared.error("Couldn't read the library", error)
        }
    }

    private func insert(_ document: ImportedDocument, at date: Date) -> String? {
        let (words, language) = countWords(document)
        let id = UUID().uuidString
        let row = StoredScript(
            id: id,
            document: document,
            createdAt: date,
            updatedAt: date,
            wordCount: words,
            wordsLanguage: language
        )
        context.insert(row)
        return save() ? id : nil
    }

    private func save() -> Bool {
        do {
            try context.save()
            return true
        } catch {
            // Never the script's text: only the error's class and message.
            Journal.shared.error("Couldn't save script", error)
            saveError = L10n.text("library_save_failed", error.localizedDescription)
            context.rollback()
            return false
        }
    }

    /// Counted with the speech language's rules: "don't" is one English word, not two.
    private func countWords(_ document: ImportedDocument) -> (Int, SpeechLanguage) {
        let s = settingsStore.settings
        let language = s.resolvedLanguage(for: document, core: core)
        let script = core.prepare(
            title: document.title,
            paragraphs: document.paragraphs,
            language: language,
            phraseMode: false,
            maxWords: s.maxWords
        )
        return (script.spokenWords, language)
    }

    /// Recounts the scripts counted with another language than the one that applies now. Keeps the order.
    private func recountStale() {
        guard let rows = try? context.fetch(FetchDescriptor<StoredScript>()) else { return }
        var changed = false
        for row in rows {
            let document = row.makeDocument()
            let language = settingsStore.settings.resolvedLanguage(for: document, core: core)
            guard row.wordsLanguageCode != language.code else { continue }
            let (words, counted) = countWords(document)
            row.wordCount = words
            row.wordsLanguageCode = counted.code
            changed = true
        }
        if changed { _ = save() }
    }

    // MARK: - Sample

    /// Created in the UI language of the moment and saved like any script: it doesn't change with the language later.
    private func sampleDocument() -> ImportedDocument {
        let title = L10n.text("sample_title")
        // The Android resource keeps its line breaks as \n escapes.
        let text = L10n.text("sample_script").replacingOccurrences(of: "\\n", with: "\n")
        return ImportedDocument(
            title: title,
            format: ImportedDocument.formatSample,
            paragraphs: core.parseMarkdown(text, title: title)
        )
    }

    private func seedSample() {
        _ = insert(sampleDocument(), at: Date())
        reload()
    }
}
