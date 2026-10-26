import XCTest
import AppKit
import SwiftUI
@testable import PulseDeckCore
@testable import PulseDeckAI

/// Real-composition layout tests proving that actual production children fit and remain reachable
/// at legal minimum (1024x680) and standard (1512x884) viewports.
@MainActor
final class StudioCompositionLayoutTests: XCTestCase {
    @MainActor
    private final class RealisticFixture {
        let root: URL
        let state: AppState
        let projector = ProjectorViewModel()

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("StudioLayout-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

            // Create sample crates with dummy audio files
            let houseCrate = root.appendingPathComponent("01_House")
            try FileManager.default.createDirectory(at: houseCrate, withIntermediateDirectories: false)
            let dummyAudio = houseCrate.appendingPathComponent("Track_01.wav")
            try Data(repeating: 0, count: 1024).write(to: dummyAudio)

            // Setup cache entry with honest real-world limits (key Unknown, heuristic cues)
            var cache = PulseDeckLibraryCache(libraryRoot: root.lastPathComponent)
            let peaks = [Float](repeating: 0.5, count: 200)
            let entry = TrackCacheEntry(
                relativePath: "01_House/Track_01.wav",
                fileFingerprint: "fixture",
                fileSizeBytes: 10_000,
                fileModificationTime: "2026-10-26T20:00:00Z",
                duration: 240.0,
                sampleRate: 44_100,
                channels: 2,
                bitDepth: 16,
                bpm: 125.0,
                musicalKey: "Unknown",
                confidence: 0.8,
                waveformMetadata: WaveformMetadata(
                    sampleCount: Int(240.0 * 44_100),
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
            cache.tracks[entry.relativePath] = entry

            let cacheURL = root.appendingPathComponent(PulseDeckCoreConfig.cacheFileName)
            try CachePersistence.saveAtomic(cache: cache, to: cacheURL)

            let loadedCache = cache
            state = AppState(
                libraryRootURL: root,
                waveformEditorModel: WaveformEditorModel(libraryRootURL: root),
                cacheLoader: { _ in loadedCache },
                audioCoordinator: nil,
                startCoordinator: false
            )

            let summary = LibraryScanner().scan(libraryURL: root)
            state.scanSummary = summary
            state.selectedCrate = summary.crates.first
            state.selectTrack(relativePath: entry.relativePath)
            state.setMasterSafetyLockEnabled(true)
        }

        func cleanup() {
            projector.teardown()
            try? FileManager.default.removeItem(at: root)
        }
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

            // 1. Verify OutputRoutingView controls are present
            let popups = allViews.compactMap { $0 as? NSPopUpButton }
            XCTAssertGreaterThanOrEqual(popups.count, 2, "Master and Cue output selectors must be mounted")

            // 2. Verify interactive NSControls are present
            let controls = allViews.compactMap { $0 as? NSControl }.filter {
                !($0 is NSScroller) && $0.bounds.width > 0 && $0.bounds.height > 0
            }
            XCTAssertGreaterThan(controls.count, 5, "Real transport, slider, and buttons must be mounted")

            // 3. Verify enclosing root scroll exists for guaranteed reachability
            let scrollViews = allViews.compactMap { $0 as? NSScrollView }
            XCTAssertFalse(scrollViews.isEmpty, "Root scroll view must enclose contents for fail-safe reachability")

            // 4. Verify primary operator controls are visible in viewport without scrolling
            let viewportRect = NSRect(origin: .zero, size: size)
            let visibleControls = controls.filter { ctrl in
                let frameInRoot = ctrl.convert(ctrl.bounds, to: root)
                return frameInRoot.intersects(viewportRect) && frameInRoot.width > 0 && frameInRoot.height > 0
            }
            XCTAssertGreaterThanOrEqual(visibleControls.count, 6, "Deck transport, popups, and library controls must be visible on screen in legal viewport")

            // 5. Verify library scroll view intersects the viewport
            let visibleScrollViews = scrollViews.filter { sv in
                let frameInRoot = sv.convert(sv.bounds, to: root)
                return frameInRoot.intersects(viewportRect)
            }
            XCTAssertGreaterThanOrEqual(visibleScrollViews.count, 2, "Library list scroll must be visible in initial viewport")
        }
    }

    func testCaptureProductionContentViewBitmaps() throws {
        let fixture = try RealisticFixture(); defer { fixture.cleanup() }
        let targets = [
            (size: NSSize(width: 1024, height: 680), name: "studio_composition_1024x680.png"),
            (size: NSSize(width: 1512, height: 884), name: "studio_composition_1512x884.png")
        ]

        let outDir = URL(fileURLWithPath: "/Users/tomaselagin/.ao/data/artifacts/pulsedeckai-82")

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

            let file = outDir.appendingPathComponent(target.name)
            try png.write(to: file)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Saved \(target.name)")
        }
    }
}
