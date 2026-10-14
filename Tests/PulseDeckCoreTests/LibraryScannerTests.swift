import XCTest
@testable import PulseDeckCore

final class LibraryScannerTests: XCTestCase {

    /// Tests library scanning against a hermetic temporary directory fixture.
    /// Avoids reliance on checkout working directory or gitignored media files.
    func testScanHermeticFixtureLibrary() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("PulseDeckTestLibrary_\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempDir)
        }

        // Create cache JSON fixture
        let cacheContent = """
        {
          "schemaVersion": "1.0.0",
          "generatedAt": "2026-10-14T15:00:00Z",
          "libraryRoot": "PulseDeck_Library",
          "tracks": {}
        }
        """
        let cacheURL = tempDir.appendingPathComponent(PulseDeckCoreConfig.cacheFileName)
        try cacheContent.write(to: cacheURL, atomically: true, encoding: .utf8)

        // Create 10 standard crates with .gitkeep
        for crateName in PulseDeckCoreConfig.standardCrates {
            let crateDir = tempDir.appendingPathComponent(crateName)
            try fileManager.createDirectory(at: crateDir, withIntermediateDirectories: true)
            let gitkeep = crateDir.appendingPathComponent(".gitkeep")
            fileManager.createFile(atPath: gitkeep.path, contents: Data())
        }

        // Add fixture files to 00_Test_Tracks_Dev: 4 supported audio formats and 1 non-audio file
        let devCrateDir = tempDir.appendingPathComponent("00_Test_Tracks_Dev")
        let fixtureFiles = ["track1.mp3", "track2.WAV", "track3.flac", "track4.m4a", "notes.txt"]
        for name in fixtureFiles {
            let fileURL = devCrateDir.appendingPathComponent(name)
            fileManager.createFile(atPath: fileURL.path, contents: Data([0xDE, 0xAD, 0xBE, 0xEF]))
        }

        let scanner = LibraryScanner()
        let summary = scanner.scan(libraryURL: tempDir)

        XCTAssertTrue(summary.isLibraryValid, "Library must be valid")
        XCTAssertNil(summary.scanError, "No scan error should occur for valid directory")
        XCTAssertTrue(summary.hasCacheFile, "Cache file must be detected")
        XCTAssertEqual(summary.cacheSchemaVersion, "1.0.0", "Cache schema version must match")
        XCTAssertEqual(summary.totalCrates, 10, "All 10 standard crates must be detected")
        XCTAssertEqual(summary.totalAudioTracks, 4, "Non-audio files must be excluded, only 4 audio tracks counted")

