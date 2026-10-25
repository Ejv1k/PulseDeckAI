import XCTest
import Combine
import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics
import PulseDeckAtomics
@testable import PulseDeckCore
@testable import PulseDeckAI

@MainActor
final class ProjectorTests: XCTestCase {

    override func setUp() async throws {
        ProjectorKeyboardRouter.resetDebounceForTesting()
    }

    // MARK: - Helper to construct AudioMeterSnapshot for offline testing

    private func makeSnapshot(
        rms: Float,
        peak: Float,
        spectrum: [Float],
        sampleRate: Double = 44100.0,
        hostTime: UInt64 = 123456789,
        frameCount: UInt32 = 1024,
        fftSize: UInt32 = 1024
    ) -> AudioMeterSnapshot {
        struct SnapshotLayout {
            let rms: Float
            let peak: Float
            let spectrum: [Float]
            let sampleRate: Double
            let hostTime: UInt64
            let frameCount: UInt32
            let fftSize: UInt32
        }
        let layout = SnapshotLayout(
            rms: rms,
            peak: peak,
            spectrum: spectrum,
            sampleRate: sampleRate,
            hostTime: hostTime,
            frameCount: frameCount,
            fftSize: fftSize
        )
        return unsafeBitCast(layout, to: AudioMeterSnapshot.self)
    }

    // MARK: - 1. Mode Enum & Key Mappings

    func testProjectorModeEnumAndKeyMappings() {
        XCTAssertEqual(ProjectorMode.fftVisualizer.rawValue, 1)
        XCTAssertEqual(ProjectorMode.mediaSlideshow.rawValue, 2)
        XCTAssertEqual(ProjectorMode.nowPlaying.rawValue, 3)
        XCTAssertEqual(ProjectorMode.blackout.rawValue, 4)

        XCTAssertEqual(ProjectorMode.allCases.count, 4)
        XCTAssertEqual(ProjectorMode.fftVisualizer.keyLabel, "1")
        XCTAssertEqual(ProjectorMode.mediaSlideshow.keyLabel, "2")
        XCTAssertEqual(ProjectorMode.nowPlaying.keyLabel, "3")
        XCTAssertEqual(ProjectorMode.blackout.keyLabel, "4")

        let vm = ProjectorViewModel()
        XCTAssertEqual(vm.currentMode, .fftVisualizer)

        vm.setMode(.mediaSlideshow)
        XCTAssertEqual(vm.currentMode, .mediaSlideshow)

        vm.setMode(.nowPlaying)
        XCTAssertEqual(vm.currentMode, .nowPlaying)

        vm.setMode(.blackout)
        XCTAssertEqual(vm.currentMode, .blackout)

        vm.teardown()
    }

    // MARK: - 2. Keyboard Router & Repeat / Textfield Suppression

