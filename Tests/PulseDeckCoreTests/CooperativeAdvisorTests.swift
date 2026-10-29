import Foundation
import XCTest
@testable import PulseDeckCore
@testable import PulseDeckAI

final class CooperativeAdvisorTests: XCTestCase {

    // MARK: - Fixtures

    private static func makeTrack(path: String, bpm: Double = 124.0, key: String = "8A", duration: Double = 180.0) -> TrackCacheEntry {
        TrackCacheEntry(
            relativePath: path,
            fileFingerprint: "fp-\(path)",
            fileSizeBytes: 1024,
            fileModificationTime: "2026-10-29T12:00:00Z",
            duration: duration,
            sampleRate: 44100,
            channels: 2,
            bitDepth: 16,
            bpm: bpm,
            musicalKey: key,
            confidence: 0.95,
            waveformMetadata: WaveformMetadata(
                sampleCount: 2, downsampleFactor: 1,
                peakValues: [0.5], lowBandPeaks: [0.5], midBandPeaks: [0.5], highBandPeaks: [0.5]
            ),
            beatGrid: BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 0.5, beatTimestamps: [0]),
            structure: TrackStructure(sections: [], vocalSegments: []),
            cueMarkers: CueMarkers(startTrimCue: 0, vocalEntryCue: 0, mixOutCue: duration, endTrimCue: duration),
            analyzerVersion: "test",
            analysisTimestamp: "2026-10-29T12:00:00Z"
        )
    }

    private static func makeValidRecommendation(suggestedPath: String, bars: Int = 16, mixIn: Double = 16.0) -> AdvisorRecommendation {
        AdvisorRecommendation(
            suggestedTrackPath: suggestedPath,
            rationale: "Smooth harmonic blend maintaining dancefloor energy.",
            harmonicCompatibility: "8A -> 8A (Perfect key match)",
            transitionBars: bars,
            suggestedMixInSeconds: mixIn,
            energyProgression: "Building from verse to peak chorus"
        )
    }

    // MARK: - Mock Types

    private final class MockLocalAdvisorProvider: LocalAdvisorProvider, @unchecked Sendable {
        let modelIdentifier: String
        var isAvailable: Bool = true
        var recommendation: AdvisorRecommendation?
        var delayNanoseconds: UInt64 = 0
        var errorToThrow: (any Error)?
        private(set) var callCount: Int = 0

        init(modelIdentifier: String = "Ollama: gemma3:4b", recommendation: AdvisorRecommendation? = nil) {
            self.modelIdentifier = modelIdentifier
            self.recommendation = recommendation
        }

        func recommend(currentTrack: TrackCacheEntry, candidates: [TrackCacheEntry]) async throws -> AdvisorRecommendation {
            callCount += 1
            if delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
            if let error = errorToThrow {
                throw error
            }
            guard let rec = recommendation else {
                throw AIAdvisorError.invalidRecommendation
            }
            return rec
        }
    }

    private final class MockAdvisorTransport: AdvisorHTTPTransport, @unchecked Sendable {
        var responseStatusCode: Int = 200
        var responseData: Data = Data()
        var delayNanoseconds: UInt64 = 0
        private(set) var requests: [URLRequest] = []

        func send(_ request: URLRequest) async throws -> AdvisorHTTPResponse {
            requests.append(request)
            if delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
            return AdvisorHTTPResponse(statusCode: responseStatusCode, headers: [:], body: responseData)
        }
    }

    // MARK: - Coordinator Tests

    func testLocalOnlyDeliversProvisionalImmediatelyWithoutCloud() async throws {
        let current = Self.makeTrack(path: "current.mp3")
        let candidate = Self.makeTrack(path: "next.mp3")
        let rec = Self.makeValidRecommendation(suggestedPath: "next.mp3")

        let localProvider = MockLocalAdvisorProvider(recommendation: rec)
        let transport = MockAdvisorTransport()
        let cloudClient = GeminiAdvisorClient(
            config: GeminiAdvisorConfig(),
            transport: transport,
            clock: SystemAdvisorClock(),
            rateLimiter: GeminiRollingWindowRateLimiter(limit: 60, clock: SystemAdvisorClock()),
            apiKeyProvider: { "fake-gemini-key" }
        )

        let coordinator = CooperativeAdvisorCoordinator(localProvider: localProvider, cloudClient: cloudClient)

        let stream = await coordinator.streamRecommendation(
            currentTrack: current,
            candidates: [candidate],
            mode: .localOnly,
            generationID: 1
        )

        var received: [CooperativeRecommendation] = []
        for try await item in stream {
            received.append(item)
        }

        // Must yield exactly 1 provisional result
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.generationID, 1)
        XCTAssertEqual(received.first?.provisional.suggestedTrackPath, "next.mp3")
        XCTAssertNil(received.first?.refinement)
        XCTAssertFalse(received.first?.isRefining ?? true)

        // Local-only mode MUST NEVER call cloud transport
        XCTAssertEqual(transport.requests.count, 0)
        XCTAssertEqual(localProvider.callCount, 1)
    }

    func testCooperativeModeDeliversProvisionalThenCloudRefinement() async throws {
        let current = Self.makeTrack(path: "trackA.mp3")
        let candidate1 = Self.makeTrack(path: "trackB.mp3")
        let candidate2 = Self.makeTrack(path: "trackC.mp3")

        let localRec = Self.makeValidRecommendation(suggestedPath: "trackB.mp3", bars: 16)
        let localProvider = MockLocalAdvisorProvider(recommendation: localRec)
        let transport = MockAdvisorTransport()

        let geminiResponseBody = """
        {
            "candidates": [{
                "content": {
                    "parts": [{
                        "text": "{\\"suggestedTrackPath\\":\\"trackC.mp3\\",\\"rationale\\":\\"Smooth harmonic blend maintaining dancefloor energy.\\",\\"harmonicCompatibility\\":\\"8A -> 8A (Perfect key match)\\",\\"transitionBars\\":32,\\"suggestedMixInSeconds\\":16.0,\\"energyProgression\\":\\"Building from verse to peak chorus\\"}"
                    }]
                }
            }]
        }
        """
        transport.responseData = Data(geminiResponseBody.utf8)

        let cloudClient = GeminiAdvisorClient(
            config: GeminiAdvisorConfig(),
            transport: transport,
            clock: SystemAdvisorClock(),
            rateLimiter: GeminiRollingWindowRateLimiter(limit: 60, clock: SystemAdvisorClock()),
            apiKeyProvider: { "valid-test-key" }
        )

        let coordinator = CooperativeAdvisorCoordinator(localProvider: localProvider, cloudClient: cloudClient)

        let stream = await coordinator.streamRecommendation(
            currentTrack: current,
            candidates: [candidate1, candidate2],
            mode: .cooperative,
            generationID: 42
        )

        var received: [CooperativeRecommendation] = []
        for try await item in stream {
            received.append(item)
        }

        // First item is provisional
        XCTAssertGreaterThanOrEqual(received.count, 2)
        let provisional = received[0]
        XCTAssertEqual(provisional.generationID, 42)
        XCTAssertEqual(provisional.provisional.suggestedTrackPath, "trackB.mp3")
        XCTAssertTrue(provisional.isRefining)
        XCTAssertNil(provisional.refinement)

        // Second item is cloud refined
        let refined = received[1]
        XCTAssertEqual(refined.generationID, 42)
        XCTAssertEqual(refined.provisional.suggestedTrackPath, "trackB.mp3")
        XCTAssertEqual(refined.refinement?.suggestedTrackPath, "trackC.mp3")
        XCTAssertEqual(refined.refinement?.transitionBars, 32)
        XCTAssertFalse(refined.isRefining)
        XCTAssertEqual(refined.activeRecommendation.suggestedTrackPath, "trackC.mp3")

        XCTAssertEqual(transport.requests.count, 1)
    }

    private final class SafeCollector<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [T] = []

        func append(_ item: T) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(item)
        }

        var elements: [T] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    func testCancellationDiscardsStaleInFlightRefinement() async throws {
        let current = Self.makeTrack(path: "track1.mp3")
        let candidate = Self.makeTrack(path: "track2.mp3")

        let localRec = Self.makeValidRecommendation(suggestedPath: "track2.mp3")
        let localProvider = MockLocalAdvisorProvider(recommendation: localRec)
        let transport = MockAdvisorTransport()
        transport.delayNanoseconds = 100_000_000 // 100ms slow cloud response

        let geminiResponseBody = """
        {
            "candidates": [{
                "content": {
                    "parts": [{
                        "text": "{\\"suggestedTrackPath\\":\\"track2.mp3\\",\\"rationale\\":\\"Late refinement\\",\\"harmonicCompatibility\\":\\"8A\\",\\"transitionBars\\":16,\\"suggestedMixInSeconds\\":10.0,\\"energyProgression\\":\\"Steady\\"}"
                    }]
                }
            }]
        }
        """
        transport.responseData = Data(geminiResponseBody.utf8)

        let cloudClient = GeminiAdvisorClient(
            config: GeminiAdvisorConfig(),
            transport: transport,
            clock: SystemAdvisorClock(),
            rateLimiter: GeminiRollingWindowRateLimiter(limit: 60, clock: SystemAdvisorClock()),
            apiKeyProvider: { "valid-test-key" }
        )

        let coordinator = CooperativeAdvisorCoordinator(localProvider: localProvider, cloudClient: cloudClient)

        let stream = await coordinator.streamRecommendation(
            currentTrack: current,
            candidates: [candidate],
            mode: .cooperative,
            generationID: 100
        )

        let collector = SafeCollector<CooperativeRecommendation>()
        let consumerTask = Task {
            for try await item in stream {
                collector.append(item)
                // Once provisional is received, cancel coordinator to simulate user track switch
                if item.isRefining {
                    await coordinator.cancel()
                }
            }
        }

        try await Task.sleep(nanoseconds: 150_000_000)
        _ = await consumerTask.result

        // Should receive the provisional item, but NOT the stale cancelled refinement
        let items = collector.elements
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.generationID, 100)
    }

    func testCandidateValidationRejectsInventedTrackPath() async throws {
        let current = Self.makeTrack(path: "deckA.mp3")
        let candidate = Self.makeTrack(path: "realCandidate.mp3")

        // Provider invents a track not present in candidates
        let inventedRec = Self.makeValidRecommendation(suggestedPath: "hallucinated.mp3")
        let localProvider = MockLocalAdvisorProvider(recommendation: inventedRec)

        let coordinator = CooperativeAdvisorCoordinator(localProvider: localProvider)

        let stream = await coordinator.streamRecommendation(
            currentTrack: current,
            candidates: [candidate],
            mode: .localOnly,
            generationID: 5
        )

        do {
            for try await _ in stream {
                XCTFail("Stream should throw invalidRecommendation")
            }
            XCTFail("Expected throw")
        } catch {
            XCTAssertEqual(error as? AIAdvisorError, AIAdvisorError.invalidRecommendation)
        }
    }

    func testMetadataDisclosureGuaranteesNoRawAudioOrPersonalData() {
        let current = Self.makeTrack(path: "Library/Dance/SongA.wav", bpm: 128.0, key: "11B", duration: 240.0)
        let candidates = [
            Self.makeTrack(path: "Library/Dance/SongB.wav", bpm: 128.0, key: "11B", duration: 210.0),
            Self.makeTrack(path: "Library/Dance/SongC.wav", bpm: 126.0, key: "10B", duration: 195.0)
        ]

        let disclosure = AdvisorMetadataDisclosure(currentTrack: current, candidates: candidates)

        XCTAssertEqual(disclosure.currentTrack.relativePath, "Library/Dance/SongA.wav")
        XCTAssertEqual(disclosure.currentTrack.bpm, 128.0)
        XCTAssertEqual(disclosure.currentTrack.musicalKey, "11B")
        XCTAssertEqual(disclosure.currentTrack.durationSeconds, 240.0)
        XCTAssertEqual(disclosure.totalCandidateCount, 2)
        XCTAssertEqual(disclosure.candidates.count, 2)
        XCTAssertEqual(disclosure.candidates[0].relativePath, "Library/Dance/SongB.wav")
    }

    // MARK: - SecretStore Tests

    func testInMemorySecretStoreIsolation() {
        let store = InMemorySecretStore()
        XCTAssertNil(store.getSecret(forKey: "GEMINI_API_KEY"))

        store.setSecret("test-secret-key-12345", forKey: "GEMINI_API_KEY")
        XCTAssertEqual(store.getSecret(forKey: "GEMINI_API_KEY"), "test-secret-key-12345")

        // Clearing secret
        store.setSecret(nil, forKey: "GEMINI_API_KEY")
        XCTAssertNil(store.getSecret(forKey: "GEMINI_API_KEY"))
    }

    // MARK: - AppState Integration Tests

    @MainActor
    func testAppStateAdvisorWorkflowAndApplyBars() async throws {
        let current = Self.makeTrack(path: "track1.mp3")
        let candidate = Self.makeTrack(path: "track2.mp3")

        let cache = PulseDeckLibraryCache(
            tracks: [
                "track1.mp3": current,
                "track2.mp3": candidate
            ]
        )

        let localRec = Self.makeValidRecommendation(suggestedPath: "track2.mp3", bars: 32)
        let localProvider = MockLocalAdvisorProvider(recommendation: localRec)
        let secretStore = InMemorySecretStore()
        let coordinator = CooperativeAdvisorCoordinator(localProvider: localProvider)

        let appState = AppState(
            libraryRootURL: URL(fileURLWithPath: "/tmp/test-pulsedeck"),
            waveformEditorModel: WaveformEditorModel(libraryRootURL: URL(fileURLWithPath: "/tmp/test-pulsedeck")),
            loadedCache: cache,
            secretStore: secretStore,
            advisorCoordinator: coordinator
        )

        appState.selectedTrackPath = "track1.mp3"
        XCTAssertEqual(appState.selectedTrack?.relativePath, "track1.mp3")
        XCTAssertEqual(appState.transitionPhraseBars, 16)

        // Request advice
        appState.requestAdvice()
        XCTAssertTrue(appState.isAdvisorLoading)

        // Wait briefly for main actor propagation
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(appState.isAdvisorLoading)
        XCTAssertNotNil(appState.activeRecommendation)
        XCTAssertEqual(appState.activeRecommendation?.activeRecommendation.suggestedTrackPath, "track2.mp3")
        XCTAssertEqual(appState.activeRecommendation?.activeRecommendation.transitionBars, 32)

        // Apply suggested bars to macro without touching transport
        appState.applySuggestedBars(32)
        XCTAssertEqual(appState.transitionPhraseBars, 32)
        XCTAssertFalse(appState.isAutoPilotArmed)
        XCTAssertFalse(appState.isTransitionRunning)
    }

    func testLocalProviderUnavailableSurfacesClearError() async throws {
        let current = Self.makeTrack(path: "track1.mp3")
        let candidate = Self.makeTrack(path: "track2.mp3")

        let localProvider = MockLocalAdvisorProvider()
        localProvider.errorToThrow = AIAdvisorError.httpStatus(provider: "Ollama", status: 404)

        let coordinator = CooperativeAdvisorCoordinator(localProvider: localProvider)

        let stream = await coordinator.streamRecommendation(
            currentTrack: current,
            candidates: [candidate],
            mode: .localOnly,
            generationID: 1
        )

        do {
            for try await _ in stream {
                XCTFail("Stream should throw")
            }
            XCTFail("Expected throw")
        } catch {
            XCTAssertEqual(error as? AIAdvisorError, AIAdvisorError.httpStatus(provider: "Ollama", status: 404))
        }
    }

    @MainActor
    func testUpdateLocalModelUpdatesIdentifier() async throws {
        let secretStore = InMemorySecretStore()
        let localProvider = MockLocalAdvisorProvider(modelIdentifier: "Ollama: gemma3:4b")
        let coordinator = CooperativeAdvisorCoordinator(localProvider: localProvider)

        let appState = AppState(
            libraryRootURL: URL(fileURLWithPath: "/tmp/test-pulsedeck"),
            waveformEditorModel: WaveformEditorModel(libraryRootURL: URL(fileURLWithPath: "/tmp/test-pulsedeck")),
            secretStore: secretStore,
            advisorCoordinator: coordinator
        )

        XCTAssertEqual(appState.selectedLocalModel, "gemma3:4b")
        appState.updateLocalModel("bonsai-2:27b")
        XCTAssertEqual(appState.selectedLocalModel, "bonsai-2:27b")
    }
}
