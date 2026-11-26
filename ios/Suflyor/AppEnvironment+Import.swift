import Foundation
import SuflyorDomain
import SuflyorImporters
import SuflyorSpeech

// Importing files, pasted text, backups and speech packs (Android: MainActivity.importUri / importText /
// installSpeechPack). Parsing runs off the main actor: a long document takes a moment.

/// What one imported file turned into.
enum ImportOutcome {
    case script(String)
    case restored(saved: Int, skipped: Int)
    case pack(SpeechLanguage)
    case failed
}

private enum ImportLimits {
    /// Android: `DocumentImporter.MAX_MB`.
    static let maxMegabytes = 40
}

extension AppEnvironment {
    // MARK: - Files

    /// Files from the picker or "Open in". The last script imported is opened.
    func importFiles(_ urls: [URL]) async {
        var lastScript: String?
        for url in urls {
            if case .script(let id) = await importFile(at: url) { lastScript = id }
        }
        if let lastScript { openScript(lastScript) }
    }

    /// One file: a speech pack, a backup, or a script. Tells the user what happened.
    func importFile(at url: URL) async -> ImportOutcome {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            Self.removeOpenInCopy(url)
        }
        let name = url.lastPathComponent
        let isZip = url.pathExtension.lowercased() == "zip"

        if isZip {
            // The catalog's SHA-256 decides: a pack is installed, anything else falls through as a backup.
            let looksLikePack = name.hasPrefix("suflyor-speech-")
            switch await packs.install(from: url) {
            case .installed(let language):
                finishPackInstall(language)
                return .pack(language)
            case .notAPack:
                if looksLikePack {
                    Journal.shared.info("Speech pack refused: not in the catalog")
                    showToast(L10n.text("pack_unknown_file"))
                    return .failed
                }
            case .damaged(let detail), .ioError(let detail):
                Journal.shared.error("Speech pack install failed: \(detail)")
                showToast(L10n.text("pack_failed", detail))
                return .failed
            }
        }

        showToast(L10n.text("import_opening"))
        let loaded = await Task.detached(priority: .userInitiated) { Self.readFile(url) }.value
        let data: Data
        switch loaded {
        case .success(let bytes): data = bytes
        case .failure(let error): return report(error)
        }

        // A zip that is not a speech pack is a backup of the library; a backup given to the importer is .unknownZip.
        if isZip || ScriptArchive.isArchive(data) {
            let core = self.core
            let archive = await Task.detached(priority: .userInitiated) { Self.readArchive(data, core: core) }.value
            switch archive {
            case .success(let entries): return restore(entries.map(\.document))
            case .failure(let error): return report(error)
            }
        }

