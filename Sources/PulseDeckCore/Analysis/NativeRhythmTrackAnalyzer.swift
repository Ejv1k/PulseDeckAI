import AVFoundation
import Accelerate
import Foundation

/// Analyzes an audio track using the native CoreML Beat This! (small0) neural network
/// for beat and downbeat tracking, deriving tempo from median inter-beat intervals.
/// Operates strictly off-MainActor, non-RT.
public struct NativeRhythmTrackAnalyzer: Sendable {
    /// Distinct version identifier explicitly documenting the model, checkpoint,
    /// fixed 1500-frame context padding adaptation, and FP32 precision.
    public static let analyzerVersion = "model-beatthis-small0-fixed1500-fp32"

    private let waveformBinLimit = 4_096
    // The model path holds the whole track plus its spectrogram in memory; 30 min keeps peak use near 1 GB.
    private let maximumDuration = 30 * 60.0
    private let chunkFrames: AVAudioFrameCount = 8_192

    public init() {}

    public func analyze(url: URL, libraryRoot: URL) async throws -> TrackCacheEntry {
        let root = libraryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let fileURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard fileURL.path.hasPrefix(rootPath) else {
            throw NativeRhythmAnalysisError.trackOutsideLibrary
        }
        let relativePath = String(fileURL.path.dropFirst(rootPath.count))
        guard !relativePath.isEmpty, !relativePath.split(separator: "/").contains("..") else {
            throw NativeRhythmAnalysisError.trackOutsideLibrary
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: fileURL)
        } catch {
            throw NativeRhythmAnalysisError.unreadableAudio(error.localizedDescription)
        }

        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channels = Int(format.channelCount)
        let frameCount = file.length
        let duration = Double(frameCount) / sampleRate

        guard sampleRate.isFinite, (8_000...384_000).contains(sampleRate), (1...32).contains(channels) else {
            throw NativeRhythmAnalysisError.invalidAudioFormat
        }
        guard frameCount > 0, duration.isFinite, duration <= maximumDuration else {
            throw NativeRhythmAnalysisError.unsupportedDuration
        }

