import CoreMedia
import Foundation
import SoundAnalysis

/// Where a track has singing, from the sound classifier built into macOS (on device, no download).
enum SingingDetector {
    static let windowSeconds = 3.0

    /// "singing" confidence (0...1) per 3 s window from the start of the file; empty when analysis fails,
    /// so callers fall back to cue placement without vocals. Throws only when the task is cancelled.
    static func confidence(url: URL) async throws -> [Float] {
        try Task.checkCancellation()
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: windowSeconds, preferredTimescale: 1_000)
            request.overlapFactor = 0
            nonisolated(unsafe) let analyzer = try SNAudioFileAnalyzer(url: url)
            let collector = Collector()
            try analyzer.add(request, withObserver: collector)
            await withTaskCancellationHandler {
                analyzer.analyze()
            } onCancel: {
                analyzer.cancelAnalysis()
            }
            try Task.checkCancellation()
            return collector.failed ? [] : collector.values
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return []
        }
    }

    private final class Collector: NSObject, SNResultsObserving {
        var values: [Float] = []
        var failed = false
        func request(_ request: SNRequest, didFailWithError error: Error) { failed = true }
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let classification = result as? SNClassificationResult else { return }
            values.append(Float(classification.classification(forIdentifier: "singing")?.confidence ?? 0))
        }
    }
}
