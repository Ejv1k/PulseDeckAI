import Foundation
import XCTest
@testable import PulseDeckCore

final class AIAdvisorServiceTests: XCTestCase {
    func testHTTPTransportRejectsLoopbackRedirectToExternalHost() async throws {
        RedirectingAdvisorURLProtocol.recorder.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingAdvisorURLProtocol.self]
        let transport = URLSessionAdvisorHTTPTransport(configuration: configuration)
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:11434/api/chat")))
        request.httpMethod = "POST"
        request.httpBody = Data("private library context".utf8)
        request.timeoutInterval = 3

        let response = try await transport.send(request)
        XCTAssertEqual(response.statusCode, 307)
        XCTAssertEqual(RedirectingAdvisorURLProtocol.recorder.hosts, ["127.0.0.1"])
    }

    func testHTTPTransportEnforcesTotalDeadlineForSlowTrickleResponse() async throws {
        let (transport, request, probe, identifier) = try Self.streamingRequest(mode: "trickle", timeout: 0.2)
        defer { StreamingAdvisorURLProtocol.registry.remove(identifier) }
        let operation = Task { try await transport.send(request) }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(2))
            operation.cancel()
        }
        defer { watchdog.cancel() }
        do {
            _ = try await operation.value
            XCTFail("Expected total request deadline")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        } catch {
            XCTFail("Expected timedOut, received \(error)")
        }
        await fulfillment(of: [probe.stopped], timeout: 1)
        XCTAssertGreaterThan(probe.chunkCount, 1, "Response must keep making progress before the deadline")
    }

    func testHTTPTransportCancelsOversizeBodiesWithoutTrustworthyContentLength() async throws {
        for mode in ["overflow-missing", "overflow-false", "overflow-declared"] {
            let (transport, request, probe, identifier) = try Self.streamingRequest(mode: mode, timeout: 1)
            defer { StreamingAdvisorURLProtocol.registry.remove(identifier) }
            let operation = Task { try await transport.send(request) }
            let watchdog = Task {
                try await Task.sleep(for: .seconds(2))
                operation.cancel()
            }
            defer { watchdog.cancel() }
            do {
                _ = try await operation.value
                XCTFail("Expected receiving-size limit for \(mode)")
            } catch {
                XCTAssertEqual(error as? AIAdvisorError, .responseTooLarge, mode)
            }
            await fulfillment(of: [probe.stopped], timeout: 1)
        }
    }

    func testHTTPTransportAcceptsExactLimitAndEmptyBody() async throws {
        for (mode, expectedCount) in [("exact-limit", 1_048_576), ("empty", 0)] {
            let (transport, request, _, identifier) = try Self.streamingRequest(mode: mode, timeout: 2)
            defer { StreamingAdvisorURLProtocol.registry.remove(identifier) }
            let response = try await transport.send(request)
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body.count, expectedCount)
        }
    }

    func testHTTPTransportCancellationStopsOnlyItsRequest() async throws {
        let (transport, request, probe, identifier) = try Self.streamingRequest(mode: "trickle", timeout: 2)
        defer { StreamingAdvisorURLProtocol.registry.remove(identifier) }
        let operation = Task { try await transport.send(request) }
        await fulfillment(of: [probe.firstChunk], timeout: 1)
        var mutableHealthyRequest = request
        mutableHealthyRequest.url = try XCTUnwrap(URL(string: "http://127.0.0.1/exact-limit"))
        mutableHealthyRequest.setValue(nil, forHTTPHeaderField: "X-Test-Identifier")
        let healthyRequest = mutableHealthyRequest
        let healthyOperation = Task { try await transport.send(healthyRequest) }
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("Expected caller cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
        await fulfillment(of: [probe.stopped], timeout: 1)

        let response = try await healthyOperation.value
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body.count, 1_048_576)
    }

    func testHTTPTransportAlreadyCancelledCallerDoesNotStartRequest() async throws {
        let (transport, request, probe, identifier) = try Self.streamingRequest(mode: "trickle", timeout: 1)
        defer { StreamingAdvisorURLProtocol.registry.remove(identifier) }
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.send(request)
        }
        do {
            _ = try await operation.value
            XCTFail("Expected caller cancellation before startup")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
        XCTAssertEqual(probe.chunkCount, 0)
    }

    private static func streamingRequest(
        mode: String,
        timeout: TimeInterval
    ) throws -> (URLSessionAdvisorHTTPTransport, URLRequest, StreamingHTTPProbe, String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingAdvisorURLProtocol.self]
        let probe = StreamingHTTPProbe()
        let identifier = UUID().uuidString
        StreamingAdvisorURLProtocol.registry.insert(probe, identifier: identifier)
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/\(mode)")))
        request.timeoutInterval = timeout
        request.setValue(identifier, forHTTPHeaderField: "X-Test-Identifier")
        return (URLSessionAdvisorHTTPTransport(configuration: configuration), request, probe, identifier)
    }

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

