import XCTest
@testable import PulseDeckCore
@testable import PulseDeckAI

@MainActor
final class UpNextBridgeTests: XCTestCase {
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

    private func app(_ tracks: [TrackCacheEntry]) -> AppState {
        let root = FileManager.default.temporaryDirectory
        let cache = PulseDeckLibraryCache(tracks: Dictionary(uniqueKeysWithValues: tracks.map { ($0.relativePath, $0) }))
        return AppState(libraryRootURL: root, waveformEditorModel: WaveformEditorModel(libraryRootURL: root),
                        loadedCache: cache, startCoordinator: false)
    }

    func testClashInTheQueueGetsABridgeThatFitsBothSides() {
        let prev = track("prev", bpm: 120, key: "8A"), next = track("next", bpm: 122, key: "10A")
        let state = app([prev, next, track("fit", bpm: 121, key: "9A"), track("clash", bpm: 121, key: "3B")])
        state.addToUpNext(prev.relativePath)
        state.addToUpNext(next.relativePath)
        XCTAssertFalse(state.upNextNeedsBridge(at: 0), "Nothing plays before the first entry")
        XCTAssertTrue(state.upNextNeedsBridge(at: 1))

        XCTAssertTrue(state.insertBridge(before: next.relativePath))
        XCTAssertEqual(state.upNext, [prev.relativePath, "01_Set/fit.wav", next.relativePath])
        XCTAssertFalse(state.upNextNeedsBridge(at: 1))
        XCTAssertFalse(state.upNextNeedsBridge(at: 2))
    }

    func testNoFittingTrackLeavesTheQueueAndSaysSo() {
        let prev = track("prev", bpm: 120, key: "8A"), next = track("next", bpm: 122, key: "10A")
        let state = app([prev, next, track("clash", bpm: 121, key: "3B")])
        state.addToUpNext(prev.relativePath)
        state.addToUpNext(next.relativePath)
        XCTAssertFalse(state.insertBridge(before: next.relativePath))
        XCTAssertEqual(state.upNext, [prev.relativePath, next.relativePath])
        XCTAssertEqual(state.statusMessage, "No analyzed track fits between these two in key and tempo.")
    }

    func testPlayedTrackIsNotOfferedAsABridge() {
        let prev = track("prev", bpm: 120, key: "8A"), next = track("next", bpm: 122, key: "10A")
        let fit = track("fit", bpm: 121, key: "9A")
        let state = app([prev, next, fit])
        state.markPlayedForTesting(fit.relativePath)
        state.addToUpNext(prev.relativePath)
        state.addToUpNext(next.relativePath)
        XCTAssertFalse(state.insertBridge(before: next.relativePath))
    }
}
