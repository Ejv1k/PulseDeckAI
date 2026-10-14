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

        // Non-finite clamping
        let nanCues = CueMarkers(startTrimCue: .nan, vocalEntryCue: .infinity, mixOutCue: -.infinity, endTrimCue: 250.0)
        let clampedNan = nanCues.clamped(toDuration: 100.0)
        XCTAssertTrue(clampedNan.isValid(forDuration: 100.0))
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
        // User manually adjusted cueMarkers and BPM; endTrimCue (215.0) originally exceeded duration (210.0)
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

        // New automated analysis arrives with duration 210.0
        let automatedAnalysis = makeSampleEntry(fingerprint: "hash_v2", analyzer: "accelerate-dsp-v2.0", duration: 210.0)
        XCTAssertEqual(automatedAnalysis.bpm, 120.0)
        XCTAssertEqual(automatedAnalysis.cueMarkers.startTrimCue, 5.0)

        // Merge preserving manual overrides
        let merged = existing.mergingPreservingOverrides(with: automatedAnalysis)

        // Manual adjustments MUST be preserved, with cues safely clamped to merged.duration
        XCTAssertEqual(merged.cueMarkers.startTrimCue, 12.0)
        XCTAssertEqual(merged.cueMarkers.vocalEntryCue, 24.0)
        XCTAssertEqual(merged.cueMarkers.mixOutCue, 195.0)
        XCTAssertEqual(merged.cueMarkers.endTrimCue, 210.0) // Clamped from 215.0 to merged.duration (210.0)
        XCTAssertTrue(merged.cueMarkers.isValid(forDuration: merged.duration))
        XCTAssertEqual(merged.bpm, 126.5)
        XCTAssertTrue(merged.aiTrimBypass)
        XCTAssertTrue(merged.manualOverrides.isManual)
        XCTAssertEqual(merged.manualOverrides.author, "DJ_Headliner")

        // Non-overridden fields update to new analysis
        XCTAssertEqual(merged.analyzerVersion, "accelerate-dsp-v2.0")
        XCTAssertEqual(merged.fileFingerprint, "hash_v2")
    }

    func testPreserveManualOverridesShorterFileAndInvalidCues() {
        var existing = makeSampleEntry(fingerprint: "hash_v1", analyzer: "accelerate-dsp-v1.0", duration: 200.0)
        // Manual cues set for a 200s track
        existing.cueMarkers = CueMarkers(startTrimCue: 30.0, vocalEntryCue: 60.0, mixOutCue: 150.0, endTrimCue: 190.0)
        existing.manualOverrides = ManualOverrides(
            isManual: true,
            overriddenFields: ["cueMarkers"]
        )

        // Track was replaced with a shorter 45s audio file
        let shorterAnalysis = makeSampleEntry(fingerprint: "hash_v2_short", analyzer: "accelerate-dsp-v2.0", duration: 45.0)
        let merged = existing.mergingPreservingOverrides(with: shorterAnalysis)

        // All cues must be clamped and strictly ordered within 45.0s
        XCTAssertTrue(merged.cueMarkers.isValid(forDuration: 45.0))
        XCTAssertEqual(merged.cueMarkers.startTrimCue, 30.0)
        XCTAssertEqual(merged.cueMarkers.vocalEntryCue, 45.0)
        XCTAssertEqual(merged.cueMarkers.mixOutCue, 45.0)
        XCTAssertEqual(merged.cueMarkers.endTrimCue, 45.0)
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

    /// Tests that CachePersistence.load strictly validates schema invariants and rejects invalid documents.
    func testCachePersistenceValidationRejectsInvalidDocuments() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("PulseDeckValidationTest_\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempDir)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]

        // 1. Wrong schema version (e.g. "2.0.0") must fail validation and return nil
        let wrongVersionCache = PulseDeckLibraryCache(schemaVersion: "2.0.0")
        let wrongVersionURL = tempDir.appendingPathComponent("wrong_version.json")
        try encoder.encode(wrongVersionCache).write(to: wrongVersionURL)
        XCTAssertNil(CachePersistence.load(from: wrongVersionURL), "Wrong schemaVersion '2.0.0' must fail validation and return nil")

        // 2. endTrimCue past duration must fail validation and return nil
        var endTrimExceedsCache = PulseDeckLibraryCache()
        var entryExceeds = makeSampleEntry(fingerprint: "hash1", analyzer: "v1", duration: 100.0)
        entryExceeds.cueMarkers = CueMarkers(startTrimCue: 5.0, vocalEntryCue: 15.0, mixOutCue: 85.0, endTrimCue: 105.0)
        endTrimExceedsCache.tracks[entryExceeds.relativePath] = entryExceeds
        let endTrimURL = tempDir.appendingPathComponent("end_trim_exceeds.json")
        try encoder.encode(endTrimExceedsCache).write(to: endTrimURL)
        XCTAssertNil(CachePersistence.load(from: endTrimURL), "endTrimCue past duration must fail validation and return nil")

        // 3. Inverted cues must fail validation and return nil
        var invertedCuesCache = PulseDeckLibraryCache()
        var entryInverted = makeSampleEntry(fingerprint: "hash2", analyzer: "v1", duration: 200.0)
        entryInverted.cueMarkers = CueMarkers(startTrimCue: 50.0, vocalEntryCue: 20.0, mixOutCue: 170.0, endTrimCue: 190.0)
        invertedCuesCache.tracks[entryInverted.relativePath] = entryInverted
        let invertedURL = tempDir.appendingPathComponent("inverted_cues.json")
        try encoder.encode(invertedCuesCache).write(to: invertedURL)
        XCTAssertNil(CachePersistence.load(from: invertedURL), "Inverted cues must fail validation and return nil")

        // 4. Confidence outside 0.0...1.0 (confidence of 1.5) must fail validation and return nil
        var invalidConfidenceCache = PulseDeckLibraryCache()
        let entryConfidence = TrackCacheEntry(
            relativePath: "00_Test_Tracks_Dev/sample.mp3",
            fileFingerprint: "hash3",
            fileSizeBytes: 1000,
            fileModificationTime: "2026-10-14T12:00:00Z",
            duration: 120.0,
            sampleRate: 44100.0,
            channels: 2,
            bitDepth: 16,
            bpm: 120.0,
            musicalKey: "8A",
            confidence: 1.5,
            waveformMetadata: WaveformMetadata(
                sampleCount: 10,
                downsampleFactor: 256,
                peakValues: [0.5],
                lowBandPeaks: [0.5],
                midBandPeaks: [0.5],
                highBandPeaks: [0.5]
            ),
            beatGrid: BeatGrid(firstBeatOffsetSeconds: 0.0, beatIntervalSeconds: 0.5, beatTimestamps: [0.0]),
            structure: TrackStructure(sections: [], vocalSegments: []),
            cueMarkers: CueMarkers(startTrimCue: 0.0, vocalEntryCue: 10.0, mixOutCue: 100.0, endTrimCue: 120.0),
            aiTrimBypass: false,
            manualOverrides: ManualOverrides(),
            analyzerVersion: "v1",
            analysisTimestamp: "2026-10-14T12:00:00Z"
        )
        invalidConfidenceCache.tracks[entryConfidence.relativePath] = entryConfidence
        let confidenceURL = tempDir.appendingPathComponent("invalid_confidence.json")
        try encoder.encode(invalidConfidenceCache).write(to: confidenceURL)
        XCTAssertNil(CachePersistence.load(from: confidenceURL), "Confidence 1.5 must fail validation and return nil")

        // 5. Negative duration must fail validation and return nil
        var negativeDurCache = PulseDeckLibraryCache()
        let entryNegDur = makeSampleEntry(fingerprint: "hash4", analyzer: "v1", duration: -10.0)
        negativeDurCache.tracks[entryNegDur.relativePath] = entryNegDur
        let negDurURL = tempDir.appendingPathComponent("negative_duration.json")
        try encoder.encode(negativeDurCache).write(to: negDurURL)
        XCTAssertNil(CachePersistence.load(from: negDurURL), "Negative duration must fail validation and return nil")

        // 6. Empty libraryRoot must fail validation and return nil
        let emptyRootCache = PulseDeckLibraryCache(libraryRoot: "   ")
        let emptyRootURL = tempDir.appendingPathComponent("empty_root.json")
        try encoder.encode(emptyRootCache).write(to: emptyRootURL)
        XCTAssertNil(CachePersistence.load(from: emptyRootURL), "Empty libraryRoot must fail validation and return nil")
    }

    private func makeSampleEntry(fingerprint: String, analyzer: String, duration: Double = 210.0) -> TrackCacheEntry {
        TrackCacheEntry(
            relativePath: "00_Test_Tracks_Dev/sample.mp3",
            fileFingerprint: fingerprint,
            fileSizeBytes: 5_242_880,
            fileModificationTime: "2026-10-14T12:00:00Z",
            duration: duration,
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
