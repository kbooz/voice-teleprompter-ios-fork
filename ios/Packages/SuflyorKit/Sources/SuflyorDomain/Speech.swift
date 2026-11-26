import Foundation

/// Text of the current utterance (Kotlin: `speech.AsrUpdate`). `isFinal` ends the utterance.
public struct AsrUpdate: Hashable, Sendable {
    public var text: String
    public var isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// Which recognizer follows the voice.
public enum AsrEngineKind: String, Codable, CaseIterable, Hashable, Sendable {
    /// sherpa-onnx with the same streaming models and packs as Android (default).
    case sherpa
    /// Apple's on-device SpeechAnalyzer / SpeechTranscriber (iOS 26+), for languages it supports.
    case apple
}

/// Streaming speech recognizer (Kotlin: `speech.AsrEngine`).
///
/// Implementations hold native state behind their own lock; the session calls them from one task at a time.
public protocol AsrEngine: AnyObject, Sendable {
    var engineDescription: String { get }
    /// Language of the model: a script in another language needs another engine.
    var language: SpeechLanguage { get }
    /// The "boost script words" setting the engine was created with; a change of the setting needs a new engine.
    var hotwordsSetting: Bool { get }

    /// Feeds mono samples in [-1, 1]. Returns an update only when the text changed or an utterance ended.
    func accept(_ samples: [Float], sampleRate: Int) -> AsrUpdate?

    /// Script words to bias recognition towards: sherpa-onnx reads `hotwords`, the Apple engine reads `biasWords`.
    func setBias(hotwords: String, biasWords: [String])

    func reset()

    /// Frees the model. Safe to call twice; afterwards `accept` returns nil and the other calls do nothing.
    func release()
}

public enum AsrLoadError: Error, Hashable, Sendable {
    /// The language needs a speech pack that isn't installed.
    case packMissing(SpeechLanguage)
    /// The chosen engine can't do this language on this device.
    case unsupportedLanguage(SpeechLanguage)
    case modelLoadFailed(String)
}

/// Creates recognizers (a model load takes a second or two: never call it on the main actor).
public protocol AsrEngineFactory: Sendable {
    func makeEngine(language: SpeechLanguage, kind: AsrEngineKind, hotwords: Bool) async throws(AsrLoadError) -> any AsrEngine
}

/// One downloadable speech pack: a zip with a streaming transducer model (Kotlin: `speech.SpeechPack`).
/// The same files and SHA-256 as the Android catalog.
public struct SpeechPackInfo: Hashable, Sendable, Identifiable {
    public var language: SpeechLanguage
    public var version: Int
    public var fileName: String
    public var bytes: Int64
    public var sha256: String
    public var model: String
    public var license: String
    /// GitHub release that holds the file.
    public var releaseTag: String

    public var id: SpeechLanguage { language }

    public init(
        language: SpeechLanguage,
        version: Int,
        fileName: String,
        bytes: Int64,
        sha256: String,
        model: String,
        license: String,
        releaseTag: String
    ) {
        self.language = language
        self.version = version
        self.fileName = fileName
        self.bytes = bytes
        self.sha256 = sha256
        self.model = model
        self.license = license
        self.releaseTag = releaseTag
    }
}

public enum SpeechPackInstallResult: Hashable, Sendable {
    case installed(SpeechLanguage)
    /// The file's SHA-256 is not in the catalog: refused before unpacking.
    case notAPack
    /// The hash matched but the archive could not be unpacked or misses model files.
    case damaged(String)
    case ioError(String)
}

/// Installed speech packs and the catalog this version accepts.
public protocol SpeechPackManaging: Sendable {
    var catalog: [SpeechPackInfo] { get }
    /// The model is inside the app bundle (full build).
    func isBundled(_ language: SpeechLanguage) -> Bool
    func isInstalled(_ language: SpeechLanguage) -> Bool
    /// Voice following in `language` is possible right now (bundled or installed).
    func isAvailable(_ language: SpeechLanguage) -> Bool
    /// Browser download page of a pack (the app itself never downloads).
    func downloadURL(for pack: SpeechPackInfo) -> URL
    /// Installs a zip picked in Files or opened with the app. Reads the file; safe to call off the main actor.
    func install(from fileURL: URL) async -> SpeechPackInstallResult
    func remove(_ language: SpeechLanguage) throws
}
