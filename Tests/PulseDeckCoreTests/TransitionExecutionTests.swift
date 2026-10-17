import XCTest
import AVFoundation
import CoreAudio
@testable import PulseDeckCore

final class TransitionExecutionTests: XCTestCase {

    private func createTestWavFile(durationSeconds: Double = 30.0) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("test_trans_\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 2)!
        let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        let frameCount = AVAudioFrameCount(44100.0 * durationSeconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        // Populate non-zero samples to verify render pipeline
        if let channelData = buffer.floatChannelData {
            for i in 0..<Int(frameCount) {
                let sample = sin(Float(i) * 0.05) * 0.5
                channelData[0][i] = sample
                channelData[1][i] = sample
            }
        }
        try file.write(from: buffer)
        return fileURL
    }

    private func makeDescriptor(
        deck: DeckIdentifier,
        duration: Double,
        bpm: Double,
        mixOutCue: Double,
        startTrimCue: Double = 0.0,
        endTrimCue: Double? = nil
    ) -> TrackTransitionDescriptor {
        let end = endTrimCue ?? duration
        let beatInterval = 60.0 / bpm
        var timestamps: [Double] = []
        var t = 0.0
        while t <= duration {
            timestamps.append(t)
            t += beatInterval
        }
        let grid = BeatGrid(firstBeatOffsetSeconds: 0.0, beatIntervalSeconds: beatInterval, beatTimestamps: timestamps)
        let vCue = startTrimCue + (mixOutCue - startTrimCue) * 0.5
        let markers = CueMarkers(
            startTrimCue: startTrimCue,
            vocalEntryCue: vCue,
            mixOutCue: mixOutCue,
            endTrimCue: end
        )
        return TrackTransitionDescriptor(
            deck: deck,
            duration: duration,
            bpm: bpm,
            confidence: 0.95,
            cueMarkers: markers,
            beatGrid: grid
        )
    }

    private func render(_ engine: AVAudioEngine, frames: AVAudioFrameCount = 4096) throws {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: frames
        ))
        XCTAssertEqual(try engine.renderOffline(frames, to: buffer), .success)
    }

    // MARK: - 1. Command Execution & FX Mapping

    func testCommandExecutionAppliesAllCommandsToDecks() async throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let service = coordinator.transitionExecutionService

        let urlA = try createTestWavFile(durationSeconds: 30.0)
        let urlB = try createTestWavFile(durationSeconds: 30.0)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        try coordinator.deckAGraph.loadTrack(url: urlA)
        try coordinator.deckBGraph.loadTrack(url: urlB)
        coordinator.deckAGraph.play()

        let descA = makeDescriptor(deck: .deckA, duration: 30.0, bpm: 120.0, mixOutCue: 10.0)
        let descB = makeDescriptor(deck: .deckB, duration: 30.0, bpm: 120.0, mixOutCue: 25.0)

        let request = TransitionRequest(
            outgoingTrack: descA,
            incomingTrack: descB,
            style: .beatSyncedBassSwap(bars: 8, allowFallbackToFilter: false),
            triggerPositionSeconds: 10.0
        )

        let plan = try await service.startTransition(request: request)
        XCTAssertEqual(plan.outgoingDeck, .deckA)
        XCTAssertEqual(plan.incomingDeck, .deckB)

        let snapshot = await service.snapshot
        XCTAssertEqual(snapshot.outgoingDeck, .deckA)
        XCTAssertEqual(snapshot.incomingDeck, .deckB)
        if case .inProgress(let style, _) = snapshot.state {
            XCTAssertEqual(style, request.style)
        } else {
            XCTFail("Expected state to be .inProgress")
        }

        // Advance to midpoint downbeat (bass swap offset)
        let midpointTime = plan.startTimestampSeconds + (plan.metadata.bassSwapOffsetSeconds ?? 8.0)
        let midCommands = try await service.advance(to: midpointTime)
        XCTAssertFalse(midCommands.isEmpty)

        // Verify EQ cut on Deck A and restoration on Deck B
        XCTAssertEqual(coordinator.deckAGraph.masterEQNode.bands[0].gain, -24.0)
        XCTAssertEqual(coordinator.deckBGraph.masterEQNode.bands[0].gain, 0.0)

        // Advance to end of transition
        let endCommands = try await service.advance(to: plan.endTimestampSeconds)
        XCTAssertFalse(endCommands.isEmpty)

        let endSnapshot = await service.snapshot
        XCTAssertEqual(endSnapshot.state, .completed)
        XCTAssertEqual(endSnapshot.progress, 1.0)
        XCTAssertEqual(coordinator.deckAGraph.volume, 0.0)
        XCTAssertEqual(coordinator.deckBGraph.volume, 1.0)
    }

    // MARK: - 2. Filter Echo Wash & Initial Gains

    func testFilterEchoWashAppliesInitialMuteBeforePlayAndEchoEffect() async throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let service = coordinator.transitionExecutionService

        let urlA = try createTestWavFile(durationSeconds: 20.0)
        let urlB = try createTestWavFile(durationSeconds: 20.0)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        try coordinator.deckAGraph.loadTrack(url: urlA)
        try coordinator.deckBGraph.loadTrack(url: urlB)
        coordinator.deckAGraph.play()

        let descA = makeDescriptor(deck: .deckA, duration: 20.0, bpm: 120.0, mixOutCue: 5.0)
        let descB = makeDescriptor(deck: .deckB, duration: 20.0, bpm: 120.0, mixOutCue: 18.0)

        let request = TransitionRequest(
            outgoingTrack: descA,
            incomingTrack: descB,
            style: .filterEchoWash(durationSeconds: 6.0, echoSend: 0.6),
            triggerPositionSeconds: 5.0
        )

        _ = try await service.startTransition(request: request)

        // Initial gain preparation: incoming deck B must be muted at 0.0
        XCTAssertEqual(coordinator.deckBGraph.volume, 0.0)
        XCTAssertTrue(coordinator.deckBGraph.isMasterPlaying)

        // Outgoing deck A must have echo engaged
        XCTAssertFalse(coordinator.deckAGraph.masterEchoNode.bypass)
        XCTAssertEqual(coordinator.deckAGraph.masterEchoNode.wetDryMix, 60.0, accuracy: 0.01)
        XCTAssertEqual(coordinator.deckAGraph.masterEchoNode.feedback, 50.0, accuracy: 0.01)

        // Advance halfway: equal-power S-curve volume and filter sweep
        let midCommands = try await service.advance(to: 8.0)
        XCTAssertFalse(midCommands.isEmpty)
        XCTAssertFalse(coordinator.deckAGraph.masterFilterNode.bypass)
        XCTAssertGreaterThan(coordinator.deckAGraph.masterFilterNode.bands[0].frequency, 20.0)
        XCTAssertGreaterThan(coordinator.deckBGraph.volume, 0.0)
        XCTAssertLessThan(coordinator.deckAGraph.volume, 1.0)

        // Advance to completion
        _ = try await service.advance(to: 11.0)
        XCTAssertEqual(coordinator.deckAGraph.volume, 0.0)
        XCTAssertEqual(coordinator.deckBGraph.volume, 1.0)
        XCTAssertTrue(coordinator.deckAGraph.masterEchoNode.bypass)
    }

    // MARK: - 3. Hard Cut on Drop

    func testHardCutOnDropDownbeatInstantSwitch() async throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let service = coordinator.transitionExecutionService

        let urlA = try createTestWavFile(durationSeconds: 20.0)
        let urlB = try createTestWavFile(durationSeconds: 20.0)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        try coordinator.deckAGraph.loadTrack(url: urlA)
        try coordinator.deckBGraph.loadTrack(url: urlB)
        coordinator.deckAGraph.play()

        let descA = makeDescriptor(deck: .deckA, duration: 20.0, bpm: 120.0, mixOutCue: 5.0)
        let descB = makeDescriptor(deck: .deckB, duration: 20.0, bpm: 120.0, mixOutCue: 16.0)

        let request = TransitionRequest(
            outgoingTrack: descA,
            incomingTrack: descB,
            style: .hardCutOnDrop(bars: 1, allowFallbackToFilter: false),
            triggerPositionSeconds: 3.5
        )

        let plan = try await service.startTransition(request: request)
        XCTAssertEqual(plan.startTimestampSeconds, 3.5)
        XCTAssertEqual(plan.endTimestampSeconds, 4.0)

        // At trigger position (3.5s), deck B is pre-cued and muted
        XCTAssertEqual(coordinator.deckBGraph.volume, 0.0)
        XCTAssertEqual(coordinator.deckAGraph.volume, 1.0)

        // Advance to cut time (4.0s)
        let cutCommands = try await service.advance(to: plan.endTimestampSeconds)
        XCTAssertFalse(cutCommands.isEmpty)

        // Deck A cut to 0.0, Deck B at 1.0
        XCTAssertEqual(coordinator.deckAGraph.volume, 0.0)
        XCTAssertEqual(coordinator.deckBGraph.volume, 1.0)
        XCTAssertTrue(coordinator.deckBGraph.isMasterPlaying)
    }

    // MARK: - 4. Deterministic Clock Harness & Skipped Updates

    func testSkippedUpdatesEmitAllIntermediateEventsInOrder() async throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let service = coordinator.transitionExecutionService

        let urlA = try createTestWavFile(durationSeconds: 30.0)
        let urlB = try createTestWavFile(durationSeconds: 30.0)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        try coordinator.deckAGraph.loadTrack(url: urlA)
        try coordinator.deckBGraph.loadTrack(url: urlB)
        coordinator.deckAGraph.play()

        let descA = makeDescriptor(deck: .deckA, duration: 30.0, bpm: 120.0, mixOutCue: 2.0)
        let descB = makeDescriptor(deck: .deckB, duration: 30.0, bpm: 120.0, mixOutCue: 25.0)

        let request = TransitionRequest(
            outgoingTrack: descA,
            incomingTrack: descB,
            style: .beatSyncedBassSwap(bars: 8, allowFallbackToFilter: false),
            triggerPositionSeconds: 2.0
        )

        let plan = try await service.startTransition(request: request)

        // Direct leap from start (2.0s) straight to end (18.0s), skipping all intermediate bars
        let batch = try await service.advance(to: plan.endTimestampSeconds)
        XCTAssertGreaterThan(batch.count, 10)

        let snap = await service.snapshot
        XCTAssertEqual(snap.state, .completed)
        XCTAssertEqual(snap.remainingEventCount, 0)
        XCTAssertEqual(coordinator.deckAGraph.volume, 0.0)
        XCTAssertEqual(coordinator.deckBGraph.volume, 1.0)
    }

    // MARK: - 5. Backend AutoPilot One-Shot Trigger

    func testAutoPilotArmsAndFiresOnceAtMixOutCue() async throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let service = coordinator.transitionExecutionService

        let urlA = try createTestWavFile(durationSeconds: 30.0)
        let urlB = try createTestWavFile(durationSeconds: 30.0)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        try coordinator.deckAGraph.loadTrack(url: urlA)
        try coordinator.deckBGraph.loadTrack(url: urlB)
        coordinator.deckAGraph.play()

        let descA = makeDescriptor(deck: .deckA, duration: 30.0, bpm: 120.0, mixOutCue: 10.0)
        let descB = makeDescriptor(deck: .deckB, duration: 30.0, bpm: 120.0, mixOutCue: 25.0)

        let request = TransitionRequest(
            outgoingTrack: descA,
            incomingTrack: descB,
            style: .filterEchoWash(durationSeconds: 4.0, echoSend: 0.5),
            triggerPositionSeconds: 10.0
        )

        let plan = try await service.armAutoPilot(request: request)
        XCTAssertEqual(plan.startTimestampSeconds, 10.0)

        let snapBefore = await service.snapshot
        XCTAssertTrue(snapBefore.isAutoPilotArmed)
        if case .armed(let armedReq, let trigger) = snapBefore.state {
            XCTAssertEqual(armedReq, request)
            XCTAssertEqual(trigger, 10.0)
        } else {
            XCTFail("Expected .armed state")
        }

        // Tick before trigger position (e.g. at 5.0s) -> AutoPilot does not fire
        let preCommands = try await service.tick(playheadSeconds: 5.0)
        XCTAssertTrue(preCommands.isEmpty)
        let snapPre = await service.snapshot
        XCTAssertTrue(snapPre.isAutoPilotArmed)

        // Tick at trigger position (10.0s) -> Fires ONCE!
        let fireCommands = try await service.tick(playheadSeconds: 10.0)
        XCTAssertFalse(fireCommands.isEmpty)

        let snapFired = await service.snapshot
        XCTAssertFalse(snapFired.isAutoPilotArmed)
        if case .inProgress = snapFired.state {
            // Success
        } else {
            XCTFail("Expected state to transition to .inProgress after trigger")
        }

        // Additional ticks on same generation do not re-trigger or restart
        let subsequentCommands = try await service.tick(playheadSeconds: 10.5)
        XCTAssertFalse(subsequentCommands.isEmpty) // Emits intermediate wash steps, not a restart
    }

    func testAutoPilotDisarmRemovesPendingTrigger() async throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let service = coordinator.transitionExecutionService

        let urlA = try createTestWavFile(durationSeconds: 20.0)
        let urlB = try createTestWavFile(durationSeconds: 20.0)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        try coordinator.deckAGraph.loadTrack(url: urlA)
        try coordinator.deckBGraph.loadTrack(url: urlB)
        coordinator.deckAGraph.play()

        let descA = makeDescriptor(deck: .deckA, duration: 20.0, bpm: 120.0, mixOutCue: 10.0)
        let descB = makeDescriptor(deck: .deckB, duration: 20.0, bpm: 120.0, mixOutCue: 18.0)

        let request = TransitionRequest(
            outgoingTrack: descA,
            incomingTrack: descB,
            style: .filterEchoWash(durationSeconds: 4.0),
            triggerPositionSeconds: 10.0
        )

        try await service.armAutoPilot(request: request)
        let isArmed = await service.snapshot.isAutoPilotArmed
        XCTAssertTrue(isArmed)

        await service.disableAutoPilot()
        let snap = await service.snapshot
        XCTAssertFalse(snap.isAutoPilotArmed)
        XCTAssertEqual(snap.state, .idle)

        // Ticking past 10.0s does nothing when disarmed
        let commands = try await service.tick(playheadSeconds: 10.5)
        XCTAssertTrue(commands.isEmpty)
    }

    // MARK: - 6. Safe Cancellation & Emergency DSP Recovery

    func testCancellationRestoresOutgoingUnityVolumeAndClearsFX() async throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let service = coordinator.transitionExecutionService

        let urlA = try createTestWavFile(durationSeconds: 30.0)
        let urlB = try createTestWavFile(durationSeconds: 30.0)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        try coordinator.deckAGraph.loadTrack(url: urlA)
        try coordinator.deckBGraph.loadTrack(url: urlB)
        coordinator.deckAGraph.play()

        let descA = makeDescriptor(deck: .deckA, duration: 30.0, bpm: 120.0, mixOutCue: 5.0)
        let descB = makeDescriptor(deck: .deckB, duration: 30.0, bpm: 120.0, mixOutCue: 25.0)

        let request = TransitionRequest(
            outgoingTrack: descA,
            incomingTrack: descB,
            style: .filterEchoWash(durationSeconds: 8.0, echoSend: 0.8),
            triggerPositionSeconds: 5.0
        )

        _ = try await service.startTransition(request: request)

        // Advance to mid-wash where outgoing deck is filtered, echoed, and faded down
        _ = try await service.advance(to: 9.0)
        XCTAssertLessThan(coordinator.deckAGraph.volume, 1.0)
        XCTAssertGreaterThan(coordinator.deckBGraph.volume, 0.0)
        XCTAssertFalse(coordinator.deckAGraph.masterEchoNode.bypass)

        // Trigger immediate cancellation
        let recoveryCommands = await service.cancelTransition()
        XCTAssertFalse(recoveryCommands.isEmpty)

        let snap = await service.snapshot
        XCTAssertEqual(snap.state, .cancelled)

        // Outgoing deck A restored
        XCTAssertEqual(coordinator.deckAGraph.volume, 1.0)
        XCTAssertEqual(coordinator.deckAGraph.eqParameters.lowGainDB, 0.0)
        XCTAssertEqual(coordinator.deckAGraph.filterParameters.sweep, 0.0)
        XCTAssertTrue(coordinator.deckAGraph.masterEchoNode.bypass)

        // Incoming deck B safely muted and stopped
        XCTAssertEqual(coordinator.deckBGraph.volume, 0.0)
        XCTAssertFalse(coordinator.deckBGraph.isMasterPlaying)
        XCTAssertTrue(coordinator.deckBGraph.masterEchoNode.bypass)
    }

    // MARK: - 7. Pause & Playback Recovery Without Accidental Restart

    func testPauseDuringTransitionPreventsAccidentalRestart() async throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let service = coordinator.transitionExecutionService

        let urlA = try createTestWavFile(durationSeconds: 20.0)
        let urlB = try createTestWavFile(durationSeconds: 20.0)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        try coordinator.deckAGraph.loadTrack(url: urlA)
        try coordinator.deckBGraph.loadTrack(url: urlB)
        coordinator.deckAGraph.play()

        let descA = makeDescriptor(deck: .deckA, duration: 20.0, bpm: 120.0, mixOutCue: 5.0)
        let descB = makeDescriptor(deck: .deckB, duration: 20.0, bpm: 120.0, mixOutCue: 15.0)

        let request = TransitionRequest(
            outgoingTrack: descA,
            incomingTrack: descB,
            style: .filterEchoWash(durationSeconds: 6.0),
            triggerPositionSeconds: 5.0
        )

        _ = try await service.startTransition(request: request)

        // Pause deck A
        coordinator.deckAGraph.pause()
        XCTAssertFalse(coordinator.deckAGraph.isMasterPlaying)

        // Ticking while paused must not emit commands or call play()
        let pausedCommands = try await service.tick()
        XCTAssertTrue(pausedCommands.isEmpty)
        XCTAssertFalse(coordinator.deckAGraph.isMasterPlaying)
    }

    // MARK: - 8. Generation / Rate / Track Invalidation

    func testRateChangeDuringTransitionInvalidatesAndCancelsPlan() async throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let service = coordinator.transitionExecutionService

        let urlA = try createTestWavFile(durationSeconds: 25.0)
        let urlB = try createTestWavFile(durationSeconds: 25.0)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        try coordinator.deckAGraph.loadTrack(url: urlA)
        try coordinator.deckBGraph.loadTrack(url: urlB)
        coordinator.deckAGraph.play()

        let descA = makeDescriptor(deck: .deckA, duration: 25.0, bpm: 120.0, mixOutCue: 5.0)
        let descB = makeDescriptor(deck: .deckB, duration: 25.0, bpm: 120.0, mixOutCue: 20.0)

        let request = TransitionRequest(
            outgoingTrack: descA,
            incomingTrack: descB,
            style: .filterEchoWash(durationSeconds: 6.0),
            triggerPositionSeconds: 5.0
        )

        _ = try await service.startTransition(request: request)

        // User or tempo fader changes playback rate on Deck A
        coordinator.deckAGraph.timePitchParameters = TimePitchParameters(rate: 1.08)

        // Next tick must detect rate mismatch, cancel transition and restore unity
        let recovery = try await service.tick(playheadSeconds: 6.0)
        XCTAssertFalse(recovery.isEmpty)

        let snap = await service.snapshot
        XCTAssertEqual(snap.state, .cancelled)
        XCTAssertEqual(coordinator.deckAGraph.volume, 1.0)
    }

    func testTrackReloadDuringTransitionInvalidatesAndCancelsPlan() async throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let service = coordinator.transitionExecutionService

        let urlA1 = try createTestWavFile(durationSeconds: 25.0)
        let urlA2 = try createTestWavFile(durationSeconds: 25.0)
        let urlB = try createTestWavFile(durationSeconds: 25.0)
        defer {
            try? FileManager.default.removeItem(at: urlA1)
            try? FileManager.default.removeItem(at: urlA2)
            try? FileManager.default.removeItem(at: urlB)
        }

        try coordinator.deckAGraph.loadTrack(url: urlA1)
        try coordinator.deckBGraph.loadTrack(url: urlB)
        coordinator.deckAGraph.play()

        let descA = makeDescriptor(deck: .deckA, duration: 25.0, bpm: 120.0, mixOutCue: 5.0)
        let descB = makeDescriptor(deck: .deckB, duration: 25.0, bpm: 120.0, mixOutCue: 20.0)

        let request = TransitionRequest(
            outgoingTrack: descA,
            incomingTrack: descB,
            style: .filterEchoWash(durationSeconds: 6.0),
            triggerPositionSeconds: 5.0
        )

        _ = try await service.startTransition(request: request)

        // Deck A reloads another track during transition
        try coordinator.deckAGraph.loadTrack(url: urlA2)

        // Tick detects schedule generation change and cancels transition
        let recovery = try await service.tick(playheadSeconds: 6.0)
        XCTAssertFalse(recovery.isEmpty)
        let finalSnap = await service.snapshot
        XCTAssertEqual(finalSnap.state, .cancelled)
    }

    // MARK: - 9. Loaded Track & Identity Validation

    func testStartTransitionRejectsUnloadedOrMismatchedDecks() async throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let service = coordinator.transitionExecutionService

        let descA = makeDescriptor(deck: .deckA, duration: 15.0, bpm: 120.0, mixOutCue: 5.0)
        let descB = makeDescriptor(deck: .deckB, duration: 15.0, bpm: 120.0, mixOutCue: 12.0)

        let request = TransitionRequest(
            outgoingTrack: descA,
            incomingTrack: descB,
            style: .filterEchoWash(durationSeconds: 4.0),
            triggerPositionSeconds: 5.0
        )

        // Deck A and B have no tracks loaded yet
        do {
            _ = try await service.startTransition(request: request)
            XCTFail("Expected trackNotLoaded error")
        } catch let error as TransitionExecutionServiceError {
            XCTAssertEqual(error, .trackNotLoaded(.deckA))
        }

        // Load track on Deck A with different duration (25.0s vs 15.0s)
        let url = try createTestWavFile(durationSeconds: 25.0)
        defer { try? FileManager.default.removeItem(at: url) }
        try coordinator.deckAGraph.loadTrack(url: url)

        do {
            _ = try await service.startTransition(request: request)
            XCTFail("Expected trackMismatch error")
        } catch let error as TransitionExecutionServiceError {
            if case .trackMismatch(let deck, let expected, _) = error {
                XCTAssertEqual(deck, .deckA)
                XCTAssertEqual(expected, 15.0)
            } else {
                XCTFail("Expected .trackMismatch error")
            }
        }
    }

    // MARK: - 10. Real Offline AV Graph Render Smoke

    func testRealOfflineAVGraphRenderSmokeDuringTransition() async throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let service = coordinator.transitionExecutionService

        let master = coordinator.masterAudioEngine.rawEngine
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 2))
        try master.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try coordinator.start()
        defer { coordinator.stop() }

        let urlA = try createTestWavFile(durationSeconds: 10.0)
        let urlB = try createTestWavFile(durationSeconds: 10.0)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        try coordinator.deckAGraph.loadTrack(url: urlA)
        try coordinator.deckBGraph.loadTrack(url: urlB)
        coordinator.deckAGraph.play()

        let descA = makeDescriptor(deck: .deckA, duration: 10.0, bpm: 120.0, mixOutCue: 1.0)
        let descB = makeDescriptor(deck: .deckB, duration: 10.0, bpm: 120.0, mixOutCue: 8.0)

        let request = TransitionRequest(
            outgoingTrack: descA,
            incomingTrack: descB,
            style: .filterEchoWash(durationSeconds: 2.0, echoSend: 0.5),
            triggerPositionSeconds: 1.0
        )

        _ = try await service.startTransition(request: request)

        // Render frames offline through the AV graph
        for _ in 0..<15 {
            try render(master, frames: 4096)
        }

        let playhead = coordinator.deckAGraph.masterPlayheadSeconds
        XCTAssertGreaterThan(playhead, 0.0)

        // Advance transition with live playhead
        let commands = try await service.advance(to: 2.0)
        XCTAssertFalse(commands.isEmpty)

        // Render more frames to smoke-test echo delay and filter units in action
        for _ in 0..<15 {
            try render(master, frames: 4096)
        }

        _ = try await service.advance(to: 3.1)
        let endSmokeSnap = await service.snapshot
        XCTAssertEqual(endSmokeSnap.state, .completed)
        XCTAssertEqual(coordinator.deckAGraph.volume, 0.0)
        XCTAssertEqual(coordinator.deckBGraph.volume, 1.0)
    }

    // MARK: - 13. Future-Start Live Playhead Progression (P1 L251 Regression)

    func testFutureStartPlayheadAdvancesMonotonicallyWithoutRegressionError() async throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let service = coordinator.transitionExecutionService

        let urlA = try createTestWavFile(durationSeconds: 30.0)
        let urlB = try createTestWavFile(durationSeconds: 30.0)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        try coordinator.deckAGraph.loadTrack(url: urlA)
        try coordinator.deckBGraph.loadTrack(url: urlB)
        coordinator.deckAGraph.play()

        // 120 BPM: beat interval = 0.5s. Downbeats at 0.0, 2.0, 4.0, 6.0, 8.0...
        // Non-downbeat trigger at 3.5s quantizes start to 4.0s!
        let descA = makeDescriptor(deck: .deckA, duration: 30.0, bpm: 120.0, mixOutCue: 3.5)
        let descB = makeDescriptor(deck: .deckB, duration: 30.0, bpm: 120.0, mixOutCue: 25.0)

        let request = TransitionRequest(
            outgoingTrack: descA,
            incomingTrack: descB,
            style: .beatSyncedBassSwap(bars: 8, allowFallbackToFilter: false),
            triggerPositionSeconds: 3.5
        )

        let plan = try await service.startTransition(request: request)
        XCTAssertEqual(plan.startTimestampSeconds, 4.0)

        // 1. Initial start at 3.5s: commands must be empty, incoming deck NOT playing yet
        let snapStart = await service.snapshot
        XCTAssertEqual(snapStart.state, .inProgress(style: request.style, progress: 0.0))
        XCTAssertFalse(coordinator.deckBGraph.isMasterPlaying)

        // 2. Live tick at 3.52s: must not throw timeRegressed, commands empty, deck B not playing
        let tick1 = try await service.advance(to: 3.52)
        XCTAssertTrue(tick1.isEmpty)
        XCTAssertFalse(coordinator.deckBGraph.isMasterPlaying)

        // 3. Live tick at 3.99s (strictly before 4.0s downbeat): commands still empty, deck B not playing
        let tick2 = try await service.advance(to: 3.99)
        XCTAssertTrue(tick2.isEmpty)
        XCTAssertFalse(coordinator.deckBGraph.isMasterPlaying)

        // 4. Live tick at 4.0s downbeat: start commands emitted and executed!
        let startCommands = try await service.advance(to: 4.0)
        XCTAssertFalse(startCommands.isEmpty)
        XCTAssertTrue(coordinator.deckBGraph.isMasterPlaying)

        // 5. Monotonic progression to completion
        _ = try await service.advance(to: plan.endTimestampSeconds)
        let snapEnd = await service.snapshot
        XCTAssertEqual(snapEnd.state, .completed)
        XCTAssertTrue(coordinator.deckBGraph.isMasterPlaying)
        XCTAssertFalse(coordinator.deckAGraph.isMasterPlaying)
    }

    // MARK: - 14. AutoPilot Deck-Scoped One-Shot History (P2 L376 Regression)

    func testAutoPilotDeckScopedOneShotHistoryPermitsConsecutiveTransitions() async throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let service = coordinator.transitionExecutionService

        let urlA = try createTestWavFile(durationSeconds: 30.0)
        let urlB = try createTestWavFile(durationSeconds: 30.0)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        try coordinator.deckAGraph.loadTrack(url: urlA)
        try coordinator.deckBGraph.loadTrack(url: urlB)
        coordinator.deckAGraph.play()

        // Seek both decks to force identical numeric scheduleGeneration (e.g. 4)
        for _ in 0..<3 {
            coordinator.deckAGraph.seek(to: 0.0)
            coordinator.deckBGraph.seek(to: 0.0)
        }
        let genA = coordinator.deckAGraph.scheduleGeneration
        let genB = coordinator.deckBGraph.scheduleGeneration
        XCTAssertEqual(genA, genB)
        XCTAssertGreaterThan(genA, 0)

        // Phase 1: AutoPilot on Deck A (A -> B)
        let descA1 = makeDescriptor(deck: .deckA, duration: 30.0, bpm: 120.0, mixOutCue: 10.0)
        let descB1 = makeDescriptor(deck: .deckB, duration: 30.0, bpm: 120.0, mixOutCue: 25.0)

        let requestAtoB = TransitionRequest(
            outgoingTrack: descA1,
            incomingTrack: descB1,
            style: .filterEchoWash(durationSeconds: 2.0, echoSend: 0.5),
            triggerPositionSeconds: 10.0
        )

        try await service.armAutoPilot(request: requestAtoB)
        let fireA = try await service.tick(playheadSeconds: 10.0)
        XCTAssertFalse(fireA.isEmpty)

        let snapA = await service.snapshot
        if case .inProgress = snapA.state {
            // Fired successfully
        } else {
            XCTFail("Expected transition in progress")
        }

        // Complete A -> B
        _ = try await service.advance(to: 12.1)
        let snapAEnd = await service.snapshot
        XCTAssertEqual(snapAEnd.state, .completed)

        // Phase 2: Consecutive AutoPilot on Deck B (B -> A) with the EXACT same numeric generation
        coordinator.deckBGraph.play()
        let descB2 = makeDescriptor(deck: .deckB, duration: 30.0, bpm: 120.0, mixOutCue: 10.0)
        let descA2 = makeDescriptor(deck: .deckA, duration: 30.0, bpm: 120.0, mixOutCue: 25.0)

        let requestBtoA = TransitionRequest(
            outgoingTrack: descB2,
            incomingTrack: descA2,
            style: .filterEchoWash(durationSeconds: 2.0, echoSend: 0.5),
            triggerPositionSeconds: 10.0
        )

        try await service.armAutoPilot(request: requestBtoA)

        // Must fire ONCE because identity is (DeckIdentifier, generation), NOT generation alone!
        let fireB = try await service.tick(playheadSeconds: 10.0)
        XCTAssertFalse(fireB.isEmpty)

        let snapB = await service.snapshot
        if case .inProgress = snapB.state {
            // Fired successfully despite identical numeric generation!
        } else {
            XCTFail("Expected Deck B AutoPilot to fire, not be suppressed by Deck A history")
        }

        // Same deck at same generation cannot refire
        let reFireB = try await service.tick(playheadSeconds: 10.0)
        XCTAssertTrue(reFireB.isEmpty)
    }

    // MARK: - 15. Crossfader Endpoint Integration & Effective Gains (P1 L442 Regression)

    func testCrossfaderEndpointsIntegrationAndEffectiveGains() async throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let service = coordinator.transitionExecutionService

        let urlA = try createTestWavFile(durationSeconds: 20.0)
        let urlB = try createTestWavFile(durationSeconds: 20.0)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        try coordinator.deckAGraph.loadTrack(url: urlA)
        try coordinator.deckBGraph.loadTrack(url: urlB)
        coordinator.deckAGraph.play()

        let descA = makeDescriptor(deck: .deckA, duration: 20.0, bpm: 120.0, mixOutCue: 2.0)
        let descB = makeDescriptor(deck: .deckB, duration: 20.0, bpm: 120.0, mixOutCue: 18.0)

        // Case 1: Initial Crossfader at Endpoint 0.0 (full Deck A)
        coordinator.setCrossfader(position: 0.0)
        XCTAssertEqual(coordinator.deckAGraph.crossfaderWeight, 1.0)
        XCTAssertEqual(coordinator.deckBGraph.crossfaderWeight, 0.0)
        XCTAssertEqual(coordinator.deckAGraph.effectiveMasterGain, 1.0)
        XCTAssertEqual(coordinator.deckBGraph.effectiveMasterGain, 0.0)

        let requestAtoB = TransitionRequest(
            outgoingTrack: descA,
            incomingTrack: descB,
            style: .filterEchoWash(durationSeconds: 2.0, echoSend: 0.5),
            triggerPositionSeconds: 2.0
        )

        _ = try await service.startTransition(request: requestAtoB)

        // At start: Deck A remains at effective gain 1.0 (no spike, no drop), Deck B muted at 0.0
        XCTAssertEqual(coordinator.deckAGraph.effectiveMasterGain, 1.0)
        XCTAssertEqual(coordinator.deckBGraph.effectiveMasterGain, 0.0)
        XCTAssertEqual(coordinator.deckAGraph.crossfaderWeight, 1.0)
        XCTAssertEqual(coordinator.deckBGraph.crossfaderWeight, 1.0)

        // Live execution at midpoint
        _ = try await service.advance(to: 3.0)
        XCTAssertGreaterThan(coordinator.deckAGraph.effectiveMasterGain, 0.0)
        XCTAssertGreaterThan(coordinator.deckBGraph.effectiveMasterGain, 0.0)

        // Completion: Crossfader explicitly handed to Deck B (1.0)
        _ = try await service.advance(to: 4.1)
        let snapEnd1 = await service.snapshot
        XCTAssertEqual(snapEnd1.state, .completed)
        XCTAssertEqual(coordinator.crossfaderPosition, 1.0)
        XCTAssertEqual(coordinator.deckBGraph.crossfaderWeight, 1.0)
        XCTAssertEqual(coordinator.deckBGraph.volume, 1.0)
        XCTAssertEqual(coordinator.deckBGraph.effectiveMasterGain, 1.0) // Audible incoming at finish!
        XCTAssertEqual(coordinator.deckAGraph.crossfaderWeight, 0.0)
        XCTAssertEqual(coordinator.deckAGraph.effectiveMasterGain, 0.0)
        XCTAssertFalse(coordinator.deckAGraph.isMasterPlaying)

        // Case 2: Transition B -> A from Endpoint 1.0 (full Deck B)
        coordinator.deckBGraph.play()
        let descB2 = makeDescriptor(deck: .deckB, duration: 20.0, bpm: 120.0, mixOutCue: 2.0)
        let descA2 = makeDescriptor(deck: .deckA, duration: 20.0, bpm: 120.0, mixOutCue: 18.0)

        let requestBtoA = TransitionRequest(
            outgoingTrack: descB2,
            incomingTrack: descA2,
            style: .filterEchoWash(durationSeconds: 2.0, echoSend: 0.5),
            triggerPositionSeconds: 2.0
        )

        _ = try await service.startTransition(request: requestBtoA)
        XCTAssertEqual(coordinator.deckBGraph.effectiveMasterGain, 1.0)
        XCTAssertEqual(coordinator.deckAGraph.effectiveMasterGain, 0.0)

        _ = try await service.advance(to: 4.1)
        let snapEnd2 = await service.snapshot
        XCTAssertEqual(snapEnd2.state, .completed)
        XCTAssertEqual(coordinator.crossfaderPosition, 0.0)
        XCTAssertEqual(coordinator.deckAGraph.crossfaderWeight, 1.0)
        XCTAssertEqual(coordinator.deckAGraph.effectiveMasterGain, 1.0) // Audible incoming at finish!
        XCTAssertEqual(coordinator.deckBGraph.crossfaderWeight, 0.0)
        XCTAssertFalse(coordinator.deckBGraph.isMasterPlaying)
    }

    // MARK: - 16. Crossfader Restoration on Cancellation

    func testCrossfaderRestorationOnCancellation() async throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let service = coordinator.transitionExecutionService

        let urlA = try createTestWavFile(durationSeconds: 20.0)
        let urlB = try createTestWavFile(durationSeconds: 20.0)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        try coordinator.deckAGraph.loadTrack(url: urlA)
        try coordinator.deckBGraph.loadTrack(url: urlB)
        coordinator.deckAGraph.play()

        coordinator.setCrossfader(position: 0.0)

        let descA = makeDescriptor(deck: .deckA, duration: 20.0, bpm: 120.0, mixOutCue: 2.0)
        let descB = makeDescriptor(deck: .deckB, duration: 20.0, bpm: 120.0, mixOutCue: 18.0)

        let request = TransitionRequest(
            outgoingTrack: descA,
            incomingTrack: descB,
            style: .filterEchoWash(durationSeconds: 4.0, echoSend: 0.5),
            triggerPositionSeconds: 2.0
        )

        _ = try await service.startTransition(request: request)
        _ = try await service.advance(to: 3.0)

        // Cancel transition mid-way
        let recoveryCommands = await service.cancelTransition()
        XCTAssertFalse(recoveryCommands.isEmpty)

        // Verify pre-transition crossfader position and unity outgoing gains restored
        XCTAssertEqual(coordinator.crossfaderPosition, 0.0)
        XCTAssertEqual(coordinator.deckAGraph.crossfaderWeight, 1.0)
        XCTAssertEqual(coordinator.deckAGraph.volume, 1.0)
        XCTAssertEqual(coordinator.deckAGraph.effectiveMasterGain, 1.0)

        XCTAssertEqual(coordinator.deckBGraph.volume, 0.0)
        XCTAssertEqual(coordinator.deckBGraph.crossfaderWeight, 0.0)
        XCTAssertEqual(coordinator.deckBGraph.effectiveMasterGain, 0.0)
        XCTAssertFalse(coordinator.deckBGraph.isMasterPlaying)
    }

    // MARK: - 17. Incompatible Crossfader Routing Rejected

    func testCrossfaderIncompatibleRoutingRejected() async throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let service = coordinator.transitionExecutionService

        let urlA = try createTestWavFile(durationSeconds: 20.0)
        let urlB = try createTestWavFile(durationSeconds: 20.0)
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        try coordinator.deckAGraph.loadTrack(url: urlA)
        try coordinator.deckBGraph.loadTrack(url: urlB)
        coordinator.deckAGraph.play()

        let descA = makeDescriptor(deck: .deckA, duration: 20.0, bpm: 120.0, mixOutCue: 2.0)
        let descB = makeDescriptor(deck: .deckB, duration: 20.0, bpm: 120.0, mixOutCue: 18.0)

        // Crossfader at 1.0 means Deck A is muted on master (weight = 0.0)
        coordinator.setCrossfader(position: 1.0)

        let requestAtoB = TransitionRequest(
            outgoingTrack: descA,
            incomingTrack: descB,
            style: .filterEchoWash(durationSeconds: 2.0, echoSend: 0.5),
            triggerPositionSeconds: 2.0
        )

        do {
            _ = try await service.startTransition(request: requestAtoB)
            XCTFail("Expected incompatibleCrossfaderRouting error")
        } catch let error as TransitionExecutionServiceError {
            XCTAssertEqual(error, .incompatibleCrossfaderRouting(deck: .deckA, crossfaderPosition: 1.0))
        }
    }
}
