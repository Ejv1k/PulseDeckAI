import XCTest
import AppKit
import AVFoundation
import CoreAudio
@testable import PulseDeckCore
@testable import PulseDeckAI

final class MasterSafetyLockIntegrationTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let root: URL
        let audio: AudioEngineCoordinator
        let app: AppState

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            audio = AudioEngineCoordinator(hal: MockAudioHardware())
            do {
                let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
                try audio.masterAudioEngine.rawEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
                try audio.cueAudioEngine.rawEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
                try audio.start()
                var tracks: [String: TrackCacheEntry] = [:]
                for (index, name) in ["a.wav", "b.wav"].enumerated() {
                    let file = try AVAudioFile(forWriting: root.appendingPathComponent(name), settings: format.settings)
                    let frames = AVAudioFrameCount(44100 * 30)
                    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
                    buffer.frameLength = frames
                    let data = try XCTUnwrap(buffer.floatChannelData)
                    for frame in 0..<Int(frames) {
                        let sample = Float(sin(Double(frame) * (index == 0 ? 0.05 : 0.075)) * 0.2)
                        data[0][frame] = sample; data[1][frame] = sample
                    }
                    try file.write(from: buffer)
                    tracks[name] = TrackCacheEntry(
                        relativePath: name, fileFingerprint: "safety-\(name)", fileSizeBytes: 1000,
                        fileModificationTime: "2026-10-25T00:00:00Z", duration: 30, sampleRate: 44100,
                        channels: 2, bitDepth: 32, bpm: 120, musicalKey: "8A", confidence: 0.95,
                        waveformMetadata: WaveformMetadata(sampleCount: 64, downsampleFactor: 512,
                            peakValues: [Float](repeating: 0.2, count: 64),
                            lowBandPeaks: [Float](repeating: 0.2, count: 64),
                            midBandPeaks: [Float](repeating: 0.2, count: 64),
                            highBandPeaks: [Float](repeating: 0.2, count: 64)),
                        beatGrid: BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 0.5,
                            beatTimestamps: stride(from: 0.0, to: 30.0, by: 0.5).map { $0 }),
                        structure: TrackStructure(sections: [], vocalSegments: []),
                        cueMarkers: CueMarkers(startTrimCue: 0, vocalEntryCue: 2, mixOutCue: 10, endTrimCue: 30),
                        aiTrimBypass: false, manualOverrides: ManualOverrides(),
                        analyzerVersion: "safety-test", analysisTimestamp: "2026-10-25T00:00:00Z")
                }
                app = AppState(libraryRootURL: root, waveformEditorModel: WaveformEditorModel(libraryRootURL: root),
                    loadedCache: PulseDeckLibraryCache(tracks: tracks), audioCoordinator: audio, startCoordinator: false)
                app.selectedTrackPath = "a.wav"; app.loadSelectedTrackIntoDeck(deck: .deckA)
                app.selectedTrackPath = "b.wav"; app.loadSelectedTrackIntoDeck(deck: .deckB)
                app.updateCrossfader(position: 0)
                app.toggleDeckPlay(deck: .deckA)
            } catch {
                audio.stop()
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }

        func cleanup() {
            app.stopPreview()
            audio.stop()
            try? FileManager.default.removeItem(at: root)
        }

        func peak(_ engine: AVAudioEngine) throws -> Float {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
            XCTAssertEqual(try engine.renderOffline(4096, to: buffer), .success)
            let channels = try XCTUnwrap(buffer.floatChannelData)
            return (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(channels[0][$1])) }
        }
    }

    @MainActor
    func testDefaultLockRejectsOnAirPauseWithoutChangingMasterPCM() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let generation = f.audio.deckAGraph.scheduleGeneration
        XCTAssertGreaterThan(try f.peak(f.audio.masterAudioEngine.rawEngine), 0.1)
        f.app.toggleDeckPlay(deck: .deckA)
        XCTAssertTrue(f.audio.deckAGraph.isMasterPlaying)
        XCTAssertEqual(f.audio.deckAGraph.scheduleGeneration, generation)
        XCTAssertGreaterThan(try f.peak(f.audio.masterAudioEngine.rawEngine), 0.1)
    }

    @MainActor
    func testDefaultLockRejectsOnAirReplacementBeforeLoading() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let original = f.audio.deckAGraph.loadedTrackURL
        let generation = f.audio.deckAGraph.scheduleGeneration
        f.app.selectedTrackPath = "b.wav"
        f.app.loadSelectedTrackIntoDeck(deck: .deckA)
        XCTAssertEqual(f.audio.deckAGraph.loadedTrackURL, original)
        XCTAssertTrue(f.audio.deckAGraph.isMasterPlaying)
        XCTAssertEqual(f.audio.deckAGraph.scheduleGeneration, generation)
        XCTAssertGreaterThan(try f.peak(f.audio.masterAudioEngine.rawEngine), 0.1)
    }
    @MainActor
    func testStopAndSeekAreRejectedWithoutMasterOrCueScheduleChanges() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.app.setDeckCueActive(deck: .deckA, active: true)
        let master = f.audio.deckAGraph.scheduleGeneration
        let cueStart = f.audio.deckAGraph.cueScheduleStartSecondsForTesting
        XCTAssertFalse(f.app.pauseDeck(deck: .deckA))
        XCTAssertFalse(f.app.stopDeck(deck: .deckA))
        XCTAssertFalse(f.app.seekDeck(deck: .deckA, to: 10))
        XCTAssertTrue(f.app.isMasterSafetyLockEnabled)
        XCTAssertTrue(f.audio.deckAGraph.isMasterPlaying)
        XCTAssertEqual(f.audio.deckAGraph.scheduleGeneration, master)
        XCTAssertEqual(f.audio.deckAGraph.cueScheduleStartSecondsForTesting, cueStart)
        XCTAssertGreaterThan(try f.peak(f.audio.masterAudioEngine.rawEngine), 0.1)
        XCTAssertGreaterThan(try f.peak(f.audio.cueAudioEngine.rawEngine), 0.1)
        XCTAssertNotNil(f.app.masterSafetyLockMessage)
    }

    @MainActor
    func testBothCrossfadeMembersAreProtectedDespiteTalkoverAndFocus() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.app.toggleDeckPlay(deck: .deckB) // Its closed Master fader permits preparation.
        f.app.updateCrossfader(position: 0.5)
        f.audio.talkoverController.stepProgress(to: 1)
        f.app.focusMasterDeck(.deckB)
        XCTAssertTrue(f.app.isMasterDeckProtected(.deckA))
        XCTAssertTrue(f.app.isMasterDeckProtected(.deckB))
        XCTAssertFalse(f.app.stopDeck(deck: .deckA))
        XCTAssertFalse(f.app.seekDeck(deck: .deckB, to: 5))
        f.audio.deckAGraph.volume = 0.000001 // Quiet music is still protected; no meter threshold.
        XCTAssertTrue(f.app.isMasterDeckProtected(.deckA))
        f.app.updateCrossfader(position: 1)
        XCTAssertFalse(f.app.isMasterDeckProtected(.deckA))
        XCTAssertTrue(f.app.isMasterDeckProtected(.deckB))
        XCTAssertTrue(f.app.seekDeck(deck: .deckA, to: 3))
        XCTAssertTrue(f.app.stopDeck(deck: .deckA))
        XCTAssertTrue(f.audio.deckBGraph.isMasterPlaying)
    }

    @MainActor
    func testRealTransportAndChannelStateOverrideStalePublishedLabels() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.audio.deckAGraph.pause() // Internal cleanup does not go through a manual policy.
        XCTAssertTrue(f.app.isDeckAPlaying)
        XCTAssertFalse(f.app.isMasterDeckProtected(.deckA))
        f.app.selectedTrackPath = "b.wav"
        f.app.loadSelectedTrackIntoDeck(deck: .deckA)
        XCTAssertFalse(f.app.isDeckAPlaying)
        f.audio.deckAGraph.play()
        f.app.focusMasterDeck(.deckB)
        XCTAssertTrue(f.app.isMasterDeckProtected(.deckA))
        XCTAssertFalse(f.app.pauseDeck(deck: .deckA))
        f.audio.deckAGraph.volume = 0
        XCTAssertFalse(f.app.isMasterDeckProtected(.deckA))
        XCTAssertTrue(f.app.pauseDeck(deck: .deckA))
    }

    @MainActor
    func testExplicitUnlockAndOneShotConfirmationDoNotSharePersistentBypass() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.app.focusMasterDeck(.deckB)
        XCTAssertFalse(f.app.forcePauseFocusedMasterDeck())
        XCTAssertTrue(f.audio.deckAGraph.isMasterPlaying)
        f.app.focusMasterDeck(.deckA)
        XCTAssertTrue(f.app.forcePauseFocusedMasterDeck())
        XCTAssertFalse(f.audio.deckAGraph.isMasterPlaying)
        XCTAssertTrue(f.app.isMasterSafetyLockEnabled)
        f.app.toggleDeckPlay(deck: .deckA)
        XCTAssertTrue(f.audio.deckAGraph.isMasterPlaying)
        XCTAssertFalse(f.app.stopDeck(deck: .deckA))
        f.app.setMasterSafetyLockEnabled(false)
        XCTAssertTrue(f.app.seekDeck(deck: .deckA, to: 4))
        XCTAssertTrue(f.app.stopDeck(deck: .deckA))
        f.app.selectedTrackPath = "b.wav"
        f.app.loadSelectedTrackIntoDeck(deck: .deckA)
        XCTAssertEqual(f.audio.deckAGraph.loadedTrackURL, f.root.appendingPathComponent("b.wav"))
        XCTAssertFalse(f.app.seekDeck(deck: .deckA, to: .nan))
        f.app.setMasterSafetyLockEnabled(true)
        XCTAssertTrue(f.app.isMasterSafetyLockEnabled)
    }

    @MainActor
    func testCuePreviewAndNonDestructiveEditorRemainUsable() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let generation = f.audio.deckAGraph.scheduleGeneration
        f.app.setDeckCueActive(deck: .deckA, active: true)
        XCTAssertTrue(f.app.isDeckACueActive)
        await f.app.loadPreviewTrack(relativePath: "b.wav", playWhenReady: true).value
        XCTAssertTrue(f.app.isPreviewPlaying)
        f.app.seekPreview(to: 5)
        XCTAssertGreaterThan(try f.peak(f.audio.cueAudioEngine.rawEngine), 0.1)
        f.app.stopPreview()
        f.app.waveformEditorModel.loadTrack(try XCTUnwrap(f.app.deckATrack))
        f.app.waveformEditorModel.seekPlayhead(to: 12)
        XCTAssertEqual(f.app.waveformEditorModel.playheadPosition, 12)
        XCTAssertEqual(f.audio.deckAGraph.scheduleGeneration, generation)
        XCTAssertTrue(f.audio.deckAGraph.isMasterPlaying)
        XCTAssertGreaterThan(try f.peak(f.audio.masterAudioEngine.rawEngine), 0.1)
    }

    @MainActor
    func testAutomationOwnershipAndInternalCompletionCleanupAreUnaffected() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.app.transitionPhraseBars = 8
        f.app.transitionMacroStyle = .filterEchoWash
        await f.app.toggleAutoPilot()
        XCTAssertTrue(f.app.isAutoPilotArmed)
        f.app.setMasterSafetyLockEnabled(false)
        XCTAssertFalse(f.app.forcePauseFocusedMasterDeck(), "Confirmation must not bypass automation")
        XCTAssertFalse(f.app.stopDeck(deck: .deckA))
        await f.app.toggleAutoPilot()
        XCTAssertFalse(f.app.isTransitionBusy)
        f.app.setMasterSafetyLockEnabled(true)
        await f.app.executeTransition()
        XCTAssertTrue(f.app.isTransitionRunning)
        let generation = f.audio.deckAGraph.scheduleGeneration
        XCTAssertFalse(f.app.forcePauseFocusedMasterDeck())
        XCTAssertFalse(f.app.seekDeck(deck: .deckA, to: 7))
        XCTAssertEqual(f.audio.deckAGraph.scheduleGeneration, generation)
        let service = f.audio.transitionExecutionService
        let snapshot = await service.currentSnapshot()
        guard let plan = snapshot.activePlan else {
            await f.app.cancelTransition()
            return XCTFail("Expected real running transition")
        }
        _ = try await service.advance(to: plan.endTimestampSeconds)
        XCTAssertFalse(f.audio.deckAGraph.isMasterPlaying)
        XCTAssertTrue(f.audio.deckBGraph.isMasterPlaying)
        XCTAssertTrue(f.app.isMasterSafetyLockEnabled)
        await f.app.cancelTransition()
        f.audio.stop() // Genuine application/device cleanup bypasses manual controls.
        XCTAssertFalse(f.audio.deckAGraph.isMasterPlaying)
        XCTAssertFalse(f.audio.deckBGraph.isMasterPlaying)
        XCTAssertFalse(f.audio.masterAudioEngine.isRunning)
        try f.audio.start()
        XCTAssertTrue(f.audio.masterAudioEngine.isRunning)
        XCTAssertTrue(f.app.isMasterSafetyLockEnabled)
    }

    func testPolicyIsConservativeAndIndependentOfFocusOrTalkover() {
        let onAir: (Bool, Bool, Bool, Float, Float) -> Bool = { running, playing, loaded, volume, weight in
            MasterSafetyLock.isOnAir(masterIsRunning: running, isPlaying: playing, hasLoadedTrack: loaded,
                                    channelVolume: volume, crossfaderWeight: weight)
        }
        XCTAssertTrue(onAir(true, true, true, 0.000001, 1))
        XCTAssertTrue(onAir(true, true, true, .nan, 1))
        XCTAssertFalse(onAir(true, true, true, 1, 0))
        XCTAssertFalse(onAir(true, true, true, 0, 1))
        XCTAssertFalse(onAir(false, true, true, 1, 1))
        XCTAssertFalse(onAir(true, false, true, 1, 1))
        XCTAssertFalse(onAir(true, true, false, 1, 1))
    }

    @MainActor
    private final class KeyReceiver: NSView {
        let router: MasterSafetyLockKeyboardRouter
        var dispatchedKeys = 0
        init(router: MasterSafetyLockKeyboardRouter) { self.router = router; super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 100)) }
        required init?(coder: NSCoder) { nil }
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            dispatchedKeys += 1
            if !router.handleStudioEvent(event) { super.keyDown(with: event) }
        }
    }

    @MainActor
    private func key(_ window: NSWindow, time: TimeInterval, shift: Bool = false, repeating: Bool = false,
                     type: NSEvent.EventType = .keyDown, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero,
            modifierFlags: shift ? modifiers.union(.shift) : modifiers, timestamp: time,
            windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: repeating, keyCode: 49))
    }

    @MainActor
    func testDispatchedSpaceConfirmationRepeatDuplicateAndFocus() throws {
        let f = try Fixture(); defer { f.cleanup() }
        _ = NSApplication.shared
        let router = MasterSafetyLockKeyboardRouter(appState: f.app)
        let receiver = KeyReceiver(router: router)
        let window = NSWindow(contentRect: receiver.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = receiver
        router.attach(to: window, anchor: receiver)
        XCTAssertTrue(window.makeFirstResponder(receiver))
        defer { router.detach(from: receiver); window.close() }
        let pause = try key(window, time: 1, shift: true)
        window.sendEvent(pause)
        XCTAssertEqual(receiver.dispatchedKeys, 1)
        XCTAssertFalse(f.audio.deckAGraph.isMasterPlaying)
        let feedback = f.app.masterSafetyLockMessage
        window.sendEvent(pause) // Same physical event routed twice.
        XCTAssertEqual(f.app.masterSafetyLockMessage, feedback)
        f.app.toggleDeckPlay(deck: .deckA)
        f.app.focusMasterDeck(.deckB)
        window.sendEvent(try key(window, time: 2, shift: true, repeating: true))
        XCTAssertTrue(f.audio.deckAGraph.isMasterPlaying)
        XCTAssertFalse(f.audio.deckBGraph.isMasterPlaying, "Holding Space across a focus change must not act on the new deck")
        XCTAssertTrue(f.app.isMasterSafetyLockEnabled)
        f.app.focusMasterDeck(.deckB)
        window.sendEvent(try key(window, time: 3))
        XCTAssertTrue(f.audio.deckBGraph.isMasterPlaying)
        window.sendEvent(try key(window, time: 4))
        XCTAssertFalse(f.audio.deckBGraph.isMasterPlaying, "Off-air normal Space keeps normal play/pause behavior")
        f.app.focusMasterDeck(.deckA)
        window.sendEvent(try key(window, time: 5))
        XCTAssertTrue(f.audio.deckAGraph.isMasterPlaying, "Normal Space cannot pause the on-air deck")
    }

    @MainActor
    private final class FocusedWindow: NSWindow {
        var reportsKeyWindow = true
        override var isKeyWindow: Bool { reportsKeyWindow }
    }

    @MainActor
    func testWindowRouterPreservesTypingPreviewAndOtherShortcuts() throws {
        let f = try Fixture(); defer { f.cleanup() }
        _ = NSApplication.shared
        let router = MasterSafetyLockKeyboardRouter(appState: f.app)
        let receiver = KeyReceiver(router: router)
        let window = FocusedWindow(contentRect: receiver.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = receiver
        router.attach(to: window, anchor: receiver)
        defer { router.detach(from: receiver); window.close() }
        XCTAssertTrue(window.makeFirstResponder(receiver))
        let ordinary = try key(window, time: 10)
        XCTAssertTrue(router.handleWindowEvent(ordinary) === ordinary, "Preview's normal Space must pass through")
        for modifiers: NSEvent.ModifierFlags in [.command, .option, .control, .function] {
            XCTAssertFalse(router.handleStudioEvent(try key(window, time: 11, modifiers: modifiers)))
        }
        let confirmed = try key(window, time: 12, shift: true)
        window.reportsKeyWindow = false
        XCTAssertTrue(router.handleWindowEvent(confirmed) === confirmed)
        window.reportsKeyWindow = true
        XCTAssertNil(router.handleWindowEvent(confirmed))
        XCTAssertFalse(f.audio.deckAGraph.isMasterPlaying)
        f.app.toggleDeckPlay(deck: .deckA)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 150, height: 22))
        receiver.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let typing = try key(window, time: 13, shift: true)
        XCTAssertTrue(router.handleWindowEvent(typing) === typing)
        XCTAssertFalse(router.handleStudioEvent(typing))
        XCTAssertTrue(f.audio.deckAGraph.isMasterPlaying)
    }

    private nonisolated static func waitForCommand(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 5) == .success
    }

    private actor CommandLatch {
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            if released { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func release() { released = true; waiter?.resume(); waiter = nil }
    }

    @MainActor
    func testPendingAutomationStartReservesManualTransportBeforePublication() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.app.transitionPhraseBars = 8
        f.app.transitionMacroStyle = .filterEchoWash
        f.app.setMasterSafetyLockEnabled(false)
        let entered = DispatchSemaphore(value: 0)
        let latch = CommandLatch()
        f.app.safetyLockBeforeTransitionStartForTesting = {
            entered.signal()
            await latch.wait()
        }
        let request = Task { @MainActor in await f.app.executeTransition() }
        let held = await Task.detached { Self.waitForCommand(entered) }.value
        guard held else {
            await latch.release(); await request.value
            return XCTFail("Validated transition never reached its controlled handoff")
        }
        XCTAssertFalse(f.app.isTransitionBusy, "Published backend state has not arrived yet")
        let generation = f.audio.deckAGraph.scheduleGeneration
        XCTAssertFalse(f.app.forcePauseFocusedMasterDeck())
        XCTAssertFalse(f.app.stopDeck(deck: .deckA))
        XCTAssertFalse(f.app.seekDeck(deck: .deckA, to: 9))
        XCTAssertEqual(f.audio.deckAGraph.scheduleGeneration, generation)
        XCTAssertTrue(f.audio.deckAGraph.isMasterPlaying)
        await latch.release()
        await request.value
        XCTAssertTrue(f.app.isTransitionRunning)
        await f.app.cancelTransition()
    }

}
