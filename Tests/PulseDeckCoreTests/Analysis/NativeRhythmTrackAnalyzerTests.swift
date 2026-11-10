import AVFoundation
import Foundation
import XCTest
@testable import PulseDeckAI
@testable import PulseDeckCore

final class NativeRhythmTrackAnalyzerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PulseDeckNativeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeLibrary() throws -> (root: URL, crate: URL) {
        let root = tempDir.appendingPathComponent("PulseDeck_Library", isDirectory: true)
        let crate = root.appendingPathComponent("01_House", isDirectory: true)
        try FileManager.default.createDirectory(at: crate, withIntermediateDirectories: true)
        return (root, crate)
    }

    private func createSyntheticClickWAV(url: URL, durationSeconds: Double, sampleRate: Double = 22050.0, bpm: Double = 120.0) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let totalFrames = AVAudioFrameCount(round(durationSeconds * sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            throw MelSpectrogramError.bufferAllocationFailed
        }
        buffer.frameLength = totalFrames
        let channelData = buffer.floatChannelData![0]
        let beatIntervalFrames = Int(sampleRate * (60.0 / bpm))

        for f in 0..<Int(totalFrames) {
            let beatIndex = f % beatIntervalFrames
            if beatIndex < 200 {
                let t = Double(beatIndex) / sampleRate
                let freq = (f % (4 * beatIntervalFrames) < 200) ? 880.0 : 440.0
                channelData[f] = Float(sin(2.0 * Double.pi * freq * t) * (1.0 - Double(beatIndex) / 200.0) * 0.8)
            } else {
                channelData[f] = 0.0
            }
        }
        try file.write(from: buffer)
    }

    private func createSilenceWAV(url: URL, durationSeconds: Double, sampleRate: Double = 22050.0) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let totalFrames = AVAudioFrameCount(round(durationSeconds * sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            throw MelSpectrogramError.bufferAllocationFailed
        }
        buffer.frameLength = totalFrames
        memset(buffer.floatChannelData![0], 0, Int(totalFrames) * MemoryLayout<Float>.size)
        try file.write(from: buffer)
    }

    // MARK: - Unit Tests

    func testNativeRhythmAnalysisProducesValidEntryAndProvenance() async throws {
        let fixture = try makeLibrary()
        let trackURL = fixture.crate.appendingPathComponent("clicks120.wav")
        try createSyntheticClickWAV(url: trackURL, durationSeconds: 10.0, sampleRate: 22050.0, bpm: 120.0)

        let analyzer = NativeRhythmTrackAnalyzer()
        let entry = try await analyzer.analyze(url: trackURL, libraryRoot: fixture.root)

        // 1. Provenance: explicit fixed-1500 model adaptation
        XCTAssertEqual(entry.analyzerVersion, "model-beatthis-small0-fixed1500-fp32-phrase1-key1")
        XCTAssertEqual(entry.relativePath, "01_House/clicks120.wav")
        XCTAssertEqual(entry.musicalKey, "Unknown")
        XCTAssertTrue(entry.structure.sections.isEmpty)
        XCTAssertTrue(entry.structure.vocalSegments.isEmpty)

        // 2. Tempo and beat grid derived from neural model predictions
        XCTAssertEqual(entry.bpm, 120.0, accuracy: 2.0)
        XCTAssertFalse(entry.beatGrid.beatTimestamps.isEmpty)
        XCTAssertEqual(entry.beatGrid.beatIntervalSeconds, 0.5, accuracy: 0.05)
        XCTAssertTrue(entry.confidence >= 0.10 && entry.confidence <= 0.85)

        // 3. Structural bounds & cue ordering
        XCTAssertTrue(entry.isValid)
        XCTAssertTrue(entry.cueMarkers.isValid(forDuration: entry.duration))

        // 4. Shared JSON schema compliance
        try SharedCacheContract().validate(entry: entry)
    }

    func testInsufficientRhythmThrowsAndDoesNotFabricateTempo() async throws {
        let fixture = try makeLibrary()
        let silenceURL = fixture.crate.appendingPathComponent("silence.wav")
        try createSilenceWAV(url: silenceURL, durationSeconds: 4.0, sampleRate: 22050.0)

        let analyzer = NativeRhythmTrackAnalyzer()
        do {
            _ = try await analyzer.analyze(url: silenceURL, libraryRoot: fixture.root)
            XCTFail("Silence audio must throw insufficientBeats error, not fabricate BPM 120")
        } catch let error as NativeRhythmAnalysisError {
            if case .insufficientBeats = error {
                // Expected failure: insufficient rhythm
            } else {
                XCTFail("Wrong error thrown for silence: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testManualCuePreservationAcrossNativeMerge() async throws {
        let fixture = try makeLibrary()
        let trackURL = fixture.crate.appendingPathComponent("clicks120.wav")
        try createSyntheticClickWAV(url: trackURL, durationSeconds: 10.0, sampleRate: 22050.0, bpm: 120.0)

        let analyzer = NativeRhythmTrackAnalyzer()
        let nativeEntry = try await analyzer.analyze(url: trackURL, libraryRoot: fixture.root)

        // Create an existing entry with explicit manual cue overrides
        var existing = nativeEntry
        existing.cueMarkers = CueMarkers(startTrimCue: 1.5, vocalEntryCue: 2.5, mixOutCue: 7.5, endTrimCue: 9.5)
        existing.manualOverrides = ManualOverrides(
            isManual: true,
            overriddenFields: ["cueMarkers"],
            updatedAt: "2026-11-02T12:00:00Z"
        )

        // Merge fresh native analysis into existing entry
        let merged = existing.mergingPreservingOverrides(with: nativeEntry)

        // Manual cues MUST be preserved bit-for-bit
        XCTAssertEqual(merged.cueMarkers.startTrimCue, 1.5)
        XCTAssertEqual(merged.cueMarkers.vocalEntryCue, 2.5)
        XCTAssertEqual(merged.cueMarkers.mixOutCue, 7.5)
        XCTAssertEqual(merged.cueMarkers.endTrimCue, 9.5)
        XCTAssertTrue(merged.manualOverrides.overriddenFields.contains("cueMarkers"))

        // Fresh beat grid and tempo are adopted
        XCTAssertEqual(merged.bpm, nativeEntry.bpm)
        XCTAssertEqual(merged.beatGrid.beatTimestamps, nativeEntry.beatGrid.beatTimestamps)
    }

    func testPythonCacheRoundtripWithNativeEntry() async throws {
        let fixture = try makeLibrary()
        let trackURL = fixture.crate.appendingPathComponent("clicks120.wav")
        try createSyntheticClickWAV(url: trackURL, durationSeconds: 10.0, sampleRate: 22050.0, bpm: 120.0)

        let analyzer = NativeRhythmTrackAnalyzer()
        let entry = try await analyzer.analyze(url: trackURL, libraryRoot: fixture.root)

        var cache = PulseDeckLibraryCache(libraryRoot: "PulseDeck_Library")
        CachePersistence.upsertTrack(entry, in: &cache)
        let cacheURL = fixture.root.appendingPathComponent(PulseDeckCoreConfig.cacheFileName)
        try CachePersistence.saveAtomic(cache: cache, to: cacheURL)

        // Verify Swift loader
        let loaded = try XCTUnwrap(CachePersistence.load(from: cacheURL))
        XCTAssertEqual(loaded.tracks["01_House/clicks120.wav"]?.analyzerVersion, "model-beatthis-small0-fixed1500-fp32-phrase1-key1")

        // Verify Python loader & validator
        let pythonProcess = Process()
        pythonProcess.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        pythonProcess.arguments = [
            "-c",
            """
            import sys
            sys.path.insert(0, '.')
            from scripts.pulsedeck_cache import PulseDeckLibraryCache
            cache = PulseDeckLibraryCache.load('\(cacheURL.path)')
            cache.validate()
            entry = cache.tracks['01_House/clicks120.wav']
            assert entry.analyzerVersion == 'model-beatthis-small0-fixed1500-fp32-phrase1-key1', f'Wrong analyzerVersion: {entry.analyzerVersion}'
            assert entry.bpm > 0, 'BPM must be positive'
            print('Python validation verified successfully')
            """
        ]
        let pipe = Pipe()
        pythonProcess.standardOutput = pipe
        pythonProcess.standardError = pipe
        try pythonProcess.run()
        pythonProcess.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(pythonProcess.terminationStatus, 0, "Python cache validation failed: \(output)")
        XCTAssertTrue(output.contains("Python validation verified successfully"))
    }

    @MainActor
    func testAppStateAnalysisMethodSelectionAndIdentity() async throws {
        let fixture = try makeLibrary()
        let editor = WaveformEditorModel(libraryRootURL: fixture.root)
        let appState = AppState(libraryRootURL: fixture.root, waveformEditorModel: editor)

        // 1. Default method is .nativeModel
        XCTAssertEqual(appState.selectedAnalysisMethod, .nativeModel)

        // 2. Global switch to .nativeModel updates default without touching tracks
        appState.selectedAnalysisMethod = .nativeModel
        XCTAssertEqual(appState.selectedAnalysisMethod, .nativeModel)

        // 3. Track request explicitly captures method
        let trackURL = fixture.crate.appendingPathComponent("clicks120.wav")
        try createSyntheticClickWAV(url: trackURL, durationSeconds: 10.0, sampleRate: 22050.0, bpm: 120.0)

        let task = appState.analyzeTrack(relativePath: "01_House/clicks120.wav", method: .nativeModel)
        XCTAssertEqual(appState.activeAnalysisMethod["01_House/clicks120.wav"], .nativeModel)
        _ = await task.value

        // Provenance must reflect Native Model
        let analyzed = appState.loadedCache?.tracks["01_House/clicks120.wav"]
        XCTAssertEqual(analyzed?.analyzerVersion, "model-beatthis-small0-fixed1500-fp32-phrase1-key1")

        // 4. Switch track explicitly back to DSP
        let dspTask = appState.analyzeTrack(relativePath: "01_House/clicks120.wav", method: .dsp)
        XCTAssertEqual(appState.activeAnalysisMethod["01_House/clicks120.wav"], .dsp)
        _ = await dspTask.value

        let dspAnalyzed = appState.loadedCache?.tracks["01_House/clicks120.wav"]
        XCTAssertEqual(dspAnalyzed?.analyzerVersion, "local-dsp-1")
    }
}
