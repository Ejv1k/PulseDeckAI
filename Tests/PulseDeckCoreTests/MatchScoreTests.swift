import XCTest
@testable import PulseDeckCore

final class MatchScoreTests: XCTestCase {
    private let key = CamelotKey.parse("Am")!

    func testRankingOrder() {
        let perfect = TrackCompatibility(key: .harmonic(key: key, relationship: .exact), tempo: .compatible(deltaPercent: 0))
        let relativeNearTempo = TrackCompatibility(key: .harmonic(key: key, relationship: .relative), tempo: .compatible(deltaPercent: 1))
        let adjacentEdgeTempo = TrackCompatibility(key: .harmonic(key: key, relationship: .adjacentPlus), tempo: .compatible(deltaPercent: -5.9))
        let unknownBoth = TrackCompatibility(key: .unknown, tempo: .unknown)
        let clash = TrackCompatibility(key: .clash(key: key), tempo: .mismatch(deltaPercent: 12))

        let ordered = [clash, unknownBoth, adjacentEdgeTempo, relativeNearTempo, perfect]
            .sorted { $0.matchScore > $1.matchScore }
        XCTAssertEqual(ordered, [perfect, relativeNearTempo, adjacentEdgeTempo, unknownBoth, clash])
        XCTAssertEqual(perfect.matchScore, 5, accuracy: 1e-9)
        XCTAssertEqual(clash.matchScore, 0, accuracy: 1e-9)
    }
}
