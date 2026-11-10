import XCTest
@testable import PulseDeckCore

final class DownbeatGridTests: XCTestCase {
    func testOldCacheWithoutDownbeatsStillDecodes() throws {
        let json = #"{"firstBeatOffsetSeconds":0,"beatIntervalSeconds":0.5,"beatTimestamps":[0,0.5,1,1.5,2]}"#
        let grid = try JSONDecoder().decode(BeatGrid.self, from: Data(json.utf8))
        XCTAssertNil(grid.downbeatTimestamps)
        XCTAssertEqual(grid.barTimestamps, [0, 2], "Falls back to every 4th beat")
        // Round trip must not invent the key.
        let encoded = String(decoding: try JSONEncoder().encode(grid), as: UTF8.self)
        XCTAssertFalse(encoded.contains("downbeatTimestamps"))
    }

    func testStoredDownbeatsDriveBarStarts() {
        // A missed beat shifts stride-4 off the bar; stored downbeats do not.
        let beats = [0.0, 0.5, 1.0, 2.0, 2.5, 3.0, 3.5, 4.0]
        let grid = BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 0.5, beatTimestamps: beats, downbeatTimestamps: [0.0, 2.0, 4.0])
        XCTAssertEqual(grid.barTimestamps, [0.0, 2.0, 4.0])
        let planner = TransitionPlanner()
        XCTAssertEqual(planner.findQuantizedOutgoingDownbeat(timestamps: grid.barTimestamps, onOrAfter: 1.0, step: 1), 2.0)
        // Legacy stride-4 over raw beats would have picked 2.5.
        XCTAssertEqual(planner.findQuantizedOutgoingDownbeat(timestamps: beats, onOrAfter: 1.0), 2.5)
    }
}

extension DownbeatGridTests {
    func testUnsortedOffBeatOrNonFiniteDownbeatsAreCleanedOrIgnored() {
        let beats = [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0]
        let messy = BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 0.5, beatTimestamps: beats,
                             downbeatTimestamps: [4.0, 2.0, .nan, 2.0, 0.0, 9.9])
        XCTAssertEqual(messy.barTimestamps, [0.0, 2.0, 4.0], "sorted, deduplicated, off-grid and NaN dropped")
        let unusable = BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 0.5, beatTimestamps: beats,
                                downbeatTimestamps: [0.25, 9.9])
        XCTAssertEqual(unusable.barTimestamps, [0.0, 2.0, 4.0], "falls back to stride-4 when <2 downbeats are usable")
    }
}
