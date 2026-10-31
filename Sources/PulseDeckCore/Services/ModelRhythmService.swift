import CoreML
import Foundation

public struct ModelRhythmAnalysis: Sendable, Equatable {
    public let beats: [Double]
    public let downbeats: [Double]
    public let modelName: String
    public let modelVersion: String
    public let frameRateHz: Double

    public init(
        beats: [Double],
        downbeats: [Double],
        modelName: String = "BeatThis_small0",
        modelVersion: String = "small0_fp32",
        frameRateHz: Double = 50.0
    ) {
        self.beats = beats
        self.downbeats = downbeats
        self.modelName = modelName
        self.modelVersion = modelVersion
        self.frameRateHz = frameRateHz
    }
}

public enum ModelRhythmServiceError: Error, LocalizedError, Equatable {
    case modelNotFound(String)
    case modelExecutionFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let name): return "CoreML rhythm model not found: \(name)"
        case .modelExecutionFailed(let reason): return "CoreML rhythm inference failed: \(reason)"
        case .cancelled: return "Rhythm analysis was cancelled"
        }
    }
}

private final class CoreMLModelRunner: @unchecked Sendable {
    private let model: MLModel

    init(model: MLModel) {
        self.model = model
    }

    func predict(input: MLFeatureProvider) throws -> MLFeatureProvider {
        try model.prediction(from: input)
    }
}

