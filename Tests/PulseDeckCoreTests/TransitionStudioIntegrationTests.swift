import XCTest
import AVFoundation
import CoreAudio
@testable import PulseDeckCore
@testable import PulseDeckAI

final class TransitionStudioIntegrationTests: XCTestCase {
    private var coordinator: AudioEngineCoordinator!
    private var appState: AppState!
    private var fixtureRoot: URL!

    override func tearDown() async throws {
        await appState?.cancelTransition()
        coordinator?.stop()
        coordinator = nil
        appState = nil
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
        fixtureRoot = nil
        try await super.tearDown()
    }

    @MainActor
    private func prepareStudio(startTrimCueA: Double = 0) throws {
        fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        let trackA = fixtureRoot.appendingPathComponent("deck-a.wav")
        let trackB = fixtureRoot.appendingPathComponent("deck-b.wav")
        try createAudioFile(at: trackA, duration: 30)
        try createAudioFile(at: trackB, duration: 30)

        let hardware = MockAudioHardware()
        hardware.addDevice(
            id: 101,
            uid: "transition-test-output",
            name: "Offline Test Output",
            manufacturer: "PulseDeck Tests",
            outputChannels: 2,
            sampleRate: 44100,
            transportType: 0
        )
        hardware.setDefaultOutputID(101)
        coordinator = AudioEngineCoordinator(hal: hardware)
        try coordinator.monitor.performOnControlQueue {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
            try coordinator.masterAudioEngine.rawEngine.enableManualRenderingMode(
                .offline,
                format: format,
                maximumFrameCount: 4096
            )
            try coordinator.cueAudioEngine.rawEngine.enableManualRenderingMode(
                .offline,
                format: format,
                maximumFrameCount: 4096
            )
        }
        try coordinator.start()

        let entryA = try makeEntry(path: "deck-a.wav", startTrimCue: startTrimCueA)
        let entryB = try makeEntry(path: "deck-b.wav")
        let cache = PulseDeckLibraryCache(tracks: [entryA.relativePath: entryA, entryB.relativePath: entryB])
        appState = AppState(
            libraryRootURL: fixtureRoot,
            waveformEditorModel: WaveformEditorModel(libraryRootURL: fixtureRoot),
            loadedCache: cache,
            audioCoordinator: coordinator,
            startCoordinator: false
        )
    }

    @MainActor
    func testReadinessAndManualDispatchCancellationUseLoadedDecks() async throws {
        try prepareStudio()
        XCTAssertFalse(appState.transitionIsReady)
        XCTAssertEqual(appState.transitionReadinessMessage, "Load a track on both decks")

        appState.selectedTrackPath = "deck-a.wav"
        appState.loadSelectedTrackIntoDeck(deck: .deckA)
        appState.selectedTrackPath = "deck-b.wav"
        appState.loadSelectedTrackIntoDeck(deck: .deckB)
        XCTAssertEqual(appState.transitionReadinessMessage, "Play exactly one outgoing deck")

        appState.transitionPhraseBars = 8
        appState.toggleDeckPlay(deck: .deckA)
        XCTAssertTrue(appState.transitionIsReady)
        appState.transitionMacroStyle = .filterEchoWash
        appState.transitionPhraseBars = 8
        await appState.executeTransition()

        guard case .inProgress(let style, _) = appState.activeTransitionState else {
            return XCTFail("Expected production transition service to enter progress")
        }
        XCTAssertEqual(style, .filterEchoWash(durationSeconds: 16, echoSend: 0.5))
        XCTAssertTrue(coordinator.deckBGraph.isMasterPlaying)
        XCTAssertEqual(coordinator.deckBGraph.volume, 0)

        let incomingGeneration = coordinator.deckBGraph.scheduleGeneration
        appState.loadSelectedTrackIntoDeck(deck: .deckB)
        appState.toggleDeckPlay(deck: .deckB)
        XCTAssertEqual(coordinator.deckBGraph.scheduleGeneration, incomingGeneration)
        XCTAssertEqual(coordinator.deckBGraph.volume, 0, "Manual controls must not override automation")
        XCTAssertTrue(coordinator.deckBGraph.isMasterPlaying)

        await appState.cancelTransition()
        XCTAssertEqual(appState.activeTransitionState, .cancelled)
        XCTAssertTrue(coordinator.deckAGraph.isMasterPlaying)
        XCTAssertFalse(coordinator.deckBGraph.isMasterPlaying)
        XCTAssertEqual(coordinator.crossfaderPosition, 0.5, accuracy: 0.001)

        appState.setDeckCueActive(deck: .deckB, active: true)
        let cueGain = coordinator.deckBGraph.cueFaderNode.outputVolume
        appState.updateCrossfader(position: 1.0)
        appState.toggleDeckPlay(deck: .deckB)
        XCTAssertTrue(coordinator.deckBGraph.isMasterPlaying)
        XCTAssertEqual(coordinator.deckBGraph.volume, 1.0, accuracy: 0.001)
        XCTAssertEqual(coordinator.deckBGraph.effectiveMasterGain, 1.0, accuracy: 0.001)
        XCTAssertEqual(coordinator.deckBGraph.masterFaderNode.outputVolume, 1.0, accuracy: 0.001)
        XCTAssertEqual(coordinator.crossfaderPosition, 1.0, accuracy: 0.001)
        XCTAssertEqual(coordinator.deckBGraph.cueFaderNode.outputVolume, cueGain)
        XCTAssertTrue(coordinator.deckBGraph.isCueActive)
        try assertAudibleMasterPCM()
        try assertAudiblePCM(coordinator.cueAudioEngine.rawEngine)
    }

