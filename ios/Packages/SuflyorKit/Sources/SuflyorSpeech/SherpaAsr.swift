import CSherpaOnnx
import Foundation
import SuflyorDomain

/// Streaming recognizer: sherpa-onnx (C API) with a streaming Zipformer transducer, configured exactly like Android's
/// `SherpaAsr.createFromFiles`. Models: the three bundled ones (ru, en, tr) or a speech pack on disk.
///
/// With "boost script words" on, a model that ships a `bpe.vocab` runs modified beam search over BPE units so the
/// script's hotwords get a bonus; any other model runs greedy search.
// @unchecked Sendable: all native state is guarded by `lock`.
public final class SherpaAsr: AsrEngine, @unchecked Sendable {
    public let engineDescription: String
    public let language: SpeechLanguage
    public let hotwordsSetting: Bool

    /// The config can encode hotwords (modified beam search + BPE vocabulary).
    private let hotwordsEnabled: Bool

    // One lock for all native state: `accept` (audio task), `reset`/`setBias` (session) and `release` may overlap.
    private let lock = NSLock()
    private var recognizer: OpaquePointer?
    private var stream: OpaquePointer?
    private var hotwords = ""
    private var hotwordsChanged = false
    private var lastText = ""
    private var released = false

    private init(
        recognizer: OpaquePointer,
        stream: OpaquePointer,
        hotwordsEnabled: Bool,
        language: SpeechLanguage,
        description: String,
        hotwordsSetting: Bool
    ) {
        self.recognizer = recognizer
        self.stream = stream
        self.hotwordsEnabled = hotwordsEnabled
        self.language = language
        self.engineDescription = description
        self.hotwordsSetting = hotwordsSetting
    }

    deinit {
        // Not through `release()`: nothing else can hold the lock in a deinit, and it is already idempotent.
        if let stream { SherpaOnnxDestroyOnlineStream(stream) }
        if let recognizer { SherpaOnnxDestroyOnlineRecognizer(recognizer) }
    }

    // MARK: - AsrEngine