        let devCrate = summary.crates.first(where: { $0.folderName == "00_Test_Tracks_Dev" })
        XCTAssertNotNil(devCrate)
        XCTAssertTrue(devCrate?.isReadable ?? false)
        XCTAssertNil(devCrate?.errorMessage)
        XCTAssertEqual(devCrate?.trackCount, 4)
        XCTAssertEqual(devCrate?.audioFiles, ["track1.mp3", "track2.WAV", "track3.flac", "track4.m4a"])
        XCTAssertTrue(devCrate?.hasGitKeep ?? false)
    }

    /// Tests that scanning a non-existent path reports a distinct scan error.
    func testScanNonExistentLibraryRoot() {
        let scanner = LibraryScanner()
        let nonExistentURL = URL(fileURLWithPath: "/tmp/non_existent_pulsedeck_dir_\(UUID().uuidString)")

        let summary = scanner.scan(libraryURL: nonExistentURL)

        XCTAssertFalse(summary.isLibraryValid)
        XCTAssertNotNil(summary.scanError)
        XCTAssertTrue(summary.scanError?.contains("not found") ?? false)
        XCTAssertEqual(summary.totalCrates, 0)
    }

    /// Tests that scanning a regular file instead of a directory reports a distinct error.
    func testScanFileInsteadOfDirectoryRoot() throws {
        let fileManager = FileManager.default
        let tempFile = fileManager.temporaryDirectory.appendingPathComponent("PulseDeckTestFile_\(UUID().uuidString).txt")
        try "hello".write(to: tempFile, atomically: true, encoding: .utf8)
        defer {
            try? fileManager.removeItem(at: tempFile)
        }

        let scanner = LibraryScanner()
        let summary = scanner.scan(libraryURL: tempFile)

        XCTAssertFalse(summary.isLibraryValid)
        XCTAssertNotNil(summary.scanError)
        XCTAssertTrue(summary.scanError?.contains("not a directory") ?? false)
        XCTAssertEqual(summary.totalCrates, 0)
    }

    /// Tests that scanning an unreadable crate directory marks it as unreadable without crashing.
    func testScanUnreadableCrateDirectory() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("PulseDeckTestUnreadable_\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            // Restore permissions before removal so cleanup succeeds
            let unreadableDir = tempDir.appendingPathComponent("01_Unreadable_Crate")
            _ = chmod(unreadableDir.path, S_IRWXU)
            try? fileManager.removeItem(at: tempDir)
        }

        let unreadableDir = tempDir.appendingPathComponent("01_Unreadable_Crate")
        try fileManager.createDirectory(at: unreadableDir, withIntermediateDirectories: true)
        // Remove read & execute permissions on the crate
        _ = chmod(unreadableDir.path, 0)

        let scanner = LibraryScanner()
        let summary = scanner.scan(libraryURL: tempDir)

        XCTAssertTrue(summary.isLibraryValid)
        XCTAssertEqual(summary.totalCrates, 1)

        let crate = summary.crates.first(where: { $0.folderName == "01_Unreadable_Crate" })
        XCTAssertNotNil(crate)
        XCTAssertFalse(crate?.isReadable ?? true, "Crate without read permissions must be marked unreadable")
        XCTAssertNotNil(crate?.errorMessage)
    }

    /// Tests scanning the repository checkout library if present at runtime.
    func testScanCheckoutLibraryIfPresent() {
        let cwd = FileManager.default.currentDirectoryPath
        let libraryURL = URL(fileURLWithPath: cwd).appendingPathComponent(PulseDeckCoreConfig.defaultLibraryFolderName)
        guard FileManager.default.fileExists(atPath: libraryURL.path) else {
            return
        }

        let scanner = LibraryScanner()
        let summary = scanner.scan(libraryURL: libraryURL)

        XCTAssertTrue(summary.isLibraryValid)
        XCTAssertTrue(summary.hasCacheFile, "PulseDeck_Library should contain .pulsedeck_ai_cache.json")
        XCTAssertEqual(summary.cacheSchemaVersion, "1.0.0", "Cache schema should be 1.0.0")
        XCTAssertGreaterThanOrEqual(summary.totalCrates, 10, "Should detect at least 10 crates")

        for expectedCrate in PulseDeckCoreConfig.standardCrates {
            let crate = summary.crates.first(where: { $0.folderName == expectedCrate })
            XCTAssertNotNil(crate, "Crate \(expectedCrate) must be detected")
            XCTAssertTrue(crate?.hasGitKeep ?? false, "Crate \(expectedCrate) must contain .gitkeep")
        }
    }

    /// Tests atomic, crash-safe cache persistence using temporary file staging,
    /// synchronous hardware flush (F_FULLFSYNC / fsync) prior to atomic replacement,
    /// and atomic replacement over existing files with round-trip reload verification.
    func testCachePersistenceSaveAndLoadDurable() throws {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("PulseDeckPersistenceTest_\(UUID().uuidString)")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempDir)
        }

        let cacheURL = tempDir.appendingPathComponent(".pulsedeck_ai_cache.json")

        // 1. Initial save of fresh cache
        var cache = PulseDeckLibraryCache(libraryRoot: "TestLibrary")
        cache.generatedAt = "2026-10-14T20:00:00Z"
        let entry1 = makeTestEntry(relativePath: "01_House/track1.mp3", duration: 180.0, bpm: 124.0, fingerprint: "hash123")
        cache.tracks["01_House/track1.mp3"] = entry1

        try CachePersistence.saveAtomic(cache: cache, to: cacheURL)

        // Verify initial load
        let loaded = CachePersistence.load(from: cacheURL)
        XCTAssertNotNil(loaded, "Persisted cache must reload cleanly from disk")
        XCTAssertEqual(loaded?.schemaVersion, "1.0.0")
        XCTAssertEqual(loaded?.libraryRoot, "TestLibrary")
        XCTAssertEqual(loaded?.generatedAt, "2026-10-14T20:00:00Z")
        XCTAssertEqual(loaded?.tracks.count, 1)
        XCTAssertEqual(loaded?.tracks["01_House/track1.mp3"]?.bpm, 124.0)

        // 2. In-place atomic replacement over existing target file with hardware sync before replace
        var updatedCache = loaded!
        updatedCache.generatedAt = "2026-10-14T20:05:00Z"
        let entry2 = makeTestEntry(relativePath: "02_Techno/track2.mp3", duration: 210.0, bpm: 128.0, fingerprint: "hash456")
        CachePersistence.upsertTrack(entry2, in: &updatedCache)

        try CachePersistence.saveAtomic(cache: updatedCache, to: cacheURL)

        // Verify reloaded updated cache
        let reloaded = CachePersistence.load(from: cacheURL)
        XCTAssertNotNil(reloaded)
        XCTAssertEqual(reloaded?.generatedAt, "2026-10-14T20:05:00Z")
        XCTAssertEqual(reloaded?.tracks.count, 2)
        XCTAssertEqual(reloaded?.tracks["02_Techno/track2.mp3"]?.bpm, 128.0)

        // 3. Graceful handling of nonexistent file
        let nonExistentURL = tempDir.appendingPathComponent("does_not_exist.json")
        XCTAssertNil(CachePersistence.load(from: nonExistentURL))

        // 4. Graceful handling of 0-byte empty file
        let emptyURL = tempDir.appendingPathComponent("empty.json")
        try Data().write(to: emptyURL)
        let emptyLoaded = CachePersistence.load(from: emptyURL)
        XCTAssertNotNil(emptyLoaded, "Empty 0-byte file should return an empty default cache")
        XCTAssertEqual(emptyLoaded?.tracks.count, 0)
    }

    func testDisplayNameFormatting() {
        XCTAssertEqual(LibraryScanner.displayName(for: "00_Test_Tracks_Dev"), "[00] Test Tracks Dev")
        XCTAssertEqual(LibraryScanner.displayName(for: "05_MainStage_Dance_120_128BPM"), "[05] MainStage Dance 120 128BPM")
        XCTAssertEqual(LibraryScanner.displayName(for: "Custom_Crate"), "Custom Crate")
    }

    private func makeTestEntry(relativePath: String, duration: Double, bpm: Double, fingerprint: String) -> TrackCacheEntry {
        TrackCacheEntry(
            relativePath: relativePath,
            fileFingerprint: fingerprint,
            fileSizeBytes: 4_194_304,
            fileModificationTime: "2026-10-14T19:00:00Z",
            duration: duration,
            sampleRate: 44100.0,
            channels: 2,
            bitDepth: 16,
            bpm: bpm,
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
                    StructureSection(name: "Intro", startSeconds: 0.0, endSeconds: 15.0, energyLevel: 0.3)
                ],
                vocalSegments: []
            ),
            cueMarkers: CueMarkers(startTrimCue: 0.0, vocalEntryCue: 15.0, mixOutCue: duration - 20.0, endTrimCue: duration),
            aiTrimBypass: false,
            manualOverrides: ManualOverrides(),
            analyzerVersion: "accelerate-dsp-v1.0",
            analysisTimestamp: "2026-10-14T19:01:00Z"
        )
    }
}