    @MainActor
    func testAutoPilotArmsAtMixOutAndDisarmsWithoutChangingDeckIntent() async throws {
        try prepareStudio()
        appState.selectedTrackPath = "deck-a.wav"
        appState.loadSelectedTrackIntoDeck(deck: .deckA)
        appState.selectedTrackPath = "deck-b.wav"
        appState.loadSelectedTrackIntoDeck(deck: .deckB)
        appState.toggleDeckPlay(deck: .deckA)

        XCTAssertNotNil(appState.autoPilotReadinessMessage)
        appState.transitionPhraseBars = 8
        XCTAssertNil(appState.autoPilotReadinessMessage)
        await appState.toggleAutoPilot()
        XCTAssertTrue(appState.isAutoPilotArmed)
        if case .armed(_, let trigger) = appState.activeTransitionState {
            XCTAssertEqual(trigger, 10, accuracy: 0.001)
        } else {
            XCTFail("Expected AutoPilot armed at outgoing mix-out cue")
        }

        let incomingGeneration = coordinator.deckBGraph.scheduleGeneration
        appState.loadSelectedTrackIntoDeck(deck: .deckB)
        appState.toggleDeckPlay(deck: .deckB)
        XCTAssertEqual(coordinator.deckBGraph.scheduleGeneration, incomingGeneration)
        XCTAssertFalse(coordinator.deckBGraph.isMasterPlaying)

        await appState.toggleAutoPilot()
        XCTAssertFalse(appState.isAutoPilotArmed)
        XCTAssertEqual(appState.activeTransitionState, .idle)
        XCTAssertTrue(coordinator.deckAGraph.isMasterPlaying)
        XCTAssertFalse(coordinator.deckBGraph.isMasterPlaying)
        XCTAssertNil(appState.transitionErrorMessage)
    }

