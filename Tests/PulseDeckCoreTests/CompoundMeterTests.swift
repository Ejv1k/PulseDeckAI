import XCTest
@testable import PulseDeckCore

final class CompoundMeterTests: XCTestCase {
    /// Regular grid over 240 s with a downbeat every `beatsPerBar` beats.
    private func grid(bpm: Double, beatsPerBar: Int?) -> BeatGrid {
        let interval = 60 / bpm
        let beats = (0..<Int(239 / interval)).map { 0.5 + Double($0) * interval }
        let downbeats = beatsPerBar.map { step in stride(from: 0, to: beats.count, by: step).map { beats[$0] } }
        return BeatGrid(firstBeatOffsetSeconds: beats[0], beatIntervalSeconds: interval, beatTimestamps: beats, downbeatTimestamps: downbeats)
    }

    private func entry(_ path: String, bpm: Double, beatsPerBar: Int?) -> TrackCacheEntry {
        TrackCacheEntry(
            relativePath: path, fileFingerprint: "fp", fileSizeBytes: 100, fileModificationTime: "",
            duration: 240, sampleRate: 44100, channels: 2, bitDepth: 16, bpm: bpm, musicalKey: "8A", confidence: 0.9,
            waveformMetadata: WaveformMetadata(sampleCount: 1, downsampleFactor: 1, peakValues: [0], lowBandPeaks: [0], midBandPeaks: [0], highBandPeaks: [0]),
            beatGrid: grid(bpm: bpm, beatsPerBar: beatsPerBar),
            structure: TrackStructure(sections: [], vocalSegments: []),
            cueMarkers: CueMarkers(startTrimCue: 10, vocalEntryCue: 30, mixOutCue: 150, endTrimCue: 235),
            aiTrimBypass: false, manualOverrides: ManualOverrides(), analyzerVersion: "1.0", analysisTimestamp: ""
        )
    }

    func testSixBeatBarsReadAsCompoundAndShowFeltTempo() {
        let ballad = entry("perfect.mp3", bpm: 187.5, beatsPerBar: 6)
        XCTAssertTrue(ballad.beatGrid.isCompoundMeter)
        XCTAssertEqual(ballad.displayBPM, 62.5, accuracy: 1e-9)
        XCTAssertEqual(ballad.tempoLabel, "62.5 BPM · 6/8")

        let pop = entry("pop.mp3", bpm: 125, beatsPerBar: 4)
        XCTAssertFalse(pop.beatGrid.isCompoundMeter)
        XCTAssertEqual(pop.tempoLabel, "125.0 BPM")
        XCTAssertFalse(entry("nodownbeats.mp3", bpm: 125, beatsPerBar: nil).beatGrid.isCompoundMeter)
    }

    func testMeterMismatchIsNotATempoMatchAndBlocksBassSwapOnly() throws {
        let ballad = entry("perfect.mp3", bpm: 187.5, beatsPerBar: 6)
        let fast44 = entry("fast.mp3", bpm: 187.5, beatsPerBar: 4)
        let fit = TrackCompatibility.evaluate(candidate: fast44, reference: ballad)
        XCTAssertEqual(fit.tempo, .meterMismatch)
        XCTAssertFalse(fit.tempo.isCompatible)
        XCTAssertEqual(TrackCompatibility.evaluate(candidate: ballad, reference: ballad).tempo, .compatible(deltaPercent: 0))

        let outgoing = TrackTransitionDescriptor(deck: .deckA, cacheEntry: ballad)
        let incoming = TrackTransitionDescriptor(deck: .deckB, cacheEntry: fast44)
        let planner = TransitionPlanner()
        XCTAssertThrowsError(try planner.plan(TransitionRequest(outgoingTrack: outgoing, incomingTrack: incoming, style: .beatSyncedBassSwap(bars: 8)))) {
            XCTAssertEqual($0 as? TransitionPlanningError, .meterMismatch)
        }
        XCTAssertTrue(try planner.plan(TransitionRequest(outgoingTrack: outgoing, incomingTrack: incoming,
                                                         style: .beatSyncedBassSwap(bars: 8, allowFallbackToFilter: true))).metadata.isFallback)
        XCTAssertNoThrow(try planner.plan(TransitionRequest(outgoingTrack: outgoing, incomingTrack: incoming, style: .hardCutOnDrop())))
    }
}
