import AVFoundation
import CoreMedia
import SuflyorDomain
import SuflyorSpeech
import Synchronization

/// The capture session's microphone as an `AudioSource`, so the speech recognizer hears exactly the audio that is
/// being recorded and the app has no second microphone client.
///
/// It owns nothing: the camera screen starts the capture session (`CameraRecorder.prepare`) before the session store
/// calls `start()` here. Sample buffers arrive on the recorder's serial queue and are converted there.
public final class CaptureAudioSource: AudioSource, @unchecked Sendable {
    private let recorder: CameraRecorder
    private let active = Mutex<AsyncStream<AudioEvent>.Continuation?>(nil)

    init(recorder: CameraRecorder) {
        self.recorder = recorder
    }

    public func start() async throws(CaptureError) -> AsyncStream<AudioEvent> {
        // Starting again restarts the source: end the previous stream first.
        stop()
        let (stream, continuation) = AsyncStream<AudioEvent>.makeStream(bufferingPolicy: .bufferingNewest(100))
        let pipeline = AudioPipeline(continuation: continuation)
        active.withLock { $0 = continuation }
        recorder.setAudioHandler { sampleBuffer in pipeline.process(sampleBuffer) }
        recorder.setInterruptionHandler { began in
            continuation.yield(began ? .interrupted : .resumed)
        }
        continuation.onTermination = { [weak self] _ in
            self?.recorder.setAudioHandler(nil)
            self?.recorder.setInterruptionHandler(nil)
        }
        return stream
    }

    public func stop() {
        let continuation = active.withLock { current -> AsyncStream<AudioEvent>.Continuation? in
            defer { current = nil }
            return current
        }
        recorder.setAudioHandler(nil)
        recorder.setInterruptionHandler(nil)
        continuation?.finish()
    }
}

/// Sample buffer to 16 kHz mono chunks. Used from the recorder's serial sample queue only, which is why it can
/// hold mutable state without a lock.
private final class AudioPipeline: @unchecked Sendable {
    private let continuation: AsyncStream<AudioEvent>.Continuation
    private var converter: PCMConverter16k?
    private var converterFormat: AVAudioFormat?
    private var chunker = AudioChunker()
    private var failed = false

    init(continuation: AsyncStream<AudioEvent>.Continuation) {
        self.continuation = continuation
    }

    func process(_ sampleBuffer: CMSampleBuffer) {
        guard !failed, let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        if converter == nil || converterFormat != pcm.format {
            do {
                converter = try PCMConverter16k(inputFormat: pcm.format)
                converterFormat = pcm.format
            } catch {
                failed = true
                Journal.shared.error("Capture audio: converter", error)
                continuation.yield(.failed(.formatUnsupported(sampleRate: Int(pcm.format.sampleRate))))
                continuation.finish()
                return
            }
        }
        guard let converter else { return }
        let samples = converter.convert(pcm)
        guard !samples.isEmpty else { return }
        for chunk in chunker.append(samples) {
            continuation.yield(.chunk(chunk))
        }
    }

    /// The capture output delivers linear PCM (usually Float32 or Int16, possibly interleaved) in a `CMSampleBuffer`.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard
            let description = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
            let format = AVAudioFormat(streamDescription: streamDescription)
        else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        // VERIFY: copies the samples out of the block buffer into the PCM buffer's audio buffer list.
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
