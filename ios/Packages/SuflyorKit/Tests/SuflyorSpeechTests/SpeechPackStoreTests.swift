import CryptoKit
import Foundation
import SuflyorDomain
import Testing

@testable import SuflyorSpeech

/// A packs folder in a temp directory that disappears with the test.
private final class Sandbox {
    let root: URL
    let packs: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("suflyor-tests-\(UUID().uuidString)", isDirectory: true)
        packs = root.appendingPathComponent("speech", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// Writes `files` as a zip and returns its URL and the catalog entry that accepts exactly that file.
    func makePack(
        language: SpeechLanguage = .pt,
        files: [(name: String, data: Data)]? = nil,
        manifestLang: String? = nil
    ) throws -> (url: URL, info: SpeechPackInfo) {
        let manifest = #"{"format": 1, "lang": "\#(manifestLang ?? language.code)", "version": 1, "model": {"type": "zipformer2", "label": "Test model"}}"#
        let entries = files ?? [
            ("manifest.json", Data(manifest.utf8)),
            ("encoder.int8.onnx", Data(repeating: 1, count: 3000)),
            ("decoder.onnx", Data(repeating: 2, count: 2000)),
            ("joiner.int8.onnx", Data(repeating: 3, count: 1000)),
            ("tokens.txt", Data("a 0\nb 1\n".utf8)),
            ("LICENSE.md", Data("license".utf8)),
        ]
        let zip = ZipBuilder.make(entries)
        let url = root.appendingPathComponent("\(UUID().uuidString).zip")
        try zip.write(to: url)
        let hash = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        let info = SpeechPackInfo(
            language: language,
            version: 1,
            fileName: "suflyor-speech-\(language.code)-1.zip",
            bytes: Int64(zip.count),
            sha256: hash,
            model: "Test model",
            license: "CC BY-SA",
            releaseTag: "speech-packs-test"
        )
        return (url, info)
    }

    func store(accepting catalog: [SpeechPackInfo]) -> SpeechPackStore {
        SpeechPackStore(rootDirectory: packs, bundle: Bundle(for: Marker.self), catalog: catalog)
    }

    func list(_ language: SpeechLanguage) -> [String] {
        let dir = packs.appendingPathComponent(language.code)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private final class Marker {}
}

@Suite struct SpeechPackStoreTests {
    @Test func installsAPackThatIsInTheCatalog() async throws {
        let sandbox = try Sandbox()
        let (zip, info) = try sandbox.makePack()
        let store = sandbox.store(accepting: [info])
        #expect(!store.isInstalled(.pt))
        #expect(!store.isAvailable(.pt))

        let result = await store.install(from: zip)
        #expect(result == .installed(.pt))
        #expect(store.isInstalled(.pt))
        #expect(store.isAvailable(.pt))
        #expect(sandbox.list(.pt) == ["LICENSE.md", "decoder.onnx", "encoder.int8.onnx", "joiner.int8.onnx", "manifest.json", "tokens.txt"])
        #expect(store.installedVersion(.pt) == 1)
        let manifestBytes = try Data(contentsOf: sandbox.packs.appendingPathComponent("pt/manifest.json")).count
        #expect(store.installedBytes(.pt) == Int64(3000 + 2000 + 1000 + 8 + 7 + manifestBytes))

        // Nothing is left behind in the packs folder.
        let top = try FileManager.default.contentsOfDirectory(atPath: sandbox.packs.path)
        #expect(top == ["pt"])

        // The factory finds the model with the label and type from the manifest.
        let location = try #require(store.modelLocation(for: .pt))
        #expect(location.label == "Test model")
        #expect(location.modelType == "zipformer2")
        #expect(!location.bundled)
        #expect(location.directory.lastPathComponent == "pt")
    }

    @Test func refusesAFileThatIsNotInTheCatalog() async throws {
        let sandbox = try Sandbox()
        let (zip, info) = try sandbox.makePack()
        let (other, _) = try sandbox.makePack(files: [("manifest.json", Data(#"{"lang": "pt"}"#.utf8)), ("tokens.txt", Data("x".utf8))])
        let store = sandbox.store(accepting: [info])

        #expect(await store.install(from: other) == .notAPack)
        #expect(!store.isInstalled(.pt))
        // Refused before unpacking: no language folder, no temporary files.
        #expect(!FileManager.default.fileExists(atPath: sandbox.packs.appendingPathComponent("pt").path))
        #expect(!FileManager.default.fileExists(atPath: sandbox.packs.appendingPathComponent("incoming.zip").path))
        #expect(!FileManager.default.fileExists(atPath: sandbox.packs.appendingPathComponent("pt.new").path))

        // Right hash but a different size is also refused (the catalog checks both).
        var wrongSize = info
        wrongSize.bytes += 1
        #expect(await sandbox.store(accepting: [wrongSize]).install(from: zip) == .notAPack)
    }

    @Test func refusesUnsafeFileNamesAndKeepsTheOldPack() async throws {
        let sandbox = try Sandbox()
        let (good, goodInfo) = try sandbox.makePack()
        let store0 = sandbox.store(accepting: [goodInfo])
        #expect(await store0.install(from: good) == .installed(.pt))

        let manifest = Data(#"{"lang": "pt"}"#.utf8)
        for badName in ["../evil.txt", "sub/evil.txt", "/etc/evil.txt", "evil.exe", "evil", ".txt", "a b.txt"] {
            let (bad, badInfo) = try sandbox.makePack(files: [("manifest.json", manifest), (badName, Data("x".utf8))])
            let store = sandbox.store(accepting: [badInfo])
            let result = await store.install(from: bad)
            guard case .damaged = result else {
                Issue.record("\(badName) was not refused: \(result)")
                continue
            }
            // The pack that was there before still works, and nothing was written outside the folder.
            #expect(store.isInstalled(.pt))
            #expect(sandbox.list(.pt).contains("encoder.int8.onnx"))
            #expect(!FileManager.default.fileExists(atPath: sandbox.root.appendingPathComponent("evil.txt").path))
        }
    }

    @Test func refusesAPackWithoutAManifestOrWithAnotherLanguage() async throws {
        let sandbox = try Sandbox()
        let (noManifest, noManifestInfo) = try sandbox.makePack(files: [("tokens.txt", Data("x".utf8))])
        guard case .damaged = await sandbox.store(accepting: [noManifestInfo]).install(from: noManifest) else {
            Issue.record("a pack without manifest.json was accepted")
            return
        }

        let (wrongLang, wrongInfo) = try sandbox.makePack(language: .pt, manifestLang: "es")
        let store = sandbox.store(accepting: [wrongInfo])
        guard case .damaged(let message) = await store.install(from: wrongLang) else {
            Issue.record("a pack for another language was accepted")
            return
        }
        #expect(message.contains("es"))
        #expect(!store.isInstalled(.pt))
        #expect(!FileManager.default.fileExists(atPath: sandbox.packs.appendingPathComponent("pt.new").path))
    }

    @Test func installingAgainReplacesThePack() async throws {
        let sandbox = try Sandbox()
        let (first, firstInfo) = try sandbox.makePack()
        let manifest = Data(#"{"lang": "pt", "version": 2, "model": {"type": "zipformer", "label": "Second"}}"#.utf8)
        let (second, secondInfo) = try sandbox.makePack(files: [("manifest.json", manifest), ("tokens.txt", Data("z".utf8))])
        let store = sandbox.store(accepting: [firstInfo, secondInfo])

        #expect(await store.install(from: first) == .installed(.pt))
        #expect(await store.install(from: second) == .installed(.pt))
        #expect(sandbox.list(.pt) == ["manifest.json", "tokens.txt"])
        let location = try #require(store.modelLocation(for: .pt))
        #expect(location.label == "Second")
        #expect(location.modelType == "zipformer")
        #expect(store.installedVersion(.pt) == 2)
        #expect(!FileManager.default.fileExists(atPath: sandbox.packs.appendingPathComponent("pt.old").path))
    }

    @Test func removeDeletesThePack() async throws {
        let sandbox = try Sandbox()
        let (zip, info) = try sandbox.makePack()
        let store = sandbox.store(accepting: [info])
        #expect(await store.install(from: zip) == .installed(.pt))
        try store.remove(.pt)
        #expect(!store.isInstalled(.pt))
        #expect(store.modelLocation(for: .pt) == nil)
        try store.remove(.pt) // removing what is not there is fine
    }

    @Test func missingFileIsAnIoError() async throws {
        let sandbox = try Sandbox()
        let store = sandbox.store(accepting: [])
        let result = await store.install(from: sandbox.root.appendingPathComponent("nothing.zip"))
        guard case .ioError = result else {
            Issue.record("expected ioError, got \(result)")
            return
        }
    }

    @Test(arguments: [
        ("manifest.json", true), ("encoder.int8.onnx", true), ("tokens.txt", true), ("bpe.vocab", true),
        ("LICENSE.md", true), ("a-b_c.d.onnx", true),
        ("../x.txt", false), ("a/b.txt", false), ("x.exe", false), (".txt", false), ("x.TXT", false), ("a b.txt", false),
        ("", false), (String(repeating: "a", count: 65) + ".txt", false), (String(repeating: "a", count: 64) + ".txt", true),
    ])
    func allowedNames(name: String, allowed: Bool) {
        #expect(SpeechPackStore.isAllowedName(name) == allowed)
    }
}

@Suite struct SpeechPackCatalogTests {
    @Test func listsEveryLanguageOnce() {
        let catalog = SpeechPackStore(rootDirectory: FileManager.default.temporaryDirectory).catalog
        #expect(catalog.count == SpeechLanguage.allCases.count)
        #expect(Set(catalog.map(\.language)) == Set(SpeechLanguage.allCases))
    }

    @Test func entriesAreWellFormed() {
        for pack in SpeechPackCatalog.packs {
            #expect(pack.sha256.count == 64 && pack.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "\(pack.fileName)")
            #expect(pack.bytes > 1_000_000, "\(pack.fileName)")
            #expect(pack.fileName == "suflyor-speech-\(pack.language.code)-\(pack.version).zip")
            #expect(pack.releaseTag.hasPrefix("speech-packs-"))
        }
    }

    @Test func downloadURLsPointToTheGitHubRelease() {
        let store = SpeechPackStore(rootDirectory: FileManager.default.temporaryDirectory)
        let pack = SpeechPackCatalog.packs.first { $0.language == .pt }!
        #expect(
            store.downloadURL(for: pack).absoluteString
                == "https://github.com/olerast67/voice-teleprompter-android/releases/download/speech-packs-1/suflyor-speech-pt-1.zip"
        )
    }

    @Test func spotChecksAgainstAndroid() throws {
        // Values copied from SpeechPackCatalog.kt; ios/scripts/speech_pack_catalog.py --check compares all of them.
        let pt = try #require(SpeechPackCatalog.packs.first { $0.language == .pt })
        #expect(pt.bytes == 118_791_612)
        #expect(pt.sha256 == "cd010ecdf64ab99c75c36b2c640f5621c958a78fb36e1033e9ce44557a3095b6")
        let ar = try #require(SpeechPackCatalog.packs.first { $0.language == .ar })
        #expect(ar.bytes == 252_997_999)
        #expect(ar.releaseTag == "speech-packs-4")
    }
}
