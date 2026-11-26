import Foundation
import SuflyorDomain

/// An audio source driven by the test: `send` pushes events into the stream the session listens to.
public final class FakeAudioSource: AudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AudioEvent>.Continuation?
    private var _startCount = 0
    private var _stopCount = 0
    private var _failOnStart: CaptureError?

    public init() {}

    public var startCount: Int { lock.withLock { _startCount } }
    public var stopCount: Int { lock.withLock { _stopCount } }

    /// `start()` throws this error while it is set.
    public var failOnStart: CaptureError? {
        get { lock.withLock { _failOnStart } }
        set { lock.withLock { _failOnStart = newValue } }
    }

    public func start() async throws(CaptureError) -> AsyncStream<AudioEvent> {
        let failure: CaptureError? = lock.withLock {
            _startCount += 1
            return _failOnStart
        }
        if let failure { throw failure }
        let (stream, newContinuation) = AsyncStream.makeStream(of: AudioEvent.self)
        lock.withLock {
            continuation?.finish()
            continuation = newContinuation
        }
        return stream
    }

    public func stop() {
        lock.withLock {
            _stopCount += 1
            continuation?.finish()
            continuation = nil
        }
    }

    public func send(_ event: AudioEvent) {
        _ = lock.withLock { continuation }?.yield(event)
    }

    /// One 100 ms chunk at `db` dBFS (a constant signal of that level), or exact zeros when `digitalSilence`.
    public func sendChunk(db: Float = -30, digitalSilence: Bool = false) {
        send(.chunk(Self.chunk(db: db, digitalSilence: digitalSilence)))
    }

    public static func chunk(db: Float = -30, digitalSilence: Bool = false, samples count: Int = 1600) -> AudioChunk {
        let amplitude = digitalSilence ? 0 : Float(pow(10, Double(db) / 20))
        return AudioChunk(
            samples: [Float](repeating: amplitude, count: count),
            sampleRate: 16_000,
            rmsDb: digitalSilence ? -120 : db,
            digitalSilence: digitalSilence
        )
    }
}
