import Foundation
import XCTest
@testable import PulseDeckCore

final class AIAdvisorServiceTests: XCTestCase {
    func testGeminiUsesConfiguredModelHeaderAndCurrentStructuredOutputSchema() async throws {
        let clock = ManualAdvisorClock()
        let transport = StubAdvisorTransport(responses: [Self.geminiResponse(Self.validRecommendation)], clock: clock)
        let service = Self.service(transport: transport, clock: clock, key: "test-secret")

        let result = try await service.recommendNextTrack(
            currentTrack: Self.track("current.mp3"),
            availableTracks: [Self.track("next.mp3")]
        )

        XCTAssertEqual(result, Self.validRecommendation)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/v1beta/models/gemini-2.5-flash:generateContent")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-secret")
        XCTAssertEqual(request.timeoutInterval, 30)
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let generation = try XCTUnwrap(payload["generationConfig"] as? [String: Any])
        let responseFormat = try XCTUnwrap(generation["responseFormat"] as? [String: Any])
        let text = try XCTUnwrap(responseFormat["text"] as? [String: Any])
        XCTAssertEqual(text["mimeType"] as? String, "application/json")
        XCTAssertNil(generation["responseSchema"])
    }

    func testRetryAfterIsHonoredAndRetryConsumesCloudAttempt() async throws {
        let throttled = AdvisorHTTPResponse(statusCode: 429, headers: ["retry-after": "7"], body: Data())
        let clock = ManualAdvisorClock()
        let transport = StubAdvisorTransport(responses: [throttled, Self.geminiResponse(Self.validRecommendation)], clock: clock)
        let service = Self.service(transport: transport, clock: clock, key: "test-secret")

        _ = try await service.recommendNextTrack(
            currentTrack: Self.track("current.mp3"),
            availableTracks: [Self.track("next.mp3")]
        )

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        let sleeps = await clock.sleeps
        XCTAssertEqual(sleeps, [7])
    }

    func testConcurrentCloudCallsStayWithinRollingTwelveRequestLimit() async throws {
        let clock = ManualAdvisorClock()
        let transport = StubAdvisorTransport(responses: Array(repeating: Self.geminiResponse(Self.validRecommendation), count: 13), clock: clock)
        let service = Self.service(transport: transport, clock: clock, key: "test-secret")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<13 {
                group.addTask {
                    _ = try await service.recommendNextTrack(
                        currentTrack: Self.track("current-\(index).mp3"),
                        availableTracks: [Self.track("next.mp3")]
                    )
                }
            }
            try await group.waitForAll()
        }

        let times = await transport.requestTimes.sorted()
        XCTAssertEqual(times.count, 13)
        for start in times.indices {
            let count = times[start...].prefix { $0 - times[start] < 60 }.count
            XCTAssertLessThanOrEqual(count, 12)
        }
    }

    func testInvalidCloudAdviceFallsBackToValidatedLocalAdvice() async throws {
        let invalidCloud = AdvisorRecommendation(
            suggestedTrackPath: "invented.mp3",
            rationale: "Made up",
            harmonicCompatibility: "8A",
            transitionBars: 16,
            suggestedMixInSeconds: 10,
            energyProgression: "steady"
        )
        let clock = ManualAdvisorClock()
        let transport = StubAdvisorTransport(responses: [
            Self.geminiResponse(invalidCloud),
            Self.ollamaResponse(Self.validRecommendation)
        ], clock: clock)
        let service = Self.service(transport: transport, clock: clock, key: "test-secret")

        let result = try await service.recommendNextTrack(
            currentTrack: Self.track("current.mp3"),
            availableTracks: [Self.track("next.mp3")]
        )

        XCTAssertEqual(result, Self.validRecommendation)
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url?.host }, ["generativelanguage.googleapis.com", "localhost"])
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "x-goog-api-key"))
    }

    func testUnavailableLocalOllamaProducesBoundedErrorWithoutSecret() async throws {
        let transport = StubAdvisorTransport(error: URLError(.cannotConnectToHost))
        let service = Self.service(transport: transport, clock: ManualAdvisorClock(), key: nil)

        do {
            _ = try await service.recommendNextTrack(
                currentTrack: Self.track("current.mp3"),
                availableTracks: [Self.track("next.mp3")]
            )
            XCTFail("Expected local connection failure")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("test-secret"))
            XCTAssertLessThanOrEqual(error.localizedDescription.count, 160)
        }
    }

    func testCancellationPropagatesWithoutLocalFallback() async throws {
        let transport = StubAdvisorTransport(error: CancellationError())
        let service = Self.service(transport: transport, clock: ManualAdvisorClock(), key: "test-secret")

        do {
            _ = try await service.recommendNextTrack(
                currentTrack: Self.track("current.mp3"),
                availableTracks: [Self.track("next.mp3")]
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testMalformedStructureAndOutOfRangeMixCueAreRejected() throws {
        let encoded = try JSONEncoder().encode(Self.validRecommendation)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["unexpected"] = "ignored by Codable"
        let malformed = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try AdvisorPromptBuilder.decodeRecommendation(malformed))

        let outOfRange = AdvisorRecommendation(
            suggestedTrackPath: "next.mp3",
            rationale: "Compatible tempo and key",
            harmonicCompatibility: "8A",
            transitionBars: 16,
            suggestedMixInSeconds: 181,
            energyProgression: "steady"
        )
        XCTAssertThrowsError(try AdvisorRecommendationValidator.validate(
            outOfRange,
            currentTrack: Self.track("current.mp3"),
            availableTracks: [Self.track("next.mp3")]
        ))
    }

    private static func service(
        transport: any AdvisorHTTPTransport,
        clock: any AdvisorClock,
        key: String?
    ) -> HybridAIAdvisorService {
        HybridAIAdvisorService(
            geminiConfig: GeminiAdvisorConfig(),
            ollamaConfig: OllamaFallbackConfig(),
            transport: transport,
            clock: clock,
            apiKeyProvider: { key }
        )
    }

    private static var validRecommendation: AdvisorRecommendation {
        AdvisorRecommendation(
            suggestedTrackPath: "next.mp3",
            rationale: "Compatible tempo and key",
            harmonicCompatibility: "8A",
            transitionBars: 16,
            suggestedMixInSeconds: 10,
            energyProgression: "steady"
        )
    }

    private static func geminiResponse(_ recommendation: AdvisorRecommendation) -> AdvisorHTTPResponse {
        let encoded = try! JSONEncoder().encode(recommendation)
        let text = String(decoding: encoded, as: UTF8.self)
        let data = try! JSONSerialization.data(withJSONObject: [
            "candidates": [["content": ["parts": [["text": text]]]]]
        ])
        return AdvisorHTTPResponse(statusCode: 200, headers: [:], body: data)
    }

    private static func ollamaResponse(_ recommendation: AdvisorRecommendation) -> AdvisorHTTPResponse {
        let encoded = try! JSONEncoder().encode(recommendation)
        let text = String(decoding: encoded, as: UTF8.self)
        let data = try! JSONSerialization.data(withJSONObject: ["message": ["content": text]])
        return AdvisorHTTPResponse(statusCode: 200, headers: [:], body: data)
    }

    private static func track(_ path: String) -> TrackCacheEntry {
        TrackCacheEntry(
            relativePath: path,
            fileFingerprint: "fingerprint-\(path)",
            fileSizeBytes: 1024,
            fileModificationTime: "2026-10-14T19:00:00Z",
            duration: 180,
            sampleRate: 44100,
            channels: 2,
            bitDepth: 16,
            bpm: 120,
            musicalKey: "8A",
            confidence: 0.9,
            waveformMetadata: WaveformMetadata(
                sampleCount: 2, downsampleFactor: 1,
                peakValues: [0.5], lowBandPeaks: [0.5], midBandPeaks: [0.5], highBandPeaks: [0.5]
            ),
            beatGrid: BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 0.5, beatTimestamps: [0]),
            structure: TrackStructure(sections: [], vocalSegments: []),
            cueMarkers: CueMarkers(startTrimCue: 0, vocalEntryCue: 0, mixOutCue: 180, endTrimCue: 180),
            analyzerVersion: "test",
            analysisTimestamp: "2026-10-14T19:01:00Z"
        )
    }
}

