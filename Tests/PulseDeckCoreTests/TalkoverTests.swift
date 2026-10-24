import XCTest
import AVFoundation
import CoreAudio
@testable import PulseDeckCore
@testable import PulseDeckAI

final class TalkoverTests: XCTestCase {

    private func createSineWavFile(durationSeconds: Double = 1.0, frequencyHz: Float = 1000.0) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("talkover_test_\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 2)!
        let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        let frameCount = AVAudioFrameCount(44100.0 * durationSeconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        if let channels = buffer.floatChannelData {
            for frame in 0..<Int(frameCount) {
                let sample = sin(Float(frame) * 2.0 * .pi * frequencyHz / 44100.0) * 0.8
                channels[0][frame] = sample
                channels[1][frame] = sample
            }
        }
        try file.write(from: buffer)
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

    // MARK: - 1. Deterministic Ramp Midpoint & Endpoints (800ms)

    func testDeterministicRampMidpointAndEndpoints() {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let talkover = coordinator.talkoverController

        // Initial neutral state
        XCTAssertEqual(talkover.currentProgress, 0.0)
        XCTAssertEqual(talkover.currentVolumeMultiplier, 1.0, accuracy: 0.001)
        XCTAssertEqual(talkover.currentEQGainDB, 0.0, accuracy: 0.001)
        XCTAssertEqual(talkover.state, .inactive)
        XCTAssertFalse(talkover.isTalkoverActive)
        XCTAssertFalse(talkover.isFullyDucked)
        XCTAssertEqual(coordinator.deckAGraph.talkoverVolumeMultiplier, 1.0)
        XCTAssertEqual(coordinator.deckBGraph.talkoverVolumeMultiplier, 1.0)
        XCTAssertTrue(coordinator.deckAGraph.masterTalkoverEQNode.bypass)

        // Trigger talkover ON
        talkover.setTalkover(active: true)
        XCTAssertTrue(talkover.isTargetActive)
        XCTAssertTrue(talkover.isTalkoverActive)

        // Advance to 400ms (midpoint of 800ms ramp)
        talkover.advanceTime(deltaSeconds: 0.4)
        XCTAssertEqual(talkover.currentProgress, 0.5, accuracy: 0.001)
        XCTAssertEqual(talkover.currentVolumeMultiplier, 0.575, accuracy: 0.001) // 1.0 - 0.85 * 0.5
        XCTAssertEqual(talkover.currentEQGainDB, -2.0, accuracy: 0.001)          // -4.0 * 0.5
        XCTAssertEqual(coordinator.deckAGraph.talkoverVolumeMultiplier, 0.575, accuracy: 0.001)
        XCTAssertEqual(coordinator.deckBGraph.talkoverVolumeMultiplier, 0.575, accuracy: 0.001)
        XCTAssertEqual(coordinator.deckAGraph.masterTalkoverEQNode.bands[0].gain, -2.0, accuracy: 0.001)
        XCTAssertFalse(coordinator.deckAGraph.masterTalkoverEQNode.bypass)
        if case .ducking(let p) = talkover.state {
            XCTAssertEqual(p, 0.5, accuracy: 0.001)
        } else {
            XCTFail("Expected .ducking state at midpoint, got \(talkover.state)")
        }

        // Advance another 400ms (total 800ms: endpoint reached)
        let reachedEndpoint = talkover.advanceTime(deltaSeconds: 0.4)
        XCTAssertTrue(reachedEndpoint)
        XCTAssertEqual(talkover.currentProgress, 1.0, accuracy: 0.001)
        XCTAssertEqual(talkover.currentVolumeMultiplier, 0.15, accuracy: 0.001)  // 15% Master volume
        XCTAssertEqual(talkover.currentEQGainDB, -4.0, accuracy: 0.001)          // -4 dB vocal pocket dip
        XCTAssertEqual(coordinator.deckAGraph.talkoverVolumeMultiplier, 0.15, accuracy: 0.001)
        XCTAssertEqual(coordinator.deckBGraph.talkoverVolumeMultiplier, 0.15, accuracy: 0.001)
        XCTAssertEqual(coordinator.deckAGraph.masterTalkoverEQNode.bands[0].gain, -4.0, accuracy: 0.001)
        XCTAssertEqual(talkover.state, .active)
        XCTAssertTrue(talkover.isFullyDucked)

        // Trigger talkover OFF (restore to unity)
        talkover.setTalkover(active: false)
        XCTAssertFalse(talkover.isTargetActive)
        XCTAssertTrue(talkover.isTalkoverActive) // Still restoring

        // Restore midpoint at 400ms
        talkover.advanceTime(deltaSeconds: 0.4)
        XCTAssertEqual(talkover.currentProgress, 0.5, accuracy: 0.001)
        XCTAssertEqual(talkover.currentVolumeMultiplier, 0.575, accuracy: 0.001)
        XCTAssertEqual(talkover.currentEQGainDB, -2.0, accuracy: 0.001)
        if case .restoring(let p) = talkover.state {
            XCTAssertEqual(p, 0.5, accuracy: 0.001)
        } else {
            XCTFail("Expected .restoring state at restore midpoint, got \(talkover.state)")
        }

        // Restore endpoint at 800ms
        let restoreReached = talkover.advanceTime(deltaSeconds: 0.4)
        XCTAssertTrue(restoreReached)
        XCTAssertEqual(talkover.currentProgress, 0.0, accuracy: 0.001)
        XCTAssertEqual(talkover.currentVolumeMultiplier, 1.0, accuracy: 0.001)
        XCTAssertEqual(talkover.currentEQGainDB, 0.0, accuracy: 0.001)
        XCTAssertEqual(talkover.state, .inactive)
        XCTAssertFalse(talkover.isTalkoverActive)
        XCTAssertTrue(coordinator.deckAGraph.masterTalkoverEQNode.bypass)
    }

    // MARK: - 2. Toggle Reversal Mid-Ramp (Continuous Without Pops)

    func testToggleReversalMidRampIsContinuous() {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let talkover = coordinator.talkoverController

        // Duck towards active
        talkover.setTalkover(active: true)
        talkover.advanceTime(deltaSeconds: 0.3) // progress = 0.3 / 0.8 = 0.375
        let midMult = talkover.currentVolumeMultiplier
        let midEQ = talkover.currentEQGainDB
        XCTAssertEqual(talkover.currentProgress, 0.375, accuracy: 0.001)
        XCTAssertEqual(midMult, 1.0 - 0.85 * 0.375, accuracy: 0.001)

        // Reversal: toggle OFF mid-ramp
        talkover.toggleTalkover()
        XCTAssertFalse(talkover.isTargetActive)
        // Multiplier immediately after toggle must NOT jump
        XCTAssertEqual(talkover.currentVolumeMultiplier, midMult, accuracy: 0.001)
        XCTAssertEqual(talkover.currentEQGainDB, midEQ, accuracy: 0.001)

        // Advance 0.15s: smoothly decreases progress by 0.15 / 0.8 = 0.1875
        talkover.advanceTime(deltaSeconds: 0.15)
        XCTAssertEqual(talkover.currentProgress, 0.1875, accuracy: 0.001)
        XCTAssertGreaterThan(talkover.currentVolumeMultiplier, midMult)

        // Advance another 0.15s: reaches 0.0 exactly (0.1875 - 0.1875 = 0.0)
        let reached = talkover.advanceTime(deltaSeconds: 0.15)
        XCTAssertTrue(reached)
        XCTAssertEqual(talkover.currentProgress, 0.0, accuracy: 0.001)
        XCTAssertEqual(talkover.state, .inactive)
    }

    // MARK: - 3. Idempotent Commands & Duplicate Events

    func testIdempotentCommandsAndDuplicateEvents() {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let talkover = coordinator.talkoverController

        // Repeated inactive sets
        talkover.setTalkover(active: false)
        talkover.setTalkover(active: false)
        XCTAssertEqual(talkover.state, .inactive)

        // Repeated active sets
        talkover.setTalkover(active: true)
        talkover.setTalkover(active: true)
        XCTAssertTrue(talkover.isTargetActive)

        talkover.advanceTime(deltaSeconds: 0.8)
        XCTAssertEqual(talkover.state, .active)

        // Repeated active sets when already fully active
        talkover.setTalkover(active: true)
        XCTAssertEqual(talkover.state, .active)
        XCTAssertEqual(talkover.currentVolumeMultiplier, 0.15, accuracy: 0.001)
    }

    // MARK: - 4. Cancel Halts Task and Resets to Neutral

    func testCancelTalkoverHaltsTaskAndResetsToNeutral() {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let talkover = coordinator.talkoverController

        talkover.setTalkover(active: true)
        talkover.advanceTime(deltaSeconds: 0.5)
        XCTAssertGreaterThan(talkover.currentProgress, 0.0)

        // Cancel
        talkover.cancelTalkover()
        XCTAssertEqual(talkover.currentProgress, 0.0)
        XCTAssertEqual(talkover.currentVolumeMultiplier, 1.0)
        XCTAssertEqual(talkover.currentEQGainDB, 0.0)
        XCTAssertEqual(talkover.state, .inactive)
        XCTAssertEqual(coordinator.deckAGraph.talkoverVolumeMultiplier, 1.0)
        XCTAssertEqual(coordinator.deckBGraph.talkoverVolumeMultiplier, 1.0)
        XCTAssertTrue(coordinator.deckAGraph.masterTalkoverEQNode.bypass)
    }

    // MARK: - 5. Gain & Crossfader Composition (Zero Stale Overwriting)

    func testFaderVolumeAndCrossfaderComposition() {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let deckA = coordinator.deckAGraph
        let deckB = coordinator.deckBGraph

        deckA.volume = 0.8
        coordinator.setCrossfader(position: 0.5) // weights 1.0 and 1.0
        XCTAssertEqual(deckA.masterFaderNode.outputVolume, 0.8, accuracy: 0.001)

        // Engage talkover to full ducking (0.15)
        coordinator.talkoverController.stepProgress(to: 1.0)
        XCTAssertEqual(deckA.talkoverVolumeMultiplier, 0.15, accuracy: 0.001)
        XCTAssertEqual(deckA.masterFaderNode.outputVolume, 0.8 * 1.0 * 0.15, accuracy: 0.001)

        // User changes volume knob during talkover
        deckA.volume = 0.6
        XCTAssertEqual(deckA.masterFaderNode.outputVolume, 0.6 * 1.0 * 0.15, accuracy: 0.001)

        // User moves crossfader toward Deck B (position 0.75: A weight = 0.5, B weight = 1.0)
        coordinator.setCrossfader(position: 0.75)
        XCTAssertEqual(deckA.crossfaderWeight, 0.5, accuracy: 0.001)
        XCTAssertEqual(deckA.masterFaderNode.outputVolume, 0.6 * 0.5 * 0.15, accuracy: 0.001)
        XCTAssertEqual(deckB.masterFaderNode.outputVolume, 1.0 * 1.0 * 0.15, accuracy: 0.001)

        // Restore talkover to unity
        coordinator.talkoverController.stepProgress(to: 0.0)
        XCTAssertEqual(deckA.masterFaderNode.outputVolume, 0.6 * 0.5 * 1.0, accuracy: 0.001)
        XCTAssertEqual(deckB.masterFaderNode.outputVolume, 1.0 * 1.0 * 1.0, accuracy: 0.001)

        // Channel volume and crossfader position remain intact; never overwritten by talkover
        XCTAssertEqual(deckA.volume, 0.6, accuracy: 0.001)
        XCTAssertEqual(coordinator.crossfaderPosition, 0.75, accuracy: 0.001)
    }

    // MARK: - 6. User and Transition EQ Intent Preserved

    func testUserAndTransitionEQIntentPreserved() {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let deckA = coordinator.deckAGraph

        // User / transition sets 3-band EQ
        let userEQ = EQ3BandParameters(lowGainDB: -24.0, midGainDB: 3.0, highGainDB: -6.0)
        deckA.eqParameters = userEQ

        XCTAssertEqual(deckA.masterEQNode.bands[0].gain, -24.0)
        XCTAssertEqual(deckA.masterEQNode.bands[1].gain, 3.0)
        XCTAssertEqual(deckA.masterEQNode.bands[2].gain, -6.0)
        XCTAssertEqual(deckA.cueEQNode.bands[0].gain, -24.0)

        // Engage talkover
        coordinator.talkoverController.stepProgress(to: 1.0)
        XCTAssertEqual(deckA.masterTalkoverEQNode.bands[0].gain, -4.0, accuracy: 0.001)
        XCTAssertFalse(deckA.masterTalkoverEQNode.bypass)

        // Master 3-band EQ nodes remain completely undisturbed!
        XCTAssertEqual(deckA.masterEQNode.bands[0].gain, -24.0)
        XCTAssertEqual(deckA.masterEQNode.bands[1].gain, 3.0)
        XCTAssertEqual(deckA.masterEQNode.bands[2].gain, -6.0)

        // Cue 3-band EQ nodes remain completely undisturbed!
        XCTAssertEqual(deckA.cueEQNode.bands[0].gain, -24.0)
        XCTAssertEqual(deckA.cueEQNode.bands[1].gain, 3.0)
        XCTAssertEqual(deckA.cueEQNode.bands[2].gain, -6.0)

        // Transition modulates EQ during talkover
        deckA.eqParameters = EQ3BandParameters(lowGainDB: 0.0, midGainDB: 0.0, highGainDB: 0.0)
        XCTAssertEqual(deckA.masterEQNode.bands[0].gain, 0.0)

        // Disengage talkover
        coordinator.talkoverController.stepProgress(to: 0.0)
        XCTAssertTrue(deckA.masterTalkoverEQNode.bypass)
        XCTAssertEqual(deckA.masterEQNode.bands[0].gain, 0.0)
    }

    // MARK: - 7. Cue Output and Preview Isolation

    func testCueOutputAndPreviewIsolation() throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let deckA = coordinator.deckAGraph

        // Enable cue PFL
        deckA.isCueActive = true
        XCTAssertEqual(deckA.cueFaderNode.outputVolume, 1.0)

        // Engage talkover
        coordinator.talkoverController.stepProgress(to: 1.0)

        // Cue fader must remain at unity 1.0 (Pre-Fader Listen)
        XCTAssertEqual(deckA.cueFaderNode.outputVolume, 1.0)
        XCTAssertEqual(deckA.masterFaderNode.outputVolume, 0.15, accuracy: 0.001)

        // Cue preview player is on cueEngine, unaffected
        coordinator.cuePreview.stop()
        XCTAssertFalse(coordinator.cuePreview.isPlaying)
    }

    // MARK: - 8. Track Changes Preserve Talkover State

    func testTrackChangesPreserveTalkoverState() throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let deckA = coordinator.deckAGraph

        // Engage talkover
        coordinator.talkoverController.stepProgress(to: 1.0)
        XCTAssertEqual(deckA.talkoverVolumeMultiplier, 0.15, accuracy: 0.001)

        // Load new track while talkover is active
        let url = try createSineWavFile(durationSeconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        try deckA.loadTrack(url: url)

        // Newly loaded deck retains ducked talkover state
        XCTAssertEqual(deckA.talkoverVolumeMultiplier, 0.15, accuracy: 0.001)
        XCTAssertEqual(deckA.masterFaderNode.outputVolume, 0.15, accuracy: 0.001)
        XCTAssertEqual(deckA.masterTalkoverEQNode.bands[0].gain, -4.0, accuracy: 0.001)

        // Restore talkover
        coordinator.talkoverController.stepProgress(to: 0.0)
        XCTAssertEqual(deckA.talkoverVolumeMultiplier, 1.0, accuracy: 0.001)
        XCTAssertEqual(deckA.masterFaderNode.outputVolume, 1.0, accuracy: 0.001)
    }

    // MARK: - 9. Teardown Halts Background Tasks

    func testEngineLifecycleTeardownHaltsTalkover() {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        coordinator.talkoverController.setTalkover(active: true)
        coordinator.talkoverController.advanceTime(deltaSeconds: 0.2)
        XCTAssertTrue(coordinator.talkoverController.isTalkoverActive)

        coordinator.stop()
        XCTAssertFalse(coordinator.talkoverController.isTalkoverActive)
        XCTAssertEqual(coordinator.talkoverController.currentProgress, 0.0)
        XCTAssertEqual(coordinator.deckAGraph.talkoverVolumeMultiplier, 1.0)
        XCTAssertEqual(coordinator.deckBGraph.talkoverVolumeMultiplier, 1.0)
    }

    // MARK: - 10. Vocal-Pocket EQ Band Configuration

    func testVocalPocketEQBandConfiguration() {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let talkoverEQ = coordinator.deckAGraph.masterTalkoverEQNode

        XCTAssertEqual(talkoverEQ.bands.count, 1)
        let band = talkoverEQ.bands[0]
        XCTAssertEqual(band.filterType, .parametric)
        XCTAssertEqual(band.frequency, TalkoverController.vocalPocketCenterHz, accuracy: 1.0)
        XCTAssertEqual(band.bandwidth, TalkoverController.vocalPocketBandwidthOctaves, accuracy: 0.01)
    }

    // MARK: - 11. Offline PCM Attenuation and Cue PCM Isolation

    func testOfflinePCMAttenuationAndCuePCMIsolation() throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let master = coordinator.masterAudioEngine.rawEngine
        let cue = coordinator.cueAudioEngine.rawEngine
        let deckA = coordinator.deckAGraph

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 2)!
        try master.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try cue.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)

        try coordinator.start()

        let url = try createSineWavFile(durationSeconds: 2.0, frequencyHz: 1000.0)
        defer { try? FileManager.default.removeItem(at: url) }
        try deckA.loadTrack(url: url)

        deckA.volume = 1.0
        coordinator.setCrossfader(position: 0.0) // 100% Deck A
        deckA.isCueActive = true                 // Enable Cue PFL
        deckA.play()

        // 1. Render initial master buffer (talkover inactive, unity gain)
        let normalBuffer = try render(master, frames: 4096)
        let normalPeak = peakAmplitude(of: normalBuffer)
        XCTAssertGreaterThan(normalPeak, 0.1, "Master must render genuine audio signal")

        // Render cue buffer (talkover inactive)
        let cueNormalBuffer = try render(cue, frames: 4096)
        let cueNormalPeak = peakAmplitude(of: cueNormalBuffer)
        XCTAssertGreaterThan(cueNormalPeak, 0.1, "Cue must render genuine audio signal")

        // 2. Engage talkover (ducking to 0.15)
        coordinator.talkoverController.stepProgress(to: 1.0)

        // Apple's AVAudioMixerNode smooths volume over a 4096-frame window to prevent clicks
        _ = try render(master, frames: 4096)
        let duckedBuffer = try render(master, frames: 4096)
        let duckedPeak = peakAmplitude(of: duckedBuffer)
        XCTAssertGreaterThan(duckedPeak, 0.01)
        // Ratio of ducked peak to normal peak should be around 0.15 (-16.5 dB attenuation + EQ dip)
        let attenuationRatio = duckedPeak / normalPeak
        XCTAssertLessThan(attenuationRatio, 0.25, "Master output must be ducked significantly")
        XCTAssertGreaterThan(attenuationRatio, 0.05, "Master output must still be audible (15%)")

        // 3. Render cue buffer while talkover is active
        _ = try render(cue, frames: 4096)
        let cueDuckedBuffer = try render(cue, frames: 4096)
        let cueDuckedPeak = peakAmplitude(of: cueDuckedBuffer)
        // Cue headphones level MUST be unattenuated!
        XCTAssertEqual(cueDuckedPeak, cueNormalPeak, accuracy: 0.05, "Cue headphones PCM must be isolated from Master talkover")

        coordinator.stop()
    }

    // MARK: - 12. AppState Talkover Integration & Lifecycle

    @MainActor
    func testAppStateTalkoverIntegration() async throws {
        let hardware = MockAudioHardware()
        let coordinator = AudioEngineCoordinator(hal: hardware)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let editor = WaveformEditorModel(libraryRootURL: tempDir)
        let appState = AppState(
            libraryRootURL: tempDir,
            waveformEditorModel: editor,
            audioCoordinator: coordinator,
            startCoordinator: false
        )

        XCTAssertFalse(appState.isTalkoverActive)
        XCTAssertEqual(appState.talkoverProgress, 0.0)

        // Toggle talkover ON via AppState
        appState.toggleTalkover()
        XCTAssertTrue(coordinator.talkoverController.isTargetActive)

        // Advance ramp deterministically
        coordinator.talkoverController.advanceTime(deltaSeconds: 0.8)
        // Allow MainActor observer task to execute
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertTrue(appState.isTalkoverActive)
        XCTAssertEqual(appState.talkoverProgress, 1.0, accuracy: 0.001)

        // Toggle talkover OFF via AppState
        appState.toggleTalkover()
        XCTAssertFalse(coordinator.talkoverController.isTargetActive)

        coordinator.talkoverController.advanceTime(deltaSeconds: 0.8)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertFalse(appState.isTalkoverActive)
        XCTAssertEqual(appState.talkoverProgress, 0.0, accuracy: 0.001)

        // Explicit setTalkover
        appState.setTalkover(active: true)
        XCTAssertTrue(coordinator.talkoverController.isTargetActive)
        appState.setTalkover(active: true) // Idempotent
        XCTAssertTrue(coordinator.talkoverController.isTargetActive)

        coordinator.stop()
    }
}
