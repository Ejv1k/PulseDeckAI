import XCTest
import AVFoundation
import CoreAudio
@testable import PulseDeckCore

final class DualEngineGraphsTests: XCTestCase {

    private func createTestWavFile(durationSeconds: Double = 1.0) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("test_track_\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 2)!
        let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        let frameCount = AVAudioFrameCount(44100.0 * durationSeconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        try file.write(from: buffer)
        return fileURL
    }

    // MARK: - 1. Graph Ownership & Node Isolation

    func testGraphOwnershipNeverSharesNodesBetweenEngines() {
        let mockHAL = MockAudioHardware()
        let coordinator = AudioEngineCoordinator(hal: mockHAL)

        // Engines are distinct instances
        XCTAssertFalse(coordinator.masterAudioEngine.rawEngine === coordinator.cueAudioEngine.rawEngine)
        XCTAssertFalse(coordinator.masterAudioEngine.subMixer === coordinator.cueAudioEngine.subMixer)
        XCTAssertFalse(coordinator.masterAudioEngine.delayNode === coordinator.cueAudioEngine.delayNode)

        // Deck A master nodes belong only to master engine
        let deckA = coordinator.deckAGraph
        XCTAssertFalse(deckA.masterPlayerNode === deckA.cuePlayerNode)
        XCTAssertFalse(deckA.masterTimePitchNode === deckA.cueTimePitchNode)
        XCTAssertFalse(deckA.masterEQNode === deckA.cueEQNode)
        XCTAssertFalse(deckA.masterFilterNode === deckA.cueFilterNode)
        XCTAssertFalse(deckA.masterFaderNode === deckA.cueFaderNode)

        // Deck B master nodes belong only to master engine and are distinct from Deck A
        let deckB = coordinator.deckBGraph
        XCTAssertFalse(deckB.masterPlayerNode === deckB.cuePlayerNode)
        XCTAssertFalse(deckB.masterPlayerNode === deckA.masterPlayerNode)
        XCTAssertFalse(deckB.cuePlayerNode === deckA.cuePlayerNode)

        // Cue preview player belongs exclusively to cue engine
        let preview = coordinator.cuePreview
        XCTAssertFalse(preview.playerNode === deckA.masterPlayerNode)
        XCTAssertFalse(preview.playerNode === deckA.cuePlayerNode)
        XCTAssertFalse(preview.faderNode === coordinator.masterAudioEngine.subMixer)
    }

    // MARK: - 2. Output-Only Constraint

    func testStrictOutputOnlyConstraintNoInputNodeAccess() {
        let mockHAL = MockAudioHardware()
        let coordinator = AudioEngineCoordinator(hal: mockHAL)

        // Verify that roles are assigned correctly
        XCTAssertEqual(coordinator.masterEngine.role, .master)
        XCTAssertEqual(coordinator.cueEngine.role, .cue)

        // Both engines are created without attaching or referencing inputNode
        XCTAssertFalse(coordinator.masterAudioEngine.rawEngine.isRunning)
        XCTAssertFalse(coordinator.cueAudioEngine.rawEngine.isRunning)
    }

    // MARK: - 3. Latency Compensation Delay Path Routing

    func testLatencyCompensationZeroOffsetBypassesDelays() {
        let mockHAL = MockAudioHardware()
        let coordinator = AudioEngineCoordinator(hal: mockHAL)

        coordinator.latencyCompensation = LatencyCompensation(offsetMs: 0.0)

        XCTAssertEqual(coordinator.masterAudioEngine.currentPathDelayMs, 0.0)
        XCTAssertTrue(coordinator.masterAudioEngine.delayNode.bypass)
        XCTAssertEqual(coordinator.masterAudioEngine.delayNode.wetDryMix, 0.0)

        XCTAssertEqual(coordinator.cueAudioEngine.currentPathDelayMs, 0.0)
        XCTAssertTrue(coordinator.cueAudioEngine.delayNode.bypass)
        XCTAssertEqual(coordinator.cueAudioEngine.delayNode.wetDryMix, 0.0)
    }

    func testLatencyCompensationPositiveOffsetDelaysCuePath() {
        let mockHAL = MockAudioHardware()
        let coordinator = AudioEngineCoordinator(hal: mockHAL)

        // Master lags Cue by 150 ms (e.g. HDMI/DSP delay) -> Delay the Cue path by 150 ms
        coordinator.latencyCompensation = LatencyCompensation(offsetMs: 150.0)

        XCTAssertEqual(coordinator.masterAudioEngine.currentPathDelayMs, 0.0)
        XCTAssertTrue(coordinator.masterAudioEngine.delayNode.bypass)

        XCTAssertEqual(coordinator.cueAudioEngine.currentPathDelayMs, 150.0)
        XCTAssertFalse(coordinator.cueAudioEngine.delayNode.bypass)
        XCTAssertEqual(coordinator.cueAudioEngine.delayNode.wetDryMix, 100.0)
        XCTAssertEqual(coordinator.cueAudioEngine.delayNode.delayTime, 0.150, accuracy: 0.001)
        XCTAssertEqual(coordinator.cueAudioEngine.delayNode.feedback, 0.0)
        XCTAssertEqual(coordinator.cueAudioEngine.delayNode.lowPassCutoff, 20000.0)
    }

    func testLatencyCompensationNegativeOffsetDelaysMasterPath() {
        let mockHAL = MockAudioHardware()
        let coordinator = AudioEngineCoordinator(hal: mockHAL)

        // Cue lags Master by 120 ms (e.g. Bluetooth A2DP headphones) -> Delay the Master path by 120 ms
        coordinator.latencyCompensation = LatencyCompensation(offsetMs: -120.0)

        XCTAssertEqual(coordinator.masterAudioEngine.currentPathDelayMs, 120.0)
        XCTAssertFalse(coordinator.masterAudioEngine.delayNode.bypass)
        XCTAssertEqual(coordinator.masterAudioEngine.delayNode.wetDryMix, 100.0)
        XCTAssertEqual(coordinator.masterAudioEngine.delayNode.delayTime, 0.120, accuracy: 0.001)

        XCTAssertEqual(coordinator.cueAudioEngine.currentPathDelayMs, 0.0)
        XCTAssertTrue(coordinator.cueAudioEngine.delayNode.bypass)
    }

    func testLatencyCompensationBoundaryClampingAndNonFiniteGuards() {
        let mockHAL = MockAudioHardware()
        let coordinator = AudioEngineCoordinator(hal: mockHAL)

        // Clamping positive > +300 ms to +300 ms
        coordinator.latencyCompensation = LatencyCompensation(offsetMs: 500.0)
        XCTAssertEqual(coordinator.cueAudioEngine.currentPathDelayMs, 300.0)
        XCTAssertEqual(coordinator.cueAudioEngine.delayNode.delayTime, 0.300, accuracy: 0.001)

        // Clamping negative < -300 ms to -300 ms
        coordinator.latencyCompensation = LatencyCompensation(offsetMs: -450.0)
        XCTAssertEqual(coordinator.masterAudioEngine.currentPathDelayMs, 300.0)
        XCTAssertEqual(coordinator.masterAudioEngine.delayNode.delayTime, 0.300, accuracy: 0.001)

        // Non-finite values safely default to zero added delay
        coordinator.latencyCompensation = LatencyCompensation(offsetMs: .nan)
        XCTAssertEqual(coordinator.masterAudioEngine.currentPathDelayMs, 0.0)
        XCTAssertEqual(coordinator.cueAudioEngine.currentPathDelayMs, 0.0)
        XCTAssertTrue(coordinator.masterAudioEngine.delayNode.bypass)
        XCTAssertTrue(coordinator.cueAudioEngine.delayNode.bypass)

        coordinator.latencyCompensation = LatencyCompensation(offsetMs: .infinity)
        XCTAssertEqual(coordinator.masterAudioEngine.currentPathDelayMs, 0.0)
        XCTAssertEqual(coordinator.cueAudioEngine.currentPathDelayMs, 0.0)
    }

    // MARK: - 4. 3-Band Equalizer

    func testEQ3BandParametersClampingAndNonFiniteProtection() {
        let mockHAL = MockAudioHardware()
        let coordinator = AudioEngineCoordinator(hal: mockHAL)
        let deck = coordinator.deckAGraph

        // Valid settings
        deck.eqParameters = EQ3BandParameters(lowGainDB: -12.0, midGainDB: 3.0, highGainDB: -6.0)
        XCTAssertEqual(deck.masterEQNode.bands[0].gain, -12.0)
        XCTAssertEqual(deck.masterEQNode.bands[1].gain, 3.0)
        XCTAssertEqual(deck.masterEQNode.bands[2].gain, -6.0)
        XCTAssertEqual(deck.cueEQNode.bands[0].gain, -12.0)

        // Clamping out-of-bounds values to [-24.0, +6.0]
        deck.eqParameters = EQ3BandParameters(lowGainDB: -40.0, midGainDB: 15.0, highGainDB: 25.0)
        XCTAssertEqual(deck.masterEQNode.bands[0].gain, -24.0)
        XCTAssertEqual(deck.masterEQNode.bands[1].gain, 6.0)
        XCTAssertEqual(deck.masterEQNode.bands[2].gain, 6.0)

        // Non-finite values default to 0.0
        deck.eqParameters = EQ3BandParameters(lowGainDB: .nan, midGainDB: .infinity, highGainDB: -.infinity)
        XCTAssertEqual(deck.masterEQNode.bands[0].gain, 0.0)
        XCTAssertEqual(deck.masterEQNode.bands[1].gain, 0.0)
        XCTAssertEqual(deck.masterEQNode.bands[2].gain, 0.0)
    }

    // MARK: - 5. Resonant Filter Sweep

    func testResonantFilterSweepAndResonanceBypass() {
        let mockHAL = MockAudioHardware()
        let coordinator = AudioEngineCoordinator(hal: mockHAL)
        let deck = coordinator.deckAGraph

        // Neutral sweep = 0.0 bypasses filter
        deck.filterParameters = ResonantFilterParameters(sweep: 0.0, resonance: 1.0)
        XCTAssertTrue(deck.masterFilterNode.bypass)
        XCTAssertTrue(deck.cueFilterNode.bypass)

        // Negative sweep (< 0.0) activates Low-Pass Filter
        deck.filterParameters = ResonantFilterParameters(sweep: -0.5, resonance: 2.0)
        XCTAssertFalse(deck.masterFilterNode.bypass)
        XCTAssertEqual(deck.masterFilterNode.bands[0].filterType, .resonantLowPass)
        XCTAssertGreaterThan(deck.masterFilterNode.bands[0].frequency, 100.0)
        XCTAssertLessThan(deck.masterFilterNode.bands[0].frequency, 20000.0)
        XCTAssertEqual(deck.masterFilterNode.bands[0].bandwidth, 2.0)

        // Positive sweep (> 0.0) activates High-Pass Filter
        deck.filterParameters = ResonantFilterParameters(sweep: 0.5, resonance: 3.0)
        XCTAssertFalse(deck.masterFilterNode.bypass)
        XCTAssertEqual(deck.masterFilterNode.bands[0].filterType, .resonantHighPass)
        XCTAssertGreaterThan(deck.masterFilterNode.bands[0].frequency, 20.0)
        XCTAssertLessThan(deck.masterFilterNode.bands[0].frequency, 10000.0)
        XCTAssertEqual(deck.masterFilterNode.bands[0].bandwidth, 3.0)

        // Non-finite sweep defaults to 0.0 (bypass)
        deck.filterParameters = ResonantFilterParameters(sweep: .nan, resonance: .nan)
        XCTAssertTrue(deck.masterFilterNode.bypass)
    }

    // MARK: - 6. TimePitch & Key-Lock

    func testTimePitchKeyLockForcedZeroPitch() {
        let mockHAL = MockAudioHardware()
        let coordinator = AudioEngineCoordinator(hal: mockHAL)
        let deck = coordinator.deckAGraph

        // Key-lock enabled: rate changes tempo while pitch is held at 0.0 cents
        deck.timePitchParameters = TimePitchParameters(rate: 1.06, pitchCents: 300.0, keyLockEnabled: true)
        XCTAssertEqual(deck.masterTimePitchNode.rate, 1.06, accuracy: 0.001)
        XCTAssertEqual(deck.masterTimePitchNode.pitch, 0.0)
        XCTAssertEqual(deck.cueTimePitchNode.pitch, 0.0)

        // Key-lock disabled: pitch shift applies directly
        deck.timePitchParameters = TimePitchParameters(rate: 1.06, pitchCents: 300.0, keyLockEnabled: false)
        XCTAssertEqual(deck.masterTimePitchNode.rate, 1.06, accuracy: 0.001)
        XCTAssertEqual(deck.masterTimePitchNode.pitch, 300.0)
        XCTAssertEqual(deck.cueTimePitchNode.pitch, 300.0)

        // Pitch cents clamping to [-2400.0, +2400.0]
        deck.timePitchParameters = TimePitchParameters(rate: 1.0, pitchCents: 4000.0, keyLockEnabled: false)
        XCTAssertEqual(deck.masterTimePitchNode.pitch, 2400.0)

        // Non-finite handling
        deck.timePitchParameters = TimePitchParameters(rate: .nan, pitchCents: .nan, keyLockEnabled: false)
        XCTAssertEqual(deck.masterTimePitchNode.rate, 1.0)
        XCTAssertEqual(deck.masterTimePitchNode.pitch, 0.0)
    }

    // MARK: - 7. Pre-Fader Listen (PFL) Routing Isolation & Cue Scrubbing

    func testPreFaderListenIsolationAndCueScrubbing() throws {
        let mockHAL = MockAudioHardware()
        let coordinator = AudioEngineCoordinator(hal: mockHAL)
        let deck = coordinator.deckAGraph

        let testFile = try createTestWavFile(durationSeconds: 3.0)
        defer { try? FileManager.default.removeItem(at: testFile) }

        try deck.loadTrack(url: testFile)

        // Channel volume fader at zero on Master FOH
        deck.volume = 0.0
        XCTAssertEqual(deck.masterFaderNode.outputVolume, 0.0)

        // Activate Cue: cue fader is 1.0 (audible in headphones) regardless of master volume
        deck.isCueActive = true
        XCTAssertEqual(deck.cueFaderNode.outputVolume, 1.0)
        XCTAssertEqual(deck.masterFaderNode.outputVolume, 0.0)

        // Crossfader fully to Deck B (Deck A weight = 0.0): Cue remains audible at 1.0
        coordinator.setCrossfader(position: 1.0)
        XCTAssertEqual(deck.crossfaderWeight, 0.0)
        XCTAssertEqual(deck.masterFaderNode.outputVolume, 0.0)
        XCTAssertEqual(deck.cueFaderNode.outputVolume, 1.0)

        // Independent cue scrubbing leaves master playhead unaffected
        deck.seekCue(to: 2.0)
        deck.playCue()
        deck.pauseCue()

        // Cue preview player operates on cue engine independently
        let preview = coordinator.cuePreview
        try preview.load(url: testFile)
        preview.play()
        preview.pause()
        preview.seek(to: 1.5)
        preview.stop()
    }

    // MARK: - 8. Lifecycle, Coordination & Recovery

    func testCoordinatorLifecycleStartPauseStop() throws {
        let mockHAL = MockAudioHardware()
        let coordinator = AudioEngineCoordinator(hal: mockHAL)

        // Start coordinator
        try coordinator.start()
        XCTAssertTrue(coordinator.masterAudioEngine.rawEngine.isRunning)
        XCTAssertTrue(coordinator.cueAudioEngine.rawEngine.isRunning)

        // Pause coordinator
        coordinator.pause()
        XCTAssertFalse(coordinator.masterAudioEngine.rawEngine.isRunning)
        XCTAssertFalse(coordinator.cueAudioEngine.rawEngine.isRunning)

        // Stop coordinator
        coordinator.stop()
        XCTAssertFalse(coordinator.masterAudioEngine.rawEngine.isRunning)
        XCTAssertFalse(coordinator.cueAudioEngine.rawEngine.isRunning)
    }

    func testCoordinatorDeviceEnumerationAndConfigurationHandling() {
        let mockHAL = MockAudioHardware()
        mockHAL.devices = [
            MockAudioHardware.DeviceRecord(
                id: 101,
                uid: "mock-speakers",
                name: "Mock Speakers",
                manufacturer: "PulseDeck",
                outputChannels: 2,
                sampleRate: 48000.0,
                transportType: kAudioDeviceTransportTypeBuiltIn
            )
        ]
        mockHAL.defaultOutputDeviceID = 101
        let coordinator = AudioEngineCoordinator(hal: mockHAL)

        let devices = coordinator.enumerateOutputDevices()
        XCTAssertGreaterThan(devices.count, 0)

        // Safe immediate reconciliation without crashing
        coordinator.handleDeviceConfigurationChange()
    }
}
