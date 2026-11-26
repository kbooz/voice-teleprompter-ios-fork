import AVFAudio
import Foundation
import Speech
import SuflyorDomain

/// Apple's on-device recognizer (iOS 26 `SpeechAnalyzer` + `SpeechTranscriber`) behind the synchronous `AsrEngine`.
///
/// The analyzer is asynchronous: `accept` pushes audio into an `AsyncStream` that feeds it, a results task collects the
/// volatile and final results into a queue, and the next `accept` hands the newest one back. Results therefore arrive up
/// to one chunk (~100 ms) later than the audio that caused them, which the session absorbs.
///
/// Nothing is downloaded here: a language whose assets are not installed fails with `.modelLoadFailed`; `installAssets`
/// (the system's own downloader, used from a settings screen) installs them.
public final class AppleSpeechAsr: AsrEngine, @unchecked Sendable {
    public let engineDescription: String
    public let language: SpeechLanguage
    public let hotwordsSetting: Bool

    private let locale: Locale
    /// What the analyzer wants to be fed (often 16 kHz Int16 or Float32).
    private let analyzerFormat: AVAudioFormat

    // Everything below is guarded by `lock`.
    private let lock = NSLock()
    private var released = false
    private var generation = 0
    private var fedSinceStart = false
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var pending: [AsrUpdate] = []
    private var lastText = ""
    private var biasWords: [String] = []
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?

