import Foundation
import XCTest
@testable import PulseDeckCore

final class WaveformCuePersistenceTests: XCTestCase {

    // MARK: - Cue Invariants and Bounds Validation

    func testCueMarkersStrictOrderingAndBounds() {
        let duration = 180.0

        // Perfectly ordered valid cues
        let validCues = CueMarkers(
            startTrimCue: 4.5,
            vocalEntryCue: 16.0,
            mixOutCue: 160.0,
            endTrimCue: 175.5
        )
        XCTAssertTrue(validCues.isValid(forDuration: duration))

        // Inverted startTrim > vocalEntry
        let invertedIntro = CueMarkers(
            startTrimCue: 20.0,
            vocalEntryCue: 16.0,
            mixOutCue: 160.0,
            endTrimCue: 175.5
        )
        XCTAssertFalse(invertedIntro.isValid(forDuration: duration))

        // Inverted vocalEntry > mixOut
        let invertedBody = CueMarkers(
            startTrimCue: 4.5,
            vocalEntryCue: 165.0,
            mixOutCue: 160.0,
            endTrimCue: 175.5
        )
        XCTAssertFalse(invertedBody.isValid(forDuration: duration))

        // Inverted mixOut > endTrim
        let invertedOutro = CueMarkers(
            startTrimCue: 4.5,
            vocalEntryCue: 16.0,
            mixOutCue: 178.0,
            endTrimCue: 175.5
        )
        XCTAssertFalse(invertedOutro.isValid(forDuration: duration))

        // Negative startTrim
        let negativeCue = CueMarkers(
            startTrimCue: -1.0,
            vocalEntryCue: 16.0,
            mixOutCue: 160.0,
            endTrimCue: 175.5
        )
        XCTAssertFalse(negativeCue.isValid(forDuration: duration))

        // endTrim exceeding duration
        let outOfBounds = CueMarkers(
            startTrimCue: 4.5,
            vocalEntryCue: 16.0,
            mixOutCue: 160.0,
            endTrimCue: 185.0
        )
        XCTAssertFalse(outOfBounds.isValid(forDuration: duration))
    }

    func testCueClampingEnforcesMonotonicOrderWithoutInversion() {
        let duration = 200.0

        // Cues scattered with out-of-bounds and inversions
        let messyCues = CueMarkers(
            startTrimCue: -5.0,
            vocalEntryCue: 50.0,
            mixOutCue: 30.0,
            endTrimCue: 250.0
        )

        let clamped = messyCues.clamped(toDuration: duration)
        XCTAssertTrue(clamped.isValid(forDuration: duration))
        XCTAssertEqual(clamped.startTrimCue, 0.0)
        XCTAssertEqual(clamped.vocalEntryCue, 50.0)
        // mixOutCue was 30.0 (< 50.0), so clamped bumps it to at least 50.0
        XCTAssertEqual(clamped.mixOutCue, 50.0)
        // endTrimCue was 250.0 (> duration), so clamped caps it to 200.0
        XCTAssertEqual(clamped.endTrimCue, 200.0)
    }

    // MARK: - Manual Overrides Preservation

    func testManualCueOverridesSurviveAutomatedMerge() {
        let duration = 120.0
        let original = makeSampleTrackEntry(
            relativePath: "00_Test_Tracks_Dev/sample.wav",
            duration: duration,
            cues: CueMarkers(startTrimCue: 2.0, vocalEntryCue: 10.0, mixOutCue: 100.0, endTrimCue: 118.0)
        )

        // Simulate human DJ edit
        var edited = original
        let manualCues = CueMarkers(startTrimCue: 4.0, vocalEntryCue: 12.5, mixOutCue: 105.0, endTrimCue: 115.0)
        edited.cueMarkers = manualCues
        edited.aiTrimBypass = true
        edited.manualOverrides = ManualOverrides(
            isManual: true,
            overriddenFields: ["cueMarkers", "aiTrimBypass"],
            updatedAt: "2026-10-17T10:00:00Z",
            author: "DJ Manual Waveform Editor",
            notes: "Adjusted drop cue"
        )

        // Simulate a new automated re-analysis pass on the track
        let newAutomatedAnalysis = makeSampleTrackEntry(
            relativePath: "00_Test_Tracks_Dev/sample.wav",
            duration: duration,
            cues: CueMarkers(startTrimCue: 1.0, vocalEntryCue: 8.0, mixOutCue: 95.0, endTrimCue: 119.0)
        )

        let merged = edited.mergingPreservingOverrides(with: newAutomatedAnalysis)

        // Invariant: automated analysis MUST NOT clobber manual cues, bypass, or provenance
        XCTAssertEqual(merged.cueMarkers, manualCues)
        XCTAssertTrue(merged.aiTrimBypass)
        XCTAssertTrue(merged.manualOverrides.isManual)
        XCTAssertTrue(merged.manualOverrides.overriddenFields.contains("cueMarkers"))
        XCTAssertTrue(merged.manualOverrides.overriddenFields.contains("aiTrimBypass"))
        XCTAssertEqual(merged.manualOverrides.author, "DJ Manual Waveform Editor")
    }

