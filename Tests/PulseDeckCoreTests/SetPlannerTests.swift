import XCTest
@testable import PulseDeckCore

final class SetPlannerTests: XCTestCase {

    func testEnergyIsMeanPeak() {
        let entryA = entry("a", peaks: [0.2, 0.4])
        let energyA = SetPlanner.energy(entryA)
        XCTAssertNotNil(energyA)
        if let energyA {
            XCTAssertEqual(energyA, 0.3, accuracy: 1e-6)
        }

        let entryB = entry("b", peaks: [])
        XCTAssertNil(SetPlanner.energy(entryB))
    }

    func testOrderBuildsWarmUpPeakCoolDown() {
        let input = [
            entry("e9", peaks: [0.9]),
            entry("e1", peaks: [0.1]),
            entry("e5", peaks: [0.5]),
            entry("e3", peaks: [0.3]),
            entry("e7", peaks: [0.7]),
        ]
        let ordered = SetPlanner.order(input)
        let names = ordered.map(trackName)
        XCTAssertEqual(names, ["e3", "e5", "e7", "e9", "e1"])
    }

    func testTracksWithoutWaveformGoLastInOriginalOrder() {
        let input = [
            entry("x", peaks: []),
            entry("e1", peaks: [0.1]),
            entry("y", peaks: []),
            entry("e9", peaks: [0.9]),
        ]
        let ordered = SetPlanner.order(input)
        let names = ordered.map(trackName)
        XCTAssertEqual(names.count, 4)
        XCTAssertEqual(Set(names.prefix(2)), Set(["e1", "e9"]))
        XCTAssertEqual(Array(names.suffix(from: 2)), ["x", "y"])
    }

    func testSingleTrackUnchanged() {
        let input = [entry("e5", peaks: [0.5])]
        let ordered = SetPlanner.order(input)
        let names = ordered.map(trackName)
        XCTAssertEqual(names, ["e5"])
    }

    // MARK: - Helpers

    private func trackName(_ track: TrackCacheEntry) -> String {
        track.relativePath
            .components(separatedBy: "/")
            .last?
            .replacingOccurrences(of: ".wav", with: "") ?? ""
    }

    private func entry(_ name: String, peaks: [Float]) -> TrackCacheEntry {
        TrackCacheEntry(
            relativePath: "01_Set/\(name).wav",
            fileFingerprint: name,
            fileSizeBytes: 5_242_880,
            fileModificationTime: "2026-10-14T12:00:00Z",
            duration: 210.0,
            sampleRate: 44100.0,
            channels: 2,
            bitDepth: 16,
            bpm: 120.0,
            musicalKey: "8A",
            confidence: 0.95,
            waveformMetadata: WaveformMetadata(
                sampleCount: peaks.count,
                downsampleFactor: 256,
                peakValues: peaks,
                lowBandPeaks: peaks,
                midBandPeaks: peaks,
                highBandPeaks: peaks
            ),
            beatGrid: BeatGrid(
                firstBeatOffsetSeconds: 0.25,
                beatIntervalSeconds: 0.5,
                beatTimestamps: [0.25, 0.75, 1.25]
            ),
            structure: TrackStructure(
                sections: [
                    StructureSection(name: "Intro", startSeconds: 0.0, endSeconds: 15.0, energyLevel: 0.3),
                    StructureSection(name: "Drop", startSeconds: 15.0, endSeconds: 60.0, energyLevel: 0.9)
                ],
                vocalSegments: [
                    VocalSegment(startSeconds: 15.0, endSeconds: 45.0, confidence: 0.88)
                ]
            ),
            cueMarkers: CueMarkers(startTrimCue: 5.0, vocalEntryCue: 15.0, mixOutCue: 180.0, endTrimCue: 205.0),
            aiTrimBypass: false,
            manualOverrides: ManualOverrides(),
            analyzerVersion: "accelerate-dsp-v1.0",
            analysisTimestamp: "2026-10-14T12:01:00Z"
        )
    }
}