    func testKeyboardRouterModeExtractionFromNSEvent() {
        // Test standard ANSI KeyCodes: 18 -> 1, 19 -> 2, 20 -> 3, 21 -> 4
        let event1 = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "1", charactersIgnoringModifiers: "1",
                                      isARepeat: false, keyCode: 18)!
        let event2 = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "2", charactersIgnoringModifiers: "2",
                                      isARepeat: false, keyCode: 19)!
        let event3 = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "3", charactersIgnoringModifiers: "3",
                                      isARepeat: false, keyCode: 20)!
        let event4 = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "4", charactersIgnoringModifiers: "4",
                                      isARepeat: false, keyCode: 21)!

        XCTAssertEqual(ProjectorKeyboardRouter.mode(for: event1), .fftVisualizer)
        XCTAssertEqual(ProjectorKeyboardRouter.mode(for: event2), .mediaSlideshow)
        XCTAssertEqual(ProjectorKeyboardRouter.mode(for: event3), .nowPlaying)
        XCTAssertEqual(ProjectorKeyboardRouter.mode(for: event4), .blackout)

        // Non-projector keys must return nil (ignored) to preserve T, F1–F8, Space
        let eventT = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "t", charactersIgnoringModifiers: "t",
                                      isARepeat: false, keyCode: 17)!
        let eventSpace = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          characters: " ", charactersIgnoringModifiers: " ",
                                          isARepeat: false, keyCode: 49)!
        XCTAssertNil(ProjectorKeyboardRouter.mode(for: eventT))
        XCTAssertNil(ProjectorKeyboardRouter.mode(for: eventSpace))
    }

    func testKeyboardRouterRepeatSuppressionAndDebounce() {
        let vm = ProjectorViewModel()
        vm.setMode(.fftVisualizer)

        let normalEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           characters: "2", charactersIgnoringModifiers: "2",
                                           isARepeat: false, keyCode: 19)!

        let handled = ProjectorKeyboardRouter.handleNSEvent(normalEvent, viewModel: vm)
        XCTAssertTrue(handled)
        XCTAssertEqual(vm.currentMode, .mediaSlideshow)

        // Repeat event must be swallowed (returns true without changing or retriggering)
        let repeatEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           characters: "3", charactersIgnoringModifiers: "3",
                                           isARepeat: true, keyCode: 20)!
        let repeatHandled = ProjectorKeyboardRouter.handleNSEvent(repeatEvent, viewModel: vm)
        XCTAssertTrue(repeatHandled)
        XCTAssertEqual(vm.currentMode, .mediaSlideshow) // Mode did NOT change because repeat was dropped

        vm.teardown()
    }

    func testKeyboardRouterTextfieldEditingProtection() {
        // When a window has an NSTextField or NSTextView as first responder, isEditingText must return true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let textField = NSTextField(string: "Event Name 2026")
        window.contentView?.addSubview(textField)
        window.makeFirstResponder(textField)

        XCTAssertTrue(ProjectorKeyboardRouter.isEditingText(in: window))

        // When focus is in a textfield, handleNSEvent must return false so digits are typed into text
        let vm = ProjectorViewModel()
        let eventWithWindow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                               characters: "1", charactersIgnoringModifiers: "1",
                                               isARepeat: false, keyCode: 18)!

        let handled = ProjectorKeyboardRouter.handleNSEvent(eventWithWindow, viewModel: vm)
        XCTAssertFalse(handled, "Keyboard router must NOT intercept digits when a textfield is editing")

        vm.teardown()
    }

    // MARK: - 3. Master FFT Frame Projection

    func testMasterFFTProjectionAuthenticData() {
        let analyzer = ProjectorSpectrumAnalyzer()

        // Create 512 linear FFT bins with known energy in bass (bins 2..4 ~ 86..172 Hz)
        var spectrum = Array(repeating: Float(0.0), count: 512)
        spectrum[2] = 0.65
        spectrum[3] = 0.80
        spectrum[4] = 0.50
        spectrum[100] = 0.45 // High frequency energy

        let snapshot = makeSnapshot(
            rms: 0.42,
            peak: 0.85,
            spectrum: spectrum,
            sampleRate: 44100.0,
            hostTime: 123456789
        )

        let frame = analyzer.processSnapshot(snapshot)
        XCTAssertFalse(frame.isSilent)
        XCTAssertEqual(frame.bands.count, 24)
        XCTAssertEqual(frame.rms, 0.42, accuracy: 1e-4)
        XCTAssertEqual(frame.peak, 0.85, accuracy: 1e-4)

        // Bass bands (indices 1..3) must show non-zero amplitude
        let bassEnergy = frame.bands[1] + frame.bands[2] + frame.bands[3]
        XCTAssertGreaterThan(bassEnergy, 0.1)

        // All band amplitudes must remain strictly bounded in [0.0, 1.0]
        for band in frame.bands {
            XCTAssertGreaterThanOrEqual(band, 0.0)
            XCTAssertLessThanOrEqual(band, 1.0)
        }
    }

    // MARK: - 4. FFT Decay on Silence and Stale Snapshot

    func testMasterFFTDecayOnSilenceAndStaleSnapshot() {
        let analyzer = ProjectorSpectrumAnalyzer()

        var spectrum = Array(repeating: Float(0.0), count: 512)
        spectrum[3] = 0.75

        let activeSnapshot = makeSnapshot(
            rms: 0.5,
            peak: 0.9,
            spectrum: spectrum,
            sampleRate: 44100.0,
            hostTime: 1000
        )

        let activeFrame = analyzer.processSnapshot(activeSnapshot)
        XCTAssertFalse(activeFrame.isSilent)
        XCTAssertGreaterThan(activeFrame.bands[2], 0.0)

        // Process nil snapshot -> must decay smoothly toward zero
        let decayFrame1 = analyzer.processSnapshot(nil)
        XCTAssertTrue(decayFrame1.isSilent)
        XCTAssertLessThanOrEqual(decayFrame1.bands[2], activeFrame.bands[2])

        // Multiple nil frames -> decays down to 0.0 completely
        var finalDecayFrame = decayFrame1
        for _ in 0..<50 {
            finalDecayFrame = analyzer.processSnapshot(nil)
        }
        for band in finalDecayFrame.bands {
            XCTAssertEqual(band, 0.0, accuracy: 1e-3, "Bands must cleanly decay to 0 on silence without random noise")
        }

        // Stale snapshot test: If the same hostTime repeats for >= 4 cycles, it is marked stale
        for _ in 0..<5 {
            _ = analyzer.processSnapshot(activeSnapshot)
        }
        let staleFrame = analyzer.processSnapshot(activeSnapshot)
        XCTAssertTrue(staleFrame.isSilent, "Stale audio engine hostTime must trigger honest silence decay")
    }

    // MARK: - 5. Now Playing Metadata Handoff & Deck Determination

    func testNowPlayingDeckDeterminationAndArtistTitleParsing() {
        // Deck A solo playing
        XCTAssertEqual(ProjectorViewModel.determineMasterDeck(isDeckAPlaying: true, isDeckBPlaying: false, crossfaderPosition: 0.5), .deckA)

        // Deck B solo playing
        XCTAssertEqual(ProjectorViewModel.determineMasterDeck(isDeckAPlaying: false, isDeckBPlaying: true, crossfaderPosition: 0.5), .deckB)

        // Both playing: crossfader <= 0.5 favors Deck A
        XCTAssertEqual(ProjectorViewModel.determineMasterDeck(isDeckAPlaying: true, isDeckBPlaying: true, crossfaderPosition: 0.3), .deckA)
        XCTAssertEqual(ProjectorViewModel.determineMasterDeck(isDeckAPlaying: true, isDeckBPlaying: true, crossfaderPosition: 0.5), .deckA)

        // Both playing: crossfader > 0.5 favors Deck B
        XCTAssertEqual(ProjectorViewModel.determineMasterDeck(isDeckAPlaying: true, isDeckBPlaying: true, crossfaderPosition: 0.7), .deckB)

        // Neither playing -> nil
        XCTAssertNil(ProjectorViewModel.determineMasterDeck(isDeckAPlaying: false, isDeckBPlaying: false, crossfaderPosition: 0.5))

        // Artist and Title parsing
        let (artist1, title1) = ProjectorViewModel.parseArtistAndTitle(from: "01_House/Daft Punk - One More Time.mp3")
        XCTAssertEqual(artist1, "Daft Punk")
        XCTAssertEqual(title1, "One More Time")

        let (artist2, title2) = ProjectorViewModel.parseArtistAndTitle(from: "Wedding March.wav")
        XCTAssertEqual(artist2, "PulseDeck AI")
        XCTAssertEqual(title2, "Wedding March")

        let (artist3, title3) = ProjectorViewModel.parseArtistAndTitle(from: "Swedish House Mafia - Don't You Worry Child (Radio Edit).m4a")
        XCTAssertEqual(artist3, "Swedish House Mafia")
        XCTAssertEqual(title3, "Don't You Worry Child (Radio Edit)")
    }

    func testNowPlayingBannerCustomization() {
        let vm = ProjectorViewModel()
        XCTAssertEqual(vm.eventBannerText, "Sarah & Michael's Wedding — October 14, 2026")

        vm.eventBannerText = "Annual Gala 2026 — Grand Ballroom"
        XCTAssertEqual(vm.eventBannerText, "Annual Gala 2026 — Grand Ballroom")

        vm.teardown()
    }

    // MARK: - 6. Media Scanner Filtering, Sorting & Bounded Items

    func testMediaScannerFilteringSortingAndBounds() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulseDeck_Projector_Test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create fixtures
        let validPhotos = ["b_photo.jpg", "a_photo.png", "c_photo.heic"]
        let validVideos = ["z_video.mp4", "m_loop.mov"]
        let ignoredFiles = [".gitkeep", ".DS_Store", "notes.txt", "audio.mp3", "track.wav"]

        for name in validPhotos + validVideos + ignoredFiles {
            let url = tempDir.appendingPathComponent(name)
            try "mock data".write(to: url, atomically: true, encoding: .utf8)
        }

        let discovered = ProjectorMediaService.discoverMediaItems(in: tempDir)

        // Must discover only the 5 valid media files
        XCTAssertEqual(discovered.count, 5)

        // Must be sorted deterministically ascending
        XCTAssertEqual(discovered[0].fileName, "a_photo.png")
        XCTAssertEqual(discovered[0].type, .photo)

        XCTAssertEqual(discovered[1].fileName, "b_photo.jpg")
        XCTAssertEqual(discovered[1].type, .photo)

        XCTAssertEqual(discovered[2].fileName, "c_photo.heic")
        XCTAssertEqual(discovered[2].type, .photo)

        XCTAssertEqual(discovered[3].fileName, "m_loop.mov")
        XCTAssertEqual(discovered[3].type, .video)

        XCTAssertEqual(discovered[4].fileName, "z_video.mp4")
        XCTAssertEqual(discovered[4].type, .video)
    }

    // MARK: - 7. Empty & Corrupt Media Honest Fallback

    func testEmptyAndCorruptMediaHonestFallback() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulseDeck_EmptyCrate_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Only .gitkeep in directory
        let gitkeepURL = tempDir.appendingPathComponent(".gitkeep")
        try "".write(to: gitkeepURL, atomically: true, encoding: .utf8)

        let discovered = ProjectorMediaService.discoverMediaItems(in: tempDir)
        XCTAssertTrue(discovered.isEmpty, "Empty crate with .gitkeep must yield 0 items")

        // Corrupt photo fixture
        let corruptURL = tempDir.appendingPathComponent("corrupt.png")
        try "not a valid png binary header".write(to: corruptURL, atomically: true, encoding: .utf8)

        let downsampled = ProjectorMediaService.downsampleImage(at: corruptURL, maxDimension: 1920)
        XCTAssertNil(downsampled, "Corrupted image file must safely return nil without crashing")
    }

    // MARK: - 8. Stale Root Cancellation & Resource Cleanup

    func testStaleRootCancellationAndResourceCleanup() async throws {
        let service = ProjectorMediaService()
        XCTAssertEqual(service.mediaState, .empty)

        let root1 = FileManager.default.temporaryDirectory.appendingPathComponent("root1_\(UUID().uuidString)")
        let root2 = FileManager.default.temporaryDirectory.appendingPathComponent("root2_\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: root1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root2, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root1)
            try? FileManager.default.removeItem(at: root2)
        }

        // Rapid switches
        service.setLibraryRoot(root1)
        service.setLibraryRoot(root2)

        // Wait briefly for background task
        try await Task.sleep(nanoseconds: 50_000_000)

        // Cleanup
        service.teardown()
        XCTAssertEqual(service.mediaState, .empty)
        XCTAssertNil(service.currentPhoto)
        XCTAssertNil(service.currentVideoPlayer)
    }

    // MARK: - 9. Muted Looping Video Intent & Audio Isolation

    func testMutedLoopingVideoIntent() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulseDeck_VideoTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let videoURL = tempDir.appendingPathComponent("sample.mp4")
        try "dummy video bytes".write(to: videoURL, atomically: true, encoding: .utf8)

        let service = ProjectorMediaService()

        service.loadMedia(at: 0) // Should not crash on invalid index

        // Test AVPlayer direct muted invariant
        let player = AVPlayer(url: videoURL)
        player.isMuted = true
        player.volume = 0.0

        XCTAssertTrue(player.isMuted, "Projector video player MUST be muted")
        XCTAssertEqual(player.volume, 0.0, accuracy: 1e-6, "Projector video volume MUST be 0.0 to prevent Master/Cue leakage")

        service.teardown()
        player.pause()
    }

    // MARK: - 10. Display Enumeration & Fallback Abstraction

    func testDisplayEnumerationAndFallbackAbstraction() {
        let displays = ProjectorWindowController.enumerateDisplays()
        if !NSScreen.screens.isEmpty {
            XCTAssertFalse(displays.isEmpty)
            let selected = ProjectorWindowController.selectPresentationScreen()
            XCTAssertNotNil(selected)
        }

        let vm = ProjectorViewModel()
        let controller = ProjectorWindowController(viewModel: vm)

        // Screen parameters change handler must run safely without crashing
        controller.handleScreenParametersChanged()

        vm.teardown()
    }

    // MARK: - 11. Blackout Behavior & Audio Isolation

    func testBlackoutBehaviorAndAudioIsolation() {
        let vm = ProjectorViewModel()
        XCTAssertEqual(vm.currentMode, .fftVisualizer)

        vm.setMode(.blackout)
        XCTAssertEqual(vm.currentMode, .blackout)

        // In blackout mode, visualizer and media continue idle behavior without mutating audio transport
        XCTAssertEqual(vm.currentMode.id, 4)
        XCTAssertEqual(vm.currentMode.title, "Blackout Screen")

        vm.teardown()
    }
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func offlineState(root: URL) -> AppState {
        AppState(libraryRootURL: root, waveformEditorModel: WaveformEditorModel(libraryRootURL: root),
                 audioCoordinator: AudioEngineCoordinator(hal: MockAudioHardware()), startCoordinator: false)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Timed out waiting for asynchronous production state")
    }

    func testUnchangedNowPlayingDoesNotPublish() throws {
        let state = offlineState(root: try temporaryRoot())
        let vm = ProjectorViewModel()
        defer { vm.teardown() }
        var publications = 0
        let token = vm.$nowPlayingMetadata.dropFirst().sink { _ in publications += 1 }
        vm.updateNowPlaying(from: state)
        vm.updateNowPlaying(from: state)
        XCTAssertEqual(publications, 0, "Unchanged metadata must not invalidate its observer")
        withExtendedLifetime(token) {}
    }

    func testNestedMediaScanForwardsToViewModelObservers() async throws {
        let root = try temporaryRoot()
        let vm = ProjectorViewModel()
        defer { vm.teardown() }
        var publications = 0
        let token = vm.objectWillChange.sink { publications += 1 }
        vm.updateLibraryRoot(root)
        try await waitUntil { !vm.mediaService.isScanning }
        XCTAssertGreaterThan(publications, 0, "Scan changes must invalidate slideshow, banner, and menu observers")
        withExtendedLifetime(token) {}
    }

    func testStartupScanDoesNotCreateHiddenVideoPlayer() async throws {
        let root = try temporaryRoot()
        let media = root.appendingPathComponent(ProjectorMediaService.mediaFolderName)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data().write(to: media.appendingPathComponent("loop.mp4"))
        let vm = ProjectorViewModel()
        defer { vm.teardown() }
        vm.updateLibraryRoot(root)
        try await waitUntil { !vm.mediaService.isScanning }
        XCTAssertEqual(vm.mediaService.items.count, 1)
        XCTAssertNil(vm.mediaService.currentVideoPlayer, "Startup scan must not instantiate a hidden looping player")
    }

    private func writePhoto(_ url: URL) throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        bytes.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    func testSingleMeterPollingOwnerFansOutDestructiveSnapshotsAndCancels() async throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        var rings: [OpaquePointer] = []
        let service = AudioMeteringService(coordinator: coordinator, allocateRingForTesting: {
            let ring = pd_meter_ring_create()
            if let ring { rings.append(ring) }
            return ring
        }, destroyRingForTesting: { pd_meter_ring_destroy($0) })
        try service.start()
        defer { service.stop() }
        let initialFanout = expectation(description: "Both views read the initial shared frame")
        let statusStarted = expectation(description: "Status subscription started")
        let projectorStarted = expectation(description: "Projector subscription started")
        let emptyPoll = expectation(description: "Remaining subscription polls the empty real queue")
        let freshFrame = expectation(description: "Remaining subscription delivers a fresh producer frame")
        let unexpectedPoll = expectation(description: "No poll survives the final consumer")
        unexpectedPoll.isInverted = true
        var masterReads = 0
        var readsBeforeInitialFrame = 0
        var totalReads = 0
        var observeEmptyPoll = false
        var stopped = false
        let distributor = AudioMeterSnapshotDistributor { role in
            totalReads += 1
            if stopped { unexpectedPoll.fulfill() }
            let snapshot = service.drainLatest(for: role)
            if role == .master {
                masterReads += 1
                if observeEmptyPoll, snapshot == nil {
                    observeEmptyPoll = false
                    emptyPoll.fulfill()
                }
            }
            return snapshot
        }
        let vm = ProjectorViewModel()
        defer { vm.teardown() }
        var deliveredFreshFrame: ProjectorVisualizerFrame?
        let masterToken = distributor.$master.sink { snapshot in
            guard snapshot?.hostTime == 300 else { return }
            vm.updateVisualizer(snapshot: snapshot)
            deliveredFreshFrame = vm.visualizerFrame
            freshFrame.fulfill()
        }
        // Cue publishes after Master in the same synchronous poll. Read both views' caches here,
        // before yielding MainActor to another legitimate polling tick.
        let cueToken = distributor.$cue.sink { cue in
            guard cue?.hostTime == 200 else { return }
            guard let statusSnapshot = distributor.master else {
                XCTFail("Master frame must already be cached when Cue publishes")
                return
            }
            vm.updateVisualizer(snapshot: distributor.master)
            XCTAssertEqual(vm.visualizerFrame.rms, statusSnapshot.rms)
            XCTAssertEqual(vm.visualizerFrame.timestamp, statusSnapshot.hostTime)
            XCTAssertEqual(distributor.master, statusSnapshot, "A second view read must not consume the shared frame")
            XCTAssertEqual(cue?.hostTime, 200, "Cue remains independent of Master")
            XCTAssertEqual(masterReads - readsBeforeInitialFrame, 1,
                           "Both active subscriptions must share one fresh-frame drain")
            XCTAssertNil(service.drainLatest(for: .master), "The real transfer queue was drained exactly once")
            initialFanout.fulfill()
        }
        defer { masterToken.cancel(); cueToken.cancel() }
        let statusConsumer = Task {
            statusStarted.fulfill()
            await distributor.observe()
        }
        let projectorConsumer = Task {
            projectorStarted.fulfill()
            await distributor.observe()
        }
        defer { statusConsumer.cancel(); projectorConsumer.cancel() }
        let startupResult = await XCTWaiter.fulfillment(of: [statusStarted, projectorStarted], timeout: 2)
        XCTAssertEqual(startupResult, .completed)
        // Both subscriptions are active before either real producer supplies a frame.
        readsBeforeInitialFrame = masterReads
        let values = [Float](repeating: 0.5, count: 1024)
        XCTAssertTrue(values.withUnsafeBufferPointer {
            pd_meter_ring_push_audio(rings[0], $0.baseAddress, nil, 1, 1024, 44100, 100)
        })
        XCTAssertTrue(values.withUnsafeBufferPointer {
            pd_meter_ring_push_audio(rings[1], $0.baseAddress, nil, 1, 1024, 44100, 200)
        })
        let fanoutResult = await XCTWaiter.fulfillment(of: [initialFanout], timeout: 2)
        XCTAssertEqual(fanoutResult, .completed)
        statusConsumer.cancel()
        await statusConsumer.value
        let readsAfterFirstCancellation = masterReads
        observeEmptyPoll = true
        let emptyResult = await XCTWaiter.fulfillment(of: [emptyPoll], timeout: 2)
        XCTAssertEqual(emptyResult, .completed)
        XCTAssertGreaterThan(masterReads, readsAfterFirstCancellation, "Remaining consumer must keep the polling owner alive")
        XCTAssertNil(distributor.master, "An observed empty destructive-queue poll must clear the cache")
        // A nil cache after an empty poll is valid. A fresh real frame proves liveness instead.
        XCTAssertTrue(values.withUnsafeBufferPointer {
            pd_meter_ring_push_audio(rings[0], $0.baseAddress, nil, 1, 1024, 44100, 300)
        })
        let freshResult = await XCTWaiter.fulfillment(of: [freshFrame], timeout: 2)
        XCTAssertEqual(freshResult, .completed)
        XCTAssertEqual(deliveredFreshFrame?.timestamp, 300)
        XCTAssertEqual(deliveredFreshFrame?.rms, 0.5)
        XCTAssertEqual(deliveredFreshFrame?.isSilent, false)
        projectorConsumer.cancel()
        await projectorConsumer.value
        stopped = true
        let readsAtStop = totalReads
        XCTAssertNil(distributor.master)
        XCTAssertNil(distributor.cue)
        XCTAssertTrue(values.withUnsafeBufferPointer {
            pd_meter_ring_push_audio(rings[0], $0.baseAddress, nil, 1, 1024, 44100, 400)
        })
        XCTAssertTrue(values.withUnsafeBufferPointer {
            pd_meter_ring_push_audio(rings[1], $0.baseAddress, nil, 1, 1024, 44100, 500)
        })
        let stoppedResult = await XCTWaiter.fulfillment(of: [unexpectedPoll], timeout: 0.15)
        XCTAssertEqual(stoppedResult, .completed)
        XCTAssertEqual(totalReads, readsAtStop, "No poll may survive the final consumer")
        XCTAssertEqual(service.drainLatest(for: .master)?.hostTime, 400, "Stopped owner must leave a fresh Master frame unread")
        XCTAssertEqual(service.drainLatest(for: .cue)?.hostTime, 500, "Stopped owner must leave a fresh Cue frame unread")
    }

    func testSharedMeterIdentityAndPureViewConstruction() throws {
        let state = offlineState(root: try temporaryRoot())
        let meters = AudioMeterSnapshotDistributor.shared(for: state)
        XCTAssertTrue(meters === AudioMeterSnapshotDistributor.shared(for: state))
        let otherState = offlineState(root: try temporaryRoot())
        XCTAssertFalse(meters === AudioMeterSnapshotDistributor.shared(for: otherState))
        let vm = ProjectorViewModel()
        defer { vm.teardown() }
        var publications = 0
        let token = vm.objectWillChange.sink { publications += 1 }
        _ = ProjectorSpectrumView(viewModel: vm, appState: state).body
        _ = ProjectorNowPlayingView(viewModel: vm, appState: state).body
        _ = ProjectorWindowView(viewModel: vm, appState: state).body
        _ = AudioMeterStatusView(appState: state).body
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(token) {}
    }

    func testPresentationTaskUpdatesOutsideRenderAndCancels() async throws {
        let state = offlineState(root: try temporaryRoot())
        let vm = ProjectorViewModel()
        defer { vm.teardown() }
        vm.isWindowOpen = true
        // Use a genuine snapshot with energy, then let the production task decay it to silence.
        vm.updateVisualizer(snapshot: makeSnapshot(rms: 0.5, peak: 0.8,
                                                  spectrum: Array(repeating: 0.2, count: 512)))
        var publications = 0
        let token = vm.$visualizerFrame.dropFirst().sink { _ in publications += 1 }
        let updates = Task { await vm.runPresentationUpdates(from: state) }
        try await waitUntil { publications > 0 }
        updates.cancel()
        await updates.value
        let stopped = publications
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertEqual(publications, stopped)
        withExtendedLifetime(token) {}
    }

    func testExplicitRescanFindsAddedAssetButRootSyncDoesNotRescan() async throws {
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent(ProjectorMediaService.mediaFolderName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writePhoto(directory.appendingPathComponent("a.png"))
        let vm = ProjectorViewModel()
        defer { vm.teardown() }
        vm.updateLibraryRoot(root)
        try await waitUntil { !vm.mediaService.isScanning }
        XCTAssertEqual(vm.mediaService.items.count, 1)
        try writePhoto(directory.appendingPathComponent("b.png"))
        vm.updateLibraryRoot(root.appendingPathComponent("."))
        XCTAssertFalse(vm.mediaService.isScanning, "Ordinary same-root synchronization must remain idempotent")
        XCTAssertEqual(vm.mediaService.items.count, 1)
        vm.rescanMedia()
        try await waitUntil { !vm.mediaService.isScanning }
        XCTAssertEqual(vm.mediaService.items.map(\.fileName), ["a.png", "b.png"])
    }

    func testPhotoDecodeAndAutomaticSlideChangesForwardToObservers() async throws {
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent(ProjectorMediaService.mediaFolderName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writePhoto(directory.appendingPathComponent("a.png"))
        try writePhoto(directory.appendingPathComponent("b.png"))
        let vm = ProjectorViewModel(slideshowInterval: .milliseconds(100))
        defer { vm.teardown() }
        vm.updateLibraryRoot(root)
        try await waitUntil { !vm.mediaService.isScanning }
        var publications = 0
        let token = vm.objectWillChange.sink { publications += 1 }
        vm.setMode(.mediaSlideshow)
        vm.isWindowOpen = true
        let beforeDecode = publications
        try await waitUntil { vm.mediaService.currentPhoto != nil }
        XCTAssertGreaterThan(publications, beforeDecode, "The actual background decode must invalidate parent observers")
        let beforeSlide = publications
        try await waitUntil { vm.mediaService.currentIndex == 1 }
        XCTAssertGreaterThan(publications, beforeSlide, "Automatic slideshow task must invalidate parent observers")
        vm.isWindowOpen = false
        XCTAssertFalse(vm.isSlideshowRunning)
        XCTAssertNil(vm.mediaService.currentPhoto)
        let stoppedIndex = vm.mediaService.currentIndex
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(vm.mediaService.currentIndex, stoppedIndex)
        withExtendedLifetime(token) {}
    }

    private func key(_ character: String, in window: NSWindow, repeatKey: Bool = false) throws -> NSEvent {
        let codes: [String: UInt16] = ["1": 18, "2": 19, "3": 20, "4": 21]
        return try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character,
            isARepeat: repeatKey, keyCode: codes[character] ?? 0))
    }

    func testActualProjectorWindowRoutesEveryModeAndPreservesTextEditing() throws {
        let state = offlineState(root: try temporaryRoot())
        let vm = ProjectorViewModel()
        defer { vm.teardown() }
        vm.showWindow(appState: state)
        let window = try XCTUnwrap(NSApplication.shared.windows.first {
            $0 is ProjectorPresentationWindow && $0.isVisible
        })
        window.makeKeyAndOrderFront(nil)
        XCTAssertNotNil(window.contentView)
        for character in ["2", "3", "4", "1"] {
            window.sendEvent(try key(character, in: window))
            XCTAssertEqual(vm.currentMode.rawValue, Int(character))
        }
        window.sendEvent(try key("4", in: window, repeatKey: true))
        XCTAssertEqual(vm.currentMode, .fftVisualizer, "Held keys must not switch modes")
        var changes = 0
        let token = vm.$currentMode.dropFirst().sink { _ in changes += 1 }
        window.sendEvent(try key("2", in: window))
        window.sendEvent(try key("2", in: window))
        XCTAssertEqual(changes, 1, "Duplicate dispatch must not publish or restart a mode")
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        let container = NSView(frame: window.contentView?.frame ?? .zero)
        if let hostedView = window.contentView { container.addSubview(hostedView) }
        container.addSubview(editor)
        window.contentView = container
        XCTAssertTrue(window.makeFirstResponder(editor))
        window.sendEvent(try key("3", in: window))
        XCTAssertEqual(vm.currentMode, .mediaSlideshow)
        XCTAssertEqual(editor.string, "3", "Digit must reach the actual AppKit text editor")
        withExtendedLifetime(token) {}
    }

    func testVideoAndTimerLifecycleUsesActualWindowCloseAndReopen() async throws {
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent(ProjectorMediaService.mediaFolderName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("loop.mp4"))
        let state = offlineState(root: root)
        let vm = ProjectorViewModel()
        defer { vm.teardown() }
        vm.updateLibraryRoot(root)
        try await waitUntil { !vm.mediaService.isScanning }
        vm.setMode(.mediaSlideshow)
        XCTAssertNil(vm.mediaService.currentVideoPlayer)
        XCTAssertFalse(vm.isSlideshowRunning)
        vm.showWindow(appState: state)
        let firstPlayer = try XCTUnwrap(vm.mediaService.currentVideoPlayer)
        XCTAssertTrue(firstPlayer.isMuted)
        XCTAssertEqual(firstPlayer.volume, 0)
        XCTAssertTrue(vm.isSlideshowRunning)
        vm.setMode(.blackout)
        XCTAssertNil(vm.mediaService.currentVideoPlayer)
        XCTAssertEqual(firstPlayer.rate, 0)
        XCTAssertFalse(vm.isSlideshowRunning)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: firstPlayer.currentItem)
        await Task.yield()
        XCTAssertEqual(firstPlayer.rate, 0, "A stale loop notification must not restart an inactive player")
        vm.setMode(.mediaSlideshow)
        let secondPlayer = try XCTUnwrap(vm.mediaService.currentVideoPlayer)
        XCTAssertFalse(secondPlayer === firstPlayer)
        // Native close exercises the delegate path, rather than just a view-model flag.
        let window = try XCTUnwrap(NSApplication.shared.windows.first {
            $0 is ProjectorPresentationWindow && $0.isVisible
        })
        window.close()
        XCTAssertFalse(vm.isWindowOpen)
        XCTAssertNil(vm.mediaService.currentVideoPlayer)
        XCTAssertFalse(vm.isSlideshowRunning)
        XCTAssertNil(window.contentView)
        vm.showWindow(appState: state)
        XCTAssertTrue(vm.isWindowOpen)
        XCTAssertTrue(vm.isSlideshowRunning)
        let reopenedPlayer = try XCTUnwrap(vm.mediaService.currentVideoPlayer)
        XCTAssertFalse(reopenedPlayer === secondPlayer)
        XCTAssertTrue(reopenedPlayer.isMuted)
        vm.closeWindow()
        XCTAssertNil(vm.mediaService.currentVideoPlayer)
    }

    func testStaleRootAndCloseCancelRealScanAndPhotoWork() async throws {
        let root1 = try temporaryRoot()
        let root2 = try temporaryRoot()
        for root in [root1, root2] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(ProjectorMediaService.mediaFolderName),
                withIntermediateDirectories: true)
        }
        try writePhoto(root1.appendingPathComponent(ProjectorMediaService.mediaFolderName).appendingPathComponent("old.png"))
        try writePhoto(root2.appendingPathComponent(ProjectorMediaService.mediaFolderName).appendingPathComponent("new.png"))
        let vm = ProjectorViewModel()
        defer { vm.teardown() }
        vm.setMode(.mediaSlideshow)
        vm.isWindowOpen = true
        vm.updateLibraryRoot(root1)
        vm.updateLibraryRoot(root2)
        try await waitUntil { !vm.mediaService.isScanning && vm.mediaService.currentPhoto != nil }
        XCTAssertEqual(vm.mediaService.items.map(\.fileName), ["new.png"])
        vm.rescanMedia()
        vm.isWindowOpen = false
        XCTAssertFalse(vm.mediaService.isScanning)
        XCTAssertNil(vm.mediaService.currentPhoto)
        vm.isWindowOpen = true
        try await waitUntil { !vm.mediaService.isScanning && vm.mediaService.currentPhoto != nil }
        XCTAssertEqual(vm.mediaService.items.map(\.fileName), ["new.png"])
        vm.teardown()
        await Task.yield()
        XCTAssertNil(vm.mediaService.currentPhoto)
        XCTAssertNil(vm.mediaService.currentVideoPlayer)
        XCTAssertFalse(vm.mediaService.isScanning)
    }

    func testInactiveResourcesDoNotRetainModelsOrAppState() throws {
        var state: AppState? = offlineState(root: try temporaryRoot())
        weak var weakState = state
        let meters = AudioMeterSnapshotDistributor.shared(for: try XCTUnwrap(state))
        state = nil
        XCTAssertNil(weakState, "The per-AppState meter cache must not retain the audio owner")
        withExtendedLifetime(meters) {}
        var vm: ProjectorViewModel? = ProjectorViewModel()
        weak var weakModel = vm
        weak var weakMedia = vm?.mediaService
        vm?.isWindowOpen = true
        vm?.setMode(.mediaSlideshow)
        vm = nil
        XCTAssertNil(weakModel, "Slideshow task and media forwarding must not retain the model")
        XCTAssertNil(weakMedia, "No player observer or decode task may retain inactive media services")
    }

    func testToolbarRescanDiscoversPhotoAddedAfterCompletedStartupScan() async throws {
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent(ProjectorMediaService.mediaFolderName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writePhoto(directory.appendingPathComponent("a.png"))
        let state = offlineState(root: root)
        let vm = ProjectorViewModel()
        defer { vm.teardown() }
        state.refreshLibrary()
        vm.updateLibraryRoot(root)
        try await waitUntil { !state.isScanning && !vm.mediaService.isScanning }
        XCTAssertEqual(vm.mediaService.items.map(\.fileName), ["a.png"])
        try writePhoto(directory.appendingPathComponent("b.png"))
        // This is the exact stored action passed to Button(action:) by the production toolbar.
        let toolbar = StatusHeaderView(appState: state, projectorViewModel: vm)
        var mediaScans = 0
        let token = vm.mediaService.$isScanning.dropFirst().filter { $0 }.sink { _ in mediaScans += 1 }
        toolbar.rescanLibrary()
        XCTAssertTrue(state.isScanning, "Toolbar action must refresh the library as well as media")
        XCTAssertTrue(vm.mediaService.isScanning, "Toolbar action must explicitly refresh unchanged-root media")
        toolbar.rescanLibrary() // Duplicate Cmd-R route while scanning must be ignored.
        XCTAssertEqual(mediaScans, 1, "One user action must not start duplicate media scans")
        try await waitUntil { !state.isScanning && !vm.mediaService.isScanning }
        XCTAssertEqual(vm.mediaService.items.map(\.fileName), ["a.png", "b.png"])
        withExtendedLifetime(token) {}
    }

    func testCorruptVideoPublishesFallbackAndReleasesActualPlayer() async throws {
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent(ProjectorMediaService.mediaFolderName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a valid video container".utf8).write(to: directory.appendingPathComponent("corrupt.mp4"))
        let service = ProjectorMediaService()
        defer { service.teardown() }
        service.setPresentationActive(true)
        service.setLibraryRoot(root)
        try await waitUntil {
            if case .error = service.mediaState { return true }
            return false
        }
        XCTAssertNil(service.currentVideoPlayer, "Failed AVPlayerItem must release its active player and loop observers")
        XCTAssertFalse(service.isScanning)
    }

    func testLateDecodedPhotosStartAnimationOnlyAfterEachImageMounts() async throws {
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent(ProjectorMediaService.mediaFolderName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writePhoto(directory.appendingPathComponent("a.png"))
        try writePhoto(directory.appendingPathComponent("b.png"))
        let service = ProjectorMediaService()
        defer { service.teardown() }
        let firstAnimation = ProjectorPhotoAnimation()
        let secondAnimation = ProjectorPhotoAnimation()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let hosted = NSHostingView(rootView: AnyView(ProgressView()))
        window.contentView = hosted
        window.makeKeyAndOrderFront(nil)
        hosted.layoutSubtreeIfNeeded()
        service.setPresentationActive(true)
        service.setLibraryRoot(root)
        try await waitUntil { service.currentPhoto != nil }
        XCTAssertEqual(firstAnimation.scale, 1, "A loading parent must not start an unmounted image's motion")
        let firstImage = try XCTUnwrap(service.currentPhoto)
        let firstID = try XCTUnwrap(service.items.first?.id)
        hosted.rootView = AnyView(ProjectorPhotoView(image: firstImage, mediaID: firstID,
                                                   animation: firstAnimation).id(firstID))
        hosted.layoutSubtreeIfNeeded()
        hosted.display()
        try await waitUntil { firstAnimation.scale > 1 }
        service.nextMediaItem()
        try await waitUntil { service.currentPhoto != nil }
        XCTAssertEqual(secondAnimation.scale, 1)
        let secondImage = try XCTUnwrap(service.currentPhoto)
        let secondID = service.items[service.currentIndex].id
        XCTAssertNotEqual(secondID, firstID)
        hosted.rootView = AnyView(ProjectorPhotoView(image: secondImage, mediaID: secondID,
                                                   animation: secondAnimation).id(secondID))
        hosted.layoutSubtreeIfNeeded()
        hosted.display()
        try await waitUntil { secondAnimation.scale > 1 && firstAnimation.scale == 1 }
        window.contentView = nil
        // Unmounting a decoded image must cancel/reset its animation state too.
        hosted.rootView = AnyView(EmptyView())
        try await waitUntil { secondAnimation.scale == 1 }
    }

    func testVideoFailureCallbacksCannotOverrideNewRootOrClosedPresentation() async throws {
        let videoRoot = try temporaryRoot()
        let photoRoot = try temporaryRoot()
        for root in [videoRoot, photoRoot] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(ProjectorMediaService.mediaFolderName),
                withIntermediateDirectories: true)
        }
        try Data("corrupt video".utf8).write(to: videoRoot.appendingPathComponent(
            ProjectorMediaService.mediaFolderName).appendingPathComponent("bad.mp4"))
        try writePhoto(photoRoot.appendingPathComponent(ProjectorMediaService.mediaFolderName).appendingPathComponent("new.png"))
        let service = ProjectorMediaService()
        defer { service.teardown() }
        service.setLibraryRoot(videoRoot)
        try await waitUntil { !service.isScanning }
        service.setPresentationActive(true)
        let oldPlayer = try XCTUnwrap(service.currentVideoPlayer)
        let oldItem = try XCTUnwrap(oldPlayer.currentItem)
        service.setLibraryRoot(photoRoot) // Cancels observations before the asynchronous failure is delivered.
        try await waitUntil { service.currentPhoto != nil }
        XCTAssertEqual(service.items.map(\.fileName), ["new.png"])
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: oldItem)
        await Task.yield()
        XCTAssertTrue(service.mediaState.isReady)
        XCTAssertNotNil(service.currentPhoto)
        service.setPresentationActive(false)
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: oldItem)
        await Task.yield()
        XCTAssertNil(service.currentVideoPlayer)
        XCTAssertNil(service.currentPhoto)
        XCTAssertTrue(service.mediaState.isReady, "Closed presentation must reject obsolete failure callbacks")
    }

}
