import Foundation

public struct GeminiAdvisorClient: Sendable {
    public let config: GeminiAdvisorConfig
    let transport: any AdvisorHTTPTransport
    let clock: any AdvisorClock
    let rateLimiter: GeminiRollingWindowRateLimiter
    public let apiKeyProvider: @Sendable () -> String?

    public init(
        config: GeminiAdvisorConfig = GeminiAdvisorConfig(),
        apiKeyProvider: @escaping @Sendable () -> String?
    ) {
        let transport = URLSessionAdvisorHTTPTransport()
        let clock = SystemAdvisorClock()
        let rateLimiter = GeminiRollingWindowRateLimiter(limit: config.requestsPerMinute, clock: clock)
        self.init(config: config, transport: transport, clock: clock, rateLimiter: rateLimiter, apiKeyProvider: apiKeyProvider)
    }

    init(
        config: GeminiAdvisorConfig,
        transport: any AdvisorHTTPTransport,
        clock: any AdvisorClock,
        rateLimiter: GeminiRollingWindowRateLimiter,
        apiKeyProvider: @escaping @Sendable () -> String?
    ) {
        self.config = config
        self.transport = transport
        self.clock = clock
        self.rateLimiter = rateLimiter
        self.apiKeyProvider = apiKeyProvider
    }

    public func recommend(
        currentTrack: TrackCacheEntry,
        availableTracks: [TrackCacheEntry]
    ) async throws -> AdvisorRecommendation {
        guard let rawKey = apiKeyProvider(),
              !rawKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let endpoint = requestURL() else {
            throw AIAdvisorError.invalidConfiguration
        }
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = try AdvisorPromptBuilder.make(currentTrack: currentTrack, availableTracks: availableTracks)
        let payload: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": [
                "responseFormat": [
                    "text": [
                        "mimeType": "application/json",
                        "schema": AdvisorPromptBuilder.recommendationJSONSchema()
                    ]
                ],
                "temperature": 0.2,
                "maxOutputTokens": 1024
            ]
        ]
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw AIAdvisorError.invalidConfiguration
        }

        var request = URLRequest(url: endpoint, timeoutInterval: config.requestTimeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

        var lastStatus: Int?
        for attempt in 0...config.maxRetries {
            try Task.checkCancellation()
            try await rateLimiter.acquireRequestSlot()

            let response: AdvisorHTTPResponse
            do {
                response = try await transport.send(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                if attempt < config.maxRetries, Self.isRetryableNetworkError(error) {
                    try await clock.sleep(for: config.backoffDelaySeconds(forAttempt: attempt))
                    continue
                }
                throw AIAdvisorError.networkFailure(provider: "Gemini")
            }

            guard response.body.count <= 1_048_576 else {
                throw AIAdvisorError.responseTooLarge
            }
            guard (200..<300).contains(response.statusCode) else {
                lastStatus = response.statusCode
                if attempt < config.maxRetries, Self.isRetryableStatus(response.statusCode) {
                    let requestedDelay = Self.retryAfterSeconds(
                        response.headers["retry-after"],
                        now: await clock.wallClockNow()
                    )
                    try await clock.sleep(for: min(
                        requestedDelay ?? config.backoffDelaySeconds(forAttempt: attempt),
                        GeminiAdvisorConfig.maxBackoffSeconds
                    ))
                    continue
                }
                throw AIAdvisorError.httpStatus(provider: "Gemini", status: response.statusCode)
            }

            let recommendation = try Self.parseRecommendation(response.body)
            return try AdvisorRecommendationValidator.validate(
                recommendation,
                currentTrack: currentTrack,
                availableTracks: availableTracks
            )
        }
        throw AIAdvisorError.httpStatus(provider: "Gemini", status: lastStatus ?? 0)
    }

    private func requestURL() -> URL? {
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty,
              model.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
                      .contains($0)
              }),
              var components = URLComponents(url: config.endpoint, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, "models/\(model):generateContent"].filter { !$0.isEmpty }.joined(separator: "/")
        return components.url
    }

    private static func parseRecommendation(_ data: Data) throws -> AdvisorRecommendation {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.compactMap({ $0["text"] as? String }).first,
              let recommendation = try? AdvisorPromptBuilder.decodeRecommendation(Data(text.utf8)) else {
            throw AIAdvisorError.malformedProviderResponse
        }
        return recommendation
    }

    private static func isRetryableStatus(_ status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }

    private static func isRetryableNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return urlError.code != .cancelled
    }

    private static func retryAfterSeconds(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}