private final class RedirectingAdvisorURLProtocol: URLProtocol {
    static let recorder = RedirectRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.recorder.record(host: url.host ?? "")
        if url.host == "127.0.0.1" {
            guard let externalURL = URL(string: "https://external.example/collect"),
                  let redirectResponse = HTTPURLResponse(
                    url: url,
                    statusCode: 307,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": externalURL.absoluteString]
                  ) else { return }
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: externalURL), redirectResponse: redirectResponse)
            client?.urlProtocol(self, didReceive: redirectResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("external reached".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private final class RedirectRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedHosts: [String] = []

    var hosts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedHosts
    }

    func record(host: String) {
        lock.lock()
        defer { lock.unlock() }
        recordedHosts.append(host)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        recordedHosts.removeAll()
    }
}

private final class StreamingHTTPProbe: @unchecked Sendable {
    let stopped = XCTestExpectation(description: "Underlying URLProtocol stopped")
    let firstChunk = XCTestExpectation(description: "First response chunk received")
    private let lock = NSLock()
    private var chunks = 0

    var chunkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return chunks
    }

    func recordChunk() {
        lock.lock()
        chunks += 1
        let first = chunks == 1
        lock.unlock()
        if first { firstChunk.fulfill() }
    }
}

private final class StreamingHTTPRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var probes: [String: StreamingHTTPProbe] = [:]

    func insert(_ probe: StreamingHTTPProbe, identifier: String) {
        lock.lock()
        defer { lock.unlock() }
        probes[identifier] = probe
    }

    func remove(_ identifier: String) {
        lock.lock()
        defer { lock.unlock() }
        probes.removeValue(forKey: identifier)
    }

    func probe(for request: URLRequest) -> StreamingHTTPProbe? {
        lock.lock()
        defer { lock.unlock() }
        return request.value(forHTTPHeaderField: "X-Test-Identifier").flatMap { probes[$0] }
    }
}

private final class StreamingAdvisorURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = StreamingHTTPRegistry()
    // Timer ownership and all fixture callbacks stay on this serial queue.
    private let queue = DispatchQueue(label: "PulseDeckTests.StreamingHTTP")
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var probe: StreamingHTTPProbe?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        queue.async { self.startOnQueue() }
    }

    private func startOnQueue() {
        guard !stopped, let url = request.url else { return }
        probe = Self.registry.probe(for: request)
        let mode = url.lastPathComponent
        let headers: [String: String]?
        switch mode {
        case "overflow-false": headers = ["Content-Length": "1"]
        case "overflow-declared": headers = ["Content-Length": "1048577"]
        default: headers = nil
        }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if mode == "empty" {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: mode == "trickle" ? .milliseconds(30) : .milliseconds(5))
        var chunks = 0
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            chunks += 1
            self.probe?.recordChunk()
            self.client?.urlProtocol(self, didLoad: Data(repeating: 0x20, count: mode == "trickle" ? 1 : 65_536))
            if mode == "exact-limit", chunks == 16 {
                self.timer?.cancel()
                self.client?.urlProtocolDidFinishLoading(self)
            } else if mode != "trickle", chunks == 17 {
                // Never finish an oversized response: only receiver cancellation can terminate it.
                self.timer?.cancel()
            }
        }
        self.timer = timer
        timer.resume()
    }

    override func stopLoading() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.timer?.cancel()
            self.timer = nil
            self.probe?.stopped.fulfill()
        }
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
