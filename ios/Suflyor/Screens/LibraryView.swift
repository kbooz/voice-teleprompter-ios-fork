import SuflyorDomain
import SuflyorImporters
import SwiftUI
import UniformTypeIdentifiers

/// The list of scripts (Android: `LibraryScreen`).
struct LibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(LibraryStore.self) private var library
    @Environment(SettingsStore.self) private var settings

    @State private var query = ""
    @State private var showAdd = false
    @State private var showRestore = false
    @State private var backup: BackupFile?
    @State private var showBackupExporter = false

    private var visibleItems: [LibraryStore.Summary] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? library.items : library.items.filter { $0.title.localizedStandardContains(text) }
    }

    var body: some View {
        let wpm = settings.settings.autoScrollWpm
        List {
            if !env.readiness.isComplete {
                Section {
                    ReadinessBanner { env.router.path.append(.settingsPage(.readiness)) }
                }
            }
            Section {
                ForEach(visibleItems) { item in
                    Button { env.openScript(item.id) } label: {
                        ScriptRow(item: item, isCurrent: item.id == library.currentID, wpm: wpm)
                    }
                    .tint(.primary)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { library.delete(item.id) } label: {
                            Label(L10n.text("common_delete"), systemImage: "trash")
                        }
                        Button { duplicate(item.id) } label: {
                            Label(L10n.text("script_cd_duplicate"), systemImage: "plus.square.on.square")
                        }
                        .tint(.indigo)
                    }
                }
            }
            if visibleItems.isEmpty {
                Text(L10n.text("library_search_empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(L10n.text("library_title"))
        .searchable(text: $query, prompt: L10n.text("library_search_hint"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { env.router.path.append(.settings) } label: {
                    Label(L10n.text("settings_title"), systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { prepareBackup() } label: {
                        Label(L10n.text("settings_backup_title"), systemImage: "square.and.arrow.down")
                    }
                    Button { showRestore = true } label: {
                        Label(L10n.text("settings_restore_title"), systemImage: "arrow.counterclockwise")
                    }
                } label: {
                    Label(L10n.text("library_cd_menu"), systemImage: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: {
                    Label(L10n.text("library_cd_add"), systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddScriptSheet()
                .presentationDetents([.medium])
        }
        .scriptFileImporter(isPresented: $showRestore, zipOnly: true)
        .backupExporter(isPresented: $showBackupExporter, file: backup)
    }

    private func duplicate(_ id: String) {
        if let copy = library.duplicate(id) { env.openScript(copy) }
    }

    private func prepareBackup() {
        guard let made = env.makeBackup() else { return }
        backup = BackupFile(data: made.data, count: made.count)
        showBackupExporter = true
    }
}

private struct ScriptRow: View {
    let item: LibraryStore.Summary
    let isCurrent: Bool
    let wpm: Int

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                Text("\(formatLabel(item.format)) · \(wordsLabel(item.words)) · ≈\(formatDuration(readingSeconds(words: item.words, wpm: wpm)))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isCurrent {
                Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}

/// "Set up recording": shown while a permission or a speech pack is missing.
private struct ReadinessBanner: View {
    @Environment(AppEnvironment.self) private var env
    let action: () -> Void

    var body: some View {
        let readiness = env.readiness
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "checklist")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("ios_app_setup_title"))
                        .font(.headline)
                    Text(L10n.text("ios_app_setup_progress", readiness.doneCount, Readiness.total))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .tint(.primary)
    }
}

/// "New script": file, clipboard, write, backup (Android: the bottom sheet of the library).
private struct AddScriptSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var showFiles = false
    @State private var showArchive = false

    var body: some View {
        NavigationStack {
            List {
                action("doc", L10n.text("library_add_file"), "DOCX, PDF, TXT, Markdown, RTF, ODT, HTML") { showFiles = true }
                // The system's own paste button reads the clipboard without the "Allow Paste" prompt.
                HStack(spacing: 14) {
                    Image(systemName: "doc.on.clipboard")
                        .frame(width: 28)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("library_add_paste")).font(.headline)
                        Text(L10n.text("library_add_paste_hint")).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    PasteButton(payloadType: String.self) { strings in
                        let text = strings.joined(separator: "\n")
                        Task { @MainActor in
                            dismiss()
                            await env.importPastedText(text)
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                }
                action("square.and.pencil", L10n.text("library_add_write"), L10n.text("library_add_write_hint")) {
                    dismiss()
                    env.router.path.append(.editor(nil))
                }
                action("arrow.counterclockwise", L10n.text("library_add_archive"), L10n.text("library_add_archive_hint")) {
                    showArchive = true
                }
            }
            .navigationTitle(L10n.text("library_add_title"))
            .navigationBarTitleDisplayMode(.inline)
            .scriptFileImporter(isPresented: $showFiles, zipOnly: false, onDone: { dismiss() })
            .scriptFileImporter(isPresented: $showArchive, zipOnly: true, onDone: { dismiss() })
        }
    }

    private func action(_ symbol: String, _ title: String, _ subtitle: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .frame(width: 28)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .tint(.primary)
    }
}

// MARK: - File picker and backup exporter

extension View {
    /// The file picker for scripts and backups. Imports every picked file; `zipOnly` offers only archives.
    func scriptFileImporter(isPresented: Binding<Bool>, zipOnly: Bool, onDone: @escaping @MainActor () -> Void = {}) -> some View {
        modifier(ScriptFileImporter(isPresented: isPresented, zipOnly: zipOnly, onDone: onDone))
    }

    func backupExporter(isPresented: Binding<Bool>, file: BackupFile?) -> some View {
        modifier(BackupExporter(isPresented: isPresented, file: file))
    }
}

private struct ScriptFileImporter: ViewModifier {
    @Binding var isPresented: Bool
    let zipOnly: Bool
    let onDone: @MainActor () -> Void
    @Environment(AppEnvironment.self) private var env

    func body(content: Content) -> some View {
        let env = self.env
        let onDone = self.onDone
        content.fileImporter(
            isPresented: $isPresented,
            allowedContentTypes: zipOnly ? [.zip] : DocumentImporter.supportedContentTypes + [.zip],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { @MainActor in
                    onDone()
                    await env.importFiles(urls)
                }
            case .failure(let error):
                Task { @MainActor in
                    Journal.shared.error("File picker failed", error)
                    env.showToast(ImportError.cannotOpen.message)
                }
            }
        }
    }
}

/// A backup zip waiting to be saved with the system's file exporter.
struct BackupFile: FileDocument {
    static let readableContentTypes: [UTType] = [.zip]
    let data: Data
    let count: Int

    init(data: Data, count: Int) {
        self.data = data
        self.count = count
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        count = 0
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct BackupExporter: ViewModifier {
    @Binding var isPresented: Bool
    let file: BackupFile?
    @Environment(AppEnvironment.self) private var env

    func body(content: Content) -> some View {
        let env = self.env
        let count = file?.count ?? 0
        content.fileExporter(
            isPresented: $isPresented,
            document: file,
            contentType: .zip,
            defaultFilename: Self.fileName()
        ) { result in
            Task { @MainActor in
                switch result {
                case .success:
                    Journal.shared.info("Backup saved: \(count) scripts")
                    env.showToast(L10n.text("backup_saved", count))
                case .failure(let error):
                    Journal.shared.error("Backup failed", error)
                    env.showToast(L10n.text("backup_failed", error.localizedDescription))
                }
            }
        }
    }

    /// "suflyor-scripts-2026-11-26", like Android's archive name.
    private static func fileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "suflyor-scripts-" + formatter.string(from: Date())
    }
}