        // 1. Compute multi-band waveform display peaks and energy envelope for visual rendering & cues
        let binCount = min(waveformBinLimit, max(1, Int(ceil(duration * 20))))
        var waveform = [Float](repeating: 0, count: binCount)
        var low = [Float](repeating: 0, count: binCount)
        var mid = [Float](repeating: 0, count: binCount)
        var high = [Float](repeating: 0, count: binCount)
        let featureRate = 100.0
        let featureCount = min(2_160_000, max(1, Int(ceil(duration * featureRate))))
        var envelope = [Float](repeating: 0, count: featureCount)
        var envelopeCounts = [Int](repeating: 0, count: featureCount)
        var mono = [Float](repeating: 0, count: Int(chunkFrames))
        var absBuffer = [Float](repeating: 0, count: Int(chunkFrames))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw NativeRhythmAnalysisError.invalidAudioFormat
        }

        var frameOffset: Int64 = 0
        var envelopeFeatureIndex = 0
        var nextFeatureBoundary = Int64(ceil(sampleRate / featureRate))
        var lowState = 0.0
        var upperState = 0.0
        let lowAlpha = Float(min(1, 2 * Double.pi * 250 / sampleRate))
        let upperAlpha = Float(min(1, 2 * Double.pi * min(2_500, sampleRate * 0.4) / sampleRate))

        while frameOffset < frameCount {
            try Task.checkCancellation()
            let requested = AVAudioFrameCount(min(Int64(chunkFrames), frameCount - frameOffset))
            do {
                try file.read(into: buffer, frameCount: requested)
            } catch {
                throw NativeRhythmAnalysisError.unreadableAudio(error.localizedDescription)
            }
            let count = Int(buffer.frameLength)
            guard count > 0, let channelsData = buffer.floatChannelData else {
                throw NativeRhythmAnalysisError.invalidAudioFormat
            }
            vDSP_vclr(&mono, 1, vDSP_Length(count))
            for channel in 0..<channels {
                vDSP_vadd(mono, 1, channelsData[channel], 1, &mono, 1, vDSP_Length(count))
            }
            var scale = Float(1.0 / Double(channels))
            vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(count))
            vDSP_vabs(mono, 1, &absBuffer, 1, vDSP_Length(count))

            for i in 0..<count {
                let absoluteFrame = Int(frameOffset) + i
                while envelopeFeatureIndex + 1 < featureCount && Int64(absoluteFrame) >= nextFeatureBoundary {
                    envelopeFeatureIndex += 1
                    nextFeatureBoundary = Int64(ceil(Double(envelopeFeatureIndex + 1) * sampleRate / featureRate))
                }
                let bin = min(binCount - 1, absoluteFrame * binCount / Int(frameCount))
                let value = Double(mono[i])
                guard value.isFinite else { throw NativeRhythmAnalysisError.invalidMetadata }
                let magnitude = absBuffer[i]
                waveform[bin] = max(waveform[bin], min(1, magnitude))
                lowState += Double(lowAlpha) * (value - lowState)
                upperState += Double(upperAlpha) * (value - upperState)
                let lowValue = Float(abs(lowState))
                let midValue = Float(abs(upperState - lowState))
                let highValue = Float(abs(value - upperState))
                low[bin] = max(low[bin], min(1, lowValue))
                mid[bin] = max(mid[bin], min(1, midValue))
                high[bin] = max(high[bin], min(1, highValue))
                envelope[envelopeFeatureIndex] += magnitude * magnitude
                envelopeCounts[envelopeFeatureIndex] += 1
            }
            frameOffset += Int64(count)
        }
        for index in envelope.indices where envelopeCounts[index] > 0 {
            envelope[index] = sqrt(envelope[index] / Float(envelopeCounts[index]))
        }

        try Task.checkCancellation()

        // 2. Run bundled CoreML Beat This! rhythm service
        let rhythmService: ModelRhythmService
        do {
            rhythmService = try ModelRhythmService(computeUnits: .cpuOnly)
        } catch {
            throw NativeRhythmAnalysisError.modelError(error.localizedDescription)
        }

        let rhythmAnalysis: ModelRhythmAnalysis
        do {
            rhythmAnalysis = try await rhythmService.analyzeRhythm(audioURL: fileURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NativeRhythmAnalysisError.modelError(error.localizedDescription)
        }

        try Task.checkCancellation()

        // 3. Derive tempo and beat grid from detected beats
        // The 50.0 to 220.0 BPM tempo range matches the supported native rhythm estimation domain.
        // Out-of-domain tempi trigger InsufficientBeats without silent octave correction,
        // preserving any previously stored valid analysis in the application cache.
        let beats = rhythmAnalysis.beats.filter { $0.isFinite && $0 >= 0.0 && $0 <= duration }
        guard beats.count >= 2 else {
            throw NativeRhythmAnalysisError.insufficientBeats("Detected \(beats.count) beats; minimum 2 required for tempo estimation.")
        }

        var validIntervals: [Double] = []
        for i in 1..<beats.count {
            let interval = beats[i] - beats[i - 1]
            // Valid interval corresponding to 50.0 to 220.0 BPM: 60/220 = ~0.2727s, 60/50 = 1.200s
            if interval >= 0.2727 && interval <= 1.2000 {
                validIntervals.append(interval)
            }
        }

        guard validIntervals.count >= 2 else {
            throw NativeRhythmAnalysisError.insufficientBeats("Fewer than 2 valid rhythmic intervals in tempo range 50-220 BPM.")
        }

        let sortedIntervals = validIntervals.sorted()
        let medianInterval: Double
        if sortedIntervals.count % 2 == 1 {
            medianInterval = sortedIntervals[sortedIntervals.count / 2]
        } else {
            medianInterval = (sortedIntervals[sortedIntervals.count / 2 - 1] + sortedIntervals[sortedIntervals.count / 2]) / 2.0
        }

        guard medianInterval > 0, medianInterval.isFinite else {
            throw NativeRhythmAnalysisError.insufficientBeats("Calculated interval is non-finite or non-positive.")
        }

        // The model works on 20 ms frames, so a single interval is quantized; averaging the regular
        // intervals around the median restores sub-frame tempo precision (e.g. 123 BPM instead of 125).
        let regularIntervals = validIntervals.filter { abs($0 - medianInterval) <= 0.05 * medianInterval }
        let beatInterval = regularIntervals.isEmpty ? medianInterval : regularIntervals.reduce(0, +) / Double(regularIntervals.count)

        let rawBPM = 60.0 / beatInterval
        let bpm = (rawBPM * 10.0).rounded() / 10.0
        guard bpm >= 50.0 && bpm <= 220.0 else {
            throw NativeRhythmAnalysisError.insufficientBeats("Derived tempo \(bpm) BPM is outside valid 50-220 range.")
        }

        // Uncalibrated regularity heuristic: scales regularity by valid interval coverage.
        // Floor 0.10 is not a minimum probability guarantee. Bounded strictly in [0.10, 0.85].
        let totalIntervalCount = max(1, beats.count - 1)
        let coverage = Double(validIntervals.count) / Double(totalIntervalCount)
        let regularCount = regularIntervals.count
        let regularity = Double(regularCount) / Double(validIntervals.count)
        let rawScore = regularity * coverage * 0.85
        let confidence = min(0.85, max(0.10, rawScore))

        let firstBeatOffset = beats.first ?? 0.0
        let beatGrid = BeatGrid(
            firstBeatOffsetSeconds: firstBeatOffset,
            beatIntervalSeconds: beatInterval,
            beatTimestamps: beats
        )

        // 4. Estimate cues from active envelope bounds (fallback to duration bounds)
        let activeRange = activeBounds(envelope, featureRate: featureRate)
        let cues = estimateCues(duration: duration, active: activeRange)
        let cueMarkers = CueMarkers(
            startTrimCue: cues.start,
            vocalEntryCue: cues.vocal,
            mixOutCue: cues.mixOut,
            endTrimCue: cues.end
        )

        // 5. File attributes and fingerprint
        let attributes = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let fileSize = attributes.fileSize, fileSize >= 0, let modified = attributes.contentModificationDate else {
            throw NativeRhythmAnalysisError.invalidMetadata
        }
        let fingerprint = "\(fileSize)-\(Int64(modified.timeIntervalSince1970 * 1_000))"
        let bitDepth: Int
        switch format.commonFormat {
        case .pcmFormatFloat32, .pcmFormatInt32: bitDepth = 32
        case .pcmFormatFloat64: bitDepth = 64
        case .pcmFormatInt16: bitDepth = 16
        case .otherFormat: throw NativeRhythmAnalysisError.invalidAudioFormat
        @unknown default: throw NativeRhythmAnalysisError.invalidAudioFormat
        }

        let entry = TrackCacheEntry(
            relativePath: relativePath,
            fileFingerprint: fingerprint,
            fileSizeBytes: Int64(fileSize),
            fileModificationTime: ISO8601DateFormatter().string(from: modified),
            duration: duration,
            sampleRate: sampleRate,
            channels: channels,
            bitDepth: bitDepth,
            bpm: bpm,
            musicalKey: "Unknown",
            confidence: confidence,
            waveformMetadata: WaveformMetadata(
                sampleCount: Int(frameCount),
                downsampleFactor: max(1, Int(frameCount) / binCount),
                peakValues: waveform,
                lowBandPeaks: low,
                midBandPeaks: mid,
                highBandPeaks: high
            ),
            beatGrid: beatGrid,
            structure: TrackStructure(sections: [], vocalSegments: []),
            cueMarkers: cueMarkers,
            analyzerVersion: Self.analyzerVersion,
            analysisTimestamp: ISO8601DateFormatter().string(from: Date())
        )

        guard entry.isValid else {
            throw NativeRhythmAnalysisError.invalidMetadata
        }
        return entry
    }

    private func activeBounds(_ envelope: [Float], featureRate: Double) -> (start: Double, end: Double) {
        guard let peak = envelope.max(), peak > 0.0001 else { return (0, Double(envelope.count) / featureRate) }
        let threshold = peak * 0.08
        let first = envelope.firstIndex(where: { $0 >= threshold }) ?? 0
        let last = envelope.lastIndex(where: { $0 >= threshold }) ?? max(0, envelope.count - 1)
        return (Double(first) / featureRate, Double(last + 1) / featureRate)
    }

    private func estimateCues(duration: Double, active: (start: Double, end: Double)) -> (start: Double, vocal: Double, mixOut: Double, end: Double) {
        let start = min(duration, max(0, active.start))
        let end = max(start, min(duration, active.end))
        let playable = max(0, end - start)
        let vocal = start + min(playable * 0.15, max(0, playable - 0.1))
        let mixOut = max(vocal, end - min(playable * 0.20, max(0, playable - 0.1)))
        return (start, vocal, mixOut, end)
    }
}

public enum NativeRhythmAnalysisError: LocalizedError, Equatable {
    case trackOutsideLibrary
    case unreadableAudio(String)
    case invalidAudioFormat
    case unsupportedDuration
    case invalidMetadata
    case insufficientBeats(String)
    case modelError(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .trackOutsideLibrary: return "Track is outside library root directory"
        case .unreadableAudio(let reason): return "Unreadable audio: \(reason)"
        case .invalidAudioFormat: return "Unsupported audio sample rate or channel configuration"
        case .unsupportedDuration: return "Track duration is 0 or exceeds maximum supported limit"
        case .invalidMetadata: return "Audio file metadata is invalid or incomplete"
        case .insufficientBeats(let reason): return "Insufficient rhythm: \(reason)"
        case .modelError(let reason): return "CoreML model error: \(reason)"
        case .cancelled: return "Native rhythm analysis was cancelled"
        }
    }
}
