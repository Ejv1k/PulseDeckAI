import XCTest
@testable import PulseDeckCore

final class BridgeFinderTests: XCTestCase {
    private func track(_ name: String, bpm: Double, key: String) -> TrackCacheEntry {
        let interval = 60.0 / bpm
        let peaks: [Float] = [0.5, 0.5, 0.5, 0.5]
        return TrackCacheEntry(
            relativePath: "01_Set/\(name).wav", fileFingerprint: name, fileSizeBytes: 1_000,
            fileModificationTime: "2026-10-14T12:00:00Z", duration: 210.0, sampleRate: 44100.0, channels: 2, bitDepth: 16,
            bpm: bpm, musicalKey: key, confidence: 0.95,
            waveformMetadata: WaveformMetadata(sampleCount: peaks.count, downsampleFactor: 256, peakValues: peaks,
                                               lowBandPeaks: peaks, midBandPeaks: peaks, highBandPeaks: peaks),
            beatGrid: BeatGrid(firstBeatOffsetSeconds: 0.25, beatIntervalSeconds: interval,
                               beatTimestamps: [0.25, 0.25 + interval, 0.25 + 2 * interval]),
            structure: TrackStructure(sections: [], vocalSegments: []),
            cueMarkers: CueMarkers(startTrimCue: 5.0, vocalEntryCue: 15.0, mixOutCue: 180.0, endTrimCue: 205.0),
            aiTrimBypass: false, manualOverrides: ManualOverrides(),
            analyzerVersion: "test", analysisTimestamp: "2026-10-14T12:01:00Z")
    }

    func testNeedsBridgeOnlyForProvenClash() {
        XCTAssertTrue(BridgeFinder.needsBridge(from: track("a", bpm: 120, key: "8A"), to: track("b", bpm: 120, key: "3B")))
        XCTAssertFalse(BridgeFinder.needsBridge(from: track("a", bpm: 120, key: "8A"), to: track("b", bpm: 121, key: "9A")))
        XCTAssertTrue(BridgeFinder.needsBridge(from: track("a", bpm: 120, key: "8A"), to: track("b", bpm: 140, key: "8A")))
        XCTAssertFalse(BridgeFinder.needsBridge(from: track("a", bpm: 120, key: "8A"), to: track("b", bpm: 120, key: "Unknown")))
    }

    func testBestBridgeFitsBothSides() {
        let previous = track("prev", bpm: 120, key: "8A")
        let next = track("next", bpm: 122, key: "10A")
        let candidates = [
            track("clash", bpm: 121, key: "3B"),
            track("fast", bpm: 140, key: "9A"),
            track("fit", bpm: 121, key: "9A")
        ]
        XCTAssertEqual(BridgeFinder.bestBridge(from: previous, to: next, candidates: candidates)?.relativePath, "01_Set/fit.wav")
    }

    func testBestBridgeSkipsEndpointsAndReturnsNilWhenNothingFits() {
        let previous = track("prev", bpm: 120, key: "8A")
        let next = track("next", bpm: 122, key: "10A")
        let candidates = [
            previous,
            next,
            track("clash", bpm: 121, key: "3B")
        ]
        XCTAssertNil(BridgeFinder.bestBridge(from: previous, to: next, candidates: candidates))
    }

    func testEqualFitsBreakTiesByPath() {
        let previous = track("prev", bpm: 120, key: "8A")
        let next = track("next", bpm: 122, key: "10A")
        let candidates = [
            track("zeta", bpm: 121, key: "9A"),
            track("alpha", bpm: 121, key: "9A")
        ]
        XCTAssertEqual(BridgeFinder.bestBridge(from: previous, to: next, candidates: candidates)?.relativePath, "01_Set/alpha.wav")
    }
}
