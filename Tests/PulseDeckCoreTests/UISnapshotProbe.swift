import XCTest
import SwiftUI
import AVFoundation
@testable import PulseDeckCore
@testable import PulseDeckAI

/// Manual visual check of the real studio window. Skipped unless PULSEDECK_SNAPSHOT_DIR is set.
/// Optional PULSEDECK_SNAPSHOT_TRACKS: newline-separated audio files copied into a temporary library.
@MainActor
final class UISnapshotProbe: XCTestCase {
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
            await app.selectTrack(relativePath: "01_Retro/\(names[0])").value
            app.setDeckEQ(deck: .deckA, eq: EQ3BandParameters(lowGainDB: -24, midGainDB: -4, highGainDB: 2))
        }
        let projector = ProjectorViewModel()
        defer { projector.teardown() }
        for (label, size) in [("1440x900", NSSize(width: 1440, height: 900)), ("1024x680", NSSize(width: 1024, height: 680))] {
            let controller = NSHostingController(rootView: ContentView().environmentObject(app).environmentObject(projector))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
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
