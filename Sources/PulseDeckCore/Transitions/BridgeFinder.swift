import Foundation

/// When a requested track clashes with what plays before it, find one track that fits both sides.
public enum BridgeFinder {
    /// True only when analysis proves a clash (key clash or tempo outside the mix range).
    /// Unknown key or tempo makes no claim either way.
    public static func needsBridge(from previous: TrackCacheEntry, to next: TrackCacheEntry) -> Bool {
        let fit = TrackCompatibility.evaluate(candidate: next, reference: previous)
        if case .clash = fit.key { return true }
        if case .mismatch = fit.tempo { return true }
        return false
    }

    /// Best single track that mixes from `previous` and into `next` in key and tempo.
    /// Ranked by the weaker of the two fits, then their sum, then path for a stable order.
    public static func bestBridge(from previous: TrackCacheEntry, to next: TrackCacheEntry,
                                  candidates: [TrackCacheEntry]) -> TrackCacheEntry? {
        let excluded: Set<String> = [previous.relativePath, next.relativePath]
        var best: (track: TrackCacheEntry, weaker: Double, sum: Double)?
        for candidate in candidates where !excluded.contains(candidate.relativePath) {
            let into = TrackCompatibility.evaluate(candidate: candidate, reference: previous)
            let outOf = TrackCompatibility.evaluate(candidate: next, reference: candidate)
            guard into.isOverallCompatible, outOf.isOverallCompatible else { continue }
            let weaker = min(into.matchScore, outOf.matchScore), sum = into.matchScore + outOf.matchScore
            if let current = best {
                let better = weaker != current.weaker ? weaker > current.weaker
                    : sum != current.sum ? sum > current.sum
                    : candidate.relativePath < current.track.relativePath
                guard better else { continue }
            }
            best = (candidate, weaker, sum)
        }
        return best?.track
    }
}
