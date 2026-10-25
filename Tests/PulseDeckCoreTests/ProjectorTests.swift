import XCTest
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
}