private actor StubAdvisorTransport: AdvisorHTTPTransport {
    private var responses: [AdvisorHTTPResponse]
    private let error: Error?
    private var _requests: [URLRequest] = []
    private var _requestTimes: [TimeInterval] = []
    private let clock: (any AdvisorClock)?

    var requests: [URLRequest] { _requests }
    var requestTimes: [TimeInterval] { _requestTimes }

    init(responses: [AdvisorHTTPResponse], clock: (any AdvisorClock)? = nil) {
        self.responses = responses
        self.error = nil
        self.clock = clock
    }

    init(error: Error) {
        self.responses = []
        self.error = error
        self.clock = nil
    }

    func send(_ request: URLRequest) async throws -> AdvisorHTTPResponse {
        _requests.append(request)
        if let clock { _requestTimes.append(await clock.monotonicNow()) }
        if let error { throw error }
        guard !responses.isEmpty else { throw AIAdvisorError.malformedProviderResponse }
        return responses.removeFirst()
    }
}

private actor ManualAdvisorClock: AdvisorClock {
    private var now: TimeInterval = 0
    private var _sleeps: [TimeInterval] = []

    var sleeps: [TimeInterval] { _sleeps }

    func monotonicNow() async -> TimeInterval { now }
    func wallClockNow() async -> Date { Date(timeIntervalSince1970: now) }

    func sleep(for seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        _sleeps.append(seconds)
        now += seconds
    }
}
