import Foundation
import PulseDeckCore

/// Production sampler for mapping multi-band waveform bins proportionally to display columns.
/// Correctly handles both zoomed-in states (where visibleBinCount < columns) and zoomed-out
/// states (where visibleBinCount >= columns) without clipping, aliasing, or repeating edge bins.
public struct WaveformSampler: Sendable {
    public struct ColumnSample: Equatable, Sendable {
        public let column: Int
        public let binIndex: Int
        public let peak: Float
        public let low: Float
        public let mid: Float
        public let high: Float

        public init(column: Int, binIndex: Int, peak: Float, low: Float, mid: Float, high: Float) {
            self.column = column
            self.binIndex = binIndex
            self.peak = peak
            self.low = low
            self.mid = mid
            self.high = high
        }
    }

    /// Samples peak and band values across visible columns.
    /// When visibleBinCount < columnCount (e.g. at 32x zoom), fractional steps map each column
    /// proportionally across the visible bins over the entire canvas width.
    /// When visibleBinCount >= columnCount, bins are aggregated (max peak) across the column slice.
    public static func sampleColumns(
        metadata: WaveformMetadata,
        binRange: ClosedRange<Int>,
        columnCount: Int
    ) -> [ColumnSample] {
        guard columnCount > 0, !metadata.peakValues.isEmpty else { return [] }

        let visibleBinCount = binRange.count
        let startBin = binRange.lowerBound
        let endBin = binRange.upperBound
        let totalBins = metadata.peakValues.count

        var samples = [ColumnSample]()
        samples.reserveCapacity(columnCount)

        for col in 0..<columnCount {
            let progressStart = Double(col) / Double(columnCount)
            let progressEnd = Double(col + 1) / Double(columnCount)

            let sliceStart = min(endBin, max(startBin, startBin + Int(progressStart * Double(visibleBinCount))))
            let sliceEnd = min(endBin + 1, max(sliceStart + 1, startBin + Int(ceil(progressEnd * Double(visibleBinCount)))))

            var peak: Float = 0.0
            var low: Float = 0.0
            var mid: Float = 0.0
            var high: Float = 0.0

            for b in sliceStart..<sliceEnd where b < totalBins {
                peak = max(peak, metadata.peakValues[b])
                low = max(low, metadata.lowBandPeaks[b])
                mid = max(mid, metadata.midBandPeaks[b])
                high = max(high, metadata.highBandPeaks[b])
            }

            samples.append(ColumnSample(
                column: col,
                binIndex: sliceStart,
                peak: peak,
                low: low,
                mid: mid,
                high: high
            ))
        }

        return samples
    }
}