    /// Carries one buffer into the converter's input block.
    private final class InputBox: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var consumed = false
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }

    private init(locale: Locale, language: SpeechLanguage, analyzerFormat: AVAudioFormat, hotwords: Bool) {
        self.locale = locale
        self.language = language
        self.analyzerFormat = analyzerFormat
        self.hotwordsSetting = hotwords
        self.engineDescription = "Apple SpeechAnalyzer, \(locale.identifier(.bcp47)), volatile results"
    }

    deinit {
        inputContinuation?.finish()
        resultsTask?.cancel()
        startTask?.cancel()
    }

    // MARK: - Availability (also for the settings screen)

    /// The locale Apple would use for `language`, or nil when its transcriber doesn't support it.
    public static func supportedLocale(for language: SpeechLanguage) async -> Locale? {
        let wanted = Locale(identifier: appleIdentifier(for: language))
        // VERIFY: `SpeechTranscriber.supportedLocale(equivalentTo:)` (async, returns Locale?) on the iOS 26 SDK.
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) { return match }
        // VERIFY: `SpeechTranscriber.supportedLocales` is an async static property returning [Locale].
        let all = await SpeechTranscriber.supportedLocales
        return all.first { $0.language.languageCode == wanted.language.languageCode }
    }

    /// Supported by the transcriber and its assets are installed, so a session can start right away.
    public static func isReady(for language: SpeechLanguage) async -> Bool {
        guard let locale = await supportedLocale(for: language) else { return false }
        // VERIFY: `SpeechTranscriber.installedLocales` is an async static property returning [Locale].
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    /// Asks the system to download the language assets (the OS does the networking; the app has no network code).
    public static func installAssets(for language: SpeechLanguage) async throws {
        guard let locale = await supportedLocale(for: language) else { throw AsrLoadError.unsupportedLanguage(language) }
        let transcriber = makeTranscriber(locale: locale)
        // VERIFY: `AssetInventory.assetInstallationRequest(supporting:)` and `downloadAndInstall()`.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    static func appleIdentifier(for language: SpeechLanguage) -> String {
        switch language {
        case .ru: "ru-RU"
        case .en: "en-US"
        case .tr: "tr-TR"
        case .pt: "pt-BR"
        case .es: "es-ES"
        case .de: "de-DE"
        case .fr: "fr-FR"
        case .it: "it-IT"
        case .nl: "nl-NL"
        case .sv: "sv-SE"
        case .he: "he-IL"
        case .ar: "ar-SA"
        case .ko: "ko-KR"
        case .zh: "zh-CN"
        }
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        // Volatile results stream while the person is still talking; no punctuation or timing data is needed.
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
    }

    // MARK: - Loading

    static func create(language: SpeechLanguage, hotwords: Bool) async throws(AsrLoadError) -> AppleSpeechAsr {
        guard let locale = await supportedLocale(for: language) else { throw .unsupportedLanguage(language) }
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw .modelLoadFailed("Apple speech assets for \(locale.identifier(.bcp47)) are not installed")
        }
        let probe = makeTranscriber(locale: locale)
        // VERIFY: `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` is async and returns AVAudioFormat?.
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe]) else {
            throw .unsupportedLanguage(language)
        }
        let engine = AppleSpeechAsr(locale: locale, language: language, analyzerFormat: format, hotwords: hotwords)
        engine.lock.withLock { engine.startPipelineLocked() }
        return engine
    }

    // MARK: - AsrEngine

    public func accept(_ samples: [Float], sampleRate: Int) -> AsrUpdate? {
        lock.withLock { () -> AsrUpdate? in
            guard !released, !samples.isEmpty else { return nil }
            if let buffer = analyzerBuffer(from: samples, sampleRate: sampleRate) {
                // VERIFY: `AnalyzerInput(buffer:)` and `yield` taking a non-Sendable payload (`sending`) under Swift 6.
                inputContinuation?.yield(AnalyzerInput(buffer: buffer))
                fedSinceStart = true
            }
            return nextUpdateLocked()
        }
    }

    public func setBias(hotwords: String, biasWords: [String]) {
        lock.withLock {
            guard !released else { return }
            // The analysis context takes plain words; a few hundred are plenty.
            self.biasWords = Array(biasWords.prefix(300))
            if let analyzer { applyContext(to: analyzer) }
        }
    }

    /// The analyzer can't forget audio, so a reset starts a new one; audio fed meanwhile waits in the new input stream.
    public func reset() {
        lock.withLock {
            guard !released, fedSinceStart || !pending.isEmpty else { return }
            tearDownPipelineLocked()
            pending.removeAll()
            lastText = ""
            startPipelineLocked()
        }
    }

    public func release() {
        lock.withLock {
            guard !released else { return }
            released = true
            tearDownPipelineLocked()
            pending.removeAll()
        }
    }

    // MARK: - Pipeline (call with the lock held)

    private func startPipelineLocked() {
        generation += 1
        let myGeneration = generation
        fedSinceStart = false
        let transcriber = Self.makeTranscriber(locale: locale)
        let newAnalyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        analyzer = newAnalyzer
        inputContinuation = continuation
        let words = biasWords

        resultsTask = Task { [weak self] in
            do {
                // VERIFY: `transcriber.results` is an AsyncSequence of results with `text` (AttributedString) and `isFinal`.
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    self?.receive(text: text, isFinal: result.isFinal, generation: myGeneration)
                }
            } catch {
                Journal.shared.error("Apple speech results ended", error)
            }
        }
        startTask = Task { [weak self] in
            do {
                if !words.isEmpty { try await Self.setContext(words, on: newAnalyzer) }
                // VERIFY: `start(inputSequence:)` returns once the analysis runs; it keeps consuming `stream`.
                try await newAnalyzer.start(inputSequence: stream)
            } catch {
                Journal.shared.error("Apple speech analyzer didn't start", error)
                self?.pipelineFailed(generation: myGeneration)
            }
        }
    }

    private func tearDownPipelineLocked() {
        generation += 1 // late results of the old pipeline are ignored
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        startTask?.cancel()
        startTask = nil
        if let old = analyzer {
            analyzer = nil
            // VERIFY: `cancelAndFinishNow()` is async on SpeechAnalyzer.
            Task { await old.cancelAndFinishNow() }
        }
    }

    private func applyContext(to analyzer: SpeechAnalyzer) {
        let words = biasWords
        guard !words.isEmpty else { return }
        Task { try? await Self.setContext(words, on: analyzer) }
    }

    private static func setContext(_ words: [String], on analyzer: SpeechAnalyzer) async throws {
        // VERIFY: `AnalysisContext`, its `contextualStrings[.general]` and `SpeechAnalyzer.setContext(_:)`.
        let context = AnalysisContext()
        context.contextualStrings[.general] = words
        try await analyzer.setContext(context)
    }

    private func pipelineFailed(generation failed: Int) {
        lock.withLock {
            guard failed == generation, !released else { return }
            // Nothing will ever answer: stop feeding. The session keeps running and the text moves on its timer.
            inputContinuation?.finish()
            inputContinuation = nil
        }
    }

    // MARK: - Results

    private func receive(text: String, isFinal: Bool, generation fromGeneration: Int) {
        lock.withLock {
            guard fromGeneration == generation, !released else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isFinal {
                lastText = ""
                if !trimmed.isEmpty { pending.append(AsrUpdate(text: trimmed, isFinal: true)) }
            } else if trimmed != lastText {
                lastText = trimmed
                if !trimmed.isEmpty { pending.append(AsrUpdate(text: trimmed, isFinal: false)) }
            }
        }
    }

    /// Several volatile results that piled up between two chunks collapse into the newest; a final is never skipped.
    private func nextUpdateLocked() -> AsrUpdate? {
        guard !pending.isEmpty else { return nil }
        while pending.count > 1, !pending[0].isFinal { pending.removeFirst() }
        return pending.removeFirst()
    }

    // MARK: - Audio

    /// Mono Float samples to a buffer in the format the analyzer asked for.
    private func analyzerBuffer(from samples: [Float], sampleRate: Int) -> AVAudioPCMBuffer? {
        guard
            let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(sampleRate),
                channels: 1,
                interleaved: false
            ),
            let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = source.floatChannelData
        else { return nil }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: samples.count) }

        if sourceFormat == analyzerFormat { return source }
        if converter == nil || converterSource != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: analyzerFormat)
            converterSource = sourceFormat
        }
        guard let converter else { return nil }
        let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return nil }
        let box = InputBox(source)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if box.consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            box.consumed = true
            inputStatus.pointee = .haveData
            return box.buffer
        }
        if status == .error || error != nil || out.frameLength == 0 { return nil }
        return out
    }
}