    @MainActor
    func testAutoPilotArmsBeforeOutgoingStartTrimWhenFutureMixOutPlanFits() async throws {
        try prepareStudio(startTrimCueA: 2)
        XCTAssertEqual(appState.autoPilotReadinessMessage, "Load a track on both decks")
        appState.selectedTrackPath = "deck-a.wav"
        appState.loadSelectedTrackIntoDeck(deck: .deckA)
        appState.selectedTrackPath = "deck-b.wav"
        appState.loadSelectedTrackIntoDeck(deck: .deckB)
        appState.transitionMacroStyle = .filterEchoWash
        appState.transitionPhraseBars = 8
        appState.toggleDeckPlay(deck: .deckA)

        XCTAssertLessThan(coordinator.deckAGraph.currentMasterPlayheadSeconds(), 2)
        XCTAssertNotNil(appState.transitionReadinessMessage, "Immediate execution must still reject a trigger before start trim")
        XCTAssertFalse(appState.transitionIsReady)
        await appState.executeTransition()
        XCTAssertNotNil(appState.transitionErrorMessage)
        let rejectedManual = await coordinator.transitionExecutionService.currentSnapshot()
        XCTAssertEqual(rejectedManual.state, .idle)

        appState.transitionPhraseBars = 16
        XCTAssertNotNil(appState.autoPilotReadinessMessage, "A future plan extending beyond end trim must still be rejected")
        await appState.toggleAutoPilot()
        XCTAssertNotNil(appState.transitionErrorMessage)
        XCTAssertFalse(appState.isAutoPilotArmed)
        let rejectedAutoPilot = await coordinator.transitionExecutionService.currentSnapshot()
        XCTAssertEqual(rejectedAutoPilot.state, .idle)
        XCTAssertNil(rejectedAutoPilot.armedRequest)

        appState.transitionPhraseBars = 8
        XCTAssertNil(appState.autoPilotReadinessMessage, "ARM must validate the future mix-out plan independently")

        await appState.toggleAutoPilot()
        XCTAssertNil(appState.transitionErrorMessage)
        XCTAssertTrue(appState.isAutoPilotArmed)
        guard case .armed(_, let trigger) = appState.activeTransitionState else {
            return XCTFail("AutoPilot must arm before the outgoing start-trim cue")
        }
        XCTAssertEqual(trigger, 10, accuracy: 0.001)
        let snapshot = await coordinator.transitionExecutionService.currentSnapshot()
        let plan = try TransitionPlanner().plan(try XCTUnwrap(snapshot.armedRequest))
        XCTAssertEqual(plan.startTimestampSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(plan.endTimestampSeconds, 26, accuracy: 0.001)
        XCTAssertTrue(coordinator.deckAGraph.isMasterPlaying)
        XCTAssertFalse(coordinator.deckBGraph.isMasterPlaying)
        XCTAssertEqual(coordinator.crossfaderPosition, 0.5, accuracy: 0.001)
    }

    @MainActor
    func testDisarmAfterAutoPilotFiresStillObservesCompletionAndUnlocksControls() async throws {
        try prepareStudio()
        appState.selectedTrackPath = "deck-a.wav"
        appState.loadSelectedTrackIntoDeck(deck: .deckA)
        appState.selectedTrackPath = "deck-b.wav"
        appState.loadSelectedTrackIntoDeck(deck: .deckB)
        appState.transitionMacroStyle = .filterEchoWash
        appState.transitionPhraseBars = 8
        appState.toggleDeckPlay(deck: .deckA)
        await appState.toggleAutoPilot()
        XCTAssertTrue(appState.isAutoPilotArmed)

        let service = coordinator.transitionExecutionService
        let fired = DispatchSemaphore(value: 0)
        let fireTask = Task.detached {
            defer { fired.signal() }
            return try await service.advance(to: 10)
        }
        // Hold MainActor until the production actor fires. The UI observer cannot
        // publish the new state before DISARM enters its stale-armed branch.
        guard waitForServiceFire(fired) else {
            fireTask.cancel()
            return XCTFail("AutoPilot did not fire while MainActor observation was held")
        }
        XCTAssertTrue(appState.isAutoPilotArmed)
        await appState.toggleAutoPilot()
        _ = try await fireTask.value
        XCTAssertTrue(appState.isTransitionRunning)
        XCTAssertTrue(appState.isTransitionBusy)
        XCTAssertFalse(appState.isAutoPilotArmed)

        let running = await service.currentSnapshot()
        let plan = try XCTUnwrap(running.activePlan)
        _ = try await service.advance(to: plan.endTimestampSeconds)
        let completed = await service.currentSnapshot()
        XCTAssertEqual(completed.state, .completed)

        // Only publication is asynchronous; the service clock and race are controlled.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while appState.isTransitionBusy, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(appState.activeTransitionState, .completed)
        XCTAssertEqual(appState.transitionProgress, 1, accuracy: 0.001)
        XCTAssertFalse(appState.isTransitionBusy)
        XCTAssertFalse(appState.isTransitionRunning)
        XCTAssertFalse(appState.isDeckAPlaying)
        XCTAssertTrue(appState.isDeckBPlaying)
        XCTAssertEqual(appState.crossfaderPosition, 1, accuracy: 0.001)
        XCTAssertNil(appState.transitionErrorMessage)

        appState.setMasterSafetyLockEnabled(false)
        appState.toggleDeckPlay(deck: .deckB)
        XCTAssertFalse(coordinator.deckBGraph.isMasterPlaying)
        appState.updateCrossfader(position: 0.25)
        XCTAssertEqual(coordinator.crossfaderPosition, 0.25, accuracy: 0.001)
    }

    private func waitForServiceFire(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 5) == .success
    }

