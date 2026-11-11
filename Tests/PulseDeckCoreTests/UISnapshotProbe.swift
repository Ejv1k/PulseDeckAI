import XCTest
import SwiftUI
import AVFoundation
@testable import PulseDeckCore
@testable import PulseDeckAI

/// Manual visual check of the real studio window. Skipped unless PULSEDECK_SNAPSHOT_DIR is set.
/// Optional PULSEDECK_SNAPSHOT_TRACKS: newline-separated audio files copied into a temporary library.
@MainActor
final class UISnapshotProbe: XCTestCase {
    /// PULSEDECK_SNAPSHOT_APPEARANCE=light|dark forces the studio look; unset follows macOS.
    private var studioAppearance: NSAppearance? {
        switch ProcessInfo.processInfo.environment["PULSEDECK_SNAPSHOT_APPEARANCE"] {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }

    private func render<V: View>(_ view: V, size: NSSize, to url: URL, appearance: NSAppearance? = nil) async throws {
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance ?? studioAppearance
        window.contentViewController = controller
        window.setContentSize(size)
        window.orderBack(nil)
        try await Task.sleep(nanoseconds: 600_000_000)
        controller.view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        window.contentViewController = nil
        window.close()
    }

    func testRenderStudio() async throws {
        guard let outDir = ProcessInfo.processInfo.environment["PULSEDECK_SNAPSHOT_DIR"] else { throw XCTSkip("snapshot only") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SnapshotLibrary-\(UUID().uuidString)")
        let crate = root.appendingPathComponent("01_Retro")
        try FileManager.default.createDirectory(at: crate, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tracks = (ProcessInfo.processInfo.environment["PULSEDECK_SNAPSHOT_TRACKS"] ?? "").split(separator: "\n").map(String.init)
        for track in tracks { try FileManager.default.copyItem(atPath: track, toPath: crate.appendingPathComponent((track as NSString).lastPathComponent).path) }

        let audio = AudioEngineCoordinator(hal: MockAudioHardware())
        let app = AppState(libraryRootURL: root, waveformEditorModel: WaveformEditorModel(libraryRootURL: root),
                           audioCoordinator: audio, startCoordinator: false, autoGainEnabled: true)
        await app.refreshLibrary()?.value
        let names = try FileManager.default.contentsOfDirectory(atPath: crate.path).sorted()
        if names.count >= 2 {
            app.loadTrack(relativePath: "01_Retro/\(names[0])", deck: .deckA)
            app.loadTrack(relativePath: "01_Retro/\(names[1])", deck: .deckB)
            await app.waitForPendingLoudness(deck: .deckA)
            await app.waitForPendingLoudness(deck: .deckB)
            if ProcessInfo.processInfo.environment["PULSEDECK_SNAPSHOT_ANALYZE"] != nil {
                let started = Date()
                await app.analyzeTrack(relativePath: "01_Retro/\(names[0])", method: .nativeModel).value
                print(String(format: "SNAP analyzed A (model) in %.1fs", Date().timeIntervalSince(started)))
                let dspStart = Date()
                await app.analyzeTrack(relativePath: "01_Retro/\(names[1])", method: .dsp).value
                print(String(format: "SNAP analyzed B (dsp) in %.1fs", Date().timeIntervalSince(dspStart)))
                for deck in [DeckIdentifier.deckA, .deckB] {
                    let t = deck == .deckA ? app.deckATrack : app.deckBTrack
                    print("SNAP \(deck.rawValue): bpm=\(t?.bpm ?? -1) key=\(t?.musicalKey ?? "-") beats=\(t?.beatGrid.beatTimestamps.count ?? 0) cues=\(String(describing: t?.cueMarkers)) msg=\(app.deckLoadMessage(for: deck) ?? "nil")")
                }
            }
            await app.selectTrack(relativePath: "01_Retro/\(names[0])").value
            app.setDeckEQ(deck: .deckA, eq: EQ3BandParameters(lowGainDB: -24, midGainDB: -4, highGainDB: 2))
            for name in names.dropFirst(2) { app.addToUpNext("01_Retro/\(name)") }
        }
        let expandKey = "studio.soundboardExpanded"
        let wasExpanded = UserDefaults.standard.object(forKey: expandKey)
        UserDefaults.standard.set(ProcessInfo.processInfo.environment["PULSEDECK_SNAPSHOT_SOUNDBOARD"] != nil, forKey: expandKey)
        defer { UserDefaults.standard.set(wasExpanded, forKey: expandKey) }
        let projector = ProjectorViewModel()
        defer { projector.teardown() }
        if ProcessInfo.processInfo.environment["PULSEDECK_SNAPSHOT_PLAYING"] != nil {
            app.toggleDeckPlay(deck: .deckA)
            print("SNAPSHOT deckA playing=\(app.isDeckAPlaying)")
        }
        defer { if app.isDeckAPlaying { app.toggleDeckPlay(deck: .deckA) } }
        if ProcessInfo.processInfo.environment["PULSEDECK_SNAPSHOT_PROJECTOR"] != nil {
            projector.updateNowPlaying(from: app)
            for mode in [ProjectorMode.nowPlaying, .fftVisualizer, .mediaSlideshow, .blackout] {
                projector.setMode(mode)
                try await render(ProjectorWindowView(viewModel: projector, appState: app), size: NSSize(width: 1280, height: 720),
                                 to: URL(fileURLWithPath: outDir).appendingPathComponent("projector-\(mode.rawValue).png"),
                                 appearance: NSAppearance(named: .darkAqua))
            }
        }
        try await render(LibrarySearchResultsView(appState: app, query: "the").frame(width: 900, height: 300), size: NSSize(width: 900, height: 300),
                         to: URL(fileURLWithPath: outDir).appendingPathComponent("search.png"))
        try await render(SettingsView(appState: app), size: NSSize(width: 520, height: 360),
                         to: URL(fileURLWithPath: outDir).appendingPathComponent("settings.png"))
        for (label, size) in [("1440x900", NSSize(width: 1440, height: 900)), ("1024x680", NSSize(width: 1024, height: 680))] {
            let controller = NSHostingController(rootView: ContentView().environmentObject(app).environmentObject(projector))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = studioAppearance
            window.contentViewController = controller
            window.setContentSize(size)
            window.orderBack(nil)
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 800_000_000)
            controller.view.layoutSubtreeIfNeeded()
            let view = controller.view
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: outDir).appendingPathComponent("studio-\(label).png"))
            window.contentViewController = nil
            window.close()
        }
    }
}
