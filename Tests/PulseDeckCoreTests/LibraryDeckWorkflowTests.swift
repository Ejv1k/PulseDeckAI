import XCTest
import AppKit
import SwiftUI
import AVFoundation
@testable import PulseDeckCore
@testable import PulseDeckAI

@MainActor
final class LibraryDeckWorkflowTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let root: URL
        let audio: AudioEngineCoordinator
        let app: AppState
        let path = "00_Private/fresh.wav"

        init(persistence: (any WaveformTrackPersisting)? = nil) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryWorkflow-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("00_Private"), withIntermediateDirectories: true)
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
            do {
                let file = try AVAudioFile(forWriting: root.appendingPathComponent(path), settings: format.settings)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100))
                buffer.frameLength = buffer.frameCapacity
                let data = try XCTUnwrap(buffer.floatChannelData)
                for frame in 0..<Int(buffer.frameLength) {
                    let sample = Float(sin(Double(frame) * 0.06) * 0.2)
                    data[0][frame] = sample; data[1][frame] = sample
                }
                try file.write(from: buffer)
            }
            audio = AudioEngineCoordinator(hal: MockAudioHardware())
            try audio.masterAudioEngine.rawEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            try audio.cueAudioEngine.rawEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            try audio.start()
            let editor = WaveformEditorModel(libraryRootURL: root, persistence: persistence ?? WaveformPersistenceActor())
            app = AppState(libraryRootURL: root, waveformEditorModel: editor,
                           audioCoordinator: audio, startCoordinator: false)
            let scan = LibraryScanner().scan(libraryURL: root)
            app.scanSummary = scan
            app.selectedCrate = scan.crates.first
        }

        func cleanup() {
            app.stopPreview()
            audio.stop()
            try? FileManager.default.removeItem(at: root)
        }

        func peak() throws -> Float {
            let engine = audio.masterAudioEngine.rawEngine
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
            XCTAssertEqual(try engine.renderOffline(4096, to: buffer), .success)
            let samples = try XCTUnwrap(buffer.floatChannelData)
            return (0..<Int(buffer.frameLength)).reduce(0) { max($0, abs(samples[0][$1])) }
        }
    }

    private struct CaptureAction: PrimitiveButtonStyle {
        let capture: (@escaping @MainActor () -> Void) -> Void
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.onAppear { capture { configuration.trigger() } }
        }
    }

    private func press<V: View>(_ button: V) throws {
        _ = NSApplication.shared
        let ready = expectation(description: "Real production button mounted")
        var action: (@MainActor () -> Void)?
        let host = NSHostingView(rootView: button.buttonStyle(CaptureAction {
            action = $0; ready.fulfill()
        }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        wait(for: [ready], timeout: 2)
        try XCTUnwrap(action)()
    }

    func testUnanalyzedLibrarySelectionAndActualLoadButtonDecodeIntoEmptyDeck() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try press(LibraryTrackSelectionButton(appState: f.app, relativePath: f.path) { Text("fresh.wav") }.button)
        XCTAssertEqual(f.app.selectedTrackPath, f.path)
        XCTAssertNil(f.app.loadedCache)
        try press(LibraryDeckLoadButton(appState: f.app, deck: .deckA, title: "DECK A", color: .blue).button)
        XCTAssertEqual(f.audio.deckAGraph.loadedTrackURL, f.root.appendingPathComponent(f.path))
        XCTAssertEqual(f.app.deckATrack?.relativePath, f.path)
        XCTAssertEqual(f.app.deckATrack?.duration ?? 0, 1, accuracy: 0.001)
        f.app.updateCrossfader(position: 0)
        f.app.toggleDeckPlay(deck: .deckA)
        XCTAssertGreaterThan(try f.peak(), 0.1, "The real graph must schedule audible offline PCM")
    }
    func testTypedDropProtectsOnAirDeckAndPreservesSelection() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.app.selectedTrackPath = "another-selection.wav"
        let original = LibraryTrackTransfer(libraryRoot: f.root, relativePath: f.path)
        let payload = try JSONDecoder().decode(LibraryTrackTransfer.self, from: JSONEncoder().encode(original))
        XCTAssertTrue(f.app.loadDroppedTracks([payload], deck: .deckA))
        XCTAssertEqual(f.app.selectedTrackPath, "another-selection.wav")
        XCTAssertEqual(f.app.focusedMasterDeck, .deckA)
        XCTAssertEqual(f.audio.deckAGraph.loadedTrackURL, f.root.appendingPathComponent(f.path))
        f.app.updateCrossfader(position: 0)
        f.app.toggleDeckPlay(deck: .deckA)
        let generation = f.audio.deckAGraph.scheduleGeneration
        XCTAssertFalse(f.app.loadDroppedTracks([payload], deck: .deckA))
        XCTAssertTrue(f.app.deckLoadMessage(for: .deckA)?.contains("Safety Lock") == true)
        XCTAssertEqual(f.audio.deckAGraph.scheduleGeneration, generation)
        XCTAssertGreaterThan(try f.peak(), 0.1)
        XCTAssertTrue(f.app.loadDroppedTracks([payload], deck: .deckB))
        XCTAssertTrue(f.audio.deckAGraph.isMasterPlaying)
    }

    func testInvalidStaleMultipleAndCorruptDropsLeaveGraphUnchangedWithFeedback() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let good = LibraryTrackTransfer(libraryRoot: f.root, relativePath: f.path)
        XCTAssertTrue(f.app.loadDroppedTracks([good], deck: .deckA))
        let url = f.audio.deckAGraph.loadedTrackURL
        let generation = f.audio.deckAGraph.scheduleGeneration
        let outside = f.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("not audio".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("00_Private/link.wav"), withDestinationURL: outside)
        for path in ["../escape.wav", outside.path, "00_Private/missing.wav", "00_Private/link.wav", "00_Private/file.txt"] {
            XCTAssertFalse(f.app.loadDroppedTracks([LibraryTrackTransfer(libraryRoot: f.root, relativePath: path)], deck: .deckA))
            XCTAssertNotNil(f.app.deckLoadMessage(for: .deckA))
        }
        try Data("not audio".utf8).write(to: f.root.appendingPathComponent("00_Private/corrupt.wav"))
        XCTAssertFalse(f.app.loadTrack(relativePath: "00_Private/corrupt.wav", deck: .deckA))
        XCTAssertTrue(f.app.deckLoadMessage(for: .deckA)?.contains("Unable to load") == true)
        XCTAssertFalse(f.app.loadDroppedTracks([good, good], deck: .deckA))
        XCTAssertFalse(f.app.loadDroppedTracks([LibraryTrackTransfer(libraryRoot: outside.deletingLastPathComponent(), relativePath: f.path)], deck: .deckA))
        XCTAssertEqual(f.audio.deckAGraph.loadedTrackURL, url)
        XCTAssertEqual(f.audio.deckAGraph.scheduleGeneration, generation)
    }

    func testActualLoadButtonWithoutSelectionShowsReason() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try press(LibraryDeckLoadButton(appState: f.app, deck: .deckA, title: "DECK A", color: .blue).button)
        XCTAssertTrue(f.app.deckLoadMessage(for: .deckA)?.contains("Select a library track") == true)
        XCTAssertNil(f.audio.deckAGraph.loadedTrackURL)
    }

    func testExplicitAnalysisProducesCacheWithoutInterruptingLoadedTransport() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        await f.app.selectTrack(relativePath: f.path).value
        XCTAssertTrue(f.app.loadTrack(relativePath: f.path, deck: .deckA))
        f.app.updateCrossfader(position: 0)
        f.app.toggleDeckPlay(deck: .deckA)
        let generation = f.audio.deckAGraph.scheduleGeneration
        await f.app.analyzeTrack(relativePath: f.path).value
        XCTAssertEqual(f.app.analysisStatus(for: f.path), .complete)
        let cached = try XCTUnwrap(f.app.loadedCache?.tracks[f.path])
        XCTAssertEqual(cached.analyzerVersion, LocalTrackAnalyzer.analyzerVersion)
        XCTAssertFalse(cached.waveformMetadata.peakValues.isEmpty)
        XCTAssertEqual(cached.musicalKey, "Unknown")
        XCTAssertEqual(f.app.waveformEditorModel.currentTrack?.relativePath, f.path)
        XCTAssertEqual(f.app.deckATrack?.analyzerVersion, LocalTrackAnalyzer.analyzerVersion)
        XCTAssertTrue(f.audio.deckAGraph.isMasterPlaying)
        XCTAssertEqual(f.audio.deckAGraph.scheduleGeneration, generation)
        XCTAssertGreaterThan(try f.peak(), 0.1)
        XCTAssertTrue(f.app.loadTrack(relativePath: f.path, deck: .deckB))
        XCTAssertEqual(f.app.deckBTrack?.fileFingerprint, cached.fileFingerprint)
    }

    private actor HeldAnalysisPersistence: WaveformTrackPersisting {
        let storage = WaveformPersistenceActor()
        let entered: XCTestExpectation
        let afterSave: Bool
        private var release: CheckedContinuation<Void, Never>?

        init(entered: XCTestExpectation, afterSave: Bool) {
            self.entered = entered; self.afterSave = afterSave
        }
        private func hold() async {
            await withCheckedContinuation { continuation in
                release = continuation
                entered.fulfill()
            }
        }
        func open() { release?.resume(); release = nil }
        func persistAnalysis(_ track: TrackCacheEntry, libraryRootURL: URL) async throws -> PulseDeckLibraryCache {
            if !afterSave { await hold() }
            let cache = try await storage.persistAnalysis(track, libraryRootURL: libraryRootURL)
            if afterSave { await hold() }
            return cache
        }
        func persistTrack(_ track: TrackCacheEntry, libraryRootURL: URL, intent: WaveformEditIntent) async throws -> PulseDeckLibraryCache {
            try await storage.persistTrack(track, libraryRootURL: libraryRootURL, intent: intent)
        }
    }

    func testHeldAnalysisAndNewerManualSaveKeepLatestCueOnDiskAndInUI() async throws {
        let entered = expectation(description: "Analysis saved but publication held")
        let gate = HeldAnalysisPersistence(entered: entered, afterSave: true)
        let f = try Fixture(persistence: gate); defer { f.cleanup() }
        await f.app.selectTrack(relativePath: f.path).value
        let job = f.app.analyzeTrack(relativePath: f.path)
        await fulfillment(of: [entered], timeout: 5)
        let entry = try XCTUnwrap(CachePersistence.load(from: f.root.appendingPathComponent(PulseDeckCoreConfig.cacheFileName))?.tracks[f.path])
        f.app.waveformEditorModel.loadTrack(entry)
        f.app.waveformEditorModel.setCue(.mixOut, toTime: 0.6)
        f.app.waveformEditorModel.toggleAITrimBypass()
        await gate.open()
        await job.value
        await f.app.waveformEditorModel.waitForPendingSaves()
        let saved = try XCTUnwrap(CachePersistence.load(from: f.root.appendingPathComponent(PulseDeckCoreConfig.cacheFileName))?.tracks[f.path])
        XCTAssertEqual(saved.cueMarkers.mixOutCue, 0.6, accuracy: 0.001)
        XCTAssertTrue(saved.manualOverrides.overriddenFields.contains("cueMarkers"))
        XCTAssertEqual(f.app.loadedCache?.tracks[f.path]?.cueMarkers.mixOutCue, 0.6)
        XCTAssertEqual(f.app.waveformEditorModel.cues.mixOutCue, 0.6)
        XCTAssertEqual(saved.analyzerVersion, LocalTrackAnalyzer.analyzerVersion)
        XCTAssertTrue(saved.aiTrimBypass)
        XCTAssertTrue(saved.manualOverrides.overriddenFields.contains("aiTrimBypass"))
        let analyzed = try LocalTrackAnalyzer().analyze(url: f.root.appendingPathComponent(f.path), libraryRoot: f.root)
        _ = try await gate.storage.persistAnalysis(analyzed, libraryRootURL: f.root)
        XCTAssertEqual(CachePersistence.load(from: f.root.appendingPathComponent(PulseDeckCoreConfig.cacheFileName))?.tracks[f.path]?.cueMarkers.mixOutCue, 0.6)
    }

    func testChangedSourceFailsAnalysisBeforeCacheWrite() async throws {
        let entered = expectation(description: "Analysis held before persistence")
        let gate = HeldAnalysisPersistence(entered: entered, afterSave: false)
        let f = try Fixture(persistence: gate); defer { f.cleanup() }
        let job = f.app.analyzeTrack(relativePath: f.path)
        await fulfillment(of: [entered], timeout: 5)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: f.root.appendingPathComponent(f.path).path)
        await gate.open()
        await job.value
        guard case .failed(let message) = f.app.analysisStatus(for: f.path) else { return XCTFail("Changed source must fail") }
        XCTAssertTrue(message.contains("changed"))
        XCTAssertNil(f.app.loadedCache)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(PulseDeckCoreConfig.cacheFileName).path))
    }

    func testRootChangeCancelsHeldAnalysisWithoutPublishingOrWritingOldCache() async throws {
        let entered = expectation(description: "Analysis held before root change")
        let gate = HeldAnalysisPersistence(entered: entered, afterSave: false)
        let f = try Fixture(persistence: gate); defer { f.cleanup() }
        let job = f.app.analyzeTrack(relativePath: f.path)
        await fulfillment(of: [entered], timeout: 5)
        let other = f.root.appendingPathComponent("another-library", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        f.app.libraryRootURL = other
        f.app.waveformEditorModel.updateLibraryRoot(other)
        await gate.open()
        await job.value
        XCTAssertNil(f.app.loadedCache)
        XCTAssertNil(f.app.analysisStatus(for: f.path))
        XCTAssertFalse(f.app.isAnalyzingLibraryTrack)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(PulseDeckCoreConfig.cacheFileName).path))
    }

    func testUnanalyzedMP3LoadsThroughActualDeckBButtonAndRenders() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let path = "00_Private/fresh.mp3"
        let encoded = "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"
        // Generated 440 Hz / 0.5 s / mono 22050 Hz / 32 kbps MP3. No runtime encoder dependency.
        try XCTUnwrap(Data(base64Encoded: encoded)).write(to: f.root.appendingPathComponent(path))
        try press(LibraryTrackSelectionButton(appState: f.app, relativePath: path) { Text("fresh.mp3") }.button)
        try press(LibraryDeckLoadButton(appState: f.app, deck: .deckB, title: "DECK B", color: .red).button)
        XCTAssertEqual(f.audio.deckBGraph.loadedTrackURL, f.root.appendingPathComponent(path))
        XCTAssertGreaterThan(f.app.deckBTrack?.duration ?? 0, 0.4)
        XCTAssertNil(f.app.loadedCache)
        XCTAssertTrue(f.app.isMasterSafetyLockEnabled)
        f.app.updateCrossfader(position: 1)
        f.app.toggleDeckPlay(deck: .deckB)
        XCTAssertGreaterThan(try f.peak(), 0.03)
    }
    func testActualAnalyzeButtonStartsExplicitLocalWork() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try press(LibraryTrackAnalysisButton(appState: f.app, relativePath: f.path).button)
        XCTAssertTrue(f.app.isAnalyzingLibraryTrack)
        XCTAssertEqual(f.app.analysisStatus(for: f.path), .running)
        await f.app.analyzeTrack(relativePath: f.path).value
        XCTAssertEqual(f.app.analysisStatus(for: f.path), .complete)
        XCTAssertFalse(f.app.isAnalyzingLibraryTrack)
        XCTAssertNotNil(f.app.loadedCache?.tracks[f.path])
    }

    func testAnalysisCompletionCannotReplaceNewerSelectedEditor() async throws {
        let entered = expectation(description: "Analysis held before changing selection")
        let gate = HeldAnalysisPersistence(entered: entered, afterSave: false)
        let f = try Fixture(persistence: gate); defer { f.cleanup() }
        let otherPath = "00_Private/other.wav"
        try FileManager.default.copyItem(at: f.root.appendingPathComponent(f.path), to: f.root.appendingPathComponent(otherPath))
        let other = try LocalTrackAnalyzer().analyze(url: f.root.appendingPathComponent(otherPath), libraryRoot: f.root)
        try CachePersistence.saveAtomic(cache: PulseDeckLibraryCache(tracks: [otherPath: other]),
                                        to: f.root.appendingPathComponent(PulseDeckCoreConfig.cacheFileName))
        await f.app.selectTrack(relativePath: f.path).value
        let job = f.app.analyzeTrack(relativePath: f.path)
        await fulfillment(of: [entered], timeout: 5)
        await f.app.selectTrack(relativePath: otherPath).value
        f.app.waveformEditorModel.zoomLevel = 2
        f.app.waveformEditorModel.playheadPosition = 0.4
        await gate.open()
        await job.value
        XCTAssertEqual(f.app.waveformEditorModel.currentTrack?.relativePath, otherPath)
        XCTAssertEqual(f.app.waveformEditorModel.zoomLevel, 2)
        XCTAssertEqual(f.app.waveformEditorModel.playheadPosition, 0.4)
        XCTAssertNotNil(f.app.loadedCache?.tracks[f.path])
        XCTAssertNotNil(f.app.loadedCache?.tracks[otherPath])
    }

    func testMalformedCacheAnalysisFailurePreservesBytesAndDoesNotBlockLoading() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let cache = f.root.appendingPathComponent(PulseDeckCoreConfig.cacheFileName)
        let original = Data("malformed cache must remain untouched".utf8)
        try original.write(to: cache)
        await f.app.analyzeTrack(relativePath: f.path).value
        guard case .failed(let reason) = f.app.analysisStatus(for: f.path) else { return XCTFail("Expected actionable analysis error") }
        XCTAssertTrue(reason.contains("schema validation"))
        XCTAssertEqual(try Data(contentsOf: cache), original)
        XCTAssertTrue(f.app.loadTrack(relativePath: f.path, deck: .deckA))
        XCTAssertEqual(f.audio.deckAGraph.loadedTrackURL, f.root.appendingPathComponent(f.path))
    }

    func testProgrammaticLoadPreservesKeyboardFocusWhileDropFocusesItsTarget() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.app.focusMasterDeck(.deckA)
        XCTAssertTrue(f.app.loadTrack(relativePath: f.path, deck: .deckB))
        XCTAssertEqual(f.app.focusedMasterDeck, .deckA)
        XCTAssertTrue(f.app.loadDroppedTracks([LibraryTrackTransfer(libraryRoot: f.root, relativePath: f.path)], deck: .deckB))
        XCTAssertEqual(f.app.focusedMasterDeck, .deckB)
    }

}
