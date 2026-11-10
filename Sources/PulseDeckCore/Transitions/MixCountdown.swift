import Foundation

/// Bars left before the outgoing track reaches its mix-out cue.
public enum MixCountdown {
    /// Whole 4/4 bars until `mixOut`, rounded up; nil without a tempo or once the point has passed.
    public static func barsRemaining(playhead: Double, mixOut: Double, bpm: Double) -> Int? {
        guard bpm.isFinite, bpm > 0, playhead.isFinite, mixOut.isFinite, playhead < mixOut else { return nil }
        return Int(((mixOut - playhead) / (240.0 / bpm)).rounded(.up))
    }
}
