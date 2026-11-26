import CryptoKit
import Foundation
import SuflyorDomain
import ZIPFoundation

/// Where a recognizer model lives and how to describe it.
struct SpeechModelLocation: Sendable {
    var directory: URL
    var label: String
    /// sherpa-onnx `model_type`: "zipformer2" for most models, "zipformer" for the Korean and Chinese packs.
    var modelType: String
    var bundled: Bool
}

/// Speech packs, with the same rules as Android's `SpeechPacks`: the app downloads nothing, the user fetches a pack zip
/// in a browser and picks it in Files (or opens it with the app). The file is accepted only when its SHA-256 and size
/// are in the catalog, which ships inside the signed app, and it is unpacked only into flat files of known types.
///
/// Installed packs live in `<root>/<code>/` with the `manifest.json` of the zip; `root` defaults to
/// Application Support/speech. Bundled models are the app bundle's `asr-<code>/` folders.
// @unchecked Sendable: stored properties are immutable; mutations of the pack folders are serialized by `writeLock`.
public final class SpeechPackStore: SpeechPackManaging, @unchecked Sendable {
    public let catalog: [SpeechPackInfo]

    private let root: URL
    private let bundle: Bundle
    // Install and remove touch the same folders.
    private let writeLock = NSLock()

    static let manifestName = "manifest.json"

    /// - Parameter rootDirectory: the folder that directly holds `<code>/` folders; nil for Application Support/speech.
    public init(rootDirectory: URL? = nil, bundle: Bundle = .main) {
        self.root = rootDirectory ?? Self.defaultRoot()
        self.bundle = bundle
        self.catalog = SpeechPackCatalog.packs
    }

    /// Tests accept their own packs.
    package init(rootDirectory: URL, bundle: Bundle = .main, catalog: [SpeechPackInfo]) {
        self.root = rootDirectory
        self.bundle = bundle
        self.catalog = catalog
    }