    @MainActor
    func testAutoPilotUsesCueEditsSavedAfterBothDecksLoad() async throws {
        try prepareStudio()
        let cacheURL = fixtureRoot.appendingPathComponent(PulseDeckCoreConfig.cacheFileName)
        try CachePersistence.saveAtomic(cache: try XCTUnwrap(appState.loadedCache), to: cacheURL)

        appState.selectedTrackPath = "deck-a.wav"
        appState.loadSelectedTrackIntoDeck(deck: .deckA)
        appState.selectedTrackPath = "deck-b.wav"
        appState.loadSelectedTrackIntoDeck(deck: .deckB)
        appState.transitionMacroStyle = .filterEchoWash
        appState.transitionPhraseBars = 8
        appState.toggleDeckPlay(deck: .deckA)

        let editor = appState.waveformEditorModel
        editor.loadTrack(try XCTUnwrap(appState.loadedCache?.tracks["deck-a.wav"]))
        editor.setCue(.mixOut, toTime: 12)
        await editor.waitForPendingSaves()
        XCTAssertEqual(appState.loadedCache?.tracks["deck-a.wav"]?.cueMarkers.mixOutCue, 12)

        editor.loadTrack(try XCTUnwrap(appState.loadedCache?.tracks["deck-b.wav"]))
        editor.setCue(.mixOut, toTime: 20)
        await editor.waitForPendingSaves()
        editor.loadTrack(try XCTUnwrap(appState.loadedCache?.tracks["deck-b.wav"]))
        editor.setCue(.vocalEntry, toTime: 18)
        await editor.waitForPendingSaves()
        editor.loadTrack(try XCTUnwrap(appState.loadedCache?.tracks["deck-b.wav"]))
        editor.setCue(.startTrim, toTime: 15)
        await editor.waitForPendingSaves()
        XCTAssertEqual(appState.loadedCache?.tracks["deck-b.wav"]?.cueMarkers.startTrimCue, 15)
        XCTAssertEqual(
            appState.autoPilotReadinessMessage,
            "The complete transition does not fit the playable cue interval on Deck B"
        )

        editor.setCue(.startTrim, toTime: 2)
        await editor.waitForPendingSaves()
        XCTAssertNil(appState.autoPilotReadinessMessage)

        await appState.toggleAutoPilot()
        guard case .armed(_, let trigger) = appState.activeTransitionState else {
            return XCTFail("Expected AutoPilot to arm from the latest saved mix-out cue")
        }
        XCTAssertEqual(trigger, 12, accuracy: 0.001)

        let snapshot = await coordinator.transitionExecutionService.currentSnapshot()
        let request = try XCTUnwrap(snapshot.armedRequest)
        XCTAssertEqual(request.outgoingTrack.cueMarkers.mixOutCue, 12, accuracy: 0.001)
        XCTAssertEqual(request.incomingTrack.cueMarkers.startTrimCue, 2, accuracy: 0.001)
        let plan = try TransitionPlanner().plan(request)
        let incomingSeek = try XCTUnwrap(plan.events.compactMap { event -> Double? in
            if case .seek(deck: .deckB, positionSeconds: let position) = event.command { return position }
            return nil
        }.first)
        XCTAssertEqual(incomingSeek, 2, accuracy: 0.001)
    }

