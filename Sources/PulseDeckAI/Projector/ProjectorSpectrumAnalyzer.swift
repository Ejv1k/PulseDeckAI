import Foundation
import PulseDeckCore

/// Pure-Swift, non-allocating spectrum analyzer that aggregates 512 linear FFT bins from
/// `AudioMeterSnapshot` into 24 perceptually-spaced visualizer bands with smooth peak decay.
///
/// Designed to run entirely on the UI thread / MainActor. Performs zero audio real-time allocations,
/// zero locking, and zero access to audio input nodes.
public final class ProjectorSpectrumAnalyzer: @unchecked Sendable {
    public static let bandCount = 24

    // Approximate frequency boundary table (Hz) for 24 bands spanning 20 Hz to 22.05 kHz.
    private static let frequencyBoundaries: [Double] = [
        20, 50, 80, 120, 180, 250, 350, 500, 700, 1000,
        1400, 2000, 2800, 3800, 5000, 6500, 8000, 10000, 12000, 14000,
        16000, 18000, 20000, 21000, 22050
    ]

    private var currentBands: [Float]
    private var lastHostTime: UInt64 = 0
    private var staleFrameCount: Int = 0

    public init() {
        self.currentBands = Array(repeating: 0.0, count: Self.bandCount)
    }

    /// Resets all visualizer bands and state to silence.
    public func reset() {
        currentBands = Array(repeating: 0.0, count: Self.bandCount)
        lastHostTime = 0
        staleFrameCount = 0
    }

    /// Processes an incoming `AudioMeterSnapshot` and returns an updated `ProjectorVisualizerFrame`.
    ///
    /// If the snapshot is nil, below the noise floor, or stale, bands decay smoothly toward 0.0.
    /// Never generates artificial or randomized FFT data.
    public func processSnapshot(
        _ snapshot: AudioMeterSnapshot?,
        decayRate: Float = 0.18,
        attackRate: Float = 0.85
    ) -> ProjectorVisualizerFrame {
        guard let snapshot else {
            decayToZero(rate: decayRate)
            return ProjectorVisualizerFrame(
                bands: currentBands,
                rms: 0.0,
                peak: 0.0,
                timestamp: lastHostTime,
                isSilent: true
            )
        }

        // Stale frame check: If the same hostTime repeats for more than 4 cycles (~130ms at 30Hz),
        // the audio engine has stopped updating the ring buffer.
        if snapshot.hostTime == lastHostTime && snapshot.hostTime != 0 {
            staleFrameCount += 1
        } else {
            staleFrameCount = 0
            lastHostTime = snapshot.hostTime
        }

        let isStale = staleFrameCount >= 4
        let isSilent = snapshot.rms < 1e-4 || snapshot.peak < 1e-4 || isStale

        if isSilent {
            decayToZero(rate: decayRate)
            return ProjectorVisualizerFrame(
                bands: currentBands,
                rms: isStale ? 0.0 : snapshot.rms,
                peak: isStale ? 0.0 : snapshot.peak,
                timestamp: snapshot.hostTime,
                isSilent: true
            )
        }

        // Project the 512 linear FFT bins into 24 frequency bands
        let sampleRate = snapshot.sampleRate > 0 ? snapshot.sampleRate : 44100.0
        let fftSize = snapshot.fftSize > 0 ? Double(snapshot.fftSize) : 1024.0
        let binWidth = sampleRate / fftSize
        let spectrum = snapshot.spectrum
        let binCount = spectrum.count

        for i in 0..<Self.bandCount {
            let lowFreq = Self.frequencyBoundaries[i]
            let highFreq = Self.frequencyBoundaries[i + 1]

            let startBin = max(0, min(binCount - 1, Int(lowFreq / binWidth)))
            let endBin = max(startBin, min(binCount - 1, Int(ceil(highFreq / binWidth))))

            var bandMax: Float = 0.0
            for b in startBin...endBin {
                let mag = spectrum[b]
                if mag > bandMax {
                    bandMax = mag
                }
            }

            // Dynamic compression and perceptual visual scaling
            // FFT magnitude is scaled with a sub-linear curve for dynamic responsiveness
            let scaledMagnitude = min(max(powf(bandMax * 3.5, 0.7), 0.0), 1.0)

            // Attack/decay peak ballistics
            let previous = currentBands[i]
            if scaledMagnitude > previous {
                currentBands[i] = previous + (scaledMagnitude - previous) * attackRate
            } else {
                currentBands[i] = max(0.0, previous - (previous * decayRate))
            }
        }

        return ProjectorVisualizerFrame(
            bands: currentBands,
            rms: snapshot.rms,
            peak: snapshot.peak,
            timestamp: snapshot.hostTime,
            isSilent: false
        )
    }

    private func decayToZero(rate: Float) {
        for i in 0..<Self.bandCount {
            currentBands[i] = max(0.0, currentBands[i] - (currentBands[i] * rate))
            if currentBands[i] < 0.001 {
                currentBands[i] = 0.0
            }
        }
    }
}
