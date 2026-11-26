import Foundation
import SuflyorDomain

/// Speech packs kept in memory: tests choose which languages are bundled or installed.
public final class FakeSpeechPackStore: SpeechPackManaging, @unchecked Sendable {
    public let catalog: [SpeechPackInfo]

    private let lock = NSLock()
    private var bundled: Set<SpeechLanguage>
    private var installed: Set<SpeechLanguage>
    private var _installResult: SpeechPackInstallResult?
    private var _installedFiles: [URL] = []

    public init(
        catalog: [SpeechPackInfo]? = nil,
        bundled: Set<SpeechLanguage> = [.ru, .en, .tr],
        installed: Set<SpeechLanguage> = []
    ) {
        self.catalog = catalog ?? SpeechLanguage.allCases.filter { !$0.hasBundledModelOnAndroid }.map(Self.samplePack)
        self.bundled = bundled
        self.installed = installed
    }

    public static func samplePack(_ language: SpeechLanguage) -> SpeechPackInfo {
        SpeechPackInfo(
            language: language,
            version: 1,
            fileName: "suflyor-speech-\(language.code)-1.zip",
            bytes: 1_000_000,
            sha256: String(repeating: "0", count: 64),
            model: "Fake \(language.code) model",
            license: "Apache-2.0",
            releaseTag: "speech-packs-test"
        )
    }

    /// What `install(from:)` answers; `.installed` also marks the language installed. Nil answers `.notAPack`.
    public var installResult: SpeechPackInstallResult? {
        get { lock.withLock { _installResult } }
        set { lock.withLock { _installResult = newValue } }
    }

    /// Files `install(from:)` was called with.
    public var installedFiles: [URL] { lock.withLock { _installedFiles } }

    public func setInstalled(_ language: SpeechLanguage, _ value: Bool) {
        lock.withLock {
            if value { installed.insert(language) } else { installed.remove(language) }
        }
    }

    public func isBundled(_ language: SpeechLanguage) -> Bool { lock.withLock { bundled.contains(language) } }
    public func isInstalled(_ language: SpeechLanguage) -> Bool { lock.withLock { installed.contains(language) } }
    public func isAvailable(_ language: SpeechLanguage) -> Bool { isBundled(language) || isInstalled(language) }

    public func downloadURL(for pack: SpeechPackInfo) -> URL {
        URL(string: AppConstants.speechPackReleaseBase + pack.releaseTag + "/" + pack.fileName)!
    }

    public func install(from fileURL: URL) async -> SpeechPackInstallResult {
        lock.withLock {
            _installedFiles.append(fileURL)
            let result = _installResult ?? .notAPack
            if case .installed(let language) = result { installed.insert(language) }
            return result
        }
    }

    public func remove(_ language: SpeechLanguage) throws {
        lock.withLock { _ = installed.remove(language) }
    }
}
