import XCTest
@testable import PulseDeckAI

@MainActor
final class PlaybackActivityTests: XCTestCase {
    func testHoldsTheMacAwakeOnlyWhilePlaying() {
        let activity = PlaybackActivity()
        XCTAssertFalse(activity.isHoldingAwake)
        activity.update(isPlaying: true)
        activity.update(isPlaying: true) // A second start must not stack a second hold.
        XCTAssertTrue(activity.isHoldingAwake)
        activity.update(isPlaying: false)
        XCTAssertFalse(activity.isHoldingAwake)
    }
}
