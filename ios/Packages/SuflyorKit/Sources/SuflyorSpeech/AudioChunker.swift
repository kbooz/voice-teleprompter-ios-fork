import Foundation
import SuflyorDomain

/// Cuts a stream of mono Float samples (already at the target rate) into chunks of `chunkMillis` and measures each one
/// like Android's `AudioCapture` loop: RMS in dBFS (-120 below 1e-7) and "every sample is exactly zero".
public struct AudioChunker: Sendable {
    private let sampleRate: Int
    private let chunkSize: Int
    private var pending: [Float] = []

    public init(sampleRate: Int = 16_000, chunkMillis: Int = 100) {
        self.sampleRate = sampleRate
        // Android reads sampleRate / 10 samples per chunk.
        self.chunkSize = max(1, sampleRate * chunkMillis / 1000)
        pending.reserveCapacity(chunkSize * 2)
    }

    /// Adds samples and returns every complete chunk; the remainder waits for the next call.
    public mutating func append(_ samples: [Float]) -> [AudioChunk] {
        pending.append(contentsOf: samples)
        var chunks: [AudioChunk] = []
        var start = 0
        while pending.count - start >= chunkSize {
            chunks.append(Self.measure(Array(pending[start ..< start + chunkSize]), sampleRate: sampleRate))
            start += chunkSize
        }
        if start > 0 { pending.removeFirst(start) }
        return chunks
    }

    static func measure(_ samples: [Float], sampleRate: Int) -> AudioChunk {
        var sum = 0.0
        var nonZero = false
        for s in samples {
            if s != 0 { nonZero = true }
            sum += Double(s) * Double(s)
        }
        let rms = samples.isEmpty ? 0 : (sum / Double(samples.count)).squareRoot()
        let db: Float = rms > 1e-7 ? Float(20 * log10(rms)) : -120
        return AudioChunk(samples: samples, sampleRate: sampleRate, rmsDb: db, digitalSilence: !nonZero)
    }
}