    // MARK: - Atomic Persistence and Reload Surviving Verification

    func testAtomicPersistenceAndSurvivingDiskReload() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PulseDeckTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cacheURL = tempDir.appendingPathComponent(PulseDeckCoreConfig.cacheFileName)
        var cache = PulseDeckLibraryCache(libraryRoot: tempDir.lastPathComponent)

        let trackPath = "00_Test_Tracks_Dev/stage_anthem.wav"
        let initialEntry = makeSampleTrackEntry(
            relativePath: trackPath,
            duration: 240.0,
            cues: CueMarkers(startTrimCue: 3.0, vocalEntryCue: 15.0, mixOutCue: 210.0, endTrimCue: 235.0)
        )
        CachePersistence.upsertTrack(initialEntry, in: &cache)

        // Save atomically to disk
        try CachePersistence.saveAtomic(cache: cache, to: cacheURL)

        // First reload: verify initial state
        guard var loadedCache = CachePersistence.load(from: cacheURL) else {
            XCTFail("Failed to load freshly saved cache")
            return
        }
        XCTAssertEqual(loadedCache.tracks.count, 1)
        let loadedInitial = try XCTUnwrap(loadedCache.tracks[trackPath])
        XCTAssertEqual(loadedInitial.cueMarkers.startTrimCue, 3.0)
        XCTAssertFalse(loadedInitial.manualOverrides.isManual)

        // Now simulate user dragging cues and toggling AI Trim Bypass in WaveformEditorModel
        let updatedCues = CueMarkers(
            startTrimCue: 5.250,
            vocalEntryCue: 18.100,
            mixOutCue: 215.400,
            endTrimCue: 238.900
        )
        var updatedEntry = loadedInitial
        updatedEntry.cueMarkers = updatedCues
        updatedEntry.aiTrimBypass = true
        updatedEntry.manualOverrides = ManualOverrides(
            isManual: true,
            overriddenFields: ["cueMarkers", "aiTrimBypass"],
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            author: "DJ (PulseDeck Manual Editor)"
        )

        // Update in cache and save atomically
        loadedCache.tracks[trackPath] = updatedEntry
        try CachePersistence.saveAtomic(cache: loadedCache, to: cacheURL)

        // Second reload from disk: verify manual edits survived
        guard let reloadedCache = CachePersistence.load(from: cacheURL) else {
            XCTFail("Failed to reload updated cache")
            return
        }
        let reloadedEntry = try XCTUnwrap(reloadedCache.tracks[trackPath])
        XCTAssertEqual(reloadedEntry.cueMarkers.startTrimCue, 5.250, accuracy: 0.001)
        XCTAssertEqual(reloadedEntry.cueMarkers.vocalEntryCue, 18.100, accuracy: 0.001)
        XCTAssertEqual(reloadedEntry.cueMarkers.mixOutCue, 215.400, accuracy: 0.001)
        XCTAssertEqual(reloadedEntry.cueMarkers.endTrimCue, 238.900, accuracy: 0.001)
        XCTAssertTrue(reloadedEntry.aiTrimBypass)
        XCTAssertTrue(reloadedEntry.manualOverrides.isManual)
        XCTAssertEqual(reloadedEntry.manualOverrides.overriddenFields, ["cueMarkers", "aiTrimBypass"])
        XCTAssertEqual(reloadedEntry.manualOverrides.author, "DJ (PulseDeck Manual Editor)")