        let importer = self.importer
        let result = await Task.detached(priority: .userInitiated) {
            Self.runImport(importer, data: data, fileName: name, contentType: nil)
        }.value
        switch result {
        case .success(let document): return store(document)
        case .failure(let error): return report(error)
        }
    }

    // MARK: - Pasted text

    func importPastedText(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast(L10n.text("import_clipboard_empty"))
            return
        }
        let importer = self.importer
        let title = L10n.text("import_title_clipboard")
        let result = await Task.detached(priority: .userInitiated) {
            Self.runPaste(importer, text: text, title: title)
        }.value
        switch result {
        case .success(let document):
            if case .script(let id) = store(document) { openScript(id) }
        case .failure(let error):
            _ = report(error)
        }
    }

    // MARK: - The Share extension's inbox

    /// Imports whatever the Share extension left in `<App Group>/Inbox/`. Called on every foreground.
    func importInbox() async {
        guard !inboxBusy,
              let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroup)
        else { return }
        let inbox = group.appendingPathComponent("Inbox", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        guard !entries.isEmpty else { return }

        inboxBusy = true
        defer { inboxBusy = false }
        var lastScript: String?
        // Each item is a folder holding the file under its own name (see ShareViewController).
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isFolder = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let files = isFolder
                ? ((try? FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? [])
                : [entry]
            for file in files {
                if case .script(let id) = await importFile(at: file) { lastScript = id }
            }
            try? FileManager.default.removeItem(at: entry)
        }
        if let lastScript { openScript(lastScript) }
    }

    // MARK: - Speech packs

    /// "Install downloaded pack" in Settings.
    func installPack(at url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        switch await runPackInstall(url) {
        case .installed(let language):
            finishPackInstall(language)
        case .notAPack:
            Journal.shared.info("Speech pack refused: not in the catalog")
            showToast(L10n.text("pack_unknown_file"))
        case .damaged(let detail), .ioError(let detail):
            Journal.shared.error("Speech pack install failed: \(detail)")
            showToast(L10n.text("pack_failed", detail))
        }
    }

    func removePack(_ language: SpeechLanguage) {
        do {
            try packs.remove(language)
            Journal.shared.info("Speech pack \(language.code) deleted")
            showToast(L10n.text("pack_deleted", speechLanguageDisplayName(language)))
        } catch {
            Journal.shared.error("Couldn't delete the speech pack", error)
            showToast(L10n.text("pack_failed", error.localizedDescription))
        }
        packsRevision += 1
    }

    private func runPackInstall(_ url: URL) async -> SpeechPackInstallResult {
        installingPack = true
        defer {
            installingPack = false
            packsRevision += 1
        }
        return await packs.install(from: url)
    }

    private func finishPackInstall(_ language: SpeechLanguage) {
        packsRevision += 1
        Journal.shared.info("Speech pack installed: \(language.code)")
        showToast(L10n.text("pack_installed", speechLanguageDisplayName(language)))
    }

    // MARK: - Backup

    /// The zip of every script, for the "Save all scripts" exporter.
    func makeBackup() -> (data: Data, count: Int)? {
        let documents = library.allDocuments()
        do {
            return (try ScriptArchive.export(documents), documents.count)
        } catch {
            Journal.shared.error("Backup failed", error)
            showToast(L10n.text("backup_failed", error.localizedDescription))
            return nil
        }
    }

    // MARK: - Results

    private func store(_ document: ImportedDocument) -> ImportOutcome {
        // A failed save reaches the user through `library.saveError` (RootView shows it).
        guard let id = library.add(document) else { return .failed }
        Journal.shared.info("Script: \(document.format), \(document.paragraphs.count) paragraphs")
        return .script(id)
    }

    private func restore(_ documents: [ImportedDocument]) -> ImportOutcome {
        let usable = documents.filter { !$0.isEmpty }
        guard !usable.isEmpty else { return report(.noText) }
        let saved = library.addAll(usable)
        let skipped = documents.count - saved
        Journal.shared.info("Backup restored: \(saved) scripts, \(skipped) skipped")
        var message = L10n.text("backup_restored", saved)
        if skipped > 0 { message += " " + L10n.text("backup_skipped", skipped) }
        showToast(message)
        router.path = []
        return .restored(saved: saved, skipped: skipped)
    }

    private func report(_ error: ImportError) -> ImportOutcome {
        Journal.shared.error("Import failed: \(error)")
        showToast(error.message)
        return .failed
    }

    // MARK: - Off the main actor

    nonisolated private static func readFile(_ url: URL) -> Result<Data, ImportError> {
        let limit = ImportLimits.maxMegabytes * 1024 * 1024
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > limit {
            return .failure(.fileTooBig(maxMb: ImportLimits.maxMegabytes))
        }
        guard let data = try? Data(contentsOf: url) else { return .failure(.cannotOpen) }
        return data.count > limit ? .failure(.fileTooBig(maxMb: ImportLimits.maxMegabytes)) : .success(data)
    }

    nonisolated private static func readArchive(
        _ data: Data,
        core: any ScriptCoreProviding
    ) -> Result<[ScriptArchive.Entry], ImportError> {
        do {
            return .success(try ScriptArchive.read(data, core: core))
        } catch {
            return .failure(error) // typed throws(ImportError)
        }
    }

    nonisolated private static func runImport(
        _ importer: DocumentImporter,
        data: Data,
        fileName: String,
        contentType: String?
    ) -> Result<ImportedDocument, ImportError> {
        do {
            return .success(try importer.importFile(data: data, fileName: fileName, contentType: contentType))
        } catch {
            return .failure(error) // typed throws(ImportError)
        }
    }

    nonisolated private static func runPaste(
        _ importer: DocumentImporter,
        text: String,
        title: String
    ) -> Result<ImportedDocument, ImportError> {
        do {
            return .success(try importer.importPastedText(text, title: title))
        } catch {
            return .failure(error) // typed throws(ImportError)
        }
    }

    /// "Open in" hands the app a copy in `Documents/Inbox/` (the app doesn't open documents in place): delete it
    /// once read, so the files don't pile up.
    nonisolated private static func removeOpenInCopy(_ url: URL) {
        guard url.isFileURL, url.path.contains("/Documents/Inbox/") else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
