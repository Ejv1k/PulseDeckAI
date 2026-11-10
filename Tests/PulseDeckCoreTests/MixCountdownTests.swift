import XCTest
@testable import PulseDeckCore

final class MixCountdownTests: XCTestCase {
    func testCountsWholeBarsRoundedUp() {
        // 120 BPM: one bar = 2 s.
        XCTAssertEqual(MixCountdown.barsRemaining(playhead: 0, mixOut: 32, bpm: 120), 16)
        XCTAssertEqual(MixCountdown.barsRemaining(playhead: 30.5, mixOut: 32, bpm: 120), 1)
        XCTAssertEqual(MixCountdown.barsRemaining(playhead: 27.9, mixOut: 32, bpm: 120), 3)
    }

    func testNoCountdownWithoutTempoOrAfterMixPoint() {
        XCTAssertNil(MixCountdown.barsRemaining(playhead: 10, mixOut: 32, bpm: 0))
        XCTAssertNil(MixCountdown.barsRemaining(playhead: 32, mixOut: 32, bpm: 120))
        XCTAssertNil(MixCountdown.barsRemaining(playhead: .nan, mixOut: 32, bpm: 120))
    }
}
