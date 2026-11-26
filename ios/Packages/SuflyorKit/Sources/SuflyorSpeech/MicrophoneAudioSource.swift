import AVFAudio
import Foundation
import SuflyorDomain

/// AVAudioEngine input tap → 16 kHz mono chunks of ~100 ms.
///
/// The audio session is `.playAndRecord` with `.mixWithOthers` (never takes the microphone or the speaker away from a
/// camera app that records, the iOS counterpart of Android's "no CAMCORDER / privacy-sensitive capture" rule), Bluetooth
/// HFP input and the loudspeaker as default output. Interruptions and route changes arrive as `AudioEvent`s; after an
/// interruption ends the engine is rebuilt and the stream goes on.
public final class MicrophoneAudioSource: AudioSource, @unchecked Sendable {
    /// Receives buffers on the tap's thread and turns them into chunks.
    private final class Pipeline: @unchecked Sendable {
        private let lock = NSLock()
        private var chunker = AudioChunker()
        private var converter: PCMConverter16k
        let continuation: AsyncStream<AudioEvent>.Continuation

        init(converter: PCMConverter16k, continuation: AsyncStream<AudioEvent>.Continuation) {
            self.converter = converter
            self.continuation = continuation
        }

        func setConverter(_ new: PCMConverter16k) {
            lock.withLock { converter = new }
        }

        func push(_ buffer: AVAudioPCMBuffer) {
            let current = lock.withLock { converter }
            let samples = current.convert(buffer)
            guard !samples.isEmpty else { return }
            let chunks = lock.withLock { chunker.append(samples) }
            for chunk in chunks { continuation.yield(.chunk(chunk)) }
        }
    }

    private struct Running {
        let generation: Int
        let engine: AVAudioEngine
        let pipeline: Pipeline
        var observers: [any NSObjectProtocol]
        var interrupted = false
    }

    // Guards `running` and `generationCounter`; AVAudioEngine calls are made while holding it, which serializes them.
    private let lock = NSLock()
    private var running: Running?
    private var generationCounter = 0

    public init() {}

    public func start() async throws(CaptureError) -> AsyncStream<AudioEvent> {
        stop() // "Calling start() again restarts the source."
        if !MicrophonePermission.isGranted {
            guard await MicrophonePermission.request() else { throw .permissionDenied }
        }
        return try startEngine()
    }

    public func stop() {
        let old = lock.withLock { () -> Running? in
            let r = running
            running = nil
            return r
        }
        tearDown(old)
    }

    // MARK: - Engine

