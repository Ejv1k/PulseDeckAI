import CoreMedia
import Foundation
import SoundAnalysis

/// Where a track has singing, from the sound classifier built into macOS (on device, no download).
enum SingingDetector {
    static let windowSeconds = 3.0

    /// "singing" confidence (0...1) per 3 s window from the start of the file; empty when analysis fails,
    /// so callers fall back to cue placement without vocals.
    static func confidence(url: URL) -> [Float] {
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: windowSeconds, preferredTimescale: 1_000)
            request.overlapFactor = 0
            let analyzer = try SNAudioFileAnalyzer(url: url)
            let collector = Collector()
            try analyzer.add(request, withObserver: collector)
            analyzer.analyze()
            return collector.values
        } catch {
            return []
        }
    }

    private final class Collector: NSObject, SNResultsObserving {
        var values: [Float] = []
        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let classification = result as? SNClassificationResult else { return }
            values.append(Float(classification.classification(forIdentifier: "singing")?.confidence ?? 0))
        }
    }
}
