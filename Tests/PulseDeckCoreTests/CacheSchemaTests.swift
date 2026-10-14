import XCTest
@testable import PulseDeckCore

final class CacheSchemaTests: XCTestCase {

    func testCueMarkersOrderingValidation() {
        // Valid ordered cues: 0.0 <= startTrim <= vocalEntry <= mixOut <= endTrim <= duration
        let validCues = CueMarkers(startTrimCue: 5.0, vocalEntryCue: 15.0, mixOutCue: 180.0, endTrimCue: 210.0)
        XCTAssertTrue(validCues.isValid(forDuration: 220.0))

        // Boundary edge case: cues at 0 and duration
        let edgeCues = CueMarkers(startTrimCue: 0.0, vocalEntryCue: 0.0, mixOutCue: 220.0, endTrimCue: 220.0)
        XCTAssertTrue(edgeCues.isValid(forDuration: 220.0))

        // Invalid: endTrim exceeds duration
        let exceedsDur = CueMarkers(startTrimCue: 5.0, vocalEntryCue: 15.0, mixOutCue: 180.0, endTrimCue: 225.0)
        XCTAssertFalse(exceedsDur.isValid(forDuration: 220.0))

        // Invalid: vocalEntry precedes startTrim
        let invertedStart = CueMarkers(startTrimCue: 20.0, vocalEntryCue: 10.0, mixOutCue: 180.0, endTrimCue: 210.0)
        XCTAssertFalse(invertedStart.isValid(forDuration: 220.0))

        // Invalid: mixOut precedes vocalEntry
        let invertedMixOut = CueMarkers(startTrimCue: 5.0, vocalEntryCue: 50.0, mixOutCue: 40.0, endTrimCue: 210.0)
        XCTAssertFalse(invertedMixOut.isValid(forDuration: 220.0))

        // Invalid: endTrim precedes mixOut
        let invertedEnd = CueMarkers(startTrimCue: 5.0, vocalEntryCue: 15.0, mixOutCue: 200.0, endTrimCue: 190.0)
        XCTAssertFalse(invertedEnd.isValid(forDuration: 220.0))
    }

    func testCueMarkersClamping() {
        let invertedCues = CueMarkers(startTrimCue: 250.0, vocalEntryCue: 10.0, mixOutCue: 300.0, endTrimCue: 50.0)
        let clamped = invertedCues.clamped(toDuration: 200.0)
        XCTAssertTrue(clamped.isValid(forDuration: 200.0))
        XCTAssertEqual(clamped.endTrimCue, 200.0)
    }

    func testCacheInvalidation() {
        let entry = makeSampleEntry(fingerprint: "hash_v1", analyzer: "accelerate-dsp-v1.0")

        // Same fingerprint and analyzer -> valid
        XCTAssertTrue(entry.isValid(currentFingerprint: "hash_v1", targetAnalyzerVersion: "accelerate-dsp-v1.0"))

        // Modified file fingerprint -> invalid
        XCTAssertFalse(entry.isValid(currentFingerprint: "hash_v2_modified", targetAnalyzerVersion: "accelerate-dsp-v1.0"))

        // Upgraded analyzer version -> invalid
        XCTAssertFalse(entry.isValid(currentFingerprint: "hash_v1", targetAnalyzerVersion: "accelerate-dsp-v2.0"))
    }

    func testPreserveManualOverridesDuringReanalysis() {
        var existing = makeSampleEntry(fingerprint: "hash_v1", analyzer: "accelerate-dsp-v1.0")
        // User manually adjusted cueMarkers and BPM
        existing.cueMarkers = CueMarkers(startTrimCue: 12.0, vocalEntryCue: 24.0, mixOutCue: 195.0, endTrimCue: 215.0)
        existing.bpm = 126.5
        existing.aiTrimBypass = true
        existing.manualOverrides = ManualOverrides(
            isManual: true,
            overriddenFields: ["cueMarkers", "bpm"],
            updatedAt: "2026-10-14T15:00:00Z",
            author: "DJ_Headliner",
            notes: "Adjusted intro trim for vocal acapella"
        )

        // New automated analysis arrives
        let automatedAnalysis = makeSampleEntry(fingerprint: "hash_v2", analyzer: "accelerate-dsp-v2.0")
        XCTAssertEqual(automatedAnalysis.bpm, 120.0)
        XCTAssertEqual(automatedAnalysis.cueMarkers.startTrimCue, 5.0)

        // Merge preserving manual overrides
        let merged = existing.mergingPreservingOverrides(with: automatedAnalysis)

        // Manual adjustments MUST be preserved
        XCTAssertEqual(merged.cueMarkers.startTrimCue, 12.0)
        XCTAssertEqual(merged.cueMarkers.vocalEntryCue, 24.0)
        XCTAssertEqual(merged.bpm, 126.5)
        XCTAssertTrue(merged.aiTrimBypass)
        XCTAssertTrue(merged.manualOverrides.isManual)
        XCTAssertEqual(merged.manualOverrides.author, "DJ_Headliner")

        // Non-overridden fields update to new analysis
        XCTAssertEqual(merged.analyzerVersion, "accelerate-dsp-v2.0")
        XCTAssertEqual(merged.fileFingerprint, "hash_v2")
    }

    func testCacheJSONEncodingDecoding() throws {
        let entry = makeSampleEntry(fingerprint: "abc123sha256", analyzer: "accelerate-dsp-v1.0")
        var cache = PulseDeckLibraryCache()
        cache.tracks[entry.relativePath] = entry

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cache)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(PulseDeckLibraryCache.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, "1.0.0")
        XCTAssertEqual(decoded.tracks.count, 1)
        XCTAssertEqual(decoded.tracks[entry.relativePath]?.relativePath, entry.relativePath)
        XCTAssertEqual(decoded.tracks[entry.relativePath]?.bpm, 120.0)
    }

    private func makeSampleEntry(fingerprint: String, analyzer: String) -> TrackCacheEntry {
        TrackCacheEntry(
            relativePath: "00_Test_Tracks_Dev/sample.mp3",
            fileFingerprint: fingerprint,
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
                sampleCount: 100,
                downsampleFactor: 256,
                peakValues: [0.1, 0.5, 0.9],
                lowBandPeaks: [0.1, 0.4, 0.8],
                midBandPeaks: [0.05, 0.3, 0.7],
                highBandPeaks: [0.02, 0.2, 0.6]
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
            analyzerVersion: analyzer,
            analysisTimestamp: "2026-10-14T12:01:00Z"
        )
    }
}
