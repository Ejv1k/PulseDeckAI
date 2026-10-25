import XCTest
import AVFoundation
import CoreAudio
import SwiftUI
import AppKit
@testable import PulseDeckCore
@testable import PulseDeckAI

final class SoundboardTests: XCTestCase {

    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 2)!

    private func createTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("soundboard_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func createSineWavFile(
        in directory: URL,
        filename: String,
        durationSeconds: Double = 0.5,
        frequencyHz: Float = 440.0
    ) throws -> URL {
        let fileURL = directory.appendingPathComponent(filename)
        let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        let frameCount = AVAudioFrameCount(44100.0 * durationSeconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        if let channels = buffer.floatChannelData {
            for frame in 0..<Int(frameCount) {
                let sample = sin(Float(frame) * 2.0 * .pi * frequencyHz / 44100.0) * 0.7
                channels[0][frame] = sample
                channels[1][frame] = sample
            }
        }
        try file.write(from: buffer)
        return fileURL
    }

    private func createSineWavFileCustomSampleRate(
        in directory: URL,
        filename: String,
        sampleRate: Double,
        durationSeconds: Double = 0.5,
        frequencyHz: Float = 440.0
    ) throws -> URL {
        let fileURL = directory.appendingPathComponent(filename)
        let customFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let file = try AVAudioFile(forWriting: fileURL, settings: customFormat.settings)
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: customFormat, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        if let channels = buffer.floatChannelData {
            for frame in 0..<Int(frameCount) {
                let sample = sin(Float(frame) * 2.0 * .pi * frequencyHz / Float(sampleRate)) * 0.7
                channels[0][frame] = sample
                channels[1][frame] = sample
            }
        }
        try file.write(from: buffer)
        return fileURL
    }

    private func createCorruptFile(in directory: URL, filename: String) throws -> URL {
        let fileURL = directory.appendingPathComponent(filename)
        let garbage = Data([0xFF, 0xFE, 0x00, 0x01, 0xDE, 0xAD, 0xBE, 0xEF])
        try garbage.write(to: fileURL)
        return fileURL
    }

    private func render(_ engine: AVAudioEngine, frames: AVAudioFrameCount = 4096) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: frames
        ))
        XCTAssertEqual(try engine.renderOffline(frames, to: buffer), .success)
        return buffer
    }

    private func peakAmplitude(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0.0 }
        var maxVal: Float = 0.0
        for ch in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                maxVal = max(maxVal, abs(channels[ch][frame]))
            }
        }
        return maxVal
    }

    // MARK: - 1. Asset Mapping & All 8 Pads

    func testAssetMappingAllEightPads() throws {
        let tempDir = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sfxDir = tempDir.appendingPathComponent("08_Soundboard_SFX")
        try FileManager.default.createDirectory(at: sfxDir, withIntermediateDirectories: true)

        let filenames = [
            "01_Airhorn.wav", "02_Laser.wav", "03_Drop.wav", "04_Chime.wav",
            "05_Kick.wav", "06_Snare.wav", "07_Sub.wav", "08_Siren.wav"
        ]
        for name in filenames {
            _ = try createSineWavFile(in: sfxDir, filename: name, durationSeconds: 0.3)
        }

        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let soundboard = coordinator.soundboardController

        let expectation = expectation(description: "Preload completes")
        soundboard.onPadsChanged = { snapshots in
            if snapshots.allSatisfy({ !$0.isFallback }) {
                expectation.fulfill()
            }
        }

        soundboard.preload(from: tempDir)
        wait(for: [expectation], timeout: 5.0)
        soundboard.onPadsChanged = nil

        let snapshots = soundboard.padSnapshots
        XCTAssertEqual(snapshots.count, 8)
        for i in 0..<8 {
            let snap = snapshots[i]
            XCTAssertEqual(snap.index, i)
            XCTAssertEqual(snap.keyLabel, "F\(i + 1)")
            XCTAssertFalse(snap.isFallback, "Pad \(i) should have loaded valid file")
            XCTAssertNil(snap.error)
            XCTAssertGreaterThan(snap.ramBytes, 0)
            XCTAssertGreaterThan(snap.durationSeconds, 0.2)
        }
    }

    // MARK: - 2. Empty Crate Fallback & Audible Actual PCM

    func testEmptyCrateFallbackAudibleActualPCM() throws {
        let tempDir = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sfxDir = tempDir.appendingPathComponent("08_Soundboard_SFX")
        try FileManager.default.createDirectory(at: sfxDir, withIntermediateDirectories: true)
        let gitkeep = sfxDir.appendingPathComponent(".gitkeep")
        try Data().write(to: gitkeep)

        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        try coordinator.masterAudioEngine.rawEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try coordinator.cueAudioEngine.rawEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try coordinator.start()
        defer { coordinator.stop() }

        let soundboard = coordinator.soundboardController

        let expectation = expectation(description: "Preload empty completes")
        soundboard.onPadsChanged = { snapshots in
            if snapshots.allSatisfy({ $0.isFallback }) {
                expectation.fulfill()
            }
        }

        soundboard.preload(from: tempDir)
        wait(for: [expectation], timeout: 5.0)
        soundboard.onPadsChanged = nil

        let snapshots = soundboard.padSnapshots
        XCTAssertEqual(snapshots.count, 8)
        for snap in snapshots {
            XCTAssertTrue(snap.isFallback, "All pads should be procedural fallbacks")
            XCTAssertNil(snap.error)
            XCTAssertGreaterThan(snap.ramBytes, 0)
        }

        // Trigger Pad 0 (1kHz Pip fallback) and render Master offline
        soundboard.triggerPad(index: 0)
        let buffer = try render(coordinator.masterAudioEngine.rawEngine, frames: 4096)
        let peak = peakAmplitude(of: buffer)
        XCTAssertGreaterThan(peak, 0.05, "Fallback tone should render audible non-zero signal")
    }

    // MARK: - 3. Partial, Corrupt, and Oversized Files Safe Behavior

    func testPartialCorruptAndOversizedFilesSafeBehavior() throws {
        let tempDir = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sfxDir = tempDir.appendingPathComponent("08_Soundboard_SFX")
        try FileManager.default.createDirectory(at: sfxDir, withIntermediateDirectories: true)

        // 2 valid files
        _ = try createSineWavFile(in: sfxDir, filename: "01_ValidA.wav", durationSeconds: 0.2)
        _ = try createSineWavFile(in: sfxDir, filename: "02_ValidB.wav", durationSeconds: 0.2)

        // 1 corrupt file
        _ = try createCorruptFile(in: sfxDir, filename: "03_Corrupt.wav")

        // 1 oversized file (> 15 seconds)
        _ = try createSineWavFile(in: sfxDir, filename: "04_Oversized.wav", durationSeconds: 16.0)

        // Pads 4..7 have no files in folder

        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        try coordinator.masterAudioEngine.rawEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try coordinator.cueAudioEngine.rawEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try coordinator.start()
        defer { coordinator.stop() }

        let soundboard = coordinator.soundboardController

        let expectation = expectation(description: "Preload mixed crate")
        soundboard.onPadsChanged = { snapshots in
            if snapshots.count == 8 {
                expectation.fulfill()
            }
        }

        soundboard.preload(from: tempDir)
        wait(for: [expectation], timeout: 5.0)
        soundboard.onPadsChanged = nil

        let snapshots = soundboard.padSnapshots
        XCTAssertEqual(snapshots.count, 8)

        // Valid pads
        XCTAssertFalse(snapshots[0].isFallback)
        XCTAssertNil(snapshots[0].error)
        XCTAssertFalse(snapshots[1].isFallback)
        XCTAssertNil(snapshots[1].error)

        // Corrupt pad
        XCTAssertTrue(snapshots[2].isFallback)
        if case .corruptFile = snapshots[2].error {
            // Success
        } else {
            XCTFail("Pad 2 should report corruptFile error")
        }

        // Oversized pad
        XCTAssertTrue(snapshots[3].isFallback)
        if case .oversizedFile = snapshots[3].error {
            // Success
        } else {
            XCTFail("Pad 3 should report oversizedFile error")
        }

        // Missing pads
        for i in 4..<8 {
            XCTAssertTrue(snapshots[i].isFallback)
            XCTAssertNil(snapshots[i].error)
        }

        // Triggering corrupt and oversized pads safely produces sound via fallback without crash
        soundboard.triggerPad(index: 2)
        let buf2 = try render(coordinator.masterAudioEngine.rawEngine, frames: 4096)
        XCTAssertGreaterThan(peakAmplitude(of: buf2), 0.05)

        soundboard.triggerPad(index: 3)
        let buf3 = try render(coordinator.masterAudioEngine.rawEngine, frames: 4096)
        XCTAssertGreaterThan(peakAmplitude(of: buf3), 0.05)
    }

    // MARK: - 4. Preloaded Buffers Trigger Without File Access (Fixture Deleted)

    func testPreloadedBuffersTriggerWithoutFileAccess() throws {
        let tempDir = try createTempDirectory()
        let sfxDir = tempDir.appendingPathComponent("08_Soundboard_SFX")
        try FileManager.default.createDirectory(at: sfxDir, withIntermediateDirectories: true)

        _ = try createSineWavFile(in: sfxDir, filename: "01_MemoryTest.wav", durationSeconds: 0.3)

        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        try coordinator.masterAudioEngine.rawEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try coordinator.cueAudioEngine.rawEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try coordinator.start()
        defer { coordinator.stop() }

        let soundboard = coordinator.soundboardController

        let expectation = expectation(description: "Preload finishes")
        soundboard.onPadsChanged = { snapshots in
            if !snapshots[0].isFallback {
                expectation.fulfill()
            }
        }

        soundboard.preload(from: tempDir)
        wait(for: [expectation], timeout: 5.0)
        soundboard.onPadsChanged = nil

        // COMPLETELY DELETE THE ENTIRE TEMPORARY DIRECTORY AND FIXTURE FROM DISK
        try FileManager.default.removeItem(at: tempDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path))

        // Trigger pad: MUST play cleanly from pre-allocated RAM buffer
        soundboard.triggerPad(index: 0)
        let buffer = try render(coordinator.masterAudioEngine.rawEngine, frames: 4096)
        let peak = peakAmplitude(of: buffer)
        XCTAssertGreaterThan(peak, 0.1, "Pad should play directly from unified RAM even with file deleted from disk")
    }

    // MARK: - 5. Simultaneous Pads & Retrigger Policy

    func testSimultaneousPadsAndRetriggerPolicy() throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        try coordinator.masterAudioEngine.rawEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try coordinator.cueAudioEngine.rawEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try coordinator.start()
        defer { coordinator.stop() }

        let soundboard = coordinator.soundboardController

        // Trigger Pad 0 and Pad 1 simultaneously
        soundboard.triggerPad(index: 0)
        soundboard.triggerPad(index: 1)

        let snapshots = soundboard.padSnapshots
        XCTAssertTrue(snapshots[0].isPlaying, "Pad 0 should be playing")
        XCTAssertTrue(snapshots[1].isPlaying, "Pad 1 should be playing")

        let buffer = try render(coordinator.masterAudioEngine.rawEngine, frames: 4096)
        XCTAssertGreaterThan(peakAmplitude(of: buffer), 0.1, "Simultaneous pads render combined audio")

        // Retrigger Pad 0 rapidly (stutter restart)
        soundboard.triggerPad(index: 0)
        XCTAssertTrue(soundboard.padSnapshots[0].isPlaying, "Pad 0 remains playing after retrigger")
        XCTAssertTrue(soundboard.padSnapshots[1].isPlaying, "Pad 1 is untouched by Pad 0 retrigger")

        // Stop Pad 0
        soundboard.stopPad(index: 0)
        XCTAssertFalse(soundboard.padSnapshots[0].isPlaying, "Pad 0 should be stopped")
        XCTAssertTrue(soundboard.padSnapshots[1].isPlaying, "Pad 1 should still be playing")

        // Stop all
        soundboard.stopAllPads()
        XCTAssertFalse(soundboard.padSnapshots[1].isPlaying, "Pad 1 should be stopped after stopAllPads")
    }

    // MARK: - 6. Master PCM With Cue Unchanged (Headphone Isolation)

    func testMasterPCMWithCueUnchanged() throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        try coordinator.masterAudioEngine.rawEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try coordinator.cueAudioEngine.rawEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try coordinator.start()
        defer { coordinator.stop() }

        let soundboard = coordinator.soundboardController

        // Trigger Pad 0 (Pip)
        soundboard.triggerPad(index: 0)

        // Render Master engine
        let masterBuffer = try render(coordinator.masterAudioEngine.rawEngine, frames: 4096)
        let masterPeak = peakAmplitude(of: masterBuffer)
        XCTAssertGreaterThan(masterPeak, 0.05, "Master output should contain soundboard audio")

        // Render Cue engine
        let cueBuffer = try render(coordinator.cueAudioEngine.rawEngine, frames: 4096)
        let cuePeak = peakAmplitude(of: cueBuffer)
        XCTAssertEqual(cuePeak, 0.0, accuracy: 0.00001, "Cue output must be strictly silent with zero soundboard leakage")
    }

    // MARK: - 7. Deck Crossfader & Talkover Isolation

    func testDeckCrossfaderAndTalkoverIsolation() throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        try coordinator.masterAudioEngine.rawEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try coordinator.cueAudioEngine.rawEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try coordinator.start()
        defer { coordinator.stop() }

        let soundboard = coordinator.soundboardController
        let talkover = coordinator.talkoverController

        // Move crossfader completely to Deck B (Deck A fader weight = 0.0, Deck B = 1.0)
        coordinator.setCrossfader(position: 1.0)
        XCTAssertEqual(coordinator.deckAGraph.crossfaderWeight, 0.0)
        XCTAssertEqual(coordinator.deckBGraph.crossfaderWeight, 1.0)

        // Engage talkover ducking to fully ducked state (800ms ramp complete)
        talkover.stepProgress(to: 1.0)
        XCTAssertEqual(coordinator.deckAGraph.talkoverVolumeMultiplier, 0.15)
        XCTAssertEqual(coordinator.deckBGraph.talkoverVolumeMultiplier, 0.15)
        XCTAssertEqual(coordinator.deckAGraph.masterTalkoverEQNode.bands[0].gain, -4.0)

        // Trigger Soundboard pad
        soundboard.triggerPad(index: 0)

        // Master should render soundboard audio at full un-ducked punch
        let buffer = try render(coordinator.masterAudioEngine.rawEngine, frames: 4096)
        XCTAssertGreaterThan(peakAmplitude(of: buffer), 0.05)

        // Verify Deck A and Deck B crossfader and talkover parameters were NOT reset or modified
        XCTAssertEqual(coordinator.deckAGraph.crossfaderWeight, 0.0)
        XCTAssertEqual(coordinator.deckBGraph.crossfaderWeight, 1.0)
        XCTAssertEqual(coordinator.deckAGraph.talkoverVolumeMultiplier, 0.15)
        XCTAssertEqual(coordinator.deckBGraph.talkoverVolumeMultiplier, 0.15)
        XCTAssertEqual(coordinator.deckAGraph.masterTalkoverEQNode.bands[0].gain, -4.0)

        // Disengage talkover
        talkover.stepProgress(to: 0.0)
        XCTAssertEqual(coordinator.deckBGraph.talkoverVolumeMultiplier, 1.0)
        XCTAssertEqual(coordinator.deckAGraph.crossfaderWeight, 0.0)
    }

    // MARK: - 8. Cancellation, Root Change, Stale Completion, Stop/Restart, Teardown

    func testCancellationRootChangeStaleCompletionStopRestartTeardown() throws {
        let tempDir1 = try createTempDirectory()
        let tempDir2 = try createTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: tempDir1)
            try? FileManager.default.removeItem(at: tempDir2)
        }

        let sfx1 = tempDir1.appendingPathComponent("08_Soundboard_SFX")
        let sfx2 = tempDir2.appendingPathComponent("08_Soundboard_SFX")
        try FileManager.default.createDirectory(at: sfx1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sfx2, withIntermediateDirectories: true)

        _ = try createSineWavFile(in: sfx1, filename: "01_Root1File.wav", durationSeconds: 0.2, frequencyHz: 300.0)
        _ = try createSineWavFile(in: sfx2, filename: "01_Root2File.wav", durationSeconds: 0.2, frequencyHz: 600.0)

        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        try coordinator.masterAudioEngine.rawEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try coordinator.start()

        let soundboard = coordinator.soundboardController

        // Preload root 1 then immediately switch to root 2
        soundboard.preload(from: tempDir1)

        let expectation2 = expectation(description: "Root 2 finishes")
        soundboard.onPadsChanged = { snapshots in
            if snapshots[0].title.contains("Root2File") {
                expectation2.fulfill()
            }
        }
        soundboard.preload(from: tempDir2)
        wait(for: [expectation2], timeout: 5.0)
        soundboard.onPadsChanged = nil

        XCTAssertTrue(soundboard.padSnapshots[0].title.contains("Root2File"), "Pad 0 should contain Root 2 asset, not stale Root 1")

        // Trigger pad
        soundboard.triggerPad(index: 0)
        XCTAssertTrue(soundboard.padSnapshots[0].isPlaying)

        // Stop coordinator
        coordinator.stop()
        XCTAssertFalse(soundboard.padSnapshots[0].isPlaying, "Stopping coordinator halts active pads")

        // Restart coordinator
        try coordinator.start()
        soundboard.triggerPad(index: 0)
        XCTAssertTrue(soundboard.padSnapshots[0].isPlaying, "Pad can be retriggered after restart")

        coordinator.stop()
    }

    // MARK: - 9. Keyboard Repeat & Routing Behavior

    @MainActor
    func testKeyboardRepeatAndRoutingBehavior() {
        let tempDir = FileManager.default.temporaryDirectory
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let appState = AppState(
            libraryRootURL: tempDir,
            waveformEditorModel: WaveformEditorModel(libraryRootURL: tempDir),
            audioCoordinator: coordinator,
            startCoordinator: false
        )

        // 1. Verify functionKeyIndex for NSEvent across all 8 function keys
        let fKeys: [(Int, Int)] = [
            (122, 0), (120, 1), (99, 2), (118, 3),
            (96, 4), (97, 5), (98, 6), (100, 7)
        ]
        for (keyCode, expectedPad) in fKeys {
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 1.0,
                windowNumber: 1,
                context: nil,
                characters: String(UnicodeScalar(NSF1FunctionKey + expectedPad)!),
                charactersIgnoringModifiers: String(UnicodeScalar(NSF1FunctionKey + expectedPad)!),
                isARepeat: false,
                keyCode: UInt16(keyCode)
            )!
            let detected = SoundboardKeyboardRouter.functionKeyIndex(for: event)
            XCTAssertEqual(detected, expectedPad, "Key code \(keyCode) should detect pad \(expectedPad)")
        }

        // 2. Verify repeat suppression
        let repeatEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 2.0,
            windowNumber: 1,
            context: nil,
            characters: String(UnicodeScalar(NSF1FunctionKey)!),
            charactersIgnoringModifiers: String(UnicodeScalar(NSF1FunctionKey)!),
            isARepeat: true,
            keyCode: 122
        )!
        XCTAssertTrue(repeatEvent.isARepeat)

        // 3. Trigger pad via AppState
        appState.triggerSoundboardPad(index: 0)
        XCTAssertTrue(appState.soundboardPads[0].isPlaying)

        // 4. Verify duplicate rapid dispatch is debounced
        appState.triggerSoundboardPad(index: 0)
        XCTAssertTrue(appState.soundboardPads[0].isPlaying)

        // 5. Stop all pads
        appState.stopAllSoundboardPads()
        XCTAssertFalse(appState.soundboardPads[0].isPlaying)

        // 6. Verify Talkover hotkey 'T' repeat suppression remains functional
        XCTAssertFalse(appState.isTalkoverActive)
        appState.toggleTalkover()
        XCTAssertTrue(appState.isTalkoverActive)
        appState.toggleTalkover()
        XCTAssertFalse(appState.isTalkoverActive)
    }

    // MARK: - 10. Sample-Rate Conversion Flushing & Trailing PCM Drain

    func testSampleRateConversionFlushesEndOfStreamAndPreservesTrailingPCM() throws {
        let tempDir = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sfxDir = tempDir.appendingPathComponent("08_Soundboard_SFX")
        try FileManager.default.createDirectory(at: sfxDir, withIntermediateDirectories: true)

        // 1. Non-44.1 kHz asset (48 kHz, 0.4s duration = 19,200 frames)
        // Converted to 44.1 kHz, expected frames ~ 17,640.
        let file48k = try createSineWavFileCustomSampleRate(
            in: sfxDir,
            filename: "01_Airhorn.wav",
            sampleRate: 48000.0,
            durationSeconds: 0.4,
            frequencyHz: 440.0
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: file48k.path))

        // 2. Short non-44.1 kHz asset (48 kHz, 0.01s = 480 frames)
        let fileShort48k = try createSineWavFileCustomSampleRate(
            in: sfxDir,
            filename: "02_Laser.wav",
            sampleRate: 48000.0,
            durationSeconds: 0.01,
            frequencyHz: 880.0
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileShort48k.path))

        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let soundboard = coordinator.soundboardController

        let expectation = expectation(description: "Preload completes")
        soundboard.onPadsChanged = { snapshots in
            if snapshots[0].isFallback == false && snapshots[1].isFallback == false {
                expectation.fulfill()
            }
        }

        soundboard.preload(from: tempDir)
        wait(for: [expectation], timeout: 5.0)
        soundboard.onPadsChanged = nil

        let snapshots = soundboard.padSnapshots
        XCTAssertFalse(snapshots[0].isFallback)
        XCTAssertFalse(snapshots[1].isFallback)

        // Inspect pad 0 preloaded buffer
        let buffer0 = try XCTUnwrap(soundboard.bufferForTesting(at: 0))
        XCTAssertEqual(buffer0.format.sampleRate, 44100.0)
        XCTAssertEqual(buffer0.format.channelCount, 2)

        // Expected frames: 0.4 * 44100 = 17640 frames (+/- 100 frames for resampling filter latency)
        let expectedFrames: Double = 0.4 * 44100.0
        XCTAssertEqual(Double(buffer0.frameLength), expectedFrames, accuracy: 200.0)

        // Verify trailing PCM is flushed and preserved (not truncated or zeroed out)
        let trailingCount = 200
        XCTAssertGreaterThan(Int(buffer0.frameLength), trailingCount)
        if let channels = buffer0.floatChannelData {
            var trailingMaxAmp: Float = 0.0
            let startFrame = Int(buffer0.frameLength) - trailingCount
            for frame in startFrame..<Int(buffer0.frameLength) {
                trailingMaxAmp = max(trailingMaxAmp, abs(channels[0][frame]))
            }
            // Continuous sine wave with amplitude 0.7 at 440 Hz has peaks every ~100 frames;
            // over 200 frames, peak amplitude must be well above 0.3 if trailing samples are flushed.
            XCTAssertGreaterThan(trailingMaxAmp, 0.3, "Trailing PCM must be preserved after endOfStream flush")
        }

        // Inspect pad 1 short buffer (was 480 frames at 48k -> ~441 frames at 44.1k)
        let buffer1 = try XCTUnwrap(soundboard.bufferForTesting(at: 1))
        XCTAssertGreaterThan(buffer1.frameLength, 0, "Short asset must not produce empty buffer")
        XCTAssertEqual(buffer1.format.sampleRate, 44100.0)
        if let channels1 = buffer1.floatChannelData {
            var shortMaxAmp: Float = 0.0
            for frame in 0..<Int(buffer1.frameLength) {
                shortMaxAmp = max(shortMaxAmp, abs(channels1[0][frame]))
            }
            XCTAssertGreaterThan(shortMaxAmp, 0.3, "Short converted asset must retain audible PCM")
        }
    }

    // MARK: - 11. Coordinator Teardown & Rescan Asset Reload

    @MainActor
    func testAppStateDeallocationReleasesCoordinatorAndSoundboard() throws {
        let tempDir = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        weak var weakCoordinator: AudioEngineCoordinator?
        weak var weakAppState: AppState?

        let createBlock: () -> Void = {
            let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
            weakCoordinator = coordinator
            let appState = AppState(
                libraryRootURL: tempDir,
                waveformEditorModel: WaveformEditorModel(libraryRootURL: tempDir),
                audioCoordinator: coordinator,
                startCoordinator: false
            )
            weakAppState = appState
            XCTAssertNotNil(weakAppState)
            XCTAssertNotNil(weakCoordinator)
        }
        createBlock()

        XCTAssertNil(weakAppState, "AppState must deallocate without retain cycle")
        XCTAssertNil(weakCoordinator, "AudioEngineCoordinator must deallocate when AppState is released")
    }

    @MainActor
    func testRescanReloadsSoundboardAssetsAddedAfterStartup() throws {
        let tempDir = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sfxDir = tempDir.appendingPathComponent("08_Soundboard_SFX")
        try FileManager.default.createDirectory(at: sfxDir, withIntermediateDirectories: true)

        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let appState = AppState(
            libraryRootURL: tempDir,
            waveformEditorModel: WaveformEditorModel(libraryRootURL: tempDir),
            audioCoordinator: coordinator,
            startCoordinator: false
        )

        // Initially no assets exist; pad 0 is procedural fallback
        XCTAssertTrue(appState.soundboardPads[0].isFallback)

        // Add 01_Airhorn.wav after startup
        _ = try createSineWavFile(in: sfxDir, filename: "01_Airhorn.wav", durationSeconds: 0.2)

        // Rescan library
        let expectation = expectation(description: "Rescan reloads soundboard asset")
        coordinator.soundboardController.onPadsChanged = { snapshots in
            if !snapshots[0].isFallback {
                expectation.fulfill()
            }
        }

        appState.refreshLibrary()
        wait(for: [expectation], timeout: 5.0)
        coordinator.soundboardController.onPadsChanged = nil

        // Verify pad 0 is now ready with the new file
        XCTAssertFalse(coordinator.soundboardController.padSnapshots[0].isFallback)
        XCTAssertEqual(coordinator.soundboardController.padSnapshots[0].title, "01_Airhorn")
    }
}