    @MainActor
    func testHardCutMacroDispatchesThroughAppStateAndHandsOffDeckIntent() async throws {
        try prepareStudio()
        appState.selectedTrackPath = "deck-a.wav"
        appState.loadSelectedTrackIntoDeck(deck: .deckA)
        appState.selectedTrackPath = "deck-b.wav"
        appState.loadSelectedTrackIntoDeck(deck: .deckB)
        appState.transitionMacroStyle = .hardCutOnDrop
        appState.transitionPhraseBars = 8
        appState.toggleDeckPlay(deck: .deckA)

        XCTAssertTrue(appState.transitionIsReady)
        await appState.executeTransition()

        let snapshot = await coordinator.transitionExecutionService.currentSnapshot()
        XCTAssertEqual(snapshot.activePlan?.style, .hardCutOnDrop(bars: 8, allowFallbackToFilter: false))
        XCTAssertEqual(snapshot.state, .completed)
        XCTAssertFalse(coordinator.deckAGraph.isMasterPlaying)
        XCTAssertTrue(coordinator.deckBGraph.isMasterPlaying)
        XCTAssertEqual(coordinator.crossfaderPosition, 1.0, accuracy: 0.001)
        XCTAssertEqual(appState.crossfaderPosition, 1.0, accuracy: 0.001)
        XCTAssertNil(appState.transitionErrorMessage)

        XCTAssertEqual(coordinator.deckAGraph.volume, 0.0, accuracy: 0.001)
        appState.selectedTrackPath = "deck-b.wav"
        appState.loadSelectedTrackIntoDeck(deck: .deckA)
        XCTAssertEqual(coordinator.deckAGraph.volume, 1.0, accuracy: 0.001)
        XCTAssertEqual(coordinator.crossfaderPosition, 1.0, accuracy: 0.001)
        XCTAssertEqual(coordinator.deckAGraph.effectiveMasterGain, 0.0, accuracy: 0.001)
        XCTAssertFalse(coordinator.deckAGraph.isCueActive)
        XCTAssertEqual(coordinator.deckAGraph.cueFaderNode.outputVolume, 0.0)
        appState.toggleDeckPlay(deck: .deckA)
        XCTAssertEqual(coordinator.crossfaderPosition, 1.0, accuracy: 0.001)
        XCTAssertEqual(coordinator.deckAGraph.effectiveMasterGain, 0.0, accuracy: 0.001)
        appState.updateCrossfader(position: 0.0)
        XCTAssertTrue(coordinator.deckAGraph.isMasterPlaying)
        XCTAssertEqual(coordinator.deckAGraph.volume, 1.0, accuracy: 0.001)
        XCTAssertEqual(coordinator.deckAGraph.effectiveMasterGain, 1.0, accuracy: 0.001)
        XCTAssertEqual(coordinator.deckAGraph.masterFaderNode.outputVolume, 1.0, accuracy: 0.001)
        try assertAudibleMasterPCM()
    }

    @MainActor
    private func assertAudibleMasterPCM(file: StaticString = #filePath, line: UInt = #line) throws {
        try assertAudiblePCM(coordinator.masterAudioEngine.rawEngine, file: file, line: line)
    }

    private func assertAudiblePCM(_ engine: AVAudioEngine, file: StaticString = #filePath, line: UInt = #line) throws {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        var peak: Float = 0
        // Render beyond the time-pitch pipeline's startup latency before checking signal.
        for _ in 0..<8 {
            XCTAssertEqual(try engine.renderOffline(4096, to: buffer), .success, file: file, line: line)
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for frame in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(channels[0][frame]))
            }
        }
        XCTAssertGreaterThan(peak, 0.05, "Manual playback must produce actual PCM after transition recovery", file: file, line: line)
    }

    private func createAudioFile(at url: URL, duration: Double) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(format.sampleRate * duration)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<Int(frames) {
            let sample = Float(sin(Double(frame) * 0.05) * 0.2)
            channels[0][frame] = sample
            channels[1][frame] = sample
        }
        try file.write(from: buffer)
    }

    private func makeEntry(path: String, startTrimCue: Double = 0) throws -> TrackCacheEntry {
        let duration = 30.0
        let interval = 0.5
        let timestamps = stride(from: 0.0, to: duration, by: interval).map { $0 }
        let peaks = [Float](repeating: 0.2, count: 64)
        return TrackCacheEntry(
            relativePath: path,
            fileFingerprint: try LibraryTrackSource.fingerprint(at: fixtureRoot.appendingPathComponent(path)),
            fileSizeBytes: 1_000,
            fileModificationTime: "2026-10-23T00:00:00Z",
            duration: duration,
            sampleRate: 44100,
            channels: 2,
            bitDepth: 16,
            bpm: 120,
            musicalKey: "8A",
            confidence: 0.95,
            waveformMetadata: WaveformMetadata(
                sampleCount: peaks.count,
                downsampleFactor: 512,
                peakValues: peaks,
                lowBandPeaks: peaks,
                midBandPeaks: peaks,
                highBandPeaks: peaks
            ),
            beatGrid: BeatGrid(
                firstBeatOffsetSeconds: 0,
                beatIntervalSeconds: interval,
                beatTimestamps: timestamps
            ),
            structure: TrackStructure(sections: [], vocalSegments: []),
            cueMarkers: CueMarkers(
                startTrimCue: startTrimCue,
                vocalEntryCue: 4,
                mixOutCue: 10,
                endTrimCue: duration
            ),
            analyzerVersion: "offline-test",
            analysisTimestamp: "2026-10-23T00:00:00Z"
        )
    }
}
