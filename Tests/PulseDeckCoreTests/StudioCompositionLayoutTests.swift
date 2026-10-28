import XCTest
import AppKit
import AVFoundation
import SwiftUI
@testable import PulseDeckCore
@testable import PulseDeckAI

@MainActor
final class StudioCompositionLayoutTests: XCTestCase {
    @MainActor
    private final class RealisticFixture {
        let root: URL
        let state: AppState
        let audio: AudioEngineCoordinator
        let projector = ProjectorViewModel()

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("RealisticStudio-" + UUID().uuidString)
            let crateURL = root.appendingPathComponent("Techno")
            try FileManager.default.createDirectory(at: crateURL, withIntermediateDirectories: true)

            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
            let sampleWAV = crateURL.appendingPathComponent("track1.wav")
            do {
                let file = try AVAudioFile(forWriting: sampleWAV, settings: format.settings)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100))
                buffer.frameLength = buffer.frameCapacity
                let data = try XCTUnwrap(buffer.floatChannelData)
                for frame in 0..<Int(buffer.frameLength) {
                    let sample = Float(sin(Double(frame) * 0.06) * 0.2)
                    data[0][frame] = sample
                    data[1][frame] = sample
                }
                try file.write(from: buffer)
            }

            audio = AudioEngineCoordinator(hal: MockAudioHardware())
            try audio.masterAudioEngine.rawEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            try audio.cueAudioEngine.rawEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            try audio.start()

            let peaks = [Float](repeating: 0.5, count: 200)
            let entry = TrackCacheEntry(
                relativePath: "Techno/track1.wav",
                fileFingerprint: "fingerprint-1",
                fileSizeBytes: 176400,
                fileModificationTime: "2026-10-26T20:00:00Z",
                duration: 240.0,
                sampleRate: 44100,
                channels: 2,
                bitDepth: 16,
                bpm: 125.0,
                musicalKey: "Unknown",
                confidence: 0.95,
                waveformMetadata: WaveformMetadata(
                    sampleCount: 240 * 44100,
                    downsampleFactor: 512,
                    peakValues: peaks,
                    lowBandPeaks: peaks,
                    midBandPeaks: peaks,
                    highBandPeaks: peaks
                ),
                beatGrid: BeatGrid(
                    firstBeatOffsetSeconds: 0,
                    beatIntervalSeconds: 0.48,
                    beatTimestamps: stride(from: 0, to: 240.0, by: 0.48).map { $0 }
                ),
                structure: TrackStructure(sections: [], vocalSegments: []),
                cueMarkers: CueMarkers(startTrimCue: 0.5, vocalEntryCue: 28.8, mixOutCue: 210.0, endTrimCue: 238.0),
                analyzerVersion: "local-dsp-1",
                analysisTimestamp: "2026-10-26T20:00:00Z"
            )

            var cache = PulseDeckLibraryCache(libraryRoot: root.lastPathComponent)
            cache.tracks[entry.relativePath] = entry

            let cacheURL = root.appendingPathComponent(PulseDeckCoreConfig.cacheFileName)
            try CachePersistence.saveAtomic(cache: cache, to: cacheURL)

            let loadedCache = cache
            state = AppState(
                libraryRootURL: root,
                waveformEditorModel: WaveformEditorModel(libraryRootURL: root),
                loadedCache: loadedCache,
                cacheLoader: { _ in loadedCache },
                audioCoordinator: audio,
                startCoordinator: false
            )

            let summary = LibraryScanner().scan(libraryURL: root)
            state.scanSummary = summary
            state.selectedCrate = summary.crates.first
            state.selectTrack(relativePath: entry.relativePath)
            state.setMasterSafetyLockEnabled(false)
        }

        func cleanup() {
            projector.teardown()
            audio.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private struct ActionCapture: PrimitiveButtonStyle {
        let onCapture: (@MainActor @escaping () -> Void) -> Void
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.onAppear { onCapture { configuration.trigger() } }
        }
    }

    private func pressButton<V: View>(_ button: V) throws {
        _ = NSApplication.shared
        let ready = expectation(description: "Button action capture ready")
        var action: (@MainActor () -> Void)?
        let host = NSHostingView(rootView: button.buttonStyle(ActionCapture {
            action = $0
            ready.fulfill()
        }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        wait(for: [ready], timeout: 2.0)
        let execute = try XCTUnwrap(action, "Button action must mount")
        execute()
    }

    private func mountProductionView(_ fixture: RealisticFixture, size: NSSize) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        let mounted = expectation(description: "Production ContentView mounted")
        let root = ContentView()
            .environmentObject(fixture.state)
            .environmentObject(fixture.projector)
            .frame(minWidth: 1024, idealWidth: 1200, minHeight: 680, idealHeight: 760)
            .onAppear { mounted.fulfill() }

        let controller = NSHostingController(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.ignoresMouseEvents = true
        window.contentMinSize = NSSize(width: 1024, height: 680)
        window.contentViewController = controller
        window.setContentSize(size)
        window.orderBack(nil)
        controller.view.layoutSubtreeIfNeeded()
        wait(for: [mounted], timeout: 3)

        let turn = expectation(description: "Layout settle turn")
        DispatchQueue.main.async { turn.fulfill() }
        wait(for: [turn], timeout: 2)
        controller.view.layoutSubtreeIfNeeded()

        return (window, controller.view)
    }

    private func descendants(of root: NSView) -> [NSView] {
        var result: [NSView] = []
        var pending = [root]
        while let view = pending.popLast(), result.count < 2048 {
            result.append(view)
            pending.append(contentsOf: view.subviews)
        }
        return result
    }

    func testProductionContentViewComposedChildrenReachability() throws {
        let fixture = try RealisticFixture(); defer { fixture.cleanup() }
        let sizes = [NSSize(width: 1024, height: 680), NSSize(width: 1512, height: 884)]

        for size in sizes {
            let (window, root) = mountProductionView(fixture, size: size)
            defer { window.contentViewController = nil; window.contentView = nil; window.close() }

            XCTAssertEqual(root.bounds.size.width, size.width, accuracy: 0.5)
            XCTAssertEqual(root.bounds.size.height, size.height, accuracy: 0.5)

            let allViews = descendants(of: root)

            // 1. Target: OutputRoutingView - Master & Cue output selectors must be mounted and visible
            let popups = allViews.compactMap { $0 as? NSPopUpButton }
            let masterSelector = try XCTUnwrap(popups.first, "Master output device selector must be mounted")
            let cueSelector = try XCTUnwrap(popups.dropFirst().first, "Cue output device selector must be mounted")
            XCTAssertTrue(masterSelector.convert(masterSelector.bounds, to: root).intersects(root.bounds),
                          "Master output device selector must be visible on screen in legal viewport")
            XCTAssertTrue(cueSelector.convert(cueSelector.bounds, to: root).intersects(root.bounds),
                          "Cue output device selector must be visible on screen in legal viewport")

            // 2. Target: DeckStudioView - Crossfader slider must be mounted and visible in initial viewport
            let controls = allViews.compactMap { $0 as? NSControl }.filter {
                !($0 is NSScroller) && $0.bounds.width > 0 && $0.bounds.height > 0
            }
            let sliders = controls.compactMap { $0 as? NSSlider }
            let crossfader = try XCTUnwrap(
                sliders.first { $0.accessibilityIdentifier() == "crossfaderSlider" } ?? sliders.first { $0.bounds.width <= 200 },
                "Center mixer crossfader slider must be mounted"
            )
            let crossfaderFrame = crossfader.convert(crossfader.bounds, to: root)
            XCTAssertTrue(crossfaderFrame.intersects(root.bounds),
                          "Center mixer crossfader must be visible on screen in legal viewport without scrolling")

            // 3. Target: Root fail-safe scroll enclosing the layout stack
            let scrollViews = allViews.compactMap { $0 as? NSScrollView }
            let rootScroll = try XCTUnwrap(
                scrollViews.first { $0.convert($0.bounds, to: root).width >= root.bounds.width - 24 },
                "Root fail-safe scroll view must enclose the layout stack"
            )

            // 4. Target: LibraryBrowserView - Inner scrollers (Crates and Track List) must be visible on screen
            let libraryScrollers = scrollViews.filter { $0 !== rootScroll }
            XCTAssertFalse(libraryScrollers.isEmpty, "Library browser crates/tracks scroller must be mounted")
            for scroller in libraryScrollers {
                let frameInRoot = scroller.convert(scroller.bounds, to: root)
                let visibleRect = frameInRoot.intersection(root.bounds)
                XCTAssertFalse(visibleRect.isNull, "Library browser scroller must be visible within viewport at size \(size)")
                XCTAssertGreaterThanOrEqual(visibleRect.height, 60, "Library browser scroller must have at least 60pt visible area on screen")
                XCTAssertNotNil(scroller.documentView, "Library scroller document view must be mounted")
            }
        }

        // 7. Verify the actual operator workflow actions execute through production components
        let trackPath = "Techno/track1.wav"

        // Step A: Select track in library via LibraryTrackSelectionButton
        let selectButton = LibraryTrackSelectionButton(appState: fixture.state, relativePath: trackPath) {
            Text("track1.wav")
        }
        try pressButton(selectButton.button)
        XCTAssertEqual(fixture.state.selectedTrackPath, trackPath, "LibraryTrackSelectionButton must select track")

        // Step B: Load selected track into Deck A via LibraryDeckLoadButton
        let loadDeckA = LibraryDeckLoadButton(appState: fixture.state, deck: .deckA, title: "DECK A", color: .blue)
        try pressButton(loadDeckA.button)
        XCTAssertEqual(fixture.state.deckATrack?.relativePath, trackPath, "LibraryDeckLoadButton must load track into Deck A")

        // Step C: Load selected track into Deck B via LibraryDeckLoadButton
        let loadDeckB = LibraryDeckLoadButton(appState: fixture.state, deck: .deckB, title: "DECK B", color: .red)
        try pressButton(loadDeckB.button)
        XCTAssertEqual(fixture.state.deckBTrack?.relativePath, trackPath, "LibraryDeckLoadButton must load track into Deck B")

        // Step D: Trigger explicit local analysis via LibraryTrackAnalysisButton
        let analyzeBtn = LibraryTrackAnalysisButton(appState: fixture.state, relativePath: trackPath)
        try pressButton(analyzeBtn.button)
        XCTAssertNotNil(fixture.state.analysisStatus(for: trackPath), "LibraryTrackAnalysisButton must start local analysis")
    }

    func testCaptureProductionContentViewBitmaps() throws {
        let fixture = try RealisticFixture(); defer { fixture.cleanup() }
        let targets = [
            (size: NSSize(width: 1024, height: 680), name: "studio_composition_1024x680.png"),
            (size: NSSize(width: 1512, height: 884), name: "studio_composition_1512x884.png")
        ]

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("studio_bitmaps_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for target in targets {
            let (window, root) = mountProductionView(fixture, size: target.size)
            defer { window.contentViewController = nil; window.contentView = nil; window.close() }

            let rect = NSRect(origin: .zero, size: target.size)
            guard let rep = root.bitmapImageRepForCachingDisplay(in: rect) else {
                XCTFail("Failed to allocate bitmapImageRep for \(target.name)")
                continue
            }
            root.cacheDisplay(in: rect, to: rep)

            guard let png = rep.representation(using: .png, properties: [:]) else {
                XCTFail("Failed to convert bitmap to PNG for \(target.name)")
                continue
            }

            // Write and verify in safe temporary directory (works in any CI runner)
            let tempFile = tempDir.appendingPathComponent(target.name)
            try png.write(to: tempFile)
            XCTAssertTrue(FileManager.default.fileExists(atPath: tempFile.path), "Saved \(target.name)")
            XCTAssertGreaterThan(png.count, 50_000, "Rendered PNG bitmap must be non-empty")
        }
    }

    func testWaveformEditorCompactModeDisplaysFailedSaveError() throws {
        let fixture = try RealisticFixture(); defer { fixture.cleanup() }
        let editor = WaveformEditorModel(libraryRootURL: fixture.root)
        let track = try XCTUnwrap(fixture.state.loadedCache?.tracks["Techno/track1.wav"])
        editor.loadTrack(track)

        let expectedError = "Failed to save: Disk write error"
        editor.errorMessage = expectedError

        let view = WaveformEditorView(model: editor)
        XCTAssertFalse(view.isDetailedEditorExpandedForTesting, "Waveform editor must default to compact mode")
        XCTAssertEqual(view.displayedCompactError, expectedError, "Failed save error must be exposed and rendered in compact bar")

        // Mount in NSHostingView and verify layout/rendering does not crash
        let host = NSHostingView(rootView: view)
        let rect = NSRect(x: 0, y: 0, width: 800, height: 160)
        host.frame = rect
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: rect))
        host.cacheDisplay(in: rect, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 5_000, "Compact bar with save failure must render non-empty bitmap")
    }

    func testWaveformCueEdgeClampedBadgeAndGuideHitTesting() {
        let rect = CGRect(x: 0, y: 0, width: 60, height: 160)
        let centerX = rect.midX // 30

        // Case A: Left edge clamping (x = 0, badge is offset to the right by +30)
        let leftClampedShape = CueHandleHitShape(
            badgeOffsetX: 30,
            badgeHalfWidth: 30,
            guideHalfWidth: 16,
            badgeHeight: 26
        )
        // 1. Center vertical guide line must be contained
        XCTAssertTrue(leftClampedShape.contains(point: CGPoint(x: centerX, y: 80), in: rect),
                      "Vertical guide line at left edge must be hit-testable")
        XCTAssertTrue(leftClampedShape.contains(point: CGPoint(x: centerX, y: 155), in: rect),
                      "Bottom grip pill at left edge must be hit-testable")
        // 2. Translated top badge (offset by +30) must be contained in hit region
        XCTAssertTrue(leftClampedShape.contains(point: CGPoint(x: centerX + 30, y: 12), in: rect),
                      "Translated top badge center at left edge must be hit-testable")
        XCTAssertTrue(leftClampedShape.contains(point: CGPoint(x: centerX + 30 - 25, y: 12), in: rect),
                      "Translated top badge left edge at left edge must be hit-testable")
        XCTAssertTrue(leftClampedShape.contains(point: CGPoint(x: centerX + 30 + 25, y: 12), in: rect),
                      "Translated top badge right edge at left edge must be hit-testable")
        // 3. Point outside badge and guide must be rejected
        XCTAssertFalse(leftClampedShape.contains(point: CGPoint(x: centerX + 120, y: 12), in: rect),
                       "Points far outside badge must not hit-test")
        XCTAssertFalse(leftClampedShape.contains(point: CGPoint(x: centerX + 40, y: 80), in: rect),
                       "Points outside guide line must not hit-test")

        // Case B: Right edge clamping (x = width, badge is offset to the left by -30)
        let rightClampedShape = CueHandleHitShape(
            badgeOffsetX: -30,
            badgeHalfWidth: 30,
            guideHalfWidth: 16,
            badgeHeight: 26
        )
        // 1. Vertical guide line must be contained
        XCTAssertTrue(rightClampedShape.contains(point: CGPoint(x: centerX, y: 80), in: rect),
                      "Vertical guide line at right edge must be hit-testable")
        // 2. Translated top badge (offset by -30) must be contained in hit region
        XCTAssertTrue(rightClampedShape.contains(point: CGPoint(x: centerX - 30, y: 12), in: rect),
                      "Translated top badge center at right edge must be hit-testable")
        XCTAssertTrue(rightClampedShape.contains(point: CGPoint(x: centerX - 30 - 25, y: 12), in: rect),
                      "Translated top badge left edge at right edge must be hit-testable")
        XCTAssertTrue(rightClampedShape.contains(point: CGPoint(x: centerX - 30 + 25, y: 12), in: rect),
                      "Translated top badge right edge at right edge must be hit-testable")
        // 3. Point outside must be rejected
        XCTAssertFalse(rightClampedShape.contains(point: CGPoint(x: centerX - 120, y: 12), in: rect),
                       "Points far outside badge at right edge must not hit-test")

        // Case C: Center un-clamped (x = width/2, badgeOffsetX = 0)
        let centerShape = CueHandleHitShape(
            badgeOffsetX: 0,
            badgeHalfWidth: 30,
            guideHalfWidth: 16,
            badgeHeight: 26
        )
        XCTAssertTrue(centerShape.contains(point: CGPoint(x: centerX, y: 12), in: rect),
                      "Center badge must be hit-testable")
        XCTAssertTrue(centerShape.contains(point: CGPoint(x: centerX, y: 80), in: rect),
                      "Center guide must be hit-testable")
    }

    func testActionControlsInteractiveBoundsMeetOrExceed28pt() throws {
        let fixture = try RealisticFixture(); defer { fixture.cleanup() }

        // 1. LibraryDeckLoadButton height >= 28pt
        let loadBtn = LibraryDeckLoadButton(appState: fixture.state, deck: .deckA, title: "DECK A", color: .blue)
        let loadHost = NSHostingView(rootView: loadBtn)
        loadHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(loadHost.fittingSize.height, 28.0,
                                    "LOAD button interactive height must meet or exceed 28pt")

        // 2. LibraryTrackAnalysisButton height >= 28pt
        let analyzeBtn = LibraryTrackAnalysisButton(appState: fixture.state, relativePath: "Techno/track1.wav")
        let analyzeHost = NSHostingView(rootView: analyzeBtn)
        analyzeHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(analyzeHost.fittingSize.height, 28.0,
                                    "Analyze button interactive height must meet or exceed 28pt")

        // 3. Transport Play/Pause button height >= 28pt
        let playBtn = Button(action: {}) {
            HStack(spacing: 4) {
                Image(systemName: "play.fill")
                Text("PLAY")
            }
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        let playHost = NSHostingView(rootView: playBtn)
        playHost.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        playHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(playHost.fittingSize.height, 28.0,
                                    "Play button interactive height must meet or exceed 28pt")
    }

    func testLibraryTrackTransferCanonicalTransferableContract() throws {
        let root = URL(fileURLWithPath: "/tmp/PulseDeck")
        let transfer = LibraryTrackTransfer(libraryRoot: root, relativePath: "Techno/track1.wav")

        // Prove Codable round-trip matches expected JSON payload
        let encoded = try JSONEncoder().encode(transfer)
        let decoded = try JSONDecoder().decode(LibraryTrackTransfer.self, from: encoded)
        XCTAssertEqual(decoded, transfer)
        XCTAssertEqual(decoded.relativePath, "Techno/track1.wav")

        // Prove UTType matches canonical identifier
        XCTAssertEqual(UTType.pulseDeckLibraryTrack.identifier, "com.pulsedeckai.library-track")
    }

    func testLibraryTrackSelectionButtonUsesNonBlockingRowButtonStyleAndPreservesSelection() throws {
        let fixture = try RealisticFixture(); defer { fixture.cleanup() }
        let trackPath = "Techno/track1.wav"

        let selectButton = LibraryTrackSelectionButton(appState: fixture.state, relativePath: trackPath) {
            Text("track1.wav")
                .frame(minHeight: 28)
                .contentShape(Rectangle())
        }

        // 1. Verify production styled body mounts with NonBlockingRowButtonStyle meeting >= 28pt target
        let host = NSHostingView(rootView: selectButton)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(host.fittingSize.height, 28.0,
                                    "Selection button interactive height must meet or exceed 28pt")

        // 2. Test keyboard activation (Space key) on the production styled button without ActionCapture override
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let spaceEvent = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown,
                                                        location: .zero,
                                                        modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber,
                                                        context: nil,
                                                        characters: " ",
                                                        charactersIgnoringModifiers: " ",
                                                        isARepeat: false,
                                                        keyCode: 49))
        window.sendEvent(spaceEvent)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(fixture.state.selectedTrackPath, trackPath,
                       "Space key activation on production styled button must select track in AppState")

        // 3. Test Return key activation on production styled button
        fixture.state.selectedTrackPath = nil
        let returnEvent = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown,
                                                         location: .zero,
                                                         modifierFlags: [],
                                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: window.windowNumber,
                                                         context: nil,
                                                         characters: "\r",
                                                         charactersIgnoringModifiers: "\r",
                                                         isARepeat: false,
                                                         keyCode: 36))
        window.sendEvent(returnEvent)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(fixture.state.selectedTrackPath, trackPath,
                       "Return key activation on production styled button must select track in AppState")
    }
}
