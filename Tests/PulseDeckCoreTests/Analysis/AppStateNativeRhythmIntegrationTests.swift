import AVFoundation
import Foundation
@testable import PulseDeckAI
@testable import PulseDeckCore
import XCTest

@MainActor
final class AppStateNativeRhythmIntegrationTests: XCTestCase {
    private func makeLibrary() throws -> (root: URL, crate: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PulseDeck_AppStateNativeTests_\(UUID().uuidString)")
        let crate = root.appendingPathComponent("01_House")
        try FileManager.default.createDirectory(at: crate, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
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
        let channelData = buffer.floatChannelData![0]
        for f in 0..<Int(totalFrames) {
            channelData[f] = 0.0
        }
        try file.write(from: buffer)
    }

    // MARK: - 1. Selected Method Dispatch & Header Independence

    func testSelectedMethodDispatchAndHeaderIndependence() async throws {
        let fixture = try makeLibrary()
        let editor = WaveformEditorModel(libraryRootURL: fixture.root)
        let app = AppState(libraryRootURL: fixture.root, waveformEditorModel: editor)

        // Default method is DSP
        XCTAssertEqual(app.selectedAnalysisMethod, .dsp)

        // Switching header method does NOT alter any track provenance
        app.selectedAnalysisMethod = .nativeModel
        XCTAssertEqual(app.selectedAnalysisMethod, .nativeModel)

        let trackURL = fixture.crate.appendingPathComponent("track1.wav")
        try createSyntheticClickWAV(url: trackURL, durationSeconds: 6.0, bpm: 120.0)

        // Dispatch without explicit method parameter adopts selectedAnalysisMethod (.nativeModel)
        let task = app.analyzeTrack(relativePath: "01_House/track1.wav")
        XCTAssertEqual(app.activeAnalysisMethod["01_House/track1.wav"], .nativeModel)
        _ = await task.value

        let analyzed = app.loadedCache?.tracks["01_House/track1.wav"]
        XCTAssertEqual(analyzed?.analyzerVersion, "model-beatthis-small0-fixed1500-fp32")

        // Changing header selection back to .dsp does NOT relabel or mutate existing track entry
        app.selectedAnalysisMethod = .dsp
        let unmodifiedEntry = app.loadedCache?.tracks["01_House/track1.wav"]
        XCTAssertEqual(unmodifiedEntry?.analyzerVersion, "model-beatthis-small0-fixed1500-fp32")
    }

    // MARK: - 2. Same Source DSP -> Native -> DSP Cache Identity

    func testSameSourceDSPNativeDSPCacheIdentity() async throws {
        let fixture = try makeLibrary()
        let editor = WaveformEditorModel(libraryRootURL: fixture.root)
        let app = AppState(libraryRootURL: fixture.root, waveformEditorModel: editor)

        let trackURL = fixture.crate.appendingPathComponent("cycle.wav")
        try createSyntheticClickWAV(url: trackURL, durationSeconds: 6.0, bpm: 120.0)
        let relPath = "01_House/cycle.wav"

        // 1. Analyze with DSP
        let dspTask1 = app.analyzeTrack(relativePath: relPath, method: .dsp)
        _ = await dspTask1.value
        let dsp1 = try XCTUnwrap(app.loadedCache?.tracks[relPath])
        XCTAssertEqual(dsp1.analyzerVersion, "local-dsp-1")
        XCTAssertEqual(dsp1.bpm, 120.0, accuracy: 2.0)

        // 2. Switch to Native CoreML
        let modelTask = app.analyzeTrack(relativePath: relPath, method: .nativeModel)
        _ = await modelTask.value
        let modelEntry = try XCTUnwrap(app.loadedCache?.tracks[relPath])
        XCTAssertEqual(modelEntry.analyzerVersion, "model-beatthis-small0-fixed1500-fp32")
        XCTAssertEqual(modelEntry.bpm, 120.0, accuracy: 2.0)
        XCTAssertFalse(modelEntry.beatGrid.beatTimestamps.isEmpty)

        // 3. Switch back to DSP
        let dspTask2 = app.analyzeTrack(relativePath: relPath, method: .dsp)
        _ = await dspTask2.value
        let dsp2 = try XCTUnwrap(app.loadedCache?.tracks[relPath])
        XCTAssertEqual(dsp2.analyzerVersion, "local-dsp-1")
    }

    // MARK: - 3. Stale Completion Cancellation Across Method Switch

    func testStaleCompletionCancellationAcrossMethodSwitch() async throws {
        let fixture = try makeLibrary()
        let editor = WaveformEditorModel(libraryRootURL: fixture.root)
        let app = AppState(libraryRootURL: fixture.root, waveformEditorModel: editor)

        let trackURL = fixture.crate.appendingPathComponent("race.wav")
        try createSyntheticClickWAV(url: trackURL, durationSeconds: 6.0, bpm: 120.0)
        let relPath = "01_House/race.wav"

        // Fire first analysis (Model)
        let task1 = app.analyzeTrack(relativePath: relPath, method: .nativeModel)

        // Immediately trigger second analysis (DSP) for same track
        let task2 = app.analyzeTrack(relativePath: relPath, method: .dsp)

        _ = await task1.value
        _ = await task2.value

        // Final result must be the second request (DSP), not clobbered by stale task1
        let finalEntry = try XCTUnwrap(app.loadedCache?.tracks[relPath])
        XCTAssertEqual(finalEntry.analyzerVersion, "local-dsp-1")
        XCTAssertEqual(app.activeAnalysisMethod[relPath], .dsp)
    }

    // MARK: - 4. Shared Manual-Cue Save Preservation Across Native Analysis

    func testSharedManualCueSavePreservationAcrossNativeAnalysis() async throws {
        let fixture = try makeLibrary()
        let editor = WaveformEditorModel(libraryRootURL: fixture.root)
        let app = AppState(libraryRootURL: fixture.root, waveformEditorModel: editor)

        let trackURL = fixture.crate.appendingPathComponent("cues.wav")
        try createSyntheticClickWAV(url: trackURL, durationSeconds: 8.0, bpm: 120.0)
        let relPath = "01_House/cues.wav"

        // Baseline analysis with DSP
        let dspTask = app.analyzeTrack(relativePath: relPath, method: .dsp)
        _ = await dspTask.value

        // Manually adjust cue markers on the track via persistence
        var entry = try XCTUnwrap(app.loadedCache?.tracks[relPath])
        entry.cueMarkers = CueMarkers(startTrimCue: 1.25, vocalEntryCue: 2.50, mixOutCue: 6.75, endTrimCue: 7.80)
        entry.manualOverrides = ManualOverrides(
            isManual: true,
            overriddenFields: ["cueMarkers"],
            updatedAt: "2026-11-02T14:00:00Z"
        )
        try await editor.persistAnalyzedTrack(entry, libraryRootURL: fixture.root)

        // Re-analyze track with Native Model
        let modelTask = app.analyzeTrack(relativePath: relPath, method: .nativeModel)
        _ = await modelTask.value

        // Verified preserved manual cues
        let updated = try XCTUnwrap(app.loadedCache?.tracks[relPath])
        XCTAssertEqual(updated.analyzerVersion, "model-beatthis-small0-fixed1500-fp32")
        XCTAssertEqual(updated.cueMarkers.startTrimCue, 1.25)
        XCTAssertEqual(updated.cueMarkers.vocalEntryCue, 2.50)
        XCTAssertEqual(updated.cueMarkers.mixOutCue, 6.75)
        XCTAssertEqual(updated.cueMarkers.endTrimCue, 7.80)
        XCTAssertTrue(updated.manualOverrides.isManual)
        XCTAssertTrue(updated.manualOverrides.overriddenFields.contains("cueMarkers"))
    }

    // MARK: - 5. Native Model Insufficient Beats Preserves Existing Valid Cache

    func testNativeModelInsufficientBeatsPreservesExistingValidCache() async throws {
        let fixture = try makeLibrary()
        let editor = WaveformEditorModel(libraryRootURL: fixture.root)
        let app = AppState(libraryRootURL: fixture.root, waveformEditorModel: editor)

        let trackURL = fixture.crate.appendingPathComponent("silence_test.wav")
        try createSyntheticClickWAV(url: trackURL, durationSeconds: 6.0, bpm: 120.0)
        let relPath = "01_House/silence_test.wav"

        // 1. Establish valid baseline analysis with DSP
        let dspTask = app.analyzeTrack(relativePath: relPath, method: .dsp)
        _ = await dspTask.value
        let initialEntry = try XCTUnwrap(app.loadedCache?.tracks[relPath])
        XCTAssertEqual(initialEntry.analyzerVersion, "local-dsp-1")
        XCTAssertEqual(initialEntry.bpm, 120.0, accuracy: 2.0)

        // 2. Overwrite audio file with silent audio (yielding insufficient rhythm)
        try createSilenceWAV(url: trackURL, durationSeconds: 4.0)

        // 3. Re-analyze with Native Model
        let failTask = app.analyzeTrack(relativePath: relPath, method: .nativeModel)
        _ = await failTask.value

        // Status must record failure
        if case .failed = app.analysisStatus(for: relPath) {
            // Expected
        } else {
            XCTFail("Status must be .failed on insufficient rhythm audio")
        }

        // Cache entry MUST be preserved completely intact, not erased or corrupted
        let preservedEntry = try XCTUnwrap(app.loadedCache?.tracks[relPath])
        XCTAssertEqual(preservedEntry.analyzerVersion, "local-dsp-1", "Cache must retain previous valid analysis on failure")
        XCTAssertEqual(preservedEntry.bpm, initialEntry.bpm)
    }

    // MARK: - 6. Root Change Drops Stale In-Flight Analysis

    func testRootChangeDropsStaleInFlightAnalysis() async throws {
        let fixture1 = try makeLibrary()
        let fixture2 = try makeLibrary()

        let editor1 = WaveformEditorModel(libraryRootURL: fixture1.root)
        let app = AppState(libraryRootURL: fixture1.root, waveformEditorModel: editor1)

        let trackURL = fixture1.crate.appendingPathComponent("switch.wav")
        try createSyntheticClickWAV(url: trackURL, durationSeconds: 6.0, bpm: 120.0)
        let relPath = "01_House/switch.wav"

        let task = app.analyzeTrack(relativePath: relPath, method: .nativeModel)

        // Change library root immediately while task is running
        app.libraryRootURL = fixture2.root

        _ = await task.value

        // The second library cache must not be contaminated by fixture1 analysis
        XCTAssertNil(app.loadedCache?.tracks[relPath])
    }
}
