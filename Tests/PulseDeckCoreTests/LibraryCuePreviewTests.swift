import XCTest
import CoreAudio
import AVFoundation
@testable import PulseDeckCore
@testable import PulseDeckAI

final class LibraryCuePreviewTests: XCTestCase {

    private var mockHAL: MockAudioHardware!
    private var coordinator: AudioEngineCoordinator!

    override func setUp() {
        super.setUp()
        mockHAL = MockAudioHardware()

        // Configure default mock devices: Speakers (Master) and Headphones (Cue)
        mockHAL.addDevice(
            id: 201,
            uid: "speakers_uid",
            name: "Internal Speakers",
            manufacturer: "Apple Inc.",
            outputChannels: 2,
            sampleRate: 44100.0,
            transportType: 0
        )
        mockHAL.addDevice(
            id: 202,
            uid: "headphones_uid",
            name: "Headphones Jack",
            manufacturer: "Apple Inc.",
            outputChannels: 2,
            sampleRate: 44100.0,
            transportType: 0
        )
        mockHAL.setDefaultOutputID(201)
        coordinator = AudioEngineCoordinator(hal: mockHAL)
    }

    override func tearDown() {
        coordinator.stop()
        coordinator = nil
        mockHAL = nil
        super.tearDown()
    }

    // MARK: - Test Helpers

    @MainActor
    private func makeOfflineAppState(
        startCoordinator: Bool = true,
        beforePreviewFilePreparation: (@Sendable (URL) async -> Void)? = nil
    ) throws -> (AppState, URL) {
        let audio = try XCTUnwrap(coordinator)
        try audio.monitor.performOnControlQueue {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
            try audio.masterAudioEngine.rawEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            try audio.cueAudioEngine.rawEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tempDir) }

