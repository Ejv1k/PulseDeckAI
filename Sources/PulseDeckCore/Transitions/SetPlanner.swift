import Foundation

/// Orders analyzed tracks into a DJ-set arc: warm-up, peak around 70 % of the set, cool-down.
/// Each step picks the remaining track that best balances closeness to the target energy and
/// harmonic/tempo fit with the previous track.
public enum SetPlanner {
    /// Loudness proxy from the stored waveform: mean peak, 0...1. Nil without waveform data.
    public static func energy(_ track: TrackCacheEntry) -> Double? {
        let peaks = track.waveformMetadata.peakValues.filter(\.isFinite)
        guard !peaks.isEmpty else { return nil }
        return Double(peaks.reduce(0, +)) / Double(peaks.count)
    }

    /// Target energy (0...1) at set position p in 0...1.
    static func targetEnergy(at p: Double) -> Double {
        p < 0.7 ? 0.2 + 0.8 * (p / 0.7) : 1.0 - 0.6 * ((p - 0.7) / 0.3)
    }

    /// Greedy arc ordering. Energies are normalized across the given tracks; tracks without
    /// waveform data are appended at the end in their original order.
    public static func order(_ tracks: [TrackCacheEntry]) -> [TrackCacheEntry] {
        let measured = tracks.compactMap { track in energy(track).map { (track, $0) } }
        let unmeasured = tracks.filter { energy($0) == nil }
        guard let low = measured.map(\.1).min(), let high = measured.map(\.1).max() else { return tracks }
        let span = max(high - low, 1e-9)
        var remaining = measured.map { (track: $0.0, energy: ($0.1 - low) / span) }
        var result: [TrackCacheEntry] = []
        let count = remaining.count
        while !remaining.isEmpty {
            let position = count > 1 ? Double(result.count) / Double(count - 1) : 0
            let target = targetEnergy(at: position)
            let previous = result.last
            let best = remaining.indices.min { a, b in
                cost(remaining[a], target: target, previous: previous) < cost(remaining[b], target: target, previous: previous)
            }!
            result.append(remaining.remove(at: best).track)
        }
        return result + unmeasured
    }

    private static func cost(_ candidate: (track: TrackCacheEntry, energy: Double), target: Double, previous: TrackCacheEntry?) -> Double {
        let energyCost = 2 * abs(candidate.energy - target)
        guard let previous else { return energyCost }
        // matchScore is 0...5; a perfect fit offsets a 0.5 energy miss.
        return energyCost - TrackCompatibility.evaluate(candidate: candidate.track, reference: previous).matchScore / 5
    }
}