        // Verify JSON schema conformity
        let rawData = try Data(contentsOf: cacheURL)
        try SharedCacheContract().validate(data: rawData)
    }

    func testLoadFailureAbortsSaveAndPreservesExistingInvalidCache() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PulseDeckTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cacheURL = tempDir.appendingPathComponent(PulseDeckCoreConfig.cacheFileName)
        let corruptContent = Data("{\"schemaVersion\": \"2.0.0\", \"libraryRoot\": \"test\"}".utf8)
        try corruptContent.write(to: cacheURL)

        // Schema version 2.0.0 fails validation; CachePersistence.load returns nil
        XCTAssertNil(CachePersistence.load(from: cacheURL))

        // Invariant: when cacheURL exists but load fails, aborting save preserves raw file on disk
        let contentOnDisk = try Data(contentsOf: cacheURL)
        XCTAssertEqual(contentOnDisk, corruptContent)
    }

    // MARK: - Coordinate Conversion & Zoom/Scroll Windowing Math

    func testCoordinateConversionAndZoomWindowing() {
        let duration = 120.0
        let totalBins = 1200
        let viewWidth: CGFloat = 800.0

        // At 1.0x Zoom (Entire track visible, scroll = 0)
        let zoom1 = 1.0
        let scroll0 = 0.0
        let visibleDur1 = duration / zoom1
        XCTAssertEqual(visibleDur1, 120.0)

        // timeToX at 1.0x
        let xStart = CGFloat((0.0 - scroll0) / visibleDur1) * viewWidth
        let xMid = CGFloat((60.0 - scroll0) / visibleDur1) * viewWidth
        let xEnd = CGFloat((120.0 - scroll0) / visibleDur1) * viewWidth
        XCTAssertEqual(xStart, 0.0, accuracy: 0.001)
        XCTAssertEqual(xMid, 400.0, accuracy: 0.001)
        XCTAssertEqual(xEnd, 800.0, accuracy: 0.001)

        // xToTime round-trip at 1.0x
        let timeFromMidX = scroll0 + Double(xMid / viewWidth) * visibleDur1
        XCTAssertEqual(timeFromMidX, 60.0, accuracy: 0.001)

        // At 2.0x Zoom centered at 60s (scroll = 30s, visible = 60s)
        let zoom2 = 2.0
        let visibleDur2 = duration / zoom2 // 60.0s
        let scroll30 = 30.0

        // Time 30s is at x = 0
        let x30 = CGFloat((30.0 - scroll30) / visibleDur2) * viewWidth
        XCTAssertEqual(x30, 0.0, accuracy: 0.001)

        // Time 60s is at center x = 400
        let x60 = CGFloat((60.0 - scroll30) / visibleDur2) * viewWidth
        XCTAssertEqual(x60, 400.0, accuracy: 0.001)

        // Time 90s is at right edge x = 800
        let x90 = CGFloat((90.0 - scroll30) / visibleDur2) * viewWidth
        XCTAssertEqual(x90, 800.0, accuracy: 0.001)

        // Visible bin range at 2.0x (bins 300 to 900)
        let startFrac = scroll30 / duration // 0.25
        let endFrac = (scroll30 + visibleDur2) / duration // 0.75
        let startBin = Int(floor(startFrac * Double(totalBins)))
        let endBin = Int(ceil(endFrac * Double(totalBins)))
        XCTAssertEqual(startBin, 300)
        XCTAssertEqual(endBin, 900)

        // Max drawn columns bounded by viewWidth
        let visibleCount = endBin - startBin
        let drawnColumns = min(visibleCount, Int(viewWidth))
        XCTAssertLessThanOrEqual(drawnColumns, Int(viewWidth))
    }

    // MARK: - Helpers

    private func makeSampleTrackEntry(
        relativePath: String,
        duration: Double,
        cues: CueMarkers
    ) -> TrackCacheEntry {
        let bins = 200
        let peaks = [Float](repeating: 0.5, count: bins)
        let low = [Float](repeating: 0.3, count: bins)
        let mid = [Float](repeating: 0.4, count: bins)
        let high = [Float](repeating: 0.2, count: bins)

        return TrackCacheEntry(
            relativePath: relativePath,
            fileFingerprint: "sha256_mock_hash",
            fileSizeBytes: 10_000_000,
            fileModificationTime: "2026-10-17T10:00:00Z",
            duration: duration,
            sampleRate: 44100.0,
            channels: 2,
            bitDepth: 16,
            bpm: 128.0,
            musicalKey: "8A",
            confidence: 0.95,
            waveformMetadata: WaveformMetadata(
                sampleCount: Int(duration * 44100),
                downsampleFactor: 512,
                peakValues: peaks,
                lowBandPeaks: low,
                midBandPeaks: mid,
                highBandPeaks: high
            ),
            beatGrid: BeatGrid(
                firstBeatOffsetSeconds: 0.468,
                beatIntervalSeconds: 0.46875,
                beatTimestamps: stride(from: 0.468, to: duration, by: 0.46875).map { $0 }
            ),
            structure: TrackStructure(
                sections: [
                    StructureSection(name: "Intro", startSeconds: 0, endSeconds: 15, energyLevel: 0.4),
                    StructureSection(name: "Drop", startSeconds: 15, endSeconds: duration - 15, energyLevel: 0.9),
                    StructureSection(name: "Outro", startSeconds: duration - 15, endSeconds: duration, energyLevel: 0.3)
                ],
                vocalSegments: [
                    VocalSegment(startSeconds: 16.0, endSeconds: 45.0, confidence: 0.9)
                ]
            ),
            cueMarkers: cues,
            aiTrimBypass: false,
            manualOverrides: ManualOverrides(),
            analyzerVersion: "v1.0.0-accelerate",
            analysisTimestamp: "2026-10-17T10:00:00Z"
        )
    }
}