        let app = AppState(
            libraryRootURL: tempDir,
            waveformEditorModel: WaveformEditorModel(libraryRootURL: tempDir),
            audioCoordinator: audio,
            startCoordinator: startCoordinator,
            beforePreviewFilePreparation: beforePreviewFilePreparation
        )
        return (app, tempDir)
    }

    private func makeSyntheticAudioFile(url: URL, durationSeconds: Double = 2.0, sampleRate: Double = 44100.0, signal: Float? = nil) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw NSError(domain: "TestAudio", code: -1)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(durationSeconds * sampleRate)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "TestAudio", code: -2)
        }
        pcm.frameLength = frameCount
        let channels = try XCTUnwrap(pcm.floatChannelData)
        for ch in 0..<Int(format.channelCount) {
            for fr in 0..<Int(frameCount) {
                channels[ch][fr] = signal ?? (Float(sin(Double(fr) * 0.05)) * 0.3)
            }
        }
        try file.write(from: pcm)
    }

    private func makeTrackEntry(
        relativePath: String,
        duration: Double = 120.0,
        bpm: Double = 120.0,
        musicalKey: String = "8A",
        confidence: Double = 0.9,
        hasValidGrid: Bool = true
    ) -> TrackCacheEntry {
        let beatInterval = bpm > 0 ? (60.0 / bpm) : 1.0
        let timestamps: [Double]
        if hasValidGrid && bpm > 0 {
            var ts: [Double] = []
            var current = 0.0
            while current < duration {
                ts.append(current)
                current += beatInterval
            }
            timestamps = ts
        } else {
            timestamps = []
        }

        return TrackCacheEntry(
            relativePath: relativePath,
            fileFingerprint: "fp-\(relativePath)",
            fileSizeBytes: 1024,
            fileModificationTime: "2026-10-22T00:00:00Z",
            duration: duration,
            sampleRate: 44100.0,
            channels: 2,
            bitDepth: 16,
            bpm: bpm,
            musicalKey: musicalKey,
            confidence: confidence,
            waveformMetadata: WaveformMetadata(
                sampleCount: 100,
                downsampleFactor: 10,
                peakValues: [Float](repeating: 0.5, count: 100),
                lowBandPeaks: [Float](repeating: 0.5, count: 100),
                midBandPeaks: [Float](repeating: 0.5, count: 100),
                highBandPeaks: [Float](repeating: 0.5, count: 100)
            ),
            beatGrid: BeatGrid(
                firstBeatOffsetSeconds: 0.0,
                beatIntervalSeconds: beatInterval,
                beatTimestamps: timestamps
            ),
            structure: TrackStructure(sections: [], vocalSegments: []),
            cueMarkers: CueMarkers(
                startTrimCue: 0.0,
                vocalEntryCue: min(2.0, duration * 0.2),
                mixOutCue: max(min(2.0, duration * 0.2), duration * 0.8),
                endTrimCue: duration
            ),
            aiTrimBypass: false,
            manualOverrides: ManualOverrides(),
            analyzerVersion: "1.0.0",
            analysisTimestamp: "2026-10-22T00:00:00Z"
        )
    }

    // MARK: - Compatibility & Camelot Key Tests

    func testCamelotKeyDirectAndStandardNotationParsing() {
        // Direct Camelot
        XCTAssertEqual(CamelotKey.parse("8A"), CamelotKey(number: 8, mode: .minor))
        XCTAssertEqual(CamelotKey.parse("12B"), CamelotKey(number: 12, mode: .major))
        XCTAssertEqual(CamelotKey.parse(" 1b "), CamelotKey(number: 1, mode: .major))
        XCTAssertNil(CamelotKey.parse("13A"))
        XCTAssertNil(CamelotKey.parse("0B"))

        // Standard Notation Mapping
        XCTAssertEqual(CamelotKey.parse("Am"), CamelotKey(number: 8, mode: .minor))
        XCTAssertEqual(CamelotKey.parse("A minor"), CamelotKey(number: 8, mode: .minor))
        XCTAssertEqual(CamelotKey.parse("C"), CamelotKey(number: 8, mode: .major))
        XCTAssertEqual(CamelotKey.parse("C maj"), CamelotKey(number: 8, mode: .major))
        XCTAssertEqual(CamelotKey.parse("F#m"), CamelotKey(number: 11, mode: .minor))
        XCTAssertEqual(CamelotKey.parse("Ebm"), CamelotKey(number: 2, mode: .minor))
        XCTAssertEqual(CamelotKey.parse("Gb"), CamelotKey(number: 2, mode: .major))

        // Unknown / Invalid
        XCTAssertNil(CamelotKey.parse("Unknown"))
        XCTAssertNil(CamelotKey.parse("unknown"))
        XCTAssertNil(CamelotKey.parse(""))
        XCTAssertNil(CamelotKey.parse("InvalidNotationXYZ"))
    }

    func testHarmonicRelationshipsOnCamelotWheel() {
        let key8A = CamelotKey(number: 8, mode: .minor)!
        let key8B = CamelotKey(number: 8, mode: .major)!
        let key9A = CamelotKey(number: 9, mode: .minor)!
        let key7A = CamelotKey(number: 7, mode: .minor)!
        let key10A = CamelotKey(number: 10, mode: .minor)!
        let key12A = CamelotKey(number: 12, mode: .minor)!
        let key1A = CamelotKey(number: 1, mode: .minor)!

        // Exact match
        XCTAssertEqual(TrackCompatibility.evaluateHarmonicRelationship(candidate: key8A, reference: key8A), .exact)
        XCTAssertTrue(HarmonicRelationship.exact.isHarmonic)

        // Relative major / minor
        XCTAssertEqual(TrackCompatibility.evaluateHarmonicRelationship(candidate: key8B, reference: key8A), .relative)
        XCTAssertTrue(HarmonicRelationship.relative.isHarmonic)

        // Adjacent +1 / -1
        XCTAssertEqual(TrackCompatibility.evaluateHarmonicRelationship(candidate: key9A, reference: key8A), .adjacentPlus)
        XCTAssertEqual(TrackCompatibility.evaluateHarmonicRelationship(candidate: key7A, reference: key8A), .adjacentMinus)

        // Wheel wrap around 12 and 1
        XCTAssertEqual(TrackCompatibility.evaluateHarmonicRelationship(candidate: key1A, reference: key12A), .adjacentPlus)
        XCTAssertEqual(TrackCompatibility.evaluateHarmonicRelationship(candidate: key12A, reference: key1A), .adjacentMinus)

        // Clash (> 1 step)
        XCTAssertEqual(TrackCompatibility.evaluateHarmonicRelationship(candidate: key10A, reference: key8A), .clash)
        XCTAssertFalse(HarmonicRelationship.clash.isHarmonic)
    }

    func testTempoThresholdBoundaryAdheresToPlannerThreshold() {
        let refTrack = makeTrackEntry(relativePath: "ref.wav", bpm: 100.0)

        // Case 1: Below threshold (< 6.0%) -> Compatible
        // 105.0 BPM vs 100.0 BPM -> delta = 5.0% < 6.0%
        let candCompatible = makeTrackEntry(relativePath: "c1.wav", bpm: 105.0)
        let comp1 = TrackCompatibility.evaluate(candidate: candCompatible, reference: refTrack)
        XCTAssertTrue(comp1.tempo.isCompatible)
        if case .compatible(let delta) = comp1.tempo {
            XCTAssertEqual(delta, 5.0, accuracy: 0.01)
        } else {
            XCTFail("Expected compatible tempo")
        }

        // Case 2: Exactly 6.0% (Boundary condition) -> Mismatch (adheres strictly to planner's < 0.06 without contradictory inclusive boundary)
        let candBoundary = makeTrackEntry(relativePath: "c2.wav", bpm: 106.0)
        let comp2 = TrackCompatibility.evaluate(candidate: candBoundary, reference: refTrack)
        XCTAssertFalse(comp2.tempo.isCompatible)
        if case .mismatch(let delta) = comp2.tempo {
            XCTAssertEqual(delta, 6.0, accuracy: 0.01)
        } else {
            XCTFail("Expected tempo mismatch at exactly 6.0%")
        }

        // Case 3: Above threshold (> 6.0%) -> Mismatch
        let candMismatch = makeTrackEntry(relativePath: "c3.wav", bpm: 110.0)
        let comp3 = TrackCompatibility.evaluate(candidate: candMismatch, reference: refTrack)
        XCTAssertFalse(comp3.tempo.isCompatible)
    }

    func testUnknownCasesAndSentinelsNeverFabricateCompatibleValues() {
        let refValid = makeTrackEntry(relativePath: "ref.wav", bpm: 120.0, musicalKey: "8A")

        // 1. Candidate with 0 BPM
        let candZeroBPM = makeTrackEntry(relativePath: "zero_bpm.wav", bpm: 0.0, musicalKey: "8A", hasValidGrid: false)
        let compZero = TrackCompatibility.evaluate(candidate: candZeroBPM, reference: refValid)
        XCTAssertEqual(compZero.tempo, .unknown)
        XCTAssertFalse(compZero.isOverallCompatible)

        // 2. Candidate with unknown-tempo 1.0s sentinel (hasValidGrid = false)
        let candSentinel = makeTrackEntry(relativePath: "sentinel.wav", bpm: 120.0, musicalKey: "8A", hasValidGrid: false)
        let compSentinel = TrackCompatibility.evaluate(candidate: candSentinel, reference: refValid)
        XCTAssertEqual(compSentinel.tempo, .unknown)
        XCTAssertFalse(compSentinel.isOverallCompatible)

        // 3. Candidate with unrecognized Key
        let candBadKey = makeTrackEntry(relativePath: "bad_key.wav", bpm: 120.0, musicalKey: "Unknown")
        let compBadKey = TrackCompatibility.evaluate(candidate: candBadKey, reference: refValid)
        XCTAssertEqual(compBadKey.key, .unknown)
        XCTAssertFalse(compBadKey.isOverallCompatible)

        // 4. Reference with 0 BPM
        let refZeroBPM = makeTrackEntry(relativePath: "ref_zero.wav", bpm: 0.0, musicalKey: "8A", hasValidGrid: false)
        let compRefZero = TrackCompatibility.evaluate(candidate: refValid, reference: refZeroBPM)
        XCTAssertEqual(compRefZero.tempo, .unknown)

        // 5. Reference with unrecognized Key
        let refBadKey = makeTrackEntry(relativePath: "ref_bad.wav", bpm: 120.0, musicalKey: "Unknown")
        let compRefBadKey = TrackCompatibility.evaluate(candidate: refValid, reference: refBadKey)
        XCTAssertEqual(compRefBadKey.key, .unknown)
    }

    // MARK: - AppState Audition & Selection Isolation

    @MainActor
    func testReferenceDeckSelectionIsolation() async throws {
        let (app, tempDir) = try makeOfflineAppState()

        let fileA = tempDir.appendingPathComponent("deckA.wav")
        let fileB = tempDir.appendingPathComponent("deckB.wav")
        let fileCand = tempDir.appendingPathComponent("cand.wav")
        try makeSyntheticAudioFile(url: fileA, durationSeconds: 5.0)
        try makeSyntheticAudioFile(url: fileB, durationSeconds: 5.0)
        try makeSyntheticAudioFile(url: fileCand, durationSeconds: 5.0)

        let trackA = makeTrackEntry(relativePath: "deckA.wav", duration: 5.0, bpm: 120.0, musicalKey: "8A")
        let trackB = makeTrackEntry(relativePath: "deckB.wav", duration: 5.0, bpm: 140.0, musicalKey: "2A")
        let candidate = makeTrackEntry(relativePath: "cand.wav", duration: 5.0, bpm: 122.0, musicalKey: "8A")

        let cache = PulseDeckLibraryCache(libraryRoot: "root", tracks: [
            "deckA.wav": trackA,
            "deckB.wav": trackB,
            "cand.wav": candidate
        ])
        let cacheURL = tempDir.appendingPathComponent(PulseDeckCoreConfig.cacheFileName)
        try CachePersistence.saveAtomic(cache: cache, to: cacheURL)

        app.refreshLibrary()
        try await Task.sleep(nanoseconds: 100_000_000)

        // When no deck loaded -> referenceTrack is nil, compatibility is nil
        XCTAssertNil(app.referenceTrack)
        XCTAssertNil(app.compatibility(for: candidate))

        // Load Deck A
        app.selectTrack(relativePath: "deckA.wav")
        app.loadSelectedTrackIntoDeck(deck: .deckA)

        // Load Deck B
        app.selectTrack(relativePath: "deckB.wav")
        app.loadSelectedTrackIntoDeck(deck: .deckB)

        // Reference set to Deck A (120 BPM, 8A)
        app.setCompatibilityReferenceDeck(.deckA)
        XCTAssertEqual(app.referenceTrack?.relativePath, "deckA.wav")
        let compA = try XCTUnwrap(app.compatibility(for: candidate))
        XCTAssertTrue(compA.isOverallCompatible)

        // Switch Reference to Deck B (140 BPM, 2A) -> Candidate (122 BPM, 8A) now clashes both tempo and key
        app.setCompatibilityReferenceDeck(.deckB)
        XCTAssertEqual(app.referenceTrack?.relativePath, "deckB.wav")
        let compB = try XCTUnwrap(app.compatibility(for: candidate))
        XCTAssertFalse(compB.isOverallCompatible)
        XCTAssertFalse(compB.key.isHarmonic)
        XCTAssertFalse(compB.tempo.isCompatible)
    }

    @MainActor
    func testAuditionPreviewLoadPlayPauseStopAndBoundedSeek() async throws {
        let (app, tempDir) = try makeOfflineAppState()
        let audioURL = tempDir.appendingPathComponent("preview_track.wav")
        try makeSyntheticAudioFile(url: audioURL, durationSeconds: 3.0)

        // Load preview track
        app.loadPreviewTrack(relativePath: "preview_track.wav")

        // Wait for detached async load to complete on MainActor
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(app.previewTrackPath, "preview_track.wav")
        XCTAssertEqual(app.previewDurationSeconds, 3.0, accuracy: 0.1)
        XCTAssertEqual(app.previewPositionSeconds, 0.0)
        XCTAssertNil(app.previewErrorMessage)

        // Toggle Play
        app.togglePreviewPlay()
        XCTAssertTrue(app.isPreviewPlaying)

        // Pause
        app.togglePreviewPlay()
        XCTAssertFalse(app.isPreviewPlaying)

        // Bounded Seek - negative clamped to 0.0
        app.seekPreview(to: -5.0)
        XCTAssertEqual(app.previewPositionSeconds, 0.0)

        // Bounded Seek - beyond duration clamped to duration
        app.seekPreview(to: 10.0)
        XCTAssertEqual(app.previewPositionSeconds, app.previewDurationSeconds, accuracy: 0.05)

        // Bounded Seek - inside valid interval
        app.seekPreview(to: 1.5)
        XCTAssertEqual(app.previewPositionSeconds, 1.5, accuracy: 0.05)

        // Stop
        app.stopPreview()
        XCTAssertFalse(app.isPreviewPlaying)
        XCTAssertEqual(app.previewPositionSeconds, 0.0)
    }

    @MainActor
    func testBeatSteppingDisabledForSentinelAndEnabledForValidGrid() async throws {
        let (app, tempDir) = try makeOfflineAppState()

        // 1. Track with valid measured grid (120 BPM, interval = 0.5s)
        let validURL = tempDir.appendingPathComponent("valid.wav")
        try makeSyntheticAudioFile(url: validURL, durationSeconds: 10.0)
        let validEntry = makeTrackEntry(relativePath: "valid.wav", duration: 10.0, bpm: 120.0, hasValidGrid: true)

        let cache = PulseDeckLibraryCache(libraryRoot: "root", tracks: ["valid.wav": validEntry])
        let cacheURL = tempDir.appendingPathComponent(PulseDeckCoreConfig.cacheFileName)
        try CachePersistence.saveAtomic(cache: cache, to: cacheURL)

        app.refreshLibrary()
        try await Task.sleep(nanoseconds: 100_000_000)

        app.loadPreviewTrack(relativePath: "valid.wav")
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(app.previewHasUsableBeatGrid)

        // Step forward 1 beat (+0.5s from 0.0)
        app.stepPreview(beats: 1.0)
        XCTAssertEqual(app.previewPositionSeconds, 0.5, accuracy: 0.05)

        // Step forward 4 beats (1 bar = +2.0s from 0.5 -> 2.5s)
        app.stepPreview(beats: 4.0)
        XCTAssertEqual(app.previewPositionSeconds, 2.5, accuracy: 0.05)

        // Step backward 1 beat (-0.5s from 2.5 -> 2.0s)
        app.stepPreview(beats: -1.0)
        XCTAssertEqual(app.previewPositionSeconds, 2.0, accuracy: 0.05)

        // 2. Track with 1.0s unknown-tempo sentinel grid
        let sentinelURL = tempDir.appendingPathComponent("sentinel.wav")
        try makeSyntheticAudioFile(url: sentinelURL, durationSeconds: 10.0)
        let sentinelEntry = makeTrackEntry(relativePath: "sentinel.wav", duration: 10.0, bpm: 0.0, hasValidGrid: false)

        let cache2 = PulseDeckLibraryCache(libraryRoot: "root", tracks: ["sentinel.wav": sentinelEntry])
        try CachePersistence.saveAtomic(cache: cache2, to: cacheURL)
        app.refreshLibrary()
        try await Task.sleep(nanoseconds: 100_000_000)

        app.loadPreviewTrack(relativePath: "sentinel.wav")
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(app.previewHasUsableBeatGrid)
        let posBefore = app.previewPositionSeconds

        // Beat stepping must be a complete no-op (disabled rather than inventing beats)
        app.stepPreview(beats: 1.0)
        XCTAssertEqual(app.previewPositionSeconds, posBefore)
        app.stepPreview(beats: 4.0)
        XCTAssertEqual(app.previewPositionSeconds, posBefore)
    }

    @MainActor
    func testStaleLoadRequestsAndRootSwitchingIsolation() async throws {
        let (app, tempDir) = try makeOfflineAppState()

        let trackA = tempDir.appendingPathComponent("trackA.wav")
        let trackB = tempDir.appendingPathComponent("trackB.wav")
        try makeSyntheticAudioFile(url: trackA, durationSeconds: 2.0)
        try makeSyntheticAudioFile(url: trackB, durationSeconds: 5.0)

        // Trigger load for track A, then immediately for track B
        app.loadPreviewTrack(relativePath: "trackA.wav")
        app.loadPreviewTrack(relativePath: "trackB.wav")

        try await Task.sleep(nanoseconds: 150_000_000)

        // Final state must reflect Track B, not stale Track A
        XCTAssertEqual(app.previewTrackPath, "trackB.wav")
        XCTAssertEqual(app.previewDurationSeconds, 5.0, accuracy: 0.1)

        // Root switching isolation: updating library root cancels in-flight preview
        let newRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: newRoot) }

        app.updateLibraryRootURL(newRoot)
        XCTAssertNil(app.previewTrackPath)
        XCTAssertFalse(app.isPreviewPlaying)
        XCTAssertEqual(app.previewPositionSeconds, 0.0)
    }

    @MainActor
    func testPreviewFailureFlagsDoNotCrashOrCorruptState() async throws {
        let (app, _) = try makeOfflineAppState()

        // Attempt to load non-existent audio file
        app.loadPreviewTrack(relativePath: "non_existent_file.wav")
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNotNil(app.previewErrorMessage)
        XCTAssertFalse(app.isPreviewPlaying)
        XCTAssertEqual(app.previewDurationSeconds, 0.0)
    }


    private actor PreparationGate {
        private var entered = false
        private var released = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func hold() async {
            entered = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
            if !released {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
        }

        func waitUntilEntered() async {
            if !entered {
                await withCheckedContinuation { entryWaiters.append($0) }
            }
        }

        func release() {
            released = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }
    }

    @MainActor
    private func assertCueSignal(_ expected: Float, file: StaticString = #filePath, line: UInt = #line) throws {
        let engine = try XCTUnwrap(coordinator).cueAudioEngine.rawEngine
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        XCTAssertEqual(try engine.renderOffline(4096, to: buffer), .success, file: file, line: line)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        let samples = (512..<Int(buffer.frameLength)).map { channels[0][$0] }
        XCTAssertFalse(samples.isEmpty, file: file, line: line)
        let maximumError = samples.map { abs($0 - expected) }.max() ?? .infinity
        XCTAssertLessThan(maximumError, 0.015, "Actual Cue PCM must match the requested file", file: file, line: line)
    }

    @MainActor
    func testImmediateLibraryCueSequenceStartsOnlyRequestedAudioAfterLoad() async throws {
        let (app, root) = try makeOfflineAppState()
        let audio = try XCTUnwrap(coordinator)
        try makeSyntheticAudioFile(url: root.appendingPathComponent("first.wav"), signal: 0.2)
        try makeSyntheticAudioFile(url: root.appendingPathComponent("next.wav"), durationSeconds: 3, signal: -0.3)

        // Exact synchronous library CUE button sequence: no sleep or yield before Play.
        let first = app.loadPreviewTrack(relativePath: "first.wav")
        app.togglePreviewPlay()
        await first.value
        XCTAssertTrue(app.isPreviewPlaying)
        XCTAssertTrue(audio.cuePreview.isPlaying)
        try assertCueSignal(0.2)

        let next = app.loadPreviewTrack(relativePath: "next.wav")
        app.togglePreviewPlay()
        await next.value
        XCTAssertTrue(app.isPreviewPlaying)
        XCTAssertTrue(audio.cuePreview.isPlaying)
        XCTAssertEqual(audio.cuePreview.trackDurationSeconds, 3, accuracy: 0.001)
        try assertCueSignal(-0.3)
        app.stopPreview()
    }

    @MainActor
    func testOutOfOrderPreparationCannotReplaceCurrentPreviewAudio() async throws {
        let gate = PreparationGate()
        let (app, root) = try makeOfflineAppState(beforePreviewFilePreparation: { url in
            if url.lastPathComponent == "old.wav" { await gate.hold() }
        })
        let audio = try XCTUnwrap(coordinator)
        try makeSyntheticAudioFile(url: root.appendingPathComponent("old.wav"), durationSeconds: 2, signal: 0.2)
        try makeSyntheticAudioFile(url: root.appendingPathComponent("current.wav"), durationSeconds: 4, signal: -0.3)
        let old = app.loadPreviewTrack(relativePath: "old.wav")
        await gate.waitUntilEntered()
        let current = app.loadPreviewTrack(relativePath: "current.wav")
        await current.value
        app.togglePreviewPlay()
        XCTAssertTrue(audio.cuePreview.isPlaying)
        try assertCueSignal(-0.3)
        await gate.release()
        await old.value

        XCTAssertEqual(app.previewTrackPath, "current.wav")
        XCTAssertEqual(app.previewDurationSeconds, 4, accuracy: 0.001)
        XCTAssertEqual(audio.cuePreview.trackDurationSeconds, 4, accuracy: 0.001)
        XCTAssertTrue(audio.cuePreview.isPlaying, "Stale preparation must not stop the current player")
        XCTAssertTrue(app.isPreviewPlaying)
        try assertCueSignal(-0.3)
        app.stopPreview()
    }

    @MainActor
    func testPendingOldRootCannotInstallOrStopNewRootAudio() async throws {
        let gate = PreparationGate()
        let (app, root) = try makeOfflineAppState(beforePreviewFilePreparation: { url in
            if url.lastPathComponent == "old.wav" { await gate.hold() }
        })
        let audio = try XCTUnwrap(coordinator)
        try makeSyntheticAudioFile(url: root.appendingPathComponent("old.wav"), durationSeconds: 2, signal: 0.2)
        let old = app.loadPreviewTrack(relativePath: "old.wav")
        await gate.waitUntilEntered()
        let newRoot = root.appendingPathComponent("newRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        try makeSyntheticAudioFile(url: newRoot.appendingPathComponent("new.wav"), durationSeconds: 5, signal: -0.3)
        app.updateLibraryRootURL(newRoot)
        let current = app.loadPreviewTrack(relativePath: "new.wav")
        await current.value
        app.togglePreviewPlay()
        try assertCueSignal(-0.3)
        await gate.release()
        await old.value

        XCTAssertEqual(app.previewTrackPath, "new.wav")
        XCTAssertEqual(audio.cuePreview.trackDurationSeconds, 5, accuracy: 0.001)
        XCTAssertTrue(audio.cuePreview.isPlaying)
        try assertCueSignal(-0.3)
        app.stopPreview()
    }


    @MainActor
    func testPendingPlayIntentCanBeCancelledAndRootRoundTripInvalidatesPreparation() async throws {
        let firstGate = PreparationGate()
        let secondGate = PreparationGate()
        let (app, root) = try makeOfflineAppState(beforePreviewFilePreparation: { url in
            if url.lastPathComponent == "first.wav" { await firstGate.hold() }
            if url.lastPathComponent == "second.wav" { await secondGate.hold() }
        })
        let audio = try XCTUnwrap(coordinator)
        try makeSyntheticAudioFile(url: root.appendingPathComponent("first.wav"), signal: 0.2)
        try makeSyntheticAudioFile(url: root.appendingPathComponent("second.wav"), durationSeconds: 4, signal: -0.3)
        let first = app.loadPreviewTrack(relativePath: "first.wav")
        app.togglePreviewPlay()
        app.togglePreviewPlay()
        await firstGate.waitUntilEntered()
        await firstGate.release()
        await first.value
        XCTAssertFalse(app.isPreviewPlaying)
        XCTAssertFalse(audio.cuePreview.isPlaying)
        app.togglePreviewPlay()
        XCTAssertTrue(app.isPreviewPlaying)
        try assertCueSignal(0.2)

        let pending = app.loadPreviewTrack(relativePath: "second.wav")
        app.togglePreviewPlay()
        await secondGate.waitUntilEntered()
        app.stopPreview()
        // Direct root assignments also invalidate identity, including a round trip to the same root/path.
        app.libraryRootURL = root.appendingPathComponent("otherRoot")
        app.libraryRootURL = root
        await secondGate.release()
        await pending.value
        XCTAssertNil(app.previewTrackPath)
        XCTAssertEqual(app.previewDurationSeconds, 0)
        XCTAssertFalse(app.isPreviewPlaying)
        XCTAssertFalse(audio.cuePreview.isPlaying)
        XCTAssertEqual(audio.cuePreview.trackDurationSeconds, 2, accuracy: 0.001,
                       "Invalidated preparation must not replace the previous installed file")
        try assertCueSignal(0)
    }

    @MainActor
    func testFailedAndStalePreparationsNeverPlayPreviousFile() async throws {
        let gate = PreparationGate()
        let (app, root) = try makeOfflineAppState(beforePreviewFilePreparation: { url in
            if url.lastPathComponent == "stale-missing.wav" { await gate.hold() }
        })
        let audio = try XCTUnwrap(coordinator)
        try makeSyntheticAudioFile(url: root.appendingPathComponent("good.wav"), signal: 0.2)
        let good = app.loadPreviewTrack(relativePath: "good.wav")
        app.togglePreviewPlay()
        await good.value
        XCTAssertTrue(app.isPreviewPlaying)
        let failed = app.loadPreviewTrack(relativePath: "missing.wav")
        app.togglePreviewPlay()
        XCTAssertFalse(audio.cuePreview.isPlaying, "A pending request cannot play the previous file")
        await failed.value
        XCTAssertNotNil(app.previewErrorMessage)
        XCTAssertFalse(app.isPreviewPlaying)
        app.togglePreviewPlay()
        XCTAssertFalse(audio.cuePreview.isPlaying, "A failed request cannot play the previous file on retry")
        try assertCueSignal(0)

        let stale = app.loadPreviewTrack(relativePath: "stale-missing.wav")
        app.togglePreviewPlay()
        await gate.waitUntilEntered()
        let retry = app.loadPreviewTrack(relativePath: "good.wav")
        app.togglePreviewPlay()
        await retry.value
        await gate.release()
        await stale.value
        XCTAssertNil(app.previewErrorMessage)
        XCTAssertEqual(app.previewTrackPath, "good.wav")
        XCTAssertTrue(app.isPreviewPlaying)
        XCTAssertTrue(audio.cuePreview.isPlaying)
        try assertCueSignal(0.2)
        app.stopPreview()
    }

    @MainActor
    func testPlayerRejectsPreparedFileAfterStopInvalidatesSerializedRequest() throws {
        let (_, root) = try makeOfflineAppState()
        let preview = try XCTUnwrap(coordinator).cuePreview
        let url = root.appendingPathComponent("prepared.wav")
        try makeSyntheticAudioFile(url: url, signal: 0.2)
        let request = preview.beginLoad()
        let file = try AVAudioFile(forReading: url)
        preview.stop()
        let installed = preview.load(file: file, requestID: request)
        XCTAssertFalse(installed)
        XCTAssertEqual(preview.trackDurationSeconds, 0)
        XCTAssertFalse(preview.isPlaying)
        try assertCueSignal(0)
    }

    // MARK: - Master Engine Isolation

    @MainActor
    func testMasterEnginePlaybackPCMAndPlayheadUnaffectedByAuditionOperations() async throws {
        let (app, tempDir) = try makeOfflineAppState(startCoordinator: true)
        let audio = try XCTUnwrap(coordinator)
        let master = audio.masterAudioEngine.rawEngine
        let format = master.manualRenderingFormat

        // Create Master deck track
        let masterTrackURL = tempDir.appendingPathComponent("master_track.wav")
        try makeSyntheticAudioFile(url: masterTrackURL, durationSeconds: 10.0)

        // Load into Deck A and start playback
        try audio.deckAGraph.loadTrack(url: masterTrackURL)
        app.toggleDeckPlay(deck: .deckA)
        XCTAssertTrue(app.isDeckAPlaying)
        XCTAssertTrue(audio.masterAudioEngine.isRunning)

        // Render initial 4096 frames on Master engine
        let buffer1 = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        XCTAssertEqual(try master.renderOffline(4096, to: buffer1), .success)
        let masterGeneration = audio.deckAGraph.scheduleGeneration
        let otherGeneration = audio.deckBGraph.scheduleGeneration
        let masterVolume = audio.deckAGraph.volume
        let masterGain = audio.deckAGraph.masterFaderNode.outputVolume
        let crossfader = app.crossfaderPosition
        let initialSampleTime = master.manualRenderingSampleTime
        XCTAssertEqual(initialSampleTime, 4096)

        // Verify non-silent Master PCM signal
        let channels1 = try XCTUnwrap(buffer1.floatChannelData)
        var maxPeak1: Float = 0.0
        for frame in 0..<Int(buffer1.frameLength) {
            maxPeak1 = max(maxPeak1, abs(channels1[0][frame]))
        }
        XCTAssertGreaterThan(maxPeak1, 0.05, "Master output must render genuine audio signal")

        // Concurrently operate Audition Preview on Cue engine:
        let previewURL = tempDir.appendingPathComponent("audition_track.wav")
        try makeSyntheticAudioFile(url: previewURL, durationSeconds: 4.0)

        app.loadPreviewTrack(relativePath: "audition_track.wav")
        try await Task.sleep(nanoseconds: 80_000_000)

        app.togglePreviewPlay()
        app.seekPreview(to: 2.0)
        app.stepPreview(beats: 1.0)
        app.stopPreview()

        // Render second block on Master engine
        let buffer2 = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        XCTAssertEqual(try master.renderOffline(4096, to: buffer2), .success)
        let secondSampleTime = master.manualRenderingSampleTime

        // Master playhead must advance monotonically unaffected
        XCTAssertEqual(secondSampleTime, 8192)
        XCTAssertEqual(audio.deckAGraph.scheduleGeneration, masterGeneration)
        XCTAssertEqual(audio.deckBGraph.scheduleGeneration, otherGeneration)
        XCTAssertEqual(audio.deckAGraph.volume, masterVolume)
        XCTAssertEqual(audio.deckAGraph.masterFaderNode.outputVolume, masterGain)
        XCTAssertEqual(app.crossfaderPosition, crossfader)

        // Verify second block also contains genuine Master audio signal
        let channels2 = try XCTUnwrap(buffer2.floatChannelData)
        var maxPeak2: Float = 0.0
        for frame in 0..<Int(buffer2.frameLength) {
            maxPeak2 = max(maxPeak2, abs(channels2[0][frame]))
        }
        XCTAssertGreaterThan(maxPeak2, 0.05, "Master PCM signal must continue undisturbed by audition player")

        // Deck A intent must remain playing
        XCTAssertTrue(app.isDeckAPlaying)
        XCTAssertTrue(audio.masterAudioEngine.isRunning)
    }

    @MainActor
    func testCueFailureDoesNotInterruptRunningMasterEngine() async throws {
        let gate = PreparationGate()
        let (app, tempDir) = try makeOfflineAppState(startCoordinator: true, beforePreviewFilePreparation: { _ in
            await gate.hold()
        })
        let audio = try XCTUnwrap(coordinator)
        let master = audio.masterAudioEngine.rawEngine
        let format = master.manualRenderingFormat

        // Create Master deck track
        let masterTrackURL = tempDir.appendingPathComponent("master_running.wav")
        try makeSyntheticAudioFile(url: masterTrackURL, durationSeconds: 8.0)
        try audio.deckAGraph.loadTrack(url: masterTrackURL)

        app.toggleDeckPlay(deck: .deckA)
        XCTAssertTrue(app.isDeckAPlaying)
        XCTAssertTrue(audio.masterAudioEngine.isRunning)

        // Render block to establish running playhead
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        XCTAssertEqual(try master.renderOffline(4096, to: buffer), .success)

        // Stop cue audio engine and inject startup error
        audio.cueAudioEngine.stop()
        audio.cueAudioEngine.startErrorForTesting = CoreAudioError.osStatus(-10868, operation: "cueStartFailure")

        // Attempting to toggle preview play fails gracefully on cue without stopping master
        try makeSyntheticAudioFile(url: tempDir.appendingPathComponent("any_track.wav"))
        let pending = app.loadPreviewTrack(relativePath: "any_track.wav")
        await gate.waitUntilEntered()
        app.togglePreviewPlay()
        XCTAssertNotNil(app.previewErrorMessage)
        await gate.release()
        await pending.value
        XCTAssertNotNil(app.previewErrorMessage, "File completion must not acknowledge a failed cue startup")
        XCTAssertFalse(app.isPreviewPlaying)

        // Master audio engine MUST still be running and advancing
        XCTAssertTrue(audio.masterAudioEngine.isRunning)
        XCTAssertTrue(app.isDeckAPlaying)

        let bufferAfter = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        XCTAssertEqual(try master.renderOffline(4096, to: bufferAfter), .success)
        XCTAssertEqual(master.manualRenderingSampleTime, 8192)
    }
}
