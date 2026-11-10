import Accelerate
import Foundation

/// Offline musical key estimation: a whole-track chromagram correlated against the
/// Krumhansl–Kessler major/minor key profiles. Pure Accelerate, no model or network.
/// Returns standard names ("Am", "Db", "F#m") that `CamelotKey.parse` understands.
public enum KeyDetector {
    /// 8192-point frames at 22.05 kHz give 2.7 Hz bins, enough to separate semitones down to ~65 Hz.
    static let frameSize = 8192
    static let minFrequency = 65.0
    static let maxFrequency = 2100.0
    /// Below this correlation the chroma is too flat (drums, noise, speech) to name a key honestly.
    static let minimumCorrelation: Float = 0.6

    static let majorProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
    static let majorNames = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    static let minorNames = ["Cm", "C#m", "Dm", "Ebm", "Em", "Fm", "F#m", "Gm", "G#m", "Am", "Bbm", "Bm"]

    /// Detects the key of mono PCM samples, or nil when no key is confident enough.
    public static func detectKey(samples: [Float], sampleRate: Double) throws -> String? {
        estimateKey(chroma: try chroma(samples: samples, sampleRate: sampleRate))
    }

    /// Sums per-frame normalized pitch-class energy; each frame counts equally regardless of loudness.
    static func chroma(samples: [Float], sampleRate: Double) throws -> [Float] {
        let n = frameSize
        let half = n / 2
        guard samples.count >= n, sampleRate > 0,
              let fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(n))), radix: .radix2, ofType: DSPSplitComplex.self) else {
            return []
        }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        let pitchClassOfBin: [Int] = (0..<half).map { k in
            let f = Double(k) * sampleRate / Double(n)
            guard k > 0, f >= minFrequency, f <= maxFrequency else { return -1 }
            let midi = 69.0 + 12.0 * log2(f / 440.0)
            return (Int(midi.rounded()) % 12 + 12) % 12
        }

        var total = [Float](repeating: 0, count: 12)
        var frame = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        var start = 0
        while start + n <= samples.count {
            try Task.checkCancellation()
            vDSP.multiply(samples[start..<(start + n)], window, result: &frame)
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBytes { bytes in
                        vDSP_ctoz(bytes.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                    }
                    let input = split
                    fft.forward(input: input, output: &split)
                    vDSP.absolute(split, result: &magnitudes)
                }
            }
            var frameChroma = [Float](repeating: 0, count: 12)
            for k in 1..<half where pitchClassOfBin[k] >= 0 {
                frameChroma[pitchClassOfBin[k]] += magnitudes[k]
            }
            if let peak = frameChroma.max(), peak > 0, peak.isFinite {
                for i in 0..<12 { total[i] += frameChroma[i] / peak }
            }
            start += n
        }
        return total
    }

    /// Picks the best of 24 rotated major/minor profiles by Pearson correlation.
    static func estimateKey(chroma: [Float]) -> String? {
        guard chroma.count == 12, chroma.allSatisfy(\.isFinite), (chroma.max() ?? 0) > 0 else { return nil }
        var best: (score: Float, tonic: Int, minor: Bool) = (-2, 0, false)
        for tonic in 0..<12 {
            for (minor, profile) in [(false, majorProfile), (true, minorProfile)] {
                let rotated = (0..<12).map { profile[($0 - tonic + 12) % 12] }
                let score = pearson(chroma, rotated)
                if score > best.score { best = (score, tonic, minor) }
            }
        }
        guard best.score >= minimumCorrelation else { return nil }
        return (best.minor ? minorNames : majorNames)[best.tonic]
    }

    static func pearson(_ a: [Float], _ b: [Float]) -> Float {
        let ma = vDSP.mean(a), mb = vDSP.mean(b)
        let da = vDSP.add(-ma, a), db = vDSP.add(-mb, b)
        let denominator = (vDSP.sumOfSquares(da) * vDSP.sumOfSquares(db)).squareRoot()
        return denominator > 0 ? vDSP.dot(da, db) / denominator : 0
    }
}