    public func accept(_ samples: [Float], sampleRate: Int) -> AsrUpdate? {
        lock.withLock { () -> AsrUpdate? in
            // The engine may be swapped for another language while the audio task still holds this one.
            guard !released, let recognizer else { return nil }
            if hotwordsChanged { recreateStream(recognizer) }
            guard let stream else { return nil }

            samples.withUnsafeBufferPointer { buffer in
                SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(sampleRate), buffer.baseAddress, Int32(buffer.count))
            }
            while SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0 {
                SherpaOnnxDecodeOnlineStream(recognizer, stream)
            }

            var text = Self.resultText(recognizer, stream).trimmingCharacters(in: .whitespacesAndNewlines)
            // The Arabic model hallucinates Latin and Cyrillic words on noise: an utterance with no Arabic letter is dropped.
            if language == .ar, !text.isEmpty, !text.unicodeScalars.contains(where: { (0x0600...0x06FF).contains($0.value) }) {
                text = ""
            }

            if SherpaOnnxOnlineStreamIsEndpoint(recognizer, stream) != 0 {
                SherpaOnnxOnlineStreamReset(recognizer, stream)
                lastText = ""
                return text.isEmpty ? nil : AsrUpdate(text: text, isFinal: true)
            }
            if text == lastText { return nil }
            lastText = text
            return text.isEmpty ? nil : AsrUpdate(text: text, isFinal: false)
        }
    }

    public func setBias(hotwords: String, biasWords: [String]) {
        lock.withLock {
            guard hotwordsEnabled, !released else { return }
            self.hotwords = hotwords
            hotwordsChanged = true
        }
    }

    public func reset() {
        lock.withLock {
            guard !released, let recognizer, let stream else { return }
            SherpaOnnxOnlineStreamReset(recognizer, stream)
            lastText = ""
        }
    }

    public func release() {
        lock.withLock {
            guard !released else { return }
            released = true
            if let stream { SherpaOnnxDestroyOnlineStream(stream) }
            if let recognizer { SherpaOnnxDestroyOnlineRecognizer(recognizer) }
            stream = nil
            recognizer = nil
        }
    }

    // MARK: - Private (call with the lock held)

    private func recreateStream(_ recognizer: OpaquePointer) {
        if let old = stream { SherpaOnnxDestroyOnlineStream(old) }
        // Only a config that can encode hotwords gets them, and never an empty list (a script with no word the model's
        // vocabulary can spell): the plain stream is the one sherpa-onnx is tested with.
        if hotwordsEnabled, !hotwords.isEmpty {
            stream = hotwords.withCString { SherpaOnnxCreateOnlineStreamWithHotwords(recognizer, $0) }
        } else {
            stream = SherpaOnnxCreateOnlineStream(recognizer)
        }
        hotwordsChanged = false
        lastText = ""
    }

    private static func resultText(_ recognizer: OpaquePointer, _ stream: OpaquePointer) -> String {
        guard let result = SherpaOnnxGetOnlineStreamResult(recognizer, stream) else { return "" }
        defer { SherpaOnnxDestroyOnlineRecognizerResult(result) }
        guard let text = result.pointee.text else { return "" }
        return String(cString: text)
    }

    // MARK: - Loading

    /// Loads a streaming transducer from `directory`: encoder, decoder and joiner (int8 preferred) and tokens.txt. With a
    /// bpe.vocab next to them and `hotwords` on, script words are boosted; otherwise greedy search.
    /// Takes a second or two: call it off the main actor.
    public static func create(
        directory: URL,
        language: SpeechLanguage,
        label: String,
        modelType: String = "zipformer2",
        hotwords: Bool
    ) throws(AsrLoadError) -> SherpaAsr {
        let fm = FileManager.default
        let vocab = directory.appendingPathComponent("bpe.vocab")
        let bpe = hotwords && fm.fileExists(atPath: vocab.path)
        let tokens = directory.appendingPathComponent("tokens.txt")
        guard fm.fileExists(atPath: tokens.path) else {
            throw .modelLoadFailed("\(directory.lastPathComponent): no tokens.txt")
        }
        let encoder = try pick("encoder", in: directory)
        let decoder = try pick("decoder", in: directory)
        let joiner = try pick("joiner", in: directory)

        // The C API copies every string while it builds the recognizer, so they can be freed right after.
        let strings = CStrings()
        var config = SherpaOnnxOnlineRecognizerConfig()
        config.feat_config.sample_rate = 16000
        config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = strings.make(encoder)
        config.model_config.transducer.decoder = strings.make(decoder)
        config.model_config.transducer.joiner = strings.make(joiner)
        config.model_config.tokens = strings.make(tokens.path)
        config.model_config.num_threads = 2
        config.model_config.provider = strings.make("cpu")
        config.model_config.model_type = strings.make(modelType)
        if bpe {
            config.model_config.modeling_unit = strings.make("bpe")
            config.model_config.bpe_vocab = strings.make(vocab.path)
        }
        let decodingMethod = bpe ? "modified_beam_search" : "greedy_search"
        config.decoding_method = strings.make(decodingMethod)
        config.max_active_paths = 4
        // Close an utterance after 0.8 s of silence following speech; the tracker keeps its own history anyway.
        // The C API fixes "must contain non-silence" per rule: rule 1 false, rule 2 true, rule 3 false (as on Android).
        config.enable_endpoint = 1
        config.rule1_min_trailing_silence = 2.0
        config.rule2_min_trailing_silence = 0.8
        config.rule3_min_utterance_length = 12.0
        config.hotwords_score = 1.5

        // The C strings must outlive the call: ARC may otherwise free `strings` after its last use above.
        let created: OpaquePointer? = withExtendedLifetime(strings) { SherpaOnnxCreateOnlineRecognizer(&config) }
        guard let recognizer = created else {
            throw .modelLoadFailed("\(label): sherpa-onnx rejected the model (see the console log)")
        }
        guard let stream = SherpaOnnxCreateOnlineStream(recognizer) else {
            SherpaOnnxDestroyOnlineRecognizer(recognizer)
            throw .modelLoadFailed("\(label): couldn't create a stream")
        }
        let description = "sherpa-onnx, \(label), \(decodingMethod)" + (bpe ? ", script words" : "")
        return SherpaAsr(
            recognizer: recognizer,
            stream: stream,
            hotwordsEnabled: bpe,
            language: language,
            description: description,
            hotwordsSetting: hotwords
        )
    }

    /// Android's `pick`: the file starting with `stem` and ending in .onnx, preferring one with "int8" in its name.
    private static func pick(_ stem: String, in directory: URL) throws(AsrLoadError) -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let files = names.filter { $0.hasPrefix(stem) && $0.hasSuffix(".onnx") }.sorted()
        guard let name = files.first(where: { $0.contains("int8") }) ?? files.first else {
            throw .modelLoadFailed("\(directory.lastPathComponent): no \(stem)*.onnx")
        }
        return directory.appendingPathComponent(name).path
    }

    /// Owns the `strdup`ed C strings of a config until it goes out of scope.
    private final class CStrings {
        private var pointers: [UnsafeMutablePointer<CChar>] = []

        func make(_ string: String) -> UnsafePointer<CChar> {
            let p = strdup(string)!
            pointers.append(p)
            return UnsafePointer(p)
        }

        deinit { for p in pointers { free(p) } }
    }
}