/// Actor providing native CoreML rhythm inference for beats and downbeats using Beat This! small0.
/// Zero Python/Torch runtime dependency. Bounded, off-MainActor, non-RT execution.
public actor ModelRhythmService {
    public static let defaultChunkSize = 1500
    public static let defaultBorderSize = 6
    public static let defaultFrameRateHz = 50.0
    public static let defaultModelName = "BeatThis_small0_fp32"

    private let runner: CoreMLModelRunner
    private let frontend: SlaneyMelSpectrogram
    public let modelName: String
    public let modelVersion: String

    public init(
        modelURL: URL? = nil,
        frontend: SlaneyMelSpectrogram? = nil,
        computeUnits: MLComputeUnits = .cpuOnly
    ) throws {
        let resolvedModelURL: URL
        if let modelURL = modelURL {
            resolvedModelURL = modelURL
        } else {
            guard let bundleURL = Bundle.module.url(forResource: Self.defaultModelName, withExtension: "mlmodelc") else {
                throw ModelRhythmServiceError.modelNotFound(Self.defaultModelName)
            }
            resolvedModelURL = bundleURL
        }

        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        let loadedModel: MLModel
        do {
            loadedModel = try MLModel(contentsOf: resolvedModelURL, configuration: config)
        } catch {
            throw ModelRhythmServiceError.modelExecutionFailed("Failed to load MLModel: \(error.localizedDescription)")
        }
        self.runner = CoreMLModelRunner(model: loadedModel)

        if let frontend = frontend {
            self.frontend = frontend
        } else {
            self.frontend = try SlaneyMelSpectrogram()
        }

        self.modelName = "BeatThis_small0"
        self.modelVersion = "small0_fp32"
    }

    /// Analyzes rhythm from an audio file URL and returns sorted beat and downbeat timestamps.
    public func analyzeRhythm(audioURL: URL) async throws -> ModelRhythmAnalysis {
        try Task.checkCancellation()

        let samples = try SlaneyMelSpectrogram.loadAudioSamples(from: audioURL)
        return try await analyzeRhythm(samples: samples)
    }

    /// Analyzes rhythm directly from 22,050 Hz mono PCM samples.
    public func analyzeRhythm(samples: [Float]) async throws -> ModelRhythmAnalysis {
        try Task.checkCancellation()

        let spect = try frontend.computeLogMelSpectrogram(samples: samples)
        let numFrames = spect.count / SlaneyMelSpectrogram.numMels

        guard numFrames > 0 else {
            return ModelRhythmAnalysis(beats: [], downbeats: [])
        }

        let (beatLogits, downbeatLogits) = try await predictLogits(spect: spect, numFrames: numFrames)

        try Task.checkCancellation()

        let beats = Self.extractPeaks(logits: beatLogits, threshold: 0.0, frameRate: Self.defaultFrameRateHz)
        let rawDownbeats = Self.extractPeaks(logits: downbeatLogits, threshold: 0.0, frameRate: Self.defaultFrameRateHz)
        let downbeats = Self.snapDownbeats(downbeats: rawDownbeats, beats: beats)

        return ModelRhythmAnalysis(
            beats: beats,
            downbeats: downbeats,
            modelName: modelName,
            modelVersion: modelVersion,
            frameRateHz: Self.defaultFrameRateHz
        )
    }

    /// Implements upstream split_piece + inference + aggregate_prediction.
    private func predictLogits(spect: [Float], numFrames: Int) async throws -> ([Float], [Float]) {
        let chunkSize = Self.defaultChunkSize
        let borderSize = Self.defaultBorderSize
        let numMels = SlaneyMelSpectrogram.numMels
        let effectiveChunkHop = chunkSize - 2 * borderSize

        // Generate chunk starts matching upstream split_piece
        var starts: [Int] = []
        var s = -borderSize
        while s < numFrames - borderSize {
            starts.append(s)
            s += effectiveChunkHop
        }
        if starts.isEmpty {
            starts = [-borderSize]
        }
        if numFrames > effectiveChunkHop && starts.count > 1 {
            // avoid_short_end: shift last chunk to end exactly at end of spectrogram
            starts[starts.count - 1] = numFrames - (chunkSize - borderSize)
        }

        // Aggregate predictions initialized to -1000.0 (probability 0)
        var pieceBeat = [Float](repeating: -1000.0, count: numFrames)
        var pieceDownbeat = [Float](repeating: -1000.0, count: numFrames)

        // Process in reverse order so earlier excerpts overwrite later ones (keep_first)
        for start in starts.reversed() {
            try Task.checkCancellation()

            let chunkInput = try MLMultiArray(shape: [1, chunkSize, numMels] as [NSNumber], dataType: .float32)
            let ptr = chunkInput.dataPointer.bindMemory(to: Float.self, capacity: chunkSize * numMels)
            ptr.initialize(repeating: 0, count: chunkSize * numMels)

            // Fill chunk with zeropad left/right
            for i in 0..<chunkSize {
                let frameIdx = start + i
                if frameIdx >= 0 && frameIdx < numFrames {
                    let srcOffset = frameIdx * numMels
                    let dstOffset = i * numMels
                    for b in 0..<numMels {
                        ptr[dstOffset + b] = spect[srcOffset + b]
                    }
                }
            }

            let inputProvider = try MLDictionaryFeatureProvider(dictionary: [
                "log_mel_spectrogram": MLFeatureValue(multiArray: chunkInput)
            ])

            let output = try runner.predict(input: inputProvider)

            guard let beatArray = output.featureValue(for: "beat_logits")?.multiArrayValue,
                  let downbeatArray = output.featureValue(for: "downbeat_logits")?.multiArrayValue else {
                throw ModelRhythmServiceError.modelExecutionFailed("Output features missing from model prediction")
            }

            let beatPtr = beatArray.dataPointer.bindMemory(to: Float.self, capacity: chunkSize)
            let downbeatPtr = downbeatArray.dataPointer.bindMemory(to: Float.self, capacity: chunkSize)

            // Discard border_size on both ends
            let sliceStart = borderSize
            let sliceEnd = chunkSize - borderSize
            let writeStart = start + borderSize

            for i in 0..<(sliceEnd - sliceStart) {
                let outIdx = writeStart + i
                if outIdx >= 0 && outIdx < numFrames {
                    pieceBeat[outIdx] = beatPtr[sliceStart + i]
                    pieceDownbeat[outIdx] = downbeatPtr[sliceStart + i]
                }
            }
        }

        return (pieceBeat, pieceDownbeat)
    }

    // 1D max pooling: kernel_size = 7, stride = 1, padding = 3
    public static func maxPool1D(signal: [Float], kernelSize: Int = 7) -> [Float] {
        let halfK = kernelSize / 2
        let count = signal.count
        var result = [Float](repeating: -.infinity, count: count)
        for i in 0..<count {
            var m: Float = -.infinity
            let start = max(0, i - halfK)
            let end = min(count - 1, i + halfK)
            for j in start...end {
                if signal[j] > m { m = signal[j] }
            }
            result[i] = m
        }
        return result
    }

    /// Replaces groups of adjacent peaks within `width` frames by their running average.
    public static func deduplicatePeaks(peaks: [Int], width: Double = 1.0) -> [Double] {
        guard let first = peaks.first else { return [] }
        var result: [Double] = []
        var p = Double(first)
        var c = 1.0
        for p2 in peaks.dropFirst() {
            let p2d = Double(p2)
            if p2d - p <= width {
                c += 1.0
                p += (p2d - p) / c
            } else {
                result.append(p)
                p = p2d
                c = 1.0
            }
        }
        result.append(p)
        return result
    }

    /// Extracts peak timestamps in seconds (logits == max_pool1d && logits > threshold).
    public static func extractPeaks(logits: [Float], threshold: Float = 0.0, frameRate: Double = 50.0) -> [Double] {
        guard !logits.isEmpty else { return [] }
        let pooled = maxPool1D(signal: logits, kernelSize: 7)
        var peakIndices: [Int] = []
        for i in 0..<logits.count {
            if logits[i] == pooled[i] && logits[i] > threshold {
                peakIndices.append(i)
            }
        }
        let dedupFrames = deduplicatePeaks(peaks: peakIndices, width: 1.0)
        return dedupFrames.map { $0 / frameRate }
    }

    /// Snaps each downbeat timestamp to the nearest beat timestamp, returning unique sorted timestamps.
    public static func snapDownbeats(downbeats: [Double], beats: [Double]) -> [Double] {
        guard !beats.isEmpty else { return downbeats }
        var snapped: [Double] = []
        for db in downbeats {
            var closest = beats[0]
            var minDiff = abs(db - closest)
            for b in beats.dropFirst() {
                let diff = abs(db - b)
                if diff < minDiff {
                    minDiff = diff
                    closest = b
                }
            }
            snapped.append(closest)
        }
        return Array(Set(snapped)).sorted()
    }
}
