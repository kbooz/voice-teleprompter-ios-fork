import Foundation
import SuflyorDomain

/// A recognizer that answers from a script: each `accept` returns the next queued update (or what `handler` says).
public final class FakeAsrEngine: AsrEngine, @unchecked Sendable {
    public let engineDescription: String
    public let language: SpeechLanguage
    public let hotwordsSetting: Bool

    /// Replaces the queue: called on every `accept` with the samples and rate. May block (to simulate a slow decode).
    public typealias Handler = @Sendable ([Float], Int) -> AsrUpdate?

    private let lock = NSLock()
    private var queue: [AsrUpdate] = []
    private var _handler: Handler?
    private var _acceptCount = 0
    private var _resetCount = 0
    private var _releaseCount = 0
    private var _hotwords = ""
    private var _biasWords: [String] = []

    public init(language: SpeechLanguage = .en, hotwordsSetting: Bool = true, description: String = "fake recognizer") {
        self.language = language
        self.hotwordsSetting = hotwordsSetting
        self.engineDescription = description
    }

    public func enqueue(_ updates: AsrUpdate...) {
        lock.withLock { queue.append(contentsOf: updates) }
    }

    public var handler: Handler? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    public var acceptCount: Int { lock.withLock { _acceptCount } }
    public var resetCount: Int { lock.withLock { _resetCount } }
    public var isReleased: Bool { lock.withLock { _releaseCount > 0 } }
    public var releaseCount: Int { lock.withLock { _releaseCount } }
    public var hotwords: String { lock.withLock { _hotwords } }
    public var biasWords: [String] { lock.withLock { _biasWords } }

    public func accept(_ samples: [Float], sampleRate: Int) -> AsrUpdate? {
        let (handler, released): (Handler?, Bool) = lock.withLock {
            _acceptCount += 1
            return (_handler, _releaseCount > 0)
        }
        if released { return nil }
        // The handler runs outside the lock so it can block while the test calls reset() or release().
        if let handler { return handler(samples, sampleRate) }
        return lock.withLock { queue.isEmpty ? nil : queue.removeFirst() }
    }

    public func setBias(hotwords: String, biasWords: [String]) {
        lock.withLock {
            _hotwords = hotwords
            _biasWords = biasWords
        }
    }

    public func reset() {
        lock.withLock { _resetCount += 1 }
    }

    public func release() {
        lock.withLock { _releaseCount += 1 }
    }
}

/// Hands out `FakeAsrEngine`s and remembers what was asked, with optional delay and failures.
public final class FakeAsrEngineFactory: AsrEngineFactory, @unchecked Sendable {
    public struct Request: Hashable, Sendable {
        public var language: SpeechLanguage
        public var kind: AsrEngineKind
        public var hotwords: Bool
    }

    private let lock = NSLock()
    private var _requests: [Request] = []
    private var _engines: [FakeAsrEngine] = []
    private var _failures: [SpeechLanguage: AsrLoadError] = [:]
    private var _delay: Duration = .zero

    public init() {}

    public var requests: [Request] { lock.withLock { _requests } }
    /// Every engine made so far, oldest first.
    public var engines: [FakeAsrEngine] { lock.withLock { _engines } }

    /// Loading `language` fails with `error` (nil removes the failure).
    public func fail(_ language: SpeechLanguage, with error: AsrLoadError?) {
        lock.withLock { _failures[language] = error }
    }

    /// Every load takes this long (the model load of a real engine takes a second or two).
    public var delay: Duration {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }

    public func makeEngine(
        language: SpeechLanguage,
        kind: AsrEngineKind,
        hotwords: Bool
    ) async throws(AsrLoadError) -> any AsrEngine {
        let (failure, wait): (AsrLoadError?, Duration) = lock.withLock {
            _requests.append(Request(language: language, kind: kind, hotwords: hotwords))
            return (_failures[language], _delay)
        }
        if wait > .zero { try? await Task.sleep(for: wait) }
        if let failure { throw failure }
        let engine = FakeAsrEngine(language: language, hotwordsSetting: hotwords, description: "fake \(language.code) (\(kind.rawValue))")
        lock.withLock { _engines.append(engine) }
        return engine
    }
}
