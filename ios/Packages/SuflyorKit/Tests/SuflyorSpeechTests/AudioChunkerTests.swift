import AVFAudio
import Foundation
import SuflyorDomain
import Testing

@testable import SuflyorSpeech

@Suite struct AudioChunkerTests {
    private func constant(_ value: Float, count: Int) -> [Float] {
        [Float](repeating: value, count: count)
    }

    @Test func cutsHundredMillisecondChunksAndKeepsTheRemainder() {
        var chunker = AudioChunker() // 16 kHz, 100 ms = 1600 samples
        let first = chunker.append(constant(0.5, count: 4000))
        #expect(first.count == 2)
        #expect(first.allSatisfy { $0.samples.count == 1600 && $0.sampleRate == 16_000 })

        // 800 samples were left over: 1000 more complete another chunk and leave 200.
        let second = chunker.append(constant(0.5, count: 1000))
        #expect(second.count == 1)
        let third = chunker.append(constant(0.5, count: 1400))
        #expect(third.count == 1) // 200 + 1400 = 1600 exactly
        #expect(chunker.append([]).isEmpty)
    }

    @Test func aSmallAppendGivesNothingUntilEnoughArrives() {
        var chunker = AudioChunker()
        #expect(chunker.append(constant(0.1, count: 1599)).isEmpty)
        #expect(chunker.append(constant(0.1, count: 1)).count == 1)
    }

    @Test func chunkSizeFollowsTheRateAndDuration() {
        var chunker = AudioChunker(sampleRate: 48_000, chunkMillis: 100)
        let chunks = chunker.append(constant(0.2, count: 4800))
        #expect(chunks.count == 1)
        #expect(chunks[0].samples.count == 4800)
        #expect(chunks[0].sampleRate == 48_000)

        var short = AudioChunker(sampleRate: 16_000, chunkMillis: 20)
        #expect(short.append(constant(0.2, count: 960)).count == 3) // 320 samples each
    }

    @Test func rmsIsInDecibelsFullScale() {
        var chunker = AudioChunker()
        let half = chunker.append(constant(0.5, count: 1600))[0]
        #expect(abs(half.rmsDb - (-6.0206)) < 0.01)
        let tenth = chunker.append(constant(-0.1, count: 1600))[0] // the sign doesn't matter
        #expect(abs(tenth.rmsDb - (-20)) < 0.01)
        #expect(!half.digitalSilence)
    }

    @Test func aSquareSignalOfMixedValuesUsesTheRms() {
        var chunker = AudioChunker()
        let samples = (0..<1600).map { $0 % 2 == 0 ? Float(0.4) : Float(-0.4) }
        #expect(abs(chunker.append(samples)[0].rmsDb - 20 * log10(0.4)) < 0.01)
    }

    @Test func exactZerosAreDigitalSilence() {
        var chunker = AudioChunker()
        let chunk = chunker.append(constant(0, count: 1600))[0]
        #expect(chunk.digitalSilence)
        #expect(chunk.rmsDb == -120)
    }

    @Test func aVeryQuietSignalIsFloorLevelButNotDigitalSilence() {
        var chunker = AudioChunker()
        let chunk = chunker.append(constant(1e-9, count: 1600))[0]
        #expect(!chunk.digitalSilence) // one non-zero sample is enough, as on Android
        #expect(chunk.rmsDb == -120) // below the 1e-7 threshold
    }

    @Test func oneNonZeroSampleBreaksDigitalSilence() {
        var chunker = AudioChunker()
        var samples = constant(0, count: 1600)
        samples[800] = 0.001
        #expect(!chunker.append(samples)[0].digitalSilence)
    }
}

@Suite struct PCMConverter16kTests {
    private func buffer(sampleRate: Double, channels: AVAudioChannelCount, frames: Int, value: Float) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for i in 0..<frames { data[channel][i] = value }
        }
        return buffer
    }

    @Test func monoSixteenKilohertzPassesThrough() throws {
        let input = try buffer(sampleRate: 16_000, channels: 1, frames: 1600, value: 0.25)
        let converter = try PCMConverter16k(inputFormat: input.format)
        let out = converter.convert(input)
        #expect(out.count == 1600)
        #expect(out.allSatisfy { $0 == 0.25 })
    }

    @Test func resamplesFrom48Kilohertz() throws {
        let input = try buffer(sampleRate: 48_000, channels: 1, frames: 4800, value: 0.5)
        let converter = try PCMConverter16k(inputFormat: input.format)
        var total = 0
        for _ in 0..<5 { total += converter.convert(input).count }
        // 0.5 s of audio gives about 8000 samples (the resampler holds back a few at the start).
        #expect(abs(total - 8000) < 400)
    }

    @Test func mixesStereoDownToMono() throws {
        let input = try buffer(sampleRate: 16_000, channels: 2, frames: 1600, value: 0.5)
        let converter = try PCMConverter16k(inputFormat: input.format)
        let out = converter.convert(input)
        #expect(abs(out.count - 1600) < 200)
        #expect(out.contains { $0 != 0 })
    }
}
