import Foundation
import AVFoundation

/// Integrated loudness per ITU-R BS.1770-4 / EBU R128 (K-weighting, 400 ms blocks with 75 % overlap,
/// -70 LUFS absolute and -10 LU relative gates), plus the sample peak, for track auto gain.
public enum LoudnessMeter {
    public struct Measurement: Sendable, Equatable {
        public let integratedLUFS: Double
        /// Largest absolute sample over all channels (linear, 1.0 = 0 dBFS).
        public let samplePeak: Float
    }

    public enum Failure: Error, Equatable { case unreadable(String), silent, unsupportedFormat }

    /// Streams the whole file; call off the main thread. Checks `Task.isCancelled` between chunks.
    public static func measure(url: URL, chunkFrames: AVAudioFrameCount = 65_536) throws -> Measurement {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw Failure.unreadable(error.localizedDescription) }
        let format = file.processingFormat
        let rate = format.sampleRate
        let channels = Int(format.channelCount)
        guard rate.isFinite, rate >= 8_000, (1...32).contains(channels),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { throw Failure.unsupportedFormat }

        var filters = (0..<channels).map { _ in KWeighting(sampleRate: rate) }
        let hop = max(1, Int((rate * 0.1).rounded()))      // 100 ms sub-block
        var subBlockSum = [Double](repeating: 0, count: channels)
        var subBlockFill = 0
        var recent: [Double] = []                          // last four sub-block energies (sum over channels)
        var blocks: [Double] = []                          // 400 ms block mean-square energies
        var peak: Float = 0

        while file.framePosition < file.length {
            if Task.isCancelled { throw CancellationError() }
            let want = AVAudioFrameCount(min(Int64(chunkFrames), file.length - file.framePosition))
            do { try file.read(into: buffer, frameCount: want) } catch { throw Failure.unreadable(error.localizedDescription) }
            let count = Int(buffer.frameLength)
            guard count > 0, let data = buffer.floatChannelData else { break }
            for i in 0..<count {
                for c in 0..<channels {
                    let x = data[c][i]
                    peak = max(peak, abs(x))
                    let y = filters[c].process(Double(x))
                    subBlockSum[c] += y * y
                }
                subBlockFill += 1
                if subBlockFill == hop {
                    recent.append(subBlockSum.reduce(0, +) / Double(hop))
                    if recent.count > 4 { recent.removeFirst() }
                    if recent.count == 4 { blocks.append(recent.reduce(0, +) / 4) }
                    subBlockSum = [Double](repeating: 0, count: channels)
                    subBlockFill = 0
                }
            }
        }
        guard let lufs = gatedLoudness(blocks) else { throw Failure.silent }
        return Measurement(integratedLUFS: lufs, samplePeak: peak)
    }

    /// Two-stage gating over block energies (channel weights 1.0, i.e. mono/stereo material).
    static func gatedLoudness(_ blocks: [Double]) -> Double? {
        func loudness(_ energy: Double) -> Double { -0.691 + 10 * log10(energy) }
        let absolute = blocks.filter { $0 > 0 && loudness($0) > -70 }
        guard !absolute.isEmpty else { return nil }
        let relativeGate = loudness(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { loudness($0) > relativeGate }
        guard !gated.isEmpty else { return nil }
        return loudness(gated.reduce(0, +) / Double(gated.count))
    }

    /// Gain (dB) that brings a track to `targetLUFS`, kept within `range` and never pushing the
    /// sample peak above `peakCeilingDBFS` (boosting a peaky track would otherwise clip).
    public static func autoGainDB(for m: Measurement, targetLUFS: Double = -14,
                                  range: ClosedRange<Double> = -12...9, peakCeilingDBFS: Double = -1) -> Double {
        var gain = min(max(targetLUFS - m.integratedLUFS, range.lowerBound), range.upperBound)
        if m.samplePeak > 0 {
            let headroom = peakCeilingDBFS - 20 * log10(Double(m.samplePeak))
            gain = min(gain, max(headroom, range.lowerBound))
        }
        return gain
    }

    /// BS.1770 K-weighting: high-shelf pre-filter then RLB high-pass, both designed for `sampleRate`.
    struct KWeighting {
        private var shelf: Biquad, highPass: Biquad
        init(sampleRate rate: Double) {
            var k = tan(Double.pi * 1681.974450955533 / rate)
            let q1 = 0.7071752369554196
            let vh = pow(10, 3.999843853973347 / 20), vb = pow(vh, 0.4996667741545416)
            var a0 = 1 + k / q1 + k * k
            shelf = Biquad(b0: (vh + vb * k / q1 + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q1 + k * k) / a0,
                           a1: 2 * (k * k - 1) / a0, a2: (1 - k / q1 + k * k) / a0)
            k = tan(Double.pi * 38.13547087602444 / rate)
            let q2 = 0.5003270373238773
            a0 = 1 + k / q2 + k * k
            highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q2 + k * k) / a0)
        }
        mutating func process(_ x: Double) -> Double { highPass.process(shelf.process(x)) }
    }

    struct Biquad {
        let b0, b1, b2, a1, a2: Double
        private var z1 = 0.0, z2 = 0.0
        init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
            self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
        }
        mutating func process(_ x: Double) -> Double { // Transposed direct form II.
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }
}
