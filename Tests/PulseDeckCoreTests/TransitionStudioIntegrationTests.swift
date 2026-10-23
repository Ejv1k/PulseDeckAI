import XCTest
import AVFoundation
import CoreAudio
@testable import PulseDeckCore
@testable import PulseDeckAI

final class TransitionStudioIntegrationTests: XCTestCase {
    private var coordinator: AudioEngineCoordinator!
    private var appState: AppState!
    private var fixtureRoot: URL!

    override func tearDown() {
        coordinator?.stop()
        coordinator = nil
        appState = nil
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
        fixtureRoot = nil
        super.tearDown()
    }

    @MainActor
    private func prepareStudio() throws {
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

        let entryA = makeEntry(path: "deck-a.wav")
        let entryB = makeEntry(path: "deck-b.wav")
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

        await appState.cancelTransition()
        XCTAssertEqual(appState.activeTransitionState, .cancelled)
        XCTAssertTrue(coordinator.deckAGraph.isMasterPlaying)
        XCTAssertFalse(coordinator.deckBGraph.isMasterPlaying)
        XCTAssertEqual(coordinator.crossfaderPosition, 0.5, accuracy: 0.001)
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

        await appState.toggleAutoPilot()
        XCTAssertFalse(appState.isAutoPilotArmed)
        XCTAssertEqual(appState.activeTransitionState, .idle)
        XCTAssertTrue(coordinator.deckAGraph.isMasterPlaying)
        XCTAssertFalse(coordinator.deckBGraph.isMasterPlaying)
        XCTAssertNil(appState.transitionErrorMessage)
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

    private func makeEntry(path: String) -> TrackCacheEntry {
        let duration = 30.0
        let interval = 0.5
        let timestamps = stride(from: 0.0, to: duration, by: interval).map { $0 }
        let peaks = [Float](repeating: 0.2, count: 64)
        return TrackCacheEntry(
            relativePath: path,
            fileFingerprint: "test-\(path)",
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
                startTrimCue: 0,
                vocalEntryCue: 4,
                mixOutCue: 10,
                endTrimCue: duration
            ),
            analyzerVersion: "offline-test",
            analysisTimestamp: "2026-10-23T00:00:00Z"
        )
    }
}