    private func startEngine() throws(CaptureError) -> AsyncStream<AudioEvent> {
        let session = AVAudioSession.sharedInstance()
        do {
            // VERIFY: `.allowBluetoothHFP` (iOS 26 name of `.allowBluetooth`) as in docs/ios/contratos.md.
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker]
            )
            try session.setActive(true)
        } catch {
            throw .sessionActivationFailed(error.localizedDescription)
        }

        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw .formatUnsupported(sampleRate: Int(format.sampleRate))
        }
        let converter: PCMConverter16k
        do {
            converter = try PCMConverter16k(inputFormat: format)
        } catch {
            throw .formatUnsupported(sampleRate: Int(format.sampleRate))
        }

        let (stream, continuation) = AsyncStream.makeStream(of: AudioEvent.self, bufferingPolicy: .bufferingNewest(64))
        let pipeline = Pipeline(converter: converter, continuation: continuation)
        installTap(on: engine, format: format, pipeline: pipeline)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            continuation.finish()
            throw .startFailed(error.localizedDescription)
        }

        let generation = lock.withLock { () -> Int in
            generationCounter += 1
            return generationCounter
        }
        let observers = observe(engine: engine, generation: generation)
        lock.withLock {
            running = Running(generation: generation, engine: engine, pipeline: pipeline, observers: observers)
        }
        // The consumer cancelling its loop ends the capture, unless a newer start() has taken over.
        continuation.onTermination = { [weak self] _ in self?.stopIfCurrent(generation) }
        return stream
    }

    private func installTap(on engine: AVAudioEngine, format: AVAudioFormat, pipeline: Pipeline) {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            pipeline.push(buffer)
        }
    }

    private func stopIfCurrent(_ generation: Int) {
        let old = lock.withLock { () -> Running? in
            guard let r = running, r.generation == generation else { return nil }
            running = nil
            return r
        }
        tearDown(old)
    }

    private func tearDown(_ r: Running?) {
        guard let r else { return }
        for token in r.observers { NotificationCenter.default.removeObserver(token) }
        r.engine.inputNode.removeTap(onBus: 0)
        r.engine.stop()
        r.pipeline.continuation.finish()
        // Lets music or a video that was ducked or paused by us carry on.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Stops for good after telling the consumer why.
    private func fail(_ generation: Int, with error: CaptureError) {
        let old = lock.withLock { () -> Running? in
            guard let r = running, r.generation == generation else { return nil }
            running = nil
            return r
        }
        guard let old else { return }
        old.pipeline.continuation.yield(.failed(error))
        tearDown(old)
    }

    private func yieldIfCurrent(_ event: AudioEvent, generation: Int) {
        let pipeline = lock.withLock { () -> Pipeline? in
            guard let r = running, r.generation == generation else { return nil }
            return r.pipeline
        }
        pipeline?.continuation.yield(event)
    }

    // MARK: - Interruptions, route and configuration changes

    private func observe(engine: AVAudioEngine, generation: Int) -> [any NSObjectProtocol] {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        var tokens: [any NSObjectProtocol] = []

        tokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) {
            [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            self?.handleInterruption(rawType: raw, generation: generation)
        })

        tokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) {
            [weak self] _ in
            self?.handleRouteChange(generation: generation)
        })

        // Posted when the input device or its format changes: the engine stops and the tap must be reinstalled.
        // VERIFY: the Swift name of the notification (AVAudioEngineConfigurationChange) on the iOS 26 SDK.
        tokens.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) {
            [weak self] _ in
            self?.handleConfigurationChange(generation: generation)
        })
        return tokens
    }

    private func handleInterruption(rawType: UInt?, generation: Int) {
        guard let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            lock.withLock {
                if running?.generation == generation { running?.interrupted = true }
            }
            yieldIfCurrent(.interrupted, generation: generation)
        case .ended:
            // The "should resume" hint is not trusted: a recording app always tries to come back.
            Task { [weak self] in await self?.resume(generation: generation) }
        @unknown default:
            break
        }
    }

    /// Tries to bring the microphone back after an interruption: at once, then after 0.5, 1 and 2 seconds.
    private func resume(generation: Int) async {
        for delayMillis in [0, 500, 1000, 2000] {
            if delayMillis > 0 { try? await Task.sleep(for: .milliseconds(delayMillis)) }
            guard isCurrent(generation) else { return }
            if rebuildEngine(generation: generation) {
                lock.withLock {
                    if running?.generation == generation { running?.interrupted = false }
                }
                yieldIfCurrent(.resumed, generation: generation)
                return
            }
        }
        fail(generation, with: .interruptedForGood)
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.withLock { running?.generation == generation }
    }

    private func handleRouteChange(generation: Int) {
        let route = AVAudioSession.sharedInstance().currentRoute
        let inputs = route.inputs.map { "\($0.portName) (\($0.portType.rawValue))" }
        let description = inputs.isEmpty ? "no input" : inputs.joined(separator: ", ")
        yieldIfCurrent(.routeChanged("Input: \(description)"), generation: generation)
    }

    private func handleConfigurationChange(generation: Int) {
        // While interrupted the system stops the engine too: the resume path rebuilds it.
        let skip = lock.withLock { running?.generation != generation || running?.interrupted == true }
        guard !skip else { return }
        if !rebuildEngine(generation: generation) {
            fail(generation, with: .startFailed("the audio input changed and could not be restarted"))
        }
    }

    /// Restarts the engine with whatever input format the system has now. Returns false when it can't start.
    private func rebuildEngine(generation: Int) -> Bool {
        lock.withLock {
            guard let r = running, r.generation == generation else { return false }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setActive(true)
                r.engine.inputNode.removeTap(onBus: 0)
                r.engine.stop()
                let format = r.engine.inputNode.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { return false }
                r.pipeline.setConverter(try PCMConverter16k(inputFormat: format))
                installTap(on: r.engine, format: format, pipeline: r.pipeline)
                r.engine.prepare()
                try r.engine.start()
                return true
            } catch {
                return false
            }
        }
    }
}
