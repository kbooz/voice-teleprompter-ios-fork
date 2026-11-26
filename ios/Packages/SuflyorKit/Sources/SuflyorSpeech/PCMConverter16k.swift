import AVFAudio
import Foundation
import SuflyorDomain

/// Any `AVAudioPCMBuffer` (the input node's tap, or buffers made from a `CMSampleBuffer`) to 16 kHz mono Float32,
/// the format both recognizers expect. Keeps the resampler's state between calls, so a stream converts without clicks.
// @unchecked Sendable: converter use is serialized by `lock`; the formats are immutable.
public final class PCMConverter16k: @unchecked Sendable {
    public static let sampleRate = 16_000

    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    // AVAudioConverter is not thread-safe.
    private let lock = NSLock()

    /// Carries the buffer into the converter's input block, which is not allowed to capture mutable state.
    // @unchecked Sendable: used by one synchronous convert call, never shared across threads.
    private final class InputBox: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var consumed = false
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }

    public init(inputFormat: AVAudioFormat) throws {
        guard
            inputFormat.sampleRate > 0,
            inputFormat.channelCount > 0,
            let out = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(Self.sampleRate),
                channels: 1,
                interleaved: false
            )
        else { throw CaptureError.formatUnsupported(sampleRate: Int(inputFormat.sampleRate)) }
        self.inputFormat = inputFormat
        self.outputFormat = out
        if inputFormat.commonFormat == .pcmFormatFloat32,
           inputFormat.channelCount == 1,
           inputFormat.sampleRate == Double(Self.sampleRate) {
            converter = nil // already in the target format
        } else {
            guard let c = AVAudioConverter(from: inputFormat, to: out) else {
                throw CaptureError.formatUnsupported(sampleRate: Int(inputFormat.sampleRate))
            }
            converter = c
        }
    }

    /// Converts one buffer. An empty array means nothing came out (a very short buffer, or a conversion error).
    public func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        guard let converter else {
            guard let data = buffer.floatChannelData else { return [] }
            return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }
        return lock.withLock {
            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
            let box = InputBox(buffer)
            var error: NSError?
            // .noDataNow (not .endOfStream) keeps the converter ready for the next buffer.
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if box.consumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                box.consumed = true
                inputStatus.pointee = .haveData
                return box.buffer
            }
            if status == .error || error != nil { return [] }
            guard let data = out.floatChannelData, out.frameLength > 0 else { return [] }
            return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
        }
    }
}
