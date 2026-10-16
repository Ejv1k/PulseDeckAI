import Accelerate
import AVFoundation
import Foundation

public enum LocalAnalysisError: Error, LocalizedError, Equatable {
    case trackOutsideLibrary
    case invalidAudioFormat
    case unsupportedDuration
    case unreadableAudio(String)
    case invalidMetadata

    public var errorDescription: String? {
        switch self {
        case .trackOutsideLibrary: return "Track is outside the library root"
        case .invalidAudioFormat: return "Audio file has unsupported sample rate or channel count"
        case .unsupportedDuration: return "Audio duration is empty or exceeds six hours"
        case .unreadableAudio(let message): return "Unable to read audio: \(message)"
        case .invalidMetadata: return "Audio metadata is invalid"
        }
    }
}

/// Offline signal analysis. Vocal-entry cue is a low-confidence structural estimate, not voice recognition.
/// The cache confidence field reports heuristic tempo evidence only and is capped at 0.6.
public struct LocalTrackAnalyzer: Sendable {
    public static let analyzerVersion = "local-dsp-1"
    private let waveformBinLimit = 4_096
    private let maximumDuration = 6 * 60 * 60.0
    private let chunkFrames: AVAudioFrameCount = 8_192

    public init() {}

    public func analyze(url: URL, libraryRoot: URL) throws -> TrackCacheEntry {
        let root = libraryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let fileURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard fileURL.path.hasPrefix(rootPath) else { throw LocalAnalysisError.trackOutsideLibrary }
        let relativePath = String(fileURL.path.dropFirst(rootPath.count))
        guard !relativePath.isEmpty, !relativePath.split(separator: "/").contains("..") else {
            throw LocalAnalysisError.trackOutsideLibrary
        }

        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: fileURL) }
        catch { throw LocalAnalysisError.unreadableAudio(error.localizedDescription) }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channels = Int(format.channelCount)
        let frameCount = file.length
        let duration = Double(frameCount) / sampleRate
        guard sampleRate.isFinite, (8_000...384_000).contains(sampleRate), (1...32).contains(channels) else {
            throw LocalAnalysisError.invalidAudioFormat
        }
        guard frameCount > 0, duration.isFinite, duration <= maximumDuration else { throw LocalAnalysisError.unsupportedDuration }

        let binCount = min(waveformBinLimit, max(1, Int(ceil(duration * 20))))
        var waveform = [Float](repeating: 0, count: binCount)
        var low = [Float](repeating: 0, count: binCount)
        var mid = [Float](repeating: 0, count: binCount)
        var high = [Float](repeating: 0, count: binCount)
        let featureRate = 100.0
        let featureCount = min(2_160_000, max(1, Int(ceil(duration * featureRate))))
        let featureStride = max(1, Int(ceil(Double(frameCount) / Double(featureCount))))
        var envelope = [Float](repeating: 0, count: featureCount)
        var envelopeCounts = [Int](repeating: 0, count: featureCount)
        var mono = [Float](repeating: 0, count: Int(chunkFrames))
        var absBuffer = [Float](repeating: 0, count: Int(chunkFrames))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw LocalAnalysisError.invalidAudioFormat
        }
        var frameOffset: Int64 = 0
        var lowState = 0.0
        var upperState = 0.0
        let lowAlpha = Float(min(1, 2 * Double.pi * 250 / sampleRate))
        let upperAlpha = Float(min(1, 2 * Double.pi * min(2_500, sampleRate * 0.4) / sampleRate))

        while frameOffset < frameCount {
            let requested = AVAudioFrameCount(min(Int64(chunkFrames), frameCount - frameOffset))
            do { try file.read(into: buffer, frameCount: requested) }
            catch { throw LocalAnalysisError.unreadableAudio(error.localizedDescription) }
            let count = Int(buffer.frameLength)
            guard count > 0, let channelsData = buffer.floatChannelData else { throw LocalAnalysisError.invalidAudioFormat }
            vDSP_vclr(&mono, 1, vDSP_Length(count))
            for channel in 0..<channels { vDSP_vadd(mono, 1, channelsData[channel], 1, &mono, 1, vDSP_Length(count)) }
            var scale = Float(1.0 / Double(channels))
            vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(count))
            vDSP_vabs(mono, 1, &absBuffer, 1, vDSP_Length(count))

            for i in 0..<count {
                let absoluteFrame = Int(frameOffset) + i
                let bin = min(binCount - 1, absoluteFrame * binCount / Int(frameCount))
                let value = Double(mono[i])
                guard value.isFinite else { throw LocalAnalysisError.invalidMetadata }
                let magnitude = absBuffer[i]
                waveform[bin] = max(waveform[bin], magnitude)
                lowState += Double(lowAlpha) * (value - lowState)
                upperState += Double(upperAlpha) * (value - upperState)
                let lowValue = Float(abs(lowState))
                let midValue = Float(abs(upperState - lowState))
                let highValue = Float(abs(value - upperState))
                low[bin] = max(low[bin], lowValue)
                mid[bin] = max(mid[bin], midValue)
                high[bin] = max(high[bin], highValue)
                let featureIndex = min(featureCount - 1, absoluteFrame / featureStride)
                envelope[featureIndex] += magnitude * magnitude
                envelopeCounts[featureIndex] += 1
            }
            frameOffset += Int64(count)
        }
        for index in envelope.indices where envelopeCounts[index] > 0 {
            envelope[index] = sqrt(envelope[index] / Float(envelopeCounts[index]))
        }

        let onset = onsetStrength(from: envelope)
        let tempo = estimateTempo(onsets: onset)
        let activeRange = activeBounds(envelope)
        let cues = estimateCues(duration: duration, active: activeRange)
        let timestamps = tempo.beatIntervalSeconds > 0
            ? makeBeatTimestamps(duration: duration, offset: tempo.offset, interval: tempo.beatIntervalSeconds)
            : []
        let attributes = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let fileSize = attributes.fileSize, fileSize >= 0, let modified = attributes.contentModificationDate else {
            throw LocalAnalysisError.invalidMetadata
        }
        let fingerprint = "\(fileSize)-\(Int64(modified.timeIntervalSince1970 * 1_000))"
        let bitDepth = (file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int) ?? 0
        let confidence = tempo.confidence
        let cuesMarkers = CueMarkers(startTrimCue: cues.start, vocalEntryCue: cues.vocal, mixOutCue: cues.mixOut, endTrimCue: cues.end)
        let entry = TrackCacheEntry(
            relativePath: relativePath,
            fileFingerprint: fingerprint,
            fileSizeBytes: Int64(fileSize),
            fileModificationTime: ISO8601DateFormatter().string(from: modified),
            duration: duration,
            sampleRate: sampleRate,
            channels: channels,
            bitDepth: bitDepth,
            bpm: tempo.bpm,
            musicalKey: "Unknown",
            confidence: confidence,
            waveformMetadata: WaveformMetadata(sampleCount: Int(frameCount), downsampleFactor: max(1, Int(frameCount) / binCount), peakValues: waveform, lowBandPeaks: low, midBandPeaks: mid, highBandPeaks: high),
            beatGrid: BeatGrid(firstBeatOffsetSeconds: tempo.offset, beatIntervalSeconds: tempo.beatIntervalSeconds, beatTimestamps: timestamps),
            structure: TrackStructure(sections: [], vocalSegments: []),
            cueMarkers: cuesMarkers,
            analyzerVersion: Self.analyzerVersion,
            analysisTimestamp: ISO8601DateFormatter().string(from: Date())
        )
        guard entry.isValid else { throw LocalAnalysisError.invalidMetadata }
        return entry
    }

    private func onsetStrength(from envelope: [Float]) -> [Float] {
        guard envelope.count > 1 else { return [] }
        var result = [Float](repeating: 0, count: envelope.count)
        for index in 1..<envelope.count { result[index] = max(0, envelope[index] - envelope[index - 1]) }
        let peak = result.max() ?? 0
        if peak > 0 { var divisor = peak; vDSP_vsdiv(result, 1, &divisor, &result, 1, vDSP_Length(result.count)) }
        return result
    }

    private func estimateTempo(onsets: [Float]) -> (bpm: Double, confidence: Double, offset: Double, beatIntervalSeconds: Double) {
        guard onsets.count >= 300, (onsets.max() ?? 0) > 0 else { return (0, 0, 0, 0) }
        let rate = 100.0
        var candidates: [(Double, Double, Int)] = []
        for bpm in stride(from: 200.0, through: 60.0, by: -1.0) {
            let lag = Int((60.0 / bpm * rate).rounded())
            guard lag > 0, lag < onsets.count / 2 else { continue }
            var score = 0.0
            var norm = 0.0
            for index in lag..<onsets.count { score += Double(onsets[index] * onsets[index - lag]); norm += Double(onsets[index] * onsets[index]) }
            candidates.append((bpm, norm > 0 ? score / norm : 0, lag))
        }
        guard let best = candidates.max(by: { $0.1 < $1.1 }), best.1 > 0.03 else { return (0, 0, 0, 0) }
        let next = candidates.filter { abs($0.0 - best.0) > 3 }.map(\.1).max() ?? 0
        let confidence = min(0.6, max(0.05, (best.1 - next) / max(0.001, best.1) * 0.6))
        let period = best.2
        let beatIntervalSeconds = Double(period) / rate
        var bestPhase = 0
        var phaseScore = -Double.infinity
        for phase in 0..<min(period, onsets.count) {
            var score = 0.0
            var i = phase
            while i < onsets.count { score += Double(onsets[i]); i += period }
            if score > phaseScore { phaseScore = score; bestPhase = phase }
        }
        return (60.0 / beatIntervalSeconds, confidence, Double(bestPhase) / rate, beatIntervalSeconds)
    }

    private func activeBounds(_ envelope: [Float]) -> (Double, Double) {
        guard let maximum = envelope.max(), maximum > 0 else { return (0, 0) }
        let threshold = max(0.000_001, maximum * 0.08)
        guard let first = envelope.firstIndex(where: { $0 >= threshold }), let last = envelope.lastIndex(where: { $0 >= threshold }) else {
            return (0, 0)
        }
        return (Double(first) / 100, Double(last + 1) / 100)
    }

    private func estimateCues(duration: Double, active: (Double, Double)) -> (start: Double, vocal: Double, mixOut: Double, end: Double) {
        let start = min(duration, max(0, active.0))
        let end = min(duration, max(start, active.1))
        let span = max(0, end - start)
        let vocal = min(end, max(start, start + min(span * 0.12, max(8, span * 0.08))))
        return (start, vocal, min(end, start + span * 0.82), end)
    }

    private func makeBeatTimestamps(duration: Double, offset: Double, interval: Double) -> [Double] {
        guard interval.isFinite, interval > 0 else { return [] }
        var beats: [Double] = []
        var time = offset
        while time < duration && beats.count < 100_000 {
            if time >= 0 { beats.append(time) }
            time += interval
        }
        return beats
    }
}
