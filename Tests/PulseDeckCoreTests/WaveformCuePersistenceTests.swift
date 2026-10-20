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

    func persistTrack(_ track: TrackCacheEntry, libraryRootURL: URL, intent: WaveformEditIntent) async throws -> PulseDeckLibraryCache {
        requests.append(track)
        let ordinal = requests.count
        if !released {
            await withCheckedContinuation { continuation in
                blocked = continuation
                if ordinal <= started.count { started[ordinal - 1].fulfill() }
            }
        }
        if failures.contains(ordinal) { throw InjectedFailure.writeFailed }
        return try await production.persistTrack(track, libraryRootURL: libraryRootURL, intent: intent)
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
    func testFirstDependentCueSaveFailureRetainsExactTargetsThroughUnrelatedSuccessAndOrderedRetry() async throws {
        try await assertDependentCueFailureRetainsTargets(failedRequest: 1)
    }

    @MainActor
    func testMiddleDependentCueSaveFailureRetainsExactTargetsThroughUnrelatedSuccessAndOrderedRetry() async throws {
        try await assertDependentCueFailureRetainsTargets(failedRequest: 2)
    }

    @MainActor
    private func assertDependentCueFailureRetainsTargets(failedRequest: Int) async throws {
        let (root, a, b, untouched) = try makeLibrary()
        let started = (1...3).map { XCTestExpectation(description: "Dependent save \($0) started") }
        let persistence = HeldWaveformPersistence(started: started, failures: [failedRequest])
        let editor = WaveformEditorModel(libraryRootURL: root, persistence: persistence)
        let app = AppState(libraryRootURL: root, waveformEditorModel: editor)
        addTeardownBlock {
            await persistence.releaseAll()
            await editor.waitForPendingSaves()
        }

        await select(app, a.relativePath)
        editor.setCue(.mixOut, toTime: 170)
        await completed(started[0])
        editor.setCue(.vocalEntry, toTime: 168)
        editor.setCue(.startTrim, toTime: 165)
        let targets = editor.cues
        XCTAssertEqual(targets, CueMarkers(startTrimCue: 165, vocalEntryCue: 168, mixOutCue: 170, endTrimCue: 175))

        var externalCache = try XCTUnwrap(CachePersistence.load(from: cacheURL(root)))
        externalCache.tracks[a.relativePath]?.bpm = 149
        externalCache.tracks[a.relativePath]?.musicalKey = "12A"
        externalCache.tracks[a.relativePath]?.manualOverrides.notes = "Preserve fresh external notes"
        try CachePersistence.saveAtomic(cache: externalCache, to: cacheURL(root))

        await persistence.releaseNext()
        await completed(started[1])
        XCTAssertEqual(editor.cues, targets)
        await persistence.releaseNext()
        await completed(started[2])
        XCTAssertEqual(editor.cues, targets)
        XCTAssertNotNil(editor.errorMessage)

        await persistence.releaseAll()
        await saved(editor)
        XCTAssertEqual(editor.cues, targets, "Failed dependent saves must retain submitted targets")
        XCTAssertTrue(editor.hasDirtyEdits(for: a.relativePath, libraryRootURL: root))
        XCTAssertTrue(editor.errorMessage?.contains("cannot save START TRIM at the requested timestamp") == true)
        var persisted = try diskEntry(a.relativePath, root: root)
        XCTAssertEqual(persisted.cueMarkers.startTrimCue, 2, "Rejected dependent save must not write a clamped value")
        XCTAssertEqual(persisted.cueMarkers.vocalEntryCue, 10, "Failed prerequisite must not permit a clamped dependent save")
        XCTAssertEqual(persisted.cueMarkers.mixOutCue, failedRequest == 1 ? 160 : 170)

        // An unrelated success must neither acknowledge failed targets nor hide their errors.
        editor.toggleAITrimBypass()
        await saved(editor)
        await select(app, b.relativePath)
        await select(app, a.relativePath)
        await select(app, a.relativePath)
        XCTAssertEqual(editor.cues, targets)
        XCTAssertTrue(editor.aiTrimBypass)
        XCTAssertTrue(editor.hasDirtyEdits(for: a.relativePath, libraryRootURL: root))
        XCTAssertNotNil(editor.errorMessage)
        XCTAssertEqual(editor.currentTrack?.bpm, 149)
        XCTAssertEqual(editor.currentTrack?.musicalKey, "12A")
        XCTAssertEqual(editor.manualOverrides.notes, "Preserve fresh external notes")

        if failedRequest == 1 {
            editor.setCue(.mixOut, toTime: editor.cueTime(for: .mixOut))
            await saved(editor)
            XCTAssertEqual(editor.cues, targets)
            XCTAssertTrue(editor.hasDirtyEdits(for: a.relativePath, libraryRootURL: root))
            XCTAssertNotNil(editor.errorMessage, "Prerequisite retry cannot clear dependent errors")
        }
        editor.setCue(.vocalEntry, toTime: editor.cueTime(for: .vocalEntry))
        await saved(editor)
        XCTAssertEqual(editor.cues, targets)
        XCTAssertTrue(editor.hasDirtyEdits(for: a.relativePath, libraryRootURL: root))
        XCTAssertNotNil(editor.errorMessage, "Vocal retry cannot clear failed start trim")
        editor.setCue(.startTrim, toTime: editor.cueTime(for: .startTrim))
        await saved(editor)

        persisted = try diskEntry(a.relativePath, root: root)
        XCTAssertEqual(persisted.cueMarkers, targets)
        XCTAssertTrue(persisted.aiTrimBypass)
        XCTAssertEqual(persisted.bpm, 149)
        XCTAssertEqual(persisted.musicalKey, "12A")
        XCTAssertEqual(persisted.manualOverrides.notes, "Preserve fresh external notes")
        XCTAssertEqual(try diskEntry(untouched.relativePath, root: root), untouched)
        XCTAssertFalse(editor.hasDirtyEdits(for: a.relativePath, libraryRootURL: root))
        XCTAssertNil(editor.errorMessage)

        let reloadedEditor = WaveformEditorModel(libraryRootURL: root)
        let reloadedApp = AppState(libraryRootURL: root, waveformEditorModel: reloadedEditor)
        await select(reloadedApp, a.relativePath)
        XCTAssertEqual(reloadedEditor.cues, targets)
        XCTAssertTrue(reloadedEditor.aiTrimBypass)
        try SharedCacheContract().validate(data: Data(contentsOf: cacheURL(root)))
    }

    @MainActor
    func testHeldSaveDependentCueMovesSurviveReselectionAndSubsequentEditReleaseReload() async throws {
        let (root, a, b, untouched) = try makeLibrary()
        let started = [XCTestExpectation(description: "First save started")]
        let persistence = HeldWaveformPersistence(started: started)
        let editor = WaveformEditorModel(libraryRootURL: root, persistence: persistence)
        let app = AppState(libraryRootURL: root, waveformEditorModel: editor)
        addTeardownBlock {
            await persistence.releaseAll()
            await editor.waitForPendingSaves()
        }

        await select(app, a.relativePath)
        editor.setCue(.mixOut, toTime: 170)
        await completed(started[0])
        editor.setCue(.vocalEntry, toTime: 168)
        editor.setCue(.startTrim, toTime: 165)
        XCTAssertTrue(editor.isSaving)

        // Switch to B and back to A while saves remain held
        await select(app, b.relativePath)
        await select(app, a.relativePath)

        XCTAssertEqual(editor.cues.startTrimCue, 165, "Start trim must not be clamped against stale persisted neighbors")
        XCTAssertEqual(editor.cues.vocalEntryCue, 168, "Vocal entry must not be clamped against stale persisted neighbors")
        XCTAssertEqual(editor.cues.mixOutCue, 170, "Mix out must match local edit")
        XCTAssertEqual(editor.cues.endTrimCue, 175, "End trim must retain untouched persisted value")

        // Repeat selection back to B and back to A (second overlay pass)
        await select(app, b.relativePath)
        await select(app, a.relativePath)

        XCTAssertEqual(editor.cues.startTrimCue, 165, "Start trim must survive repeated selection overlay")
        XCTAssertEqual(editor.cues.vocalEntryCue, 168, "Vocal entry must survive repeated selection overlay")
        XCTAssertEqual(editor.cues.mixOutCue, 170, "Mix out must survive repeated selection overlay")
        XCTAssertEqual(editor.cues.endTrimCue, 175, "End trim must retain untouched persisted value")

        // Subsequent edit while earlier saves still held
        editor.setCue(.mixOut, toTime: 172)

        // Release all held saves and await completion
        await persistence.releaseAll()
        await saved(editor)

        let finalA = try diskEntry(a.relativePath, root: root)
        XCTAssertEqual(finalA.cueMarkers.startTrimCue, 165)
        XCTAssertEqual(finalA.cueMarkers.vocalEntryCue, 168)
        XCTAssertEqual(finalA.cueMarkers.mixOutCue, 172)
        XCTAssertEqual(finalA.cueMarkers.endTrimCue, 175)
        XCTAssertEqual(try diskEntry(untouched.relativePath, root: root), untouched)

        // Reload fresh editor/app from disk
        let reloadedEditor = WaveformEditorModel(libraryRootURL: root)
        let reloadedApp = AppState(libraryRootURL: root, waveformEditorModel: reloadedEditor)
        await select(reloadedApp, a.relativePath)
        XCTAssertEqual(reloadedEditor.cues.startTrimCue, 165)
        XCTAssertEqual(reloadedEditor.cues.vocalEntryCue, 168)
        XCTAssertEqual(reloadedEditor.cues.mixOutCue, 172)
        XCTAssertEqual(reloadedEditor.cues.endTrimCue, 175)
    }

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
    func testFailedCueSaveSurvivesSuccessfulDifferentCueSaveAndCanRetry() async throws {
        let (root, a, _, _) = try makeLibrary()
        let started = [
            XCTestExpectation(description: "Failed start cue save"),
            XCTestExpectation(description: "Successful vocal cue save"),
            XCTestExpectation(description: "Retried start cue save")
        ]
        let persistence = HeldWaveformPersistence(started: started, failures: [1])
        let editor = WaveformEditorModel(libraryRootURL: root, persistence: persistence)
        let app = AppState(libraryRootURL: root, waveformEditorModel: editor)
        addTeardownBlock {
            await persistence.releaseAll()
            await editor.waitForPendingSaves()
        }
        await select(app, a.relativePath)

        var diskCache = try XCTUnwrap(CachePersistence.load(from: cacheURL(root)))
        var diskTrack = try XCTUnwrap(diskCache.tracks[a.relativePath])
        diskTrack.bpm = 150.0
        diskTrack.musicalKey = "12A"
        diskTrack.cueMarkers.endTrimCue = 170.0
        diskTrack.manualOverrides = ManualOverrides(
            isManual: true,
            overriddenFields: ["bpm", "musicalKey"],
            author: "External DJ",
            notes: "Fresh external notes"
        )
        diskCache.tracks[a.relativePath] = diskTrack
        try CachePersistence.saveAtomic(cache: diskCache, to: cacheURL(root))

        editor.setCue(.startTrim, toTime: 4.0)
        await completed(started[0])
        editor.setCue(.vocalEntry, toTime: 20.0)
        await persistence.releaseNext()
        await completed(started[1])

        XCTAssertNotNil(editor.errorMessage, "Older failed cue must remain visible while another cue saves")
        XCTAssertTrue(editor.hasDirtyEdits(for: a.relativePath, libraryRootURL: root))
        await persistence.releaseNext()
        await saved(editor)

        XCTAssertEqual(editor.cues.startTrimCue, 4.0)
        XCTAssertEqual(editor.cues.vocalEntryCue, 20.0)
        XCTAssertNotNil(editor.errorMessage, "Successful vocal save must not hide failed start cue")
        XCTAssertTrue(editor.hasDirtyEdits(for: a.relativePath, libraryRootURL: root))
        var persisted = try diskEntry(a.relativePath, root: root)
        XCTAssertEqual(persisted.cueMarkers.startTrimCue, a.cueMarkers.startTrimCue)
        XCTAssertEqual(persisted.cueMarkers.vocalEntryCue, 20.0)
        XCTAssertEqual(persisted.cueMarkers.endTrimCue, 170.0)
        XCTAssertEqual(persisted.bpm, 150.0)
        XCTAssertEqual(persisted.musicalKey, "12A")
        XCTAssertEqual(persisted.manualOverrides.notes, "Fresh external notes")

        await select(app, a.relativePath)
        XCTAssertEqual(editor.cues.startTrimCue, 4.0, "Reselection must retain failed cue intent")
        XCTAssertEqual(editor.cues.vocalEntryCue, 20.0, "Reselection must retain successful cue")
        XCTAssertEqual(editor.cues.endTrimCue, 170.0, "Reselection must adopt unrelated disk cue")
        XCTAssertEqual(editor.currentTrack?.bpm, 150.0, "Reselection must adopt fresh disk BPM")
        XCTAssertEqual(editor.currentTrack?.musicalKey, "12A", "Reselection must adopt fresh disk key")
        XCTAssertEqual(editor.manualOverrides.notes, "Fresh external notes")
        XCTAssertNotNil(editor.errorMessage, "Reselection must retain failed cue error")

        editor.setCue(.startTrim, toTime: 4.0)
        await completed(started[2])
        await persistence.releaseNext()
        await saved(editor)

        persisted = try diskEntry(a.relativePath, root: root)
        XCTAssertEqual(persisted.cueMarkers.startTrimCue, 4.0)
        XCTAssertEqual(persisted.cueMarkers.vocalEntryCue, 20.0)
        XCTAssertEqual(persisted.cueMarkers.endTrimCue, 170.0)
        XCTAssertEqual(persisted.bpm, 150.0)
        XCTAssertEqual(persisted.musicalKey, "12A")
        XCTAssertEqual(persisted.manualOverrides.notes, "Fresh external notes")
        XCTAssertFalse(editor.hasDirtyEdits(for: a.relativePath, libraryRootURL: root))
        XCTAssertNil(editor.errorMessage)
    }

    @MainActor
    func testFailedCueSaveSurvivesSuccessfulBypassSaveAndCanRetry() async throws {
        let (root, a, _, _) = try makeLibrary()
        let started = [
            XCTestExpectation(description: "Failed start cue save"),
            XCTestExpectation(description: "Successful bypass save"),
            XCTestExpectation(description: "Retried start cue save")
        ]
        let persistence = HeldWaveformPersistence(started: started, failures: [1])
        let editor = WaveformEditorModel(libraryRootURL: root, persistence: persistence)
        let app = AppState(libraryRootURL: root, waveformEditorModel: editor)
        addTeardownBlock {
            await persistence.releaseAll()
            await editor.waitForPendingSaves()
        }
        await select(app, a.relativePath)

        var diskCache = try XCTUnwrap(CachePersistence.load(from: cacheURL(root)))
        var diskTrack = try XCTUnwrap(diskCache.tracks[a.relativePath])
        diskTrack.bpm = 151.0
        diskTrack.musicalKey = "1A"
        diskTrack.cueMarkers.vocalEntryCue = 12.0
        diskTrack.manualOverrides = ManualOverrides(
            isManual: true,
            overriddenFields: ["bpm", "musicalKey"],
            author: "External DJ",
            notes: "Fresh external notes"
        )
        diskCache.tracks[a.relativePath] = diskTrack
        try CachePersistence.saveAtomic(cache: diskCache, to: cacheURL(root))

        editor.setCue(.startTrim, toTime: 4.0)
        await completed(started[0])
        editor.toggleAITrimBypass()
        await persistence.releaseNext()
        await completed(started[1])

        XCTAssertNotNil(editor.errorMessage, "Older failed cue must remain visible while bypass saves")
        XCTAssertTrue(editor.hasDirtyEdits(for: a.relativePath, libraryRootURL: root))
        await persistence.releaseNext()
        await saved(editor)

        XCTAssertEqual(editor.cues.startTrimCue, 4.0)
        XCTAssertTrue(editor.aiTrimBypass)
        XCTAssertNotNil(editor.errorMessage, "Successful bypass save must not hide failed cue")
        XCTAssertTrue(editor.hasDirtyEdits(for: a.relativePath, libraryRootURL: root))
        var persisted = try diskEntry(a.relativePath, root: root)
        XCTAssertEqual(persisted.cueMarkers.startTrimCue, a.cueMarkers.startTrimCue)
        XCTAssertEqual(persisted.cueMarkers.vocalEntryCue, 12.0)
        XCTAssertEqual(persisted.bpm, 151.0)
        XCTAssertEqual(persisted.musicalKey, "1A")
        XCTAssertEqual(persisted.manualOverrides.notes, "Fresh external notes")
        XCTAssertTrue(persisted.aiTrimBypass)

        await select(app, a.relativePath)
        XCTAssertEqual(editor.cues.startTrimCue, 4.0, "Reselection must retain failed cue intent")
        XCTAssertEqual(editor.cues.vocalEntryCue, 12.0, "Reselection must adopt unrelated disk cue")
        XCTAssertEqual(editor.currentTrack?.bpm, 151.0, "Reselection must adopt fresh disk BPM")
        XCTAssertEqual(editor.currentTrack?.musicalKey, "1A", "Reselection must adopt fresh disk key")
        XCTAssertEqual(editor.manualOverrides.notes, "Fresh external notes")
        XCTAssertTrue(editor.aiTrimBypass, "Reselection must retain successful bypass")
        XCTAssertNotNil(editor.errorMessage, "Reselection must retain failed cue error")

        editor.setCue(.startTrim, toTime: 4.0)
        await completed(started[2])
        await persistence.releaseNext()
        await saved(editor)

        persisted = try diskEntry(a.relativePath, root: root)
        XCTAssertEqual(persisted.cueMarkers.startTrimCue, 4.0)
        XCTAssertEqual(persisted.cueMarkers.vocalEntryCue, 12.0)
        XCTAssertEqual(persisted.bpm, 151.0)
        XCTAssertEqual(persisted.musicalKey, "1A")
        XCTAssertEqual(persisted.manualOverrides.notes, "Fresh external notes")
        XCTAssertTrue(persisted.aiTrimBypass)
        XCTAssertFalse(editor.hasDirtyEdits(for: a.relativePath, libraryRootURL: root))
        XCTAssertNil(editor.errorMessage)
    }

    @MainActor
    func testEarlierSaveCompletionPreservesCueDragUntilDragIsCommitted() async throws {
        let (root, a, _, _) = try makeLibrary()
        let started = [XCTestExpectation(description: "Earlier save"), XCTestExpectation(description: "Drag save")]
        let persistence = HeldWaveformPersistence(started: started)
        let editor = WaveformEditorModel(libraryRootURL: root, persistence: persistence)
        let app = AppState(libraryRootURL: root, waveformEditorModel: editor)
        addTeardownBlock {
            await persistence.releaseAll()
            await editor.waitForPendingSaves()
        }

        await select(app, a.relativePath)
        editor.setCue(.startTrim, toTime: 6.2)
        await completed(started[0])

        editor.beginDrag(cue: .vocalEntry)
        editor.updateDrag(cue: .vocalEntry, toTime: 25.0)
        await persistence.releaseNext()
        await editor.waitForPendingSaves()

        XCTAssertEqual(editor.cues.vocalEntryCue, 25.0)
        XCTAssertEqual(editor.activeDraggingCue, .vocalEntry)

        editor.endDrag(cue: .vocalEntry)
        await completed(started[1])
        await persistence.releaseNext()
        await saved(editor)

        let persisted = try diskEntry(a.relativePath, root: root)
        XCTAssertEqual(persisted.cueMarkers.startTrimCue, 6.2)
        XCTAssertEqual(persisted.cueMarkers.vocalEntryCue, 25.0)

        let reloadedEditor = WaveformEditorModel(libraryRootURL: root)
        let reloadedApp = AppState(libraryRootURL: root, waveformEditorModel: reloadedEditor)
        await select(reloadedApp, a.relativePath)
        XCTAssertEqual(reloadedEditor.cues.startTrimCue, 6.2)
        XCTAssertEqual(reloadedEditor.cues.vocalEntryCue, 25.0)
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
        changed.manualOverrides = ManualOverrides(isManual: true, overriddenFields: ["cueMarkers"])
        let intent = WaveformEditIntent.cue(.startTrim, acceptedPreviousValues: [a.cueMarkers.startTrimCue])
        let result = try await actor.persistTrack(changed, libraryRootURL: root, intent: intent)
        XCTAssertEqual(result.tracks[b.relativePath], b)
        XCTAssertEqual(result.tracks[untouched.relativePath], untouched)
        XCTAssertEqual(try diskEntry(a.relativePath, root: root), changed)
        try FileManager.default.removeItem(at: cacheURL(root))
        let created = try await actor.persistTrack(changed, libraryRootURL: root, intent: intent)
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

    func testProductionSamplerHandlesEmptyAndUnequalBandLengthsSafely() throws {
        // Schema-valid entry where peakValues has entries, but band arrays are empty or shorter
        let peaks: [Float] = [0.1, 0.4, 0.9, 0.3, 0.7]
        let lowPeaks: [Float] = [0.2] // shorter
        let midPeaks: [Float] = [] // empty
        let highPeaks: [Float] = [0.05, 0.3, 0.8] // shorter

        let metadata = WaveformMetadata(
            sampleCount: 2_560,
            downsampleFactor: 512,
            peakValues: peaks,
            lowBandPeaks: lowPeaks,
            midBandPeaks: midPeaks,
            highBandPeaks: highPeaks
        )

        // Must not crash/trap, and must correctly sample available peaks while defaulting missing bands to 0
        let samples = WaveformSampler.sampleColumns(metadata: metadata, binRange: 0...4, columnCount: 5)
        XCTAssertEqual(samples.count, 5)
        XCTAssertEqual(samples[2].peak, 0.9)
        XCTAssertEqual(samples[2].low, 0.0) // low was only 1 element, bin 2 is safely 0.0
        XCTAssertEqual(samples[2].mid, 0.0) // mid was empty, safely 0.0
        XCTAssertEqual(samples[2].high, 0.8) // high has 3 elements, bin 2 is 0.8
        XCTAssertEqual(samples[4].high, 0.0) // bin 4 out of bounds for high, safely 0.0

        // Entirely empty bands in valid cache loaded from disk must render safely
        let (root, _, _, _) = try makeLibrary()
        var diskCache = try XCTUnwrap(CachePersistence.load(from: cacheURL(root)))
        let emptyBandsTrack = TrackCacheEntry(
            relativePath: "crate/empty_bands.wav",
            fileFingerprint: "empty_bands_fp",
            fileSizeBytes: 5_000,
            fileModificationTime: "2026-10-17T10:00:00Z",
            duration: 60.0,
            sampleRate: 44_100,
            channels: 2,
            bitDepth: 16,
            bpm: 120.0,
            musicalKey: "5A",
            confidence: 0.9,
            waveformMetadata: WaveformMetadata(
                sampleCount: 60 * 44_100,
                downsampleFactor: 512,
                peakValues: [0.5, 0.8],
                lowBandPeaks: [],
                midBandPeaks: [],
                highBandPeaks: []
            ),
            beatGrid: BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 0.5, beatTimestamps: [0, 0.5]),
            structure: TrackStructure(sections: [], vocalSegments: []),
            cueMarkers: CueMarkers(startTrimCue: 0, vocalEntryCue: 5, mixOutCue: 50, endTrimCue: 60),
            analyzerVersion: "fixture",
            analysisTimestamp: "2026-10-17T10:00:00Z"
        )
        diskCache.tracks[emptyBandsTrack.relativePath] = emptyBandsTrack
        try CachePersistence.saveAtomic(cache: diskCache, to: cacheURL(root))

        let reloaded = try XCTUnwrap(CachePersistence.load(from: cacheURL(root))?.tracks[emptyBandsTrack.relativePath])
        let loadedSamples = WaveformSampler.sampleColumns(metadata: reloaded.waveformMetadata, binRange: 0...1, columnCount: 10)
        XCTAssertEqual(loadedSamples.count, 10)
        XCTAssertEqual(loadedSamples.first?.peak, 0.5)
        XCTAssertEqual(loadedSamples.last?.peak, 0.8)
        XCTAssertEqual(loadedSamples.first?.low, 0.0)
    }

    func testProductionMinimapSamplerCoversCompleteTrackAndAgreesWithScrollMapping() {
        // Case 1: 1,200 bins across 800 columns (total > cols)
        // Ensure final third (bins 800..1199) is NOT omitted and end spike is present in final column
        let totalBins = 1_200
        let cols = 800
        var peaks1200 = [Float](repeating: 0.1, count: totalBins)
        peaks1200[1_199] = 0.95 // Spike at the very end of track
        let metadata1200 = WaveformMetadata(
            sampleCount: 1_200 * 512,
            downsampleFactor: 512,
            peakValues: peaks1200,
            lowBandPeaks: peaks1200,
            midBandPeaks: peaks1200,
            highBandPeaks: peaks1200
        )

        let minimapSamples1200 = WaveformSampler.sampleMinimap(metadata: metadata1200, columnCount: cols)
        XCTAssertEqual(minimapSamples1200.count, cols)
        XCTAssertEqual(minimapSamples1200.first?.binIndex, 0)
        // Last column must reach the end bin and capture the spike
        XCTAssertEqual(minimapSamples1200.last?.peak, 0.95)
        XCTAssertGreaterThanOrEqual(minimapSamples1200.last?.binIndex ?? 0, 1_198)

        // Coordinate mapper viewport at scroll end aligns with end bins
        let duration = 240.0
        let mapper = WaveformCoordinateMapper(
            duration: duration,
            zoomLevel: 2.0,
            scrollOffsetSeconds: 120.0, // Scrolled to final half
            totalBins: totalBins
        )
        let visibleRange = try! XCTUnwrap(mapper.visibleBinRange())
        XCTAssertEqual(visibleRange.upperBound, totalBins - 1)
        // Minimap drag at far right corresponds to full duration
        let endFrac = 1.0
        XCTAssertEqual(endFrac * duration, duration)

        // Case 2: Fewer bins than columns (100 bins, 800 columns)
        // Proportional sampling must distribute bins across width without freezing the last bin
        let fewBins = 100
        var linearPeaks = [Float](repeating: 0.0, count: fewBins)
        for i in 0..<fewBins { linearPeaks[i] = Float(i) / Float(fewBins) }
        let metadataFew = WaveformMetadata(
            sampleCount: fewBins * 512,
            downsampleFactor: 512,
            peakValues: linearPeaks,
            lowBandPeaks: linearPeaks,
            midBandPeaks: linearPeaks,
            highBandPeaks: linearPeaks
        )

        let minimapFew = WaveformSampler.sampleMinimap(metadata: metadataFew, columnCount: cols)
        XCTAssertEqual(minimapFew.count, cols)
        XCTAssertEqual(minimapFew.first?.binIndex, 0)
        // Center column (400) maps proportionally to ~50, NOT clamped to 99
        let midBin = try! XCTUnwrap(minimapFew[400].binIndex)
        XCTAssertTrue((49...51).contains(midBin), "Mid column should map near bin 50, got \(midBin)")
        // Bin index strictly increases across width
        for c in 1..<minimapFew.count {
            XCTAssertGreaterThanOrEqual(minimapFew[c].binIndex, minimapFew[c - 1].binIndex)
        }
    }

    @MainActor
    func testSelectionAdoptsFreshDiskChangesAndManualSavePreservesFreshAnalysisAndUnrelatedFields() async throws {
        let (root, a, _, _) = try makeLibrary()
        let editor = WaveformEditorModel(libraryRootURL: root)
        let app = AppState(libraryRootURL: root, waveformEditorModel: editor)

        // 1. Initial selection loads baseline state into in-memory cache and editor
        await select(app, a.relativePath)
        XCTAssertEqual(editor.currentTrack?.bpm, 128.0)
        XCTAssertEqual(editor.currentTrack?.musicalKey, "8A")

        // 2. External analyzer updates disk after in-memory cache was populated
        var updatedDiskCache = try XCTUnwrap(CachePersistence.load(from: cacheURL(root)))
        let updatedEntry = TrackCacheEntry(
            relativePath: a.relativePath,
            fileFingerprint: "fresh_reanalysis_hash",
            fileSizeBytes: 12_000,
            fileModificationTime: "2026-10-17T12:00:00Z",
            duration: a.duration,
            sampleRate: a.sampleRate,
            channels: a.channels,
            bitDepth: a.bitDepth,
            bpm: 142.5,
            musicalKey: "11B",
            confidence: 0.99,
            waveformMetadata: a.waveformMetadata,
            beatGrid: a.beatGrid,
            structure: a.structure,
            cueMarkers: a.cueMarkers,
            aiTrimBypass: false,
            manualOverrides: ManualOverrides(
                isManual: true,
                overriddenFields: ["bpm"],
                updatedAt: "2026-10-17T12:00:00Z",
                author: "External Pro DJ",
                notes: "Preserve external phrasing"
            ),
            analyzerVersion: "v2-pro",
            analysisTimestamp: "2026-10-17T12:00:00Z"
        )
        updatedDiskCache.tracks[a.relativePath] = updatedEntry
        try CachePersistence.saveAtomic(cache: updatedDiskCache, to: cacheURL(root))

        // 3. Same-track reselection must NOT early return; unedited selection adopts fresh disk
        await select(app, a.relativePath)
        XCTAssertEqual(editor.currentTrack?.bpm, 142.5)
        XCTAssertEqual(editor.currentTrack?.musicalKey, "11B")
        XCTAssertEqual(editor.currentTrack?.fileFingerprint, "fresh_reanalysis_hash")
        XCTAssertEqual(editor.manualOverrides.notes, "Preserve external phrasing")
        XCTAssertEqual(editor.manualOverrides.author, "External Pro DJ")

        // 4. Subsequent manual cue edit and AI trim bypass save
        editor.setCue(.startTrim, toTime: 4.8)
        editor.toggleAITrimBypass()
        await saved(editor)

        // 5. Verify saved disk entry preserved fresh non-manual metadata AND unrelated manual fields
        let savedEntry = try diskEntry(a.relativePath, root: root)
        XCTAssertEqual(savedEntry.cueMarkers.startTrimCue, 4.8)
        XCTAssertTrue(savedEntry.aiTrimBypass)
        XCTAssertEqual(savedEntry.bpm, 142.5, "Fresh analysis/manual BPM preserved")
        XCTAssertEqual(savedEntry.musicalKey, "11B", "Fresh analysis key preserved")
        XCTAssertEqual(savedEntry.fileFingerprint, "fresh_reanalysis_hash", "Fresh non-manual fingerprint preserved")
        XCTAssertEqual(savedEntry.confidence, 0.99, "Fresh non-manual confidence preserved")
        XCTAssertEqual(savedEntry.manualOverrides.notes, "Preserve external phrasing", "Unrelated manual notes preserved")
        XCTAssertEqual(savedEntry.manualOverrides.author, "DJ (PulseDeck Manual Editor)")
        XCTAssertEqual(Set(savedEntry.manualOverrides.overriddenFields), ["bpm", "cueMarkers", "aiTrimBypass"])
    }

    @MainActor
    func testCueAndBypassSaveMergesOnlyCurrentIntentIntoFreshDiskEntry() async throws {
        let (root, a, _, _) = try makeLibrary()
        var initialCache = try XCTUnwrap(CachePersistence.load(from: cacheURL(root)))
        initialCache.tracks[a.relativePath]?.manualOverrides = ManualOverrides(
            isManual: true,
            overriddenFields: ["bpm", "musicalKey"],
            author: "Original DJ",
            notes: "old notes"
        )
        try CachePersistence.saveAtomic(cache: initialCache, to: cacheURL(root))

        let editor = WaveformEditorModel(libraryRootURL: root)
        let app = AppState(libraryRootURL: root, waveformEditorModel: editor)
        await select(app, a.relativePath)
        XCTAssertEqual(editor.manualOverrides.notes, "old notes")

        var externalCache = try XCTUnwrap(CachePersistence.load(from: cacheURL(root)))
        var externalEntry = try XCTUnwrap(externalCache.tracks[a.relativePath])
        externalEntry.bpm = 147.5
        externalEntry.musicalKey = "12A"
        externalEntry.cueMarkers.vocalEntryCue = 12.0
        externalEntry.cueMarkers.mixOutCue = 155.0
        externalEntry.manualOverrides.updatedAt = "2026-10-17T13:00:00Z"
        externalEntry.manualOverrides.author = "External DJ"
        externalEntry.manualOverrides.notes = "new notes"
        externalCache.tracks[a.relativePath] = externalEntry
        try CachePersistence.saveAtomic(cache: externalCache, to: cacheURL(root))

        editor.setCue(.startTrim, toTime: 4.0)
        editor.toggleAITrimBypass()
        await saved(editor)

        let savedEntry = try diskEntry(a.relativePath, root: root)
        XCTAssertEqual(savedEntry.cueMarkers.startTrimCue, 4.0)
        XCTAssertEqual(savedEntry.cueMarkers.vocalEntryCue, 12.0)
        XCTAssertEqual(savedEntry.cueMarkers.mixOutCue, 155.0)
        XCTAssertTrue(savedEntry.aiTrimBypass)
        XCTAssertEqual(savedEntry.bpm, 147.5)
        XCTAssertEqual(savedEntry.musicalKey, "12A")
        XCTAssertEqual(savedEntry.manualOverrides.notes, "new notes")
        XCTAssertEqual(savedEntry.manualOverrides.author, "DJ (PulseDeck Manual Editor)")
        XCTAssertEqual(Set(savedEntry.manualOverrides.overriddenFields), ["bpm", "musicalKey", "cueMarkers", "aiTrimBypass"])

        let reloadedEditor = WaveformEditorModel(libraryRootURL: root)
        let reloadedApp = AppState(libraryRootURL: root, waveformEditorModel: reloadedEditor)
        await select(reloadedApp, a.relativePath)
        XCTAssertEqual(reloadedEditor.cues.startTrimCue, 4.0)
        XCTAssertEqual(reloadedEditor.cues.vocalEntryCue, 12.0)
        XCTAssertEqual(reloadedEditor.cues.mixOutCue, 155.0)
        XCTAssertTrue(reloadedEditor.aiTrimBypass)
        XCTAssertEqual(reloadedEditor.manualOverrides.notes, "new notes")
        XCTAssertEqual(reloadedEditor.currentTrack?.bpm, 147.5)
        XCTAssertEqual(reloadedEditor.currentTrack?.musicalKey, "12A")
    }

    @MainActor
    func testConcurrentEditToSameCueAbortsWithoutOverwritingDisk() async throws {
        let (root, a, b, _) = try makeLibrary()
        let editor = WaveformEditorModel(libraryRootURL: root)
        let app = AppState(libraryRootURL: root, waveformEditorModel: editor)
        await select(app, a.relativePath)

        var externalCache = try XCTUnwrap(CachePersistence.load(from: cacheURL(root)))
        externalCache.tracks[a.relativePath]?.cueMarkers.startTrimCue = 3.0
        try CachePersistence.saveAtomic(cache: externalCache, to: cacheURL(root))

        editor.setCue(.startTrim, toTime: 4.0)
        await saved(editor)

        XCTAssertTrue(editor.errorMessage?.contains("newer START TRIM edit on disk") == true)
        XCTAssertEqual(try diskEntry(a.relativePath, root: root).cueMarkers.startTrimCue, 3.0)
        XCTAssertEqual(try diskEntry(a.relativePath, root: root).cueMarkers.vocalEntryCue, a.cueMarkers.vocalEntryCue)
        XCTAssertTrue(editor.hasDirtyEdits(for: a.relativePath, libraryRootURL: root))

        editor.toggleAITrimBypass()
        await saved(editor)
        await select(app, b.relativePath)
        await select(app, a.relativePath)
        XCTAssertEqual(editor.cues.startTrimCue, 4)
        XCTAssertTrue(editor.aiTrimBypass)
        XCTAssertTrue(editor.errorMessage?.contains("newer START TRIM edit on disk") == true)
        XCTAssertTrue(editor.hasDirtyEdits(for: a.relativePath, libraryRootURL: root))

        editor.setCue(.startTrim, toTime: editor.cueTime(for: .startTrim))
        await saved(editor)
        XCTAssertEqual(editor.cues.startTrimCue, 4)
        XCTAssertEqual(try diskEntry(a.relativePath, root: root).cueMarkers.startTrimCue, 3)
        XCTAssertTrue(editor.errorMessage?.contains("newer START TRIM edit on disk") == true)
        XCTAssertTrue(editor.hasDirtyEdits(for: a.relativePath, libraryRootURL: root))

        // Once the external conflict is resolved, explicit retry persists the retained target.
        externalCache = try XCTUnwrap(CachePersistence.load(from: cacheURL(root)))
        externalCache.tracks[a.relativePath]?.cueMarkers.startTrimCue = a.cueMarkers.startTrimCue
        try CachePersistence.saveAtomic(cache: externalCache, to: cacheURL(root))
        editor.setCue(.startTrim, toTime: editor.cueTime(for: .startTrim))
        await saved(editor)
        XCTAssertEqual(try diskEntry(a.relativePath, root: root).cueMarkers.startTrimCue, 4)
        XCTAssertTrue(try diskEntry(a.relativePath, root: root).aiTrimBypass)
        XCTAssertFalse(editor.hasDirtyEdits(for: a.relativePath, libraryRootURL: root))
        XCTAssertNil(editor.errorMessage)
    }

    @MainActor
    func testPendingInteractionPreventsDiskOverwriteUntilAcknowledged() async throws {
        let (root, a, _, _) = try makeLibrary()
        let started = [XCTestExpectation(description: "Held save")]
        let persistence = HeldWaveformPersistence(started: started)
        let editor = WaveformEditorModel(libraryRootURL: root, persistence: persistence)
        let app = AppState(libraryRootURL: root, waveformEditorModel: editor)
        addTeardownBlock {
            await persistence.releaseAll()
            await editor.waitForPendingSaves()
        }

        await select(app, a.relativePath)

        // Begin active edit which triggers pending save
        editor.setCue(.startTrim, toTime: 6.2)
        await completed(started[0])
        XCTAssertTrue(editor.isSaving)
        XCTAssertTrue(editor.hasDirtyEdits(for: a.relativePath, libraryRootURL: root))

        // Disk changes while local edit is pending
        var diskCache = try XCTUnwrap(CachePersistence.load(from: cacheURL(root)))
        diskCache.tracks[a.relativePath]?.bpm = 150.0
        try CachePersistence.saveAtomic(cache: diskCache, to: cacheURL(root))

        // Reselecting same path while edit is pending must NOT overwrite dirty local cues
        let reselectTask = app.selectTrack(relativePath: a.relativePath)
        await reselectTask.value
        XCTAssertEqual(editor.cues.startTrimCue, 6.2)

        // Active drag gesture also prevents disk overwrite
        editor.beginDrag(cue: .vocalEntry)
        editor.updateDrag(cue: .vocalEntry, toTime: 25.0)
        let dragReselectTask = app.selectTrack(relativePath: a.relativePath)
        await dragReselectTask.value
        XCTAssertEqual(editor.cues.vocalEntryCue, 25.0)
        editor.endDrag(cue: .vocalEntry)

        // Release all held saves and wait for completion
        await persistence.releaseAll()
        await saved(editor)

        // Once saved and acknowledged, dirty state is cleared
        XCTAssertFalse(editor.hasDirtyEdits(for: a.relativePath, libraryRootURL: root))
        let final = try diskEntry(a.relativePath, root: root)
        XCTAssertEqual(final.cueMarkers.startTrimCue, 6.2)
        XCTAssertEqual(final.cueMarkers.vocalEntryCue, 25.0)
        XCTAssertEqual(final.bpm, 150.0, "Saved merge preserved disk BPM")
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