    private static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("speech", isDirectory: true)
    }

    // MARK: - SpeechPackManaging

    public func isBundled(_ language: SpeechLanguage) -> Bool {
        bundledDirectory(language) != nil
    }

    public func isInstalled(_ language: SpeechLanguage) -> Bool {
        FileManager.default.fileExists(atPath: packDirectory(language).appendingPathComponent(Self.manifestName).path)
    }

    public func isAvailable(_ language: SpeechLanguage) -> Bool {
        isBundled(language) || isInstalled(language)
    }

    public func downloadURL(for pack: SpeechPackInfo) -> URL {
        // The base is a constant https URL: this cannot be nil.
        URL(string: AppConstants.speechPackReleaseBase + pack.releaseTag + "/" + pack.fileName)!
    }

    public func remove(_ language: SpeechLanguage) throws {
        try writeLock.withLock {
            let dir = packDirectory(language)
            if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
        }
    }

    /// Hashes the file while copying it next to the packs (so it can't change under us), checks the catalog, then
    /// unpacks into `<code>.new` and swaps it in. The old pack of that language is replaced only once the new one is
    /// complete. A 250 MB pack takes a few seconds: the work runs on the global executor, not on the caller's.
    public func install(from fileURL: URL) async -> SpeechPackInstallResult {
        let store = self
        return await Task.detached(priority: .userInitiated) {
            store.writeLock.withLock { store.installBlocking(fileURL) }
        }.value
    }

    // MARK: - Extras for the settings screen

    /// Pack version on disk, or nil. An older version than the catalog's still works; the screen offers the update.
    public func installedVersion(_ language: SpeechLanguage) -> Int? {
        manifest(language)?["version"] as? Int
    }

    /// Disk space an installed pack takes.
    public func installedBytes(_ language: SpeechLanguage) -> Int64 {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: packDirectory(language).path)) ?? []
        return names.reduce(into: Int64(0)) { total, name in
            let path = packDirectory(language).appendingPathComponent(name).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
            total += size ?? 0
        }
    }

    // MARK: - Used by SpeechEngineFactory

    /// The model to load for `language`: the bundled one first, as on Android, then an installed pack.
    func modelLocation(for language: SpeechLanguage) -> SpeechModelLocation? {
        if let dir = bundledDirectory(language) {
            return SpeechModelLocation(directory: dir, label: Self.bundledLabel(language), modelType: "zipformer2", bundled: true)
        }
        guard isInstalled(language) else { return nil }
        let model = manifest(language)?["model"] as? [String: Any]
        let label = (model?["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(language.code) speech pack"
        let type = (model?["type"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "zipformer2"
        return SpeechModelLocation(directory: packDirectory(language), label: label, modelType: type, bundled: false)
    }

    // The labels Android's SherpaAsr.modelFor gives the bundled models.
    private static func bundledLabel(_ language: SpeechLanguage) -> String {
        switch language {
        case .ru: "Zipformer ru small int8"
        case .en: "Zipformer en LibriSpeech 2023-06-26 int8"
        case .tr: "Zipformer tr seda-v0.2-tiny c16 int8"
        default: "\(language.code) bundled model"
        }
    }

    // MARK: - Paths

    private func packDirectory(_ language: SpeechLanguage) -> URL {
        root.appendingPathComponent(language.code, isDirectory: true)
    }

    private func bundledDirectory(_ language: SpeechLanguage) -> URL? {
        guard language.hasBundledModelOnAndroid, let base = bundle.resourceURL else { return nil }
        let dir = base.appendingPathComponent("asr-\(language.code)", isDirectory: true)
        let tokens = dir.appendingPathComponent("tokens.txt")
        return FileManager.default.fileExists(atPath: tokens.path) ? dir : nil
    }

    private func manifest(_ language: SpeechLanguage) -> [String: Any]? {
        let url = packDirectory(language).appendingPathComponent(Self.manifestName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Installing

    private struct Rejected: Error {
        var message: String
    }

    private func installBlocking(_ fileURL: URL) -> SpeechPackInstallResult {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let incoming = root.appendingPathComponent("incoming.zip")
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            excludeFromBackup(root)
            try? fm.removeItem(at: incoming)
            defer { try? fm.removeItem(at: incoming) }

            let (hash, total) = try Self.copyAndHash(from: fileURL, to: incoming)
            guard let pack = catalog.first(where: { $0.sha256 == hash && $0.bytes == total }) else { return .notAPack }

            // Unpacked files take about as much as the zip (onnx barely compresses).
            let need = pack.bytes + (64 << 20)
            if let free = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage, free < need {
                return .ioError("Not enough free space: \(need >> 20) MB needed")
            }

            let fresh = root.appendingPathComponent("\(pack.language.code).new", isDirectory: true)
            try? fm.removeItem(at: fresh)
            try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
            do {
                try Self.unzip(incoming, into: fresh)
                try Self.checkManifest(in: fresh, expecting: pack.language)
            } catch let rejected as Rejected {
                try? fm.removeItem(at: fresh)
                return .damaged(rejected.message)
            } catch {
                try? fm.removeItem(at: fresh)
                return .damaged(error.localizedDescription)
            }

            let target = packDirectory(pack.language)
            let old = root.appendingPathComponent("\(pack.language.code).old", isDirectory: true)
            try? fm.removeItem(at: old)
            if fm.fileExists(atPath: target.path) { try fm.moveItem(at: target, to: old) }
            do {
                try fm.moveItem(at: fresh, to: target)
            } catch {
                // Put the old pack back: a failed update must not leave the language without a model.
                if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: target) }
                throw error
            }
            try? fm.removeItem(at: old)
            return .installed(pack.language)
        } catch {
            return .ioError(error.localizedDescription)
        }
    }

    private func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    /// Copies in 1 MB steps while hashing; returns the lowercase hex SHA-256 and the size.
    private static func copyAndHash(from source: URL, to destination: URL) throws -> (String, Int64) {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            let block = try input.read(upToCount: 1 << 20) ?? Data()
            if block.isEmpty { break }
            hasher.update(data: block)
            try output.write(contentsOf: block)
            total += Int64(block.count)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (hex, total)
    }

    /// Only flat file names of the expected kinds: a zip can't write outside the folder ("../") or drop other files.
    static func isAllowedName(_ name: String) -> Bool {
        let extensions = ["onnx", "txt", "json", "md", "vocab"]
        guard let ext = extensions.first(where: { name.hasSuffix("." + $0) }) else { return false }
        let stem = name.dropLast(ext.count + 1)
        guard (1...64).contains(stem.count) else { return false }
        return stem.unicodeScalars.allSatisfy { c in
            (c.value >= 0x30 && c.value <= 0x39) || (c.value >= 0x41 && c.value <= 0x5A)
                || (c.value >= 0x61 && c.value <= 0x7A) || c == "_" || c == "." || c == "-"
        }
    }

    private static func unzip(_ zip: URL, into directory: URL) throws {
        let archive = try Archive(url: zip, accessMode: .read)
        var sawManifest = false
        for entry in archive {
            let name = entry.path
            if entry.type == .directory { continue }
            guard entry.type == .file, isAllowedName(name) else {
                throw Rejected(message: "unexpected file in the pack: \(name)")
            }
            _ = try archive.extract(entry, to: directory.appendingPathComponent(name))
            if name == manifestName { sawManifest = true }
        }
        guard sawManifest else { throw Rejected(message: "the pack has no \(manifestName)") }
    }

    private static func checkManifest(in directory: URL, expecting language: SpeechLanguage) throws {
        let data = try Data(contentsOf: directory.appendingPathComponent(manifestName))
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let lang = object?["lang"] as? String
        guard lang == language.code else {
            throw Rejected(message: "the pack's manifest is for \(lang ?? "no language")")
        }
    }
}
