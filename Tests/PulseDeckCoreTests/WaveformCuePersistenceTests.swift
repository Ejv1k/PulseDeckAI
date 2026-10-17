import Foundation
import Combine
import XCTest
@testable import PulseDeckCore
@testable import PulseDeckAI

/// Gates requests, then delegates every successful write to the actual production persistence actor.
/// It contains no cache loading, merging, serialization or sampling implementation.
private actor HeldWaveformPersistence: WaveformTrackPersisting {
    enum InjectedFailure: Error { case writeFailed }
    private let production = WaveformPersistenceActor()
    private let started: [XCTestExpectation]
    private let failures: Set<Int>
    private var blocked: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var requests: [TrackCacheEntry] = []

    init(started: [XCTestExpectation], failures: Set<Int> = []) {
        self.started = started
        self.failures = failures
    }

    func persistTrack(_ track: TrackCacheEntry, libraryRootURL: URL) async throws -> PulseDeckLibraryCache {
        requests.append(track)
        let ordinal = requests.count
        if !released {
            await withCheckedContinuation { continuation in
                blocked = continuation
                if ordinal <= started.count { started[ordinal - 1].fulfill() }
            }
        }
        if failures.contains(ordinal) { throw InjectedFailure.writeFailed }
        return try await production.persistTrack(track, libraryRootURL: libraryRootURL)
    }

    func releaseNext() {
        let continuation = blocked
        blocked = nil
        continuation?.resume()
    }

    func releaseAll() {
        released = true
        releaseNext()
    }
}

