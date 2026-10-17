import Foundation

struct OllamaAdvisorClient: Sendable {
    let config: OllamaFallbackConfig
    let transport: any AdvisorHTTPTransport

    func recommend(
        currentTrack: TrackCacheEntry,
        availableTracks: [TrackCacheEntry]
    ) async throws -> AdvisorRecommendation {
        guard config.isEnabled,
              let endpoint = requestURL() else {
            throw AIAdvisorError.noProviderAvailable
        }
        let prompt = try AdvisorPromptBuilder.make(currentTrack: currentTrack, availableTracks: availableTracks)
        let payload: [String: Any] = [
            "model": config.model,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
            "format": AdvisorPromptBuilder.ollamaRecommendationJSONSchema(),
            "options": ["temperature": 0.2, "num_predict": 1024],
            "keep_alive": "5m"
        ]
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw AIAdvisorError.invalidConfiguration
        }

        var request = URLRequest(url: endpoint, timeoutInterval: config.requestTimeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

        let response: AdvisorHTTPResponse
        do {
            response = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AIAdvisorError.networkFailure(provider: "Ollama")
        }
        guard response.body.count <= 1_048_576 else {
            throw AIAdvisorError.responseTooLarge
        }
        guard (200..<300).contains(response.statusCode) else {
            throw AIAdvisorError.httpStatus(provider: "Ollama", status: response.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let content = message["content"] as? String,
              let recommendation = try? AdvisorPromptBuilder.decodeRecommendation(Data(content.utf8)) else {
            throw AIAdvisorError.malformedProviderResponse
        }
        return try AdvisorRecommendationValidator.validate(
            recommendation,
            currentTrack: currentTrack,
            availableTracks: availableTracks
        )
    }

    private func requestURL() -> URL? {
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty,
              var components = URLComponents(url: config.endpoint, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http",
              let host = components.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1"].contains(host),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, "api/chat"].filter { !$0.isEmpty }.joined(separator: "/")
        return components.url
    }
}
