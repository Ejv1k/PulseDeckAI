import Foundation

struct GeminiAdvisorClient: Sendable {
    let config: GeminiAdvisorConfig
    let transport: any AdvisorHTTPTransport
    let clock: any AdvisorClock
    let rateLimiter: GeminiRollingWindowRateLimiter
    let apiKeyProvider: @Sendable () -> String?

    func recommend(
        currentTrack: TrackCacheEntry,
        availableTracks: [TrackCacheEntry]
    ) async throws -> AdvisorRecommendation {
        let prompt = try AdvisorPromptBuilder.make(currentTrack: currentTrack, availableTracks: availableTracks)
        let text = try await generateText(prompt: prompt, schema: AdvisorPromptBuilder.recommendationJSONSchema())
        guard let recommendation = try? AdvisorPromptBuilder.decodeRecommendation(Data(text.utf8)) else {
            throw AIAdvisorError.malformedProviderResponse
        }
        return try AdvisorRecommendationValidator.validate(
            recommendation,
            currentTrack: currentTrack,
            availableTracks: availableTracks
        )
    }

    /// Asks which built-in transition fits two tracks; the answer is validated before anyone sees it.
    func adviseTransition(outgoing: TrackCacheEntry, incoming: TrackCacheEntry) async throws -> TransitionAdvice {
        let text = try await generateText(prompt: TransitionAdvicePrompt.make(outgoing: outgoing, incoming: incoming),
                                          schema: TransitionAdvicePrompt.schema())
        return try TransitionAdvicePrompt.parse(text)
    }

    /// One generateContent call with rate limiting and retries; returns the model's text part.
    private func generateText(prompt: String, schema: [String: Any]) async throws -> String {
        guard let rawKey = apiKeyProvider(),
              !rawKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let endpoint = requestURL() else {
            throw AIAdvisorError.invalidConfiguration
        }
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": [
                "responseFormat": [
                    "text": [
                        "mimeType": "application/json",
                        "schema": schema
                    ]
                ],
                "temperature": 0.2,
                // Thinking models count thought tokens against this cap; the answer itself is small.
                "maxOutputTokens": 2048
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

            return try Self.parseText(response.body)
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

    private static func parseText(_ data: Data) throws -> String {
        // Thinking models may return thought parts first; the answer is the last non-thought text part.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.filter({ ($0["thought"] as? Bool) != true }).compactMap({ $0["text"] as? String }).last else {
            throw AIAdvisorError.malformedProviderResponse
        }
        return text
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
