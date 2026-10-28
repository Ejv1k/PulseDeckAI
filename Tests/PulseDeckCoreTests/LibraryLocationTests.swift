import XCTest
import Combine
import AppKit
import AVFoundation
@testable import PulseDeckCore
@testable import PulseDeckAI

@MainActor
final class LibraryLocationTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let parent: URL
        let suite = "LibraryLocationTests." + UUID().uuidString
        let defaults: UserDefaults
        let store: LibraryLocationStore

        init() throws {
            parent = FileManager.default.temporaryDirectory.appendingPathComponent("Library location – " + UUID().uuidString)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            defaults = UserDefaults(suiteName: suite)!
            store = LibraryLocationStore(defaults: defaults)
        }

        func root(_ name: String) throws -> URL {
            let url = parent.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url.appendingPathComponent("01 Crate"), withIntermediateDirectories: true)
            return url
        }

        func app(_ root: URL, cache: PulseDeckLibraryCache? = nil,
                 chooser: @escaping @MainActor () -> URL?) -> AppState {
            AppState(libraryRootURL: root, waveformEditorModel: WaveformEditorModel(libraryRootURL: root),
                     loadedCache: cache, audioCoordinator: nil, startCoordinator: false,
                     libraryLocationStore: store, chooseLibraryDirectory: chooser)
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: parent)
        }
    }

    func testChooseScansNewRootRemembersItAndRestoresAcrossStoreInstances() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = try f.root("A"), b = try f.root("Česká knihovna")
        let app = f.app(a, chooser: { b })
        app.selectedTrackPath = "old-selection.wav"
        let scanned = expectation(description: "Chosen library scanned")
        let observation = app.$scanSummary.compactMap { $0 }.first().sink { summary in
            XCTAssertEqual(summary.libraryURL, b)
            scanned.fulfill()
        }
        app.openLibrary()
        await fulfillment(of: [scanned], timeout: 3)
        withExtendedLifetime(observation) {}
        XCTAssertEqual(app.libraryRootURL, b)
        XCTAssertEqual(app.waveformEditorModel.libraryRootURL, b)
        XCTAssertNil(app.selectedTrackPath)
        XCTAssertNil(app.libraryLocationError)
        let restarted = LibraryLocationStore(defaults: UserDefaults(suiteName: f.suite)!)
        let location = LibraryLocation.resolve(arguments: ["app"], workingDirectory: a, store: restarted)
        XCTAssertEqual(location.root, b)
        XCTAssertNil(location.error)
    }

    func testCancelPreservesRootCacheSelectionAndPreference() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let root = try f.root("selected")
        f.store.remember(root)
        let cache = PulseDeckLibraryCache(libraryRoot: "sentinel", tracks: [:])
        let app = f.app(root, cache: cache, chooser: { nil })
        app.selectedTrackPath = "sentinel.wav"
        let scan = LibraryScanner().scan(libraryURL: root)
        app.scanSummary = scan; app.selectedCrate = scan.crates.first
        app.openLibrary()
        XCTAssertEqual(app.libraryRootURL, root)
        XCTAssertEqual(app.selectedTrackPath, "sentinel.wav")
        XCTAssertEqual(app.loadedCache?.libraryRoot, "sentinel")
        XCTAssertEqual(app.scanSummary, scan)
        XCTAssertEqual(app.selectedCrate, scan.crates.first)
        XCTAssertEqual(f.store.chosenRoot, root)
        XCTAssertFalse(app.isScanning)
        XCTAssertNil(app.libraryLocationError)
    }

    func testNonDirectoryAndMissingChoicesLeaveExistingStateAndPreferenceIntact() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let root = try f.root("selected")
        f.store.remember(root)
        let file = f.parent.appendingPathComponent("not a folder.txt")
        try Data([1]).write(to: file)
        for invalid in [file, f.parent.appendingPathComponent("missing") ] {
            let app = f.app(root, cache: PulseDeckLibraryCache(libraryRoot: "unchanged", tracks: [:]), chooser: { invalid })
            app.selectedTrackPath = "sentinel.wav"
            app.openLibrary()
            XCTAssertEqual(app.libraryRootURL, root)
            XCTAssertEqual(app.loadedCache?.libraryRoot, "unchanged")
            XCTAssertEqual(app.selectedTrackPath, "sentinel.wav")
            XCTAssertEqual(f.store.chosenRoot, root)
            XCTAssertNotNil(app.libraryLocationError)
            XCTAssertFalse(app.isScanning)
        }
    }

    func testMissingRememberedRootIsRetainedWithRecoveryRatherThanCWDFallback() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let root = try f.root("remembered")
        f.store.remember(root)
        try FileManager.default.removeItem(at: root)
        let cwd = try f.root("cwd")
        let legacy = cwd.appendingPathComponent("PulseDeck_Library")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
        let location = LibraryLocation.resolve(arguments: ["app"], workingDirectory: cwd, store: f.store)
        XCTAssertEqual(location.root, root)
        XCTAssertNotEqual(location.root, legacy)
        XCTAssertTrue(location.error?.contains("Open Library") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Resolution must not recreate a missing library")
        XCTAssertEqual(f.store.chosenRoot, root)
    }

    func testMissingAtLaunchReconnectAndRescanRecoversRememberedAndExplicitRoots() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let missing = f.parent.appendingPathComponent("Reconnected library", isDirectory: true)
        for explicit in [false, true] {
            if FileManager.default.fileExists(atPath: missing.path) {
                try FileManager.default.removeItem(at: missing)
            }
            f.store.remember(missing)
            let arguments = explicit ? ["app", "--library-root", missing.path] : ["app"]
            let launch = LibraryLocation.resolve(arguments: arguments, workingDirectory: f.parent, store: f.store)
            let app = AppState(libraryRootURL: launch.root,
                waveformEditorModel: WaveformEditorModel(libraryRootURL: launch.root),
                audioCoordinator: nil, startCoordinator: false, libraryLocationStore: f.store,
                libraryLaunchIssue: launch.issue, chooseLibraryDirectory: { XCTFail("Rescan must not require the picker"); return nil })
            XCTAssertNotNil(app.libraryLocationError)
            XCTAssertNil(app.refreshLibrary(), "A still-disconnected folder cannot scan")
            XCTAssertEqual(app.libraryRootURL.path, missing.path)
            try FileManager.default.createDirectory(at: missing.appendingPathComponent("01 Returned crate"), withIntermediateDirectories: true)
            let cache = PulseDeckLibraryCache(libraryRoot: "reconnected-cache", tracks: [:])
            try JSONEncoder().encode(cache).write(to: missing.appendingPathComponent(PulseDeckCoreConfig.cacheFileName))
            let scan = try XCTUnwrap(app.refreshLibrary())
            await scan.value
            XCTAssertNil(app.libraryLocationError)
            XCTAssertEqual(app.scanSummary?.libraryURL.path, missing.path)
            XCTAssertEqual(app.scanSummary?.crates.first?.folderName, "01 Returned crate")
            XCTAssertEqual(app.loadedCache?.libraryRoot, "reconnected-cache")
            XCTAssertEqual(f.store.chosenRoot?.path, missing.path)
        }
    }

    func testRescanOfMalformedOverrideRemainsBlockedEvenWhenCWDFallbackExists() throws {
        let f = try Fixture(); defer { f.cleanup() }
        _ = try f.root("PulseDeck_Library")
        let launch = LibraryLocation.resolve(arguments: ["app", "--library-root", "relative"], workingDirectory: f.parent, store: f.store)
        let app = AppState(libraryRootURL: launch.root,
            waveformEditorModel: WaveformEditorModel(libraryRootURL: launch.root),
            audioCoordinator: nil, startCoordinator: false, libraryLocationStore: f.store,
            libraryLaunchIssue: launch.issue, chooseLibraryDirectory: { nil })
        let error = app.libraryLocationError
        XCTAssertNil(app.refreshLibrary())
        XCTAssertEqual(app.libraryLocationError, error)
        XCTAssertNil(app.scanSummary)
        XCTAssertNil(app.loadedCache)
        XCTAssertNil(f.store.chosenRoot)
    }

    private func populateAssets(_ root: URL) throws {
        let sfx = root.appendingPathComponent("08_Soundboard_SFX")
        let visuals = root.appendingPathComponent("09_Visual_Backgrounds_Media")
        try FileManager.default.createDirectory(at: sfx, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: visuals, withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: sfx.appendingPathComponent("01 Quiet.wav"), settings: format.settings)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410))
            pcm.frameLength = 4410
            let channels = try XCTUnwrap(pcm.floatChannelData)
            for channel in 0..<2 {
                for frame in 0..<4410 { channels[channel][frame] = Float(sin(Double(frame) * 0.05)) * 0.002 }
            }
            try file.write(from: pcm)
        }
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try XCTUnwrap(image.bitmapData)
        bytes.initialize(repeating: 255, count: image.bytesPerRow * image.pixelsHigh)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: visuals.appendingPathComponent("private.png"))
    }

    func testMalformedOverrideBlocksPopulatedFallbackConsumersUntilExplicitChoice() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let fallback = try f.root("PulseDeck_Library")
        try populateAssets(fallback)
        let launch = LibraryLocation.resolve(arguments: ["app", "--library-root", "relative"], workingDirectory: f.parent, store: f.store)
        let audio = AudioEngineCoordinator(hal: MockAudioHardware())
        defer { audio.stop() }
        var preloadRoots: [URL] = []
        let app = AppState(libraryRootURL: launch.root,
            waveformEditorModel: WaveformEditorModel(libraryRootURL: launch.root),
            audioCoordinator: audio, startCoordinator: false, libraryLocationStore: f.store,
            libraryLaunchIssue: launch.issue, beforeSoundboardPreloadForTesting: { preloadRoots.append($0) },
            chooseLibraryDirectory: { fallback })
        let projector = ProjectorViewModel(); defer { projector.teardown() }
        var mediaRoots: [URL] = []
        PulseDeckApp.updateProjectorLibrary(from: app, model: projector, beforeDiscoveryForTesting: { mediaRoots.append($0) })
        app.preloadSoundboard()
        XCTAssertNil(app.resolvedLibraryRootURL)
        // These synchronous hooks sit immediately before the real discovery calls, including constructor preload.
        XCTAssertTrue(preloadRoots.isEmpty, "No soundboard discovery may be scheduled, even during initialization")
        XCTAssertTrue(mediaRoots.isEmpty, "The actual onAppear bridge must never register a fallback root")
        XCTAssertFalse(projector.mediaService.isScanning)
        XCTAssertTrue(projector.mediaService.items.isEmpty)
        XCTAssertTrue(audio.soundboardController.padSnapshots.allSatisfy(\.isFallback))
        let assetPath = "08_Soundboard_SFX/01 Quiet.wav"
        await app.selectTrack(relativePath: assetPath).value
        await app.loadPreviewTrack(relativePath: assetPath).value
        await app.analyzeTrack(relativePath: assetPath).value
        XCTAssertFalse(app.loadTrack(relativePath: assetPath, deck: .deckA))
        XCTAssertNil(app.selectedTrackPath)
        XCTAssertNil(app.previewTrackPath)
        XCTAssertNil(audio.deckAGraph.loadedTrackURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallback.appendingPathComponent(PulseDeckCoreConfig.cacheFileName).path))

        let padReady = expectation(description: "Chosen root's quiet file actually preloaded")
        let mediaReady = expectation(description: "Chosen root's real image discovered")
        let pads = app.$soundboardPads.filter { !$0.isEmpty && !$0[0].isFallback }.first().sink { _ in padReady.fulfill() }
        let media = projector.mediaService.$items.filter { !$0.isEmpty }.first().sink { _ in mediaReady.fulfill() }
        app.openLibrary()
        PulseDeckApp.updateProjectorLibrary(from: app, model: projector, beforeDiscoveryForTesting: { mediaRoots.append($0) })
        await fulfillment(of: [padReady, mediaReady], timeout: 5)
        XCTAssertEqual(app.resolvedLibraryRootURL?.path, fallback.path)
        XCTAssertFalse(preloadRoots.isEmpty)
        XCTAssertTrue(preloadRoots.allSatisfy { $0.path == fallback.path })
        XCTAssertEqual(mediaRoots.map(\.path), [fallback.path])
        XCTAssertEqual(audio.soundboardController.padSnapshots[0].title, "01 Quiet")
        XCTAssertEqual(projector.mediaService.items.first?.fileURL.lastPathComponent, "private.png")
        XCTAssertEqual(f.store.chosenRoot?.path, fallback.path)
        withExtendedLifetime((pads, media)) {}
    }

    func testValidExplicitRootDiscoversItsAssetsInsteadOfPopulatedCWDFallback() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let fallback = try f.root("PulseDeck_Library"), intended = try f.root("Explicit chosen library")
        try populateAssets(fallback); try populateAssets(intended)
        let launch = LibraryLocation.resolve(arguments: ["app", "--library-root", intended.path], workingDirectory: f.parent, store: f.store)
        let audio = AudioEngineCoordinator(hal: MockAudioHardware()); defer { audio.stop() }
        var preloadRoots: [URL] = []
        let app = AppState(libraryRootURL: launch.root, waveformEditorModel: WaveformEditorModel(libraryRootURL: launch.root),
            audioCoordinator: audio, startCoordinator: false, libraryLocationStore: f.store,
            libraryLaunchIssue: launch.issue, beforeSoundboardPreloadForTesting: { preloadRoots.append($0) }, chooseLibraryDirectory: { nil })
        let projector = ProjectorViewModel(); defer { projector.teardown() }
        var mediaRoots: [URL] = []
        let padReady = expectation(description: "Explicit root's quiet file preloaded")
        let mediaReady = expectation(description: "Explicit root's image discovered")
        let pads = app.$soundboardPads.filter { !$0.isEmpty && !$0[0].isFallback }.first().sink { _ in padReady.fulfill() }
        let media = projector.mediaService.$items.filter { !$0.isEmpty }.first().sink { _ in mediaReady.fulfill() }
        PulseDeckApp.updateProjectorLibrary(from: app, model: projector, beforeDiscoveryForTesting: { mediaRoots.append($0) })
        await fulfillment(of: [padReady, mediaReady], timeout: 5)
        XCTAssertEqual(app.resolvedLibraryRootURL?.path, intended.path)
        XCTAssertEqual(preloadRoots.map(\.path), [intended.path])
        XCTAssertEqual(mediaRoots.map(\.path), [intended.path])
        XCTAssertEqual(projector.mediaService.items.first?.fileURL.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path, intended.resolvingSymlinksInPath().path)
        XCTAssertNil(f.store.chosenRoot, "An explicit launch must not persist a user choice")
        withExtendedLifetime((pads, media)) {}
    }

    func testExplicitAbsolutePathAndFileURLWinWithoutOverwritingRememberedChoice() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let remembered = try f.root("remembered"), override = try f.root("Explicit česká folder")
        f.store.remember(remembered)
        for argument in [override.path, override.absoluteString] {
            let location = LibraryLocation.resolve(arguments: ["app", "--library-root", argument], workingDirectory: f.parent, store: f.store)
            XCTAssertEqual(location.root, override)
            XCTAssertNil(location.error)
            XCTAssertEqual(f.store.chosenRoot, remembered)
        }
        let missing = override.appendingPathComponent("missing")
        let failed = LibraryLocation.resolve(arguments: ["app", "--library-root", missing.path], workingDirectory: f.parent, store: f.store)
        XCTAssertEqual(failed.root.path, missing.path)
        XCTAssertNotNil(failed.error)
        XCTAssertEqual(f.store.chosenRoot, remembered)
    }

    func testMalformedOverrideNeverSilentlyLoadsRememberedLibrary() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.store.remember(try f.root("remembered"))
        let cases = [["--library-root"], ["--library-root", "relative/path"],
                     ["--library-root", "https://example.invalid/library"],
                     ["--library-root", "file://remote-host/library"],
                     ["--library-root", f.parent.path, "--library-root", f.parent.path]]
        for arguments in cases {
            let location = LibraryLocation.resolve(arguments: ["app"] + arguments, workingDirectory: f.parent, store: f.store)
            XCTAssertNotNil(location.error)
            XCTAssertNotEqual(location.root, f.store.chosenRoot)
        }
    }

    func testInjectedRootWinsAndDoesNotReadNormalPreferences() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let remembered = try f.root("remembered"), injected = try f.root("injected")
        f.store.remember(remembered)
        let app = f.app(injected, chooser: { nil })
        XCTAssertEqual(app.libraryRootURL, injected)
        XCTAssertEqual(app.waveformEditorModel.libraryRootURL, injected)
        XCTAssertEqual(f.store.chosenRoot, remembered)
    }

    func testLegacyCWDFallbackOnlyWhenNoChoiceOrOverrideExists() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let legacy = try f.root("PulseDeck_Library")
        let location = LibraryLocation.resolve(arguments: ["app"], workingDirectory: f.parent, store: f.store)
        XCTAssertEqual(location.root, legacy)
        XCTAssertNil(location.error)
        XCTAssertNil(f.store.chosenRoot, "Fallback must not persist an unchosen root")
    }

    private actor ScanGate {
        var held: CheckedContinuation<PulseDeckLibraryCache?, Never>?
        let entered: XCTestExpectation
        init(entered: XCTestExpectation) { self.entered = entered }
        func load() async -> PulseDeckLibraryCache? {
            await withCheckedContinuation { held = $0; entered.fulfill() }
        }
        func release() { held?.resume(returning: PulseDeckLibraryCache(libraryRoot: "stale", tracks: [:])); held = nil }
    }

    func testChoosingDuringOldScanScansNewRootAndRejectsLateOldCache() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let old = try f.root("old"), new = try f.root("new")
        let entered = expectation(description: "Old root scan held")
        let gate = ScanGate(entered: entered)
        let app = AppState(libraryRootURL: old, waveformEditorModel: WaveformEditorModel(libraryRootURL: old),
            cacheLoader: { url in
                if url.deletingLastPathComponent() == old {
                    return await gate.load()
                }
                return PulseDeckLibraryCache(libraryRoot: "new", tracks: [:])
            }, audioCoordinator: nil, startCoordinator: false,
            libraryLocationStore: f.store, chooseLibraryDirectory: { new })
        let oldScan = app.refreshLibrary()
        await fulfillment(of: [entered], timeout: 3)
        let scanned = expectation(description: "New root completes while old scan is held")
        let observation = app.$scanSummary.compactMap { $0 }.first().sink { summary in
            XCTAssertEqual(summary.libraryURL, new); scanned.fulfill()
        }
        app.openLibrary()
        await fulfillment(of: [scanned], timeout: 3)
        XCTAssertEqual(app.loadedCache?.libraryRoot, "new")
        await gate.release()
        await oldScan?.value
        XCTAssertEqual(app.libraryRootURL, new)
        XCTAssertEqual(app.loadedCache?.libraryRoot, "new")
        XCTAssertEqual(app.scanSummary?.libraryURL, new)
        withExtendedLifetime(observation) {}
    }
}