final class WaveformCuePersistenceTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testExplicitSelectionSurvivesConcurrentRefreshAndOlderSelections() async throws {
        let (root, a, b, _) = try makeLibrary()
        let editor = WaveformEditorModel(libraryRootURL: root)
        let app = AppState(libraryRootURL: root, waveformEditorModel: editor)
        let scanned = XCTestExpectation(description: "Background refresh completes")
        let observation = app.$isScanning.dropFirst().filter { !$0 }.sink { _ in scanned.fulfill() }
        defer { observation.cancel() }
        app.refreshLibrary()
        let first = app.selectTrack(relativePath: a.relativePath)
        let latest = app.selectTrack(relativePath: b.relativePath)
        await latest.value
        await first.value
        await completed(scanned)
        XCTAssertEqual(app.selectedTrackPath, b.relativePath)
        XCTAssertEqual(editor.currentTrack?.relativePath, b.relativePath)
        XCTAssertEqual(editor.cues, b.cueMarkers)
    }

    @MainActor
    func testPendingSaveSwitchReselectFurtherEditsBypassAndReloadUseLatestProductionState() async throws {
        let (root, a, b, untouched) = try makeLibrary()
        var seeded = try XCTUnwrap(CachePersistence.load(from: cacheURL(root)))
        seeded.tracks[a.relativePath]?.manualOverrides = ManualOverrides(isManual: true,
            overriddenFields: ["bpm", "musicalKey"], author: "Original DJ", notes: "Keep original phrasing")
        try CachePersistence.saveAtomic(cache: seeded, to: cacheURL(root))
        let started = (1...5).map { XCTestExpectation(description: "Production save \($0) started") }
        let persistence = HeldWaveformPersistence(started: started)
        let editor = WaveformEditorModel(libraryRootURL: root, persistence: persistence)
        let app = AppState(libraryRootURL: root, waveformEditorModel: editor)
        addTeardownBlock {
            await persistence.releaseAll()
            await editor.waitForPendingSaves()
        }

        await select(app, a.relativePath)
        editor.setCue(.startTrim, toTime: 5.5)
        await completed(started[0])
        XCTAssertTrue(editor.isSaving)
        XCTAssertEqual(try diskEntry(a.relativePath, root: root).cueMarkers, a.cueMarkers)

        // Selection and another track's editing finish on MainActor while A's first disk write is held.
        await select(app, b.relativePath)
        editor.setCue(.vocalEntry, toTime: 22)
        await select(app, a.relativePath)
        XCTAssertEqual(editor.cues.startTrimCue, 5.5)
        XCTAssertTrue(editor.manualOverrides.isManual)
        editor.setCue(.vocalEntry, toTime: 20)
        editor.toggleAITrimBypass()
        await select(app, b.relativePath)
        XCTAssertEqual(editor.cues.vocalEntryCue, 22)
        editor.toggleAITrimBypass()
        await select(app, a.relativePath)
        XCTAssertEqual(editor.cues.startTrimCue, 5.5)
        XCTAssertEqual(editor.cues.vocalEntryCue, 20)
        XCTAssertTrue(editor.aiTrimBypass)
        let submittedBeforeRelease = await persistence.requests
        XCTAssertEqual(submittedBeforeRelease.count, 1, "Save chain must retain submission order")

        await persistence.releaseNext()
        await completed(started[1])
        // An older A completion publishes a cache, but cannot erase newer A/B edits or change displayed cues.
        XCTAssertEqual(editor.cues.startTrimCue, 5.5)
        XCTAssertEqual(editor.cues.vocalEntryCue, 20)
        XCTAssertTrue(editor.aiTrimBypass)
        XCTAssertEqual(app.loadedCache?.tracks[a.relativePath]?.cueMarkers.vocalEntryCue, 20)
        XCTAssertEqual(app.loadedCache?.tracks[b.relativePath]?.cueMarkers.vocalEntryCue, 22)
        XCTAssertEqual(app.loadedCache?.tracks[b.relativePath]?.aiTrimBypass, true)
        for next in 2..<started.count {
            await persistence.releaseNext()
            await completed(started[next])
        }
        await persistence.releaseNext()
        await saved(editor)

        let finalA = try diskEntry(a.relativePath, root: root)
        let finalB = try diskEntry(b.relativePath, root: root)
        XCTAssertEqual(finalA.cueMarkers.startTrimCue, 5.5)
        XCTAssertEqual(finalA.cueMarkers.vocalEntryCue, 20)
        XCTAssertTrue(finalA.aiTrimBypass)
        XCTAssertEqual(finalB.cueMarkers.startTrimCue, b.cueMarkers.startTrimCue)
        XCTAssertEqual(finalB.cueMarkers.vocalEntryCue, 22)
        XCTAssertTrue(finalB.aiTrimBypass)
        XCTAssertEqual(try diskEntry(untouched.relativePath, root: root), untouched)
        XCTAssertEqual(Set(finalA.manualOverrides.overriddenFields), ["bpm", "musicalKey", "cueMarkers", "aiTrimBypass"])
        XCTAssertEqual(finalA.manualOverrides.notes, "Keep original phrasing")
        XCTAssertEqual(finalA.bpm, a.bpm)
        XCTAssertEqual(finalA.musicalKey, a.musicalKey)
        XCTAssertNotNil(finalA.manualOverrides.updatedAt)
        XCTAssertEqual(finalA.manualOverrides.author, "DJ (PulseDeck Manual Editor)")
        let submitted = await persistence.requests
        XCTAssertEqual(submitted.map(\.relativePath), [a.relativePath, b.relativePath, a.relativePath, a.relativePath, b.relativePath])

        let reloadedEditor = WaveformEditorModel(libraryRootURL: root)
        let reloadedApp = AppState(libraryRootURL: root, waveformEditorModel: reloadedEditor)
        await select(reloadedApp, a.relativePath)
        XCTAssertEqual(reloadedEditor.cues, finalA.cueMarkers)
        XCTAssertTrue(reloadedEditor.aiTrimBypass)
        reloadedEditor.setCue(.endTrim, toTime: 178)
        reloadedEditor.toggleAITrimBypass()
        await saved(reloadedEditor)
        await select(reloadedApp, b.relativePath)
        await select(reloadedApp, a.relativePath)
        XCTAssertEqual(reloadedEditor.cues.startTrimCue, 5.5)
        XCTAssertEqual(reloadedEditor.cues.vocalEntryCue, 20)
        XCTAssertEqual(reloadedEditor.cues.endTrimCue, 178)
        XCTAssertFalse(reloadedEditor.aiTrimBypass)
        XCTAssertEqual(try diskEntry(b.relativePath, root: root), finalB)
        try SharedCacheContract().validate(data: Data(contentsOf: cacheURL(root)))
    }

    @MainActor
    func testOlderSaveFailureCannotReplaceNewerRevisionOrDiscardDirtyEdits() async throws {
        let (root, a, _, _) = try makeLibrary()
        let started = [XCTestExpectation(description: "Old save"), XCTestExpectation(description: "Latest save")]
        let persistence = HeldWaveformPersistence(started: started, failures: [1])
        let editor = WaveformEditorModel(libraryRootURL: root, persistence: persistence)
        let app = AppState(libraryRootURL: root, waveformEditorModel: editor)
        addTeardownBlock {
            await persistence.releaseAll()
            await editor.waitForPendingSaves()
        }
        await select(app, a.relativePath)
        editor.setCue(.startTrim, toTime: 4)
        await completed(started[0])
        editor.setCue(.startTrim, toTime: 6)
        await persistence.releaseNext()
        await completed(started[1])
        XCTAssertEqual(editor.cues.startTrimCue, 6)
        XCTAssertNil(editor.errorMessage, "Obsolete failure must not replace the latest edit's status")
        XCTAssertTrue(editor.isSaving)
        await persistence.releaseNext()
        await saved(editor)
        XCTAssertNil(editor.errorMessage)
        XCTAssertEqual(try diskEntry(a.relativePath, root: root).cueMarkers.startTrimCue, 6)
    }

    @MainActor
    func testProductionEditorAbortsInvalidExistingCacheWithoutLosingDirtyState() async throws {
        let (root, a, b, _) = try makeLibrary()
        let editor = WaveformEditorModel(libraryRootURL: root)
        let app = AppState(libraryRootURL: root, waveformEditorModel: editor)
        await select(app, a.relativePath)
        let invalid = Data("{\"schemaVersion\":\"2.0.0\",\"libraryRoot\":\"test\"}".utf8)
        try invalid.write(to: cacheURL(root))
        editor.setCue(.startTrim, toTime: 5)
        await saved(editor)
        XCTAssertNotNil(editor.errorMessage)
        XCTAssertEqual(try Data(contentsOf: cacheURL(root)), invalid)
        await select(app, b.relativePath)
        await select(app, a.relativePath)
        XCTAssertEqual(editor.cues.startTrimCue, 5, "Failed writes remain dirty across selection")
        XCTAssertTrue(editor.manualOverrides.isManual)
        XCTAssertNotNil(editor.errorMessage, "Reselection must not hide an unsaved revision's failure")
        XCTAssertEqual(try Data(contentsOf: cacheURL(root)), invalid)
    }

    @MainActor
    func testDragCommitsBeforeTrackSwitchAndUsesProductionCueClamps() async throws {
        let (root, a, b, _) = try makeLibrary()
        let editor = WaveformEditorModel(libraryRootURL: root)
        let app = AppState(libraryRootURL: root, waveformEditorModel: editor)
        await select(app, a.relativePath)
        editor.beginDrag(cue: .startTrim)
        editor.updateDrag(cue: .startTrim, toTime: 100)
        XCTAssertEqual(editor.cues.startTrimCue, a.cueMarkers.vocalEntryCue)
        await select(app, b.relativePath)
        await saved(editor)
        await select(app, a.relativePath)
        XCTAssertEqual(editor.cues.startTrimCue, a.cueMarkers.vocalEntryCue)
        editor.setCue(.vocalEntry, toTime: -20)
        XCTAssertEqual(editor.cues.vocalEntryCue, editor.cues.startTrimCue)
        editor.setCue(.endTrim, toTime: 1_000)
        XCTAssertEqual(editor.cues.endTrimCue, a.duration)
        await saved(editor)
        XCTAssertTrue(try diskEntry(a.relativePath, root: root).cueMarkers.isValid(forDuration: a.duration))
    }

    @MainActor
    func testPendingSaveForAnotherLibraryCannotPolluteCurrentSelection() async throws {
        let (firstRoot, a, _, _) = try makeLibrary()
        let (secondRoot, otherA, _, _) = try makeLibrary()
        let started = XCTestExpectation(description: "First library save")
        let persistence = HeldWaveformPersistence(started: [started])
        let editor = WaveformEditorModel(libraryRootURL: firstRoot, persistence: persistence)
        let app = AppState(libraryRootURL: firstRoot, waveformEditorModel: editor)
        addTeardownBlock {
            await persistence.releaseAll()
            await editor.waitForPendingSaves()
        }
        await select(app, a.relativePath)
        editor.setCue(.startTrim, toTime: 6)
        await completed(started)
        app.libraryRootURL = secondRoot
        await select(app, otherA.relativePath)
        XCTAssertEqual(editor.cues, otherA.cueMarkers)
        await persistence.releaseAll()
        await saved(editor)
        XCTAssertEqual(editor.cues, otherA.cueMarkers)
        XCTAssertEqual(app.loadedCache?.tracks[otherA.relativePath], otherA)
        XCTAssertEqual(try diskEntry(otherA.relativePath, root: secondRoot), otherA)
        XCTAssertEqual(try diskEntry(a.relativePath, root: firstRoot).cueMarkers.startTrimCue, 6)
    }

    func testProductionPersistenceCreatesAbsentCacheAndPreservesOtherTracks() async throws {
        let (root, a, b, untouched) = try makeLibrary()
        let actor = WaveformPersistenceActor()
        var changed = a
        changed.cueMarkers.startTrimCue = 5
        let result = try await actor.persistTrack(changed, libraryRootURL: root)
        XCTAssertEqual(result.tracks[b.relativePath], b)
        XCTAssertEqual(result.tracks[untouched.relativePath], untouched)
        XCTAssertEqual(try diskEntry(a.relativePath, root: root), changed)
        try FileManager.default.removeItem(at: cacheURL(root))
        let created = try await actor.persistTrack(changed, libraryRootURL: root)
        XCTAssertEqual(created.tracks, [a.relativePath: changed])
        try SharedCacheContract().validate(data: Data(contentsOf: cacheURL(root)))
    }

    func testProductionSamplerMapsFractionalBinsAcrossWholeCanvas() {
        let totalBins = 4_096
        var peaks = [Float](repeating: 0.1, count: totalBins)
        peaks[1_064] = 0.95
        let metadata = WaveformMetadata(sampleCount: 2_097_152, downsampleFactor: 512,
            peakValues: peaks, lowBandPeaks: peaks, midBandPeaks: peaks, highBandPeaks: peaks)
        let samples = WaveformSampler.sampleColumns(metadata: metadata, binRange: 1_000...1_128, columnCount: 800)
        XCTAssertEqual(samples.count, 800)
        XCTAssertEqual(samples.first?.binIndex, 1_000)
        XCTAssertEqual(samples[400].binIndex, 1_064)
        XCTAssertEqual(samples[400].peak, 0.95)
        XCTAssertEqual(samples.last?.binIndex, 1_128)
        for index in 1..<samples.count { XCTAssertGreaterThanOrEqual(samples[index].binIndex, samples[index - 1].binIndex) }
        XCTAssertTrue(WaveformSampler.sampleColumns(metadata: metadata, binRange: 0...10, columnCount: 0).isEmpty)
    }

    func testProductionSamplerAggregatesPeaksWhenZoomedOut() {
        let metadata = WaveformMetadata(sampleCount: 80, downsampleFactor: 1,
            peakValues: [0, 0.2, 0.8, 0.1, 0.3, 0.9, 0.4, 0.2],
            lowBandPeaks: [0, 0.2, 0.8, 0.1, 0.3, 0.9, 0.4, 0.2],
            midBandPeaks: [0, 0.2, 0.8, 0.1, 0.3, 0.9, 0.4, 0.2],
            highBandPeaks: [0, 0.2, 0.8, 0.1, 0.3, 0.9, 0.4, 0.2])
        let samples = WaveformSampler.sampleColumns(metadata: metadata, binRange: 0...7, columnCount: 2)
        XCTAssertEqual(samples.map(\.peak), [0.8, 0.9])
    }

    func testProductionCoordinateMapperUsesVisibleWindowAndFiniteBounds() {
        let mapper = WaveformCoordinateMapper(duration: 120, zoomLevel: 2, scrollOffsetSeconds: 30, totalBins: 1_200)
        XCTAssertEqual(mapper.visibleDuration, 60)
        XCTAssertEqual(mapper.timeToX(time: 30, viewWidth: 800), 0)
        XCTAssertEqual(mapper.timeToX(time: 60, viewWidth: 800), 400)
        XCTAssertEqual(mapper.timeToX(time: 90, viewWidth: 800), 800)
        XCTAssertEqual(mapper.xToTime(x: 400, viewWidth: 800), 60)
        XCTAssertEqual(mapper.visibleBinRange(), 300...900)
        let invalid = WaveformCoordinateMapper(duration: .nan, zoomLevel: .infinity, scrollOffsetSeconds: .nan, totalBins: -1)
        XCTAssertEqual(invalid.duration, 0)
        XCTAssertEqual(invalid.zoomLevel, 1)
        XCTAssertNil(invalid.visibleBinRange())
    }

    @MainActor
    private func select(_ app: AppState, _ relativePath: String) async {
        let task = app.selectTrack(relativePath: relativePath)
        let done = XCTestExpectation(description: "Selection \(relativePath) completes while saves may be held")
        Task { await task.value; done.fulfill() }
        await completed(done)
        XCTAssertEqual(app.selectedTrackPath, relativePath)
        XCTAssertEqual(app.waveformEditorModel.currentTrack?.relativePath, relativePath)
    }

    @MainActor
    private func saved(_ editor: WaveformEditorModel) async {
        let done = XCTestExpectation(description: "Queued production saves complete")
        Task { await editor.waitForPendingSaves(); done.fulfill() }
        await completed(done)
        XCTAssertFalse(editor.isSaving)
    }

    private func completed(_ expectation: XCTestExpectation) async {
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 3)
        XCTAssertEqual(result, .completed)
    }

    private func cacheURL(_ root: URL) -> URL { root.appendingPathComponent(PulseDeckCoreConfig.cacheFileName) }

    private func diskEntry(_ path: String, root: URL) throws -> TrackCacheEntry {
        try XCTUnwrap(CachePersistence.load(from: cacheURL(root))?.tracks[path])
    }

    private func makeLibrary() throws -> (URL, TrackCacheEntry, TrackCacheEntry, TrackCacheEntry) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WaveformProductionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let a = entry(path: "crate/a.wav", duration: 180, start: 2, vocal: 10, mix: 160, end: 175)
        let b = entry(path: "crate/b.wav", duration: 200, start: 3, vocal: 15, mix: 180, end: 195)
        let untouched = entry(path: "crate/untouched.wav", duration: 200, start: 4, vocal: 16, mix: 182, end: 198)
        let cache = PulseDeckLibraryCache(libraryRoot: root.lastPathComponent,
            tracks: [a.relativePath: a, b.relativePath: b, untouched.relativePath: untouched])
        try CachePersistence.saveAtomic(cache: cache, to: cacheURL(root))
        return (root, a, b, untouched)
    }

    private func entry(path: String, duration: Double, start: Double, vocal: Double, mix: Double, end: Double) -> TrackCacheEntry {
        let peaks = [Float](repeating: 0.5, count: 200)
        return TrackCacheEntry(relativePath: path, fileFingerprint: "fixture", fileSizeBytes: 10_000,
            fileModificationTime: "2026-10-17T10:00:00Z", duration: duration, sampleRate: 44_100, channels: 2,
            bitDepth: 16, bpm: 128, musicalKey: "8A", confidence: 0.8,
            waveformMetadata: WaveformMetadata(sampleCount: Int(duration * 44_100), downsampleFactor: 512,
                peakValues: peaks, lowBandPeaks: peaks, midBandPeaks: peaks, highBandPeaks: peaks),
            beatGrid: BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 0.46875,
                beatTimestamps: stride(from: 0, to: duration, by: 0.46875).map { $0 }),
            structure: TrackStructure(sections: [], vocalSegments: []),
            cueMarkers: CueMarkers(startTrimCue: start, vocalEntryCue: vocal, mixOutCue: mix, endTrimCue: end),
            analyzerVersion: "fixture", analysisTimestamp: "2026-10-17T10:00:00Z")
    }
}
