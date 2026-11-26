import SuflyorDomain
import SwiftUI

/// Plain-text editor. Formatting is Markdown-light: `**bold**`, `# heading`, `[note that is not read]`
/// (Android: `EditorScreen`).
struct EditorView: View {
    let id: String?
    let speechLanguage: SpeechLanguage?

    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings

    @State private var title: String
    @State private var text: String
    /// Spoken words of the text as typed; -1 until counted.
    @State private var words = -1
    @State private var saving = false

    /// Android `DocumentImporter.MAX_CHARS`.
    private static let maxChars = 300_000

    init(id: String?, initialTitle: String, initialText: String, speechLanguage: SpeechLanguage?) {
        self.id = id
        self.speechLanguage = speechLanguage
        _title = State(initialValue: initialTitle)
        _text = State(initialValue: initialText)
    }

    private var canSave: Bool {
        !saving && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let wpm = settings.settings.autoScrollWpm
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField(L10n.text("editor_hint_title"), text: $title)
                        .font(.title2.weight(.semibold))
                        .submitLabel(.next)
                    Divider()
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(L10n.text("editor_hint_text"))
                                .font(.system(size: 18))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $text)
                            .font(.system(size: 18))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 320)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)

            VStack(alignment: .leading, spacing: 6) {
                if words >= 0 {
                    Text(L10n.text("editor_stats", wordsLabel(words), formatDuration(readingSeconds(words: words, wpm: wpm)), wpm))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(L10n.text("editor_syntax_help"))
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .navigationTitle(L10n.text(id == nil ? "editor_title_new" : "editor_title_edit"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.text("editor_action_done")) { save() }
                    .disabled(!canSave)
            }
        }
        // The count follows the typing after a pause, counted like the saved script, off the main actor.
        .task(id: text) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let snapshot = text
            let core = env.core
            let current = settings.settings
            let language = speechLanguage
            let count = await Task.detached(priority: .utility) {
                Self.countSpokenWords(snapshot, core: core, settings: current, language: language)
            }.value
            guard !Task.isCancelled else { return }
            words = count
        }
    }

    // MARK: - Save

    private func save() {
        guard canSave else { return }
        saving = true
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? L10n.text("common_untitled") : trimmed
        let snapshot = text
        let core = env.core
        let old = id.flatMap { library.document(id: $0) }
        Task {
            let paragraphs = await Task.detached(priority: .userInitiated) {
                core.parseMarkdown(snapshot, title: name)
            }.value
            saving = false
            let chars = paragraphs.reduce(0) { $0 + $1.text.utf16.count }
            if chars > Self.maxChars {
                env.showToast(ImportError.textTooLong(kChars: chars / 1000, maxKChars: Self.maxChars / 1000).message)
                return
            }
            let document = ImportedDocument(
                title: name,
                format: old?.format ?? ImportedDocument.formatText,
                paragraphs: paragraphs,
                warnings: [],
                speechLanguage: old?.speechLanguage ?? speechLanguage
            )
            guard !document.isEmpty else {
                env.showToast(L10n.text("main_no_words"))
                return
            }
            if let id {
                library.update(id, with: document)
                env.router.pop()
            } else if let newID = library.add(document) {
                env.openScript(newID)
            }
        }
    }

    /// Words that will be read aloud, with the rules of the script's speech language (headings and [notes] don't count).
    nonisolated private static func countSpokenWords(
        _ text: String,
        core: KMPScriptCore,
        settings: PrompterSettings,
        language: SpeechLanguage?
    ) -> Int {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
        let paragraphs = core.parseMarkdown(text, title: "")
        let document = ImportedDocument(
            title: "",
            format: ImportedDocument.formatText,
            paragraphs: paragraphs,
            speechLanguage: language
        )
        let resolved = settings.resolvedLanguage(for: document, core: core)
        return core.prepare(
            title: "",
            paragraphs: paragraphs,
            language: resolved,
            phraseMode: false,
            maxWords: settings.maxWords
        ).spokenWords
    }
}
