import Foundation

/// Conservative on-air membership, independent of UI focus and talkover attenuation.
public enum MasterSafetyLock {
    public static func isOnAir(
        masterIsRunning: Bool,
        isPlaying: Bool,
        hasLoadedTrack: Bool,
        channelVolume: Float,
        crossfaderWeight: Float
    ) -> Bool {
        guard masterIsRunning, isPlaying, hasLoadedTrack else { return false }
        // Unknown gain must not authorize a destructive action on a playing deck.
        guard channelVolume.isFinite, crossfaderWeight.isFinite else { return true }
        return Double(channelVolume) * Double(crossfaderWeight) > 0
    }
}

enum MasterSafetyLockAction: String, Sendable {
    case pause, stop, seek, replace
}

enum MasterSafetyLockMutationResult: Sendable {
    case applied(isPlaying: Bool)
    case blocked
    case notOnAir
}
