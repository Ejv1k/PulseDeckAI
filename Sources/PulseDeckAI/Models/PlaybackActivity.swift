import Foundation

/// Keeps the Mac and its displays (projector included) awake while a deck plays, and stops App Nap
/// from slowing the transition clock when the window is covered.
@MainActor
final class PlaybackActivity {
    private var token: NSObjectProtocol?

    var isHoldingAwake: Bool { token != nil }

    func update(isPlaying: Bool) {
        if isPlaying, token == nil {
            token = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleDisplaySleepDisabled, .latencyCritical],
                reason: "Music is playing")
        } else if !isPlaying, let held = token {
            ProcessInfo.processInfo.endActivity(held)
            token = nil
        }
    }
}
