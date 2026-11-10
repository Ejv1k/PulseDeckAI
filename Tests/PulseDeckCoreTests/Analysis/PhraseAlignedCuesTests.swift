import XCTest
@testable import PulseDeckCore

final class PhraseAlignedCuesTests: XCTestCase {
    /// 120 BPM in 4/4: one bar every 2 s, first downbeat at 0.5 s, 100 bars.
    private let downbeats = (0..<100).map { 0.5 + Double($0) * 2.0 }

    func testCuesSnapToEightBarPhrasesAndLeaveSixteenBarsForTransition() {
        let cues = NativeRhythmTrackAnalyzer.phraseAlignedCues(
            downbeats: downbeats,
            fallback: (start: 0.3, vocal: 30.0, mixOut: 160.0, end: 199.0)
        )
        XCTAssertEqual(cues.start, 0.5, accuracy: 1e-9)   // first downbeat after audible start
        XCTAssertEqual(cues.vocal, 32.5, accuracy: 1e-9)  // phrase boundary nearest 30 s (bar 16)
        XCTAssertEqual(cues.mixOut, 160.5, accuracy: 1e-9) // last phrase with >= 16 bars (32 s) before 199 s
        XCTAssertEqual(cues.end, 199.0, accuracy: 1e-9)
    }

    func testTooFewDownbeatsKeepsFallback() {
        let fallback = (start: 1.0, vocal: 5.0, mixOut: 20.0, end: 25.0)
        let cues = NativeRhythmTrackAnalyzer.phraseAlignedCues(downbeats: Array(downbeats.prefix(10)), fallback: fallback)
        XCTAssertEqual(cues.start, fallback.start)
        XCTAssertEqual(cues.vocal, fallback.vocal)
        XCTAssertEqual(cues.mixOut, fallback.mixOut)
        XCTAssertEqual(cues.end, fallback.end)
    }

    func testShortTrackStaysOrderedOnPhraseBoundaries() {
        let bars = (0..<20).map { Double($0) * 2.0 }
        let cues = NativeRhythmTrackAnalyzer.phraseAlignedCues(
            downbeats: bars,
            fallback: (start: 0.0, vocal: 6.0, mixOut: 32.0, end: 40.0)
        )
        XCTAssertEqual(cues.vocal, 16.0, accuracy: 1e-9)
        XCTAssertEqual(cues.mixOut, 32.0, accuracy: 1e-9)
        XCTAssertTrue(CueMarkers(startTrimCue: cues.start, vocalEntryCue: cues.vocal,
                                 mixOutCue: cues.mixOut, endTrimCue: cues.end).isValid(forDuration: 40.0))
    }
}

extension PhraseAlignedCuesTests {
    func testLateFirstDownbeatDoesNotTrimQuietIntro() {
        // Model found no downbeats in the first 20 s of a quiet intro.
        let late = (0..<60).map { 20.0 + Double($0) * 2.0 }
        let cues = NativeRhythmTrackAnalyzer.phraseAlignedCues(
            downbeats: late,
            fallback: (start: 1.2, vocal: 30.0, mixOut: 110.0, end: 140.0)
        )
        XCTAssertEqual(cues.start, 1.2, accuracy: 1e-9)
        XCTAssertGreaterThan(cues.vocal, cues.start)
    }
}
