import CryptoKit
import Foundation

/// Optional Gemini advisor with bounded local Ollama fallback and a memory-only recommendation cache.
/// All provider I/O occurs in async methods on this actor, never on an audio callback.
public actor HybridAIAdvisorService: AIAdvisorServiceContract {
    public nonisolated let geminiConfig: GeminiAdvisorConfig
    public nonisolated let ollamaConfig: OllamaFallbackConfig

    private let geminiClient: GeminiAdvisorClient
    private let ollamaClient: OllamaAdvisorClient
    private var recommendationCache: [String: AdvisorRecommendation] = [:]
    private var cacheOrder: [String] = []
    private let cacheCapacity = 64

    public init(
        geminiConfig: GeminiAdvisorConfig = GeminiAdvisorConfig(),
        ollamaConfig: OllamaFallbackConfig = OllamaFallbackConfig()
    ) {
        let transport = URLSessionAdvisorHTTPTransport()
        let clock = SystemAdvisorClock()
        let limiter = GeminiRollingWindowRateLimiter(limit: geminiConfig.requestsPerMinute, clock: clock)
        self.geminiConfig = geminiConfig
        self.ollamaConfig = ollamaConfig
        self.geminiClient = GeminiAdvisorClient(
            config: geminiConfig,
            transport: transport,
            clock: clock,
            rateLimiter: limiter,
            apiKeyProvider: {
                ProcessInfo.processInfo.environment[geminiConfig.apiKeyEnvironmentVariable]
            }
        )
        self.ollamaClient = OllamaAdvisorClient(config: ollamaConfig, transport: transport)
    }

    init(
        geminiConfig: GeminiAdvisorConfig,
        ollamaConfig: OllamaFallbackConfig,
        transport: any AdvisorHTTPTransport,
        clock: any AdvisorClock,
        apiKeyProvider: @escaping @Sendable () -> String?
    ) {
        let limiter = GeminiRollingWindowRateLimiter(limit: geminiConfig.requestsPerMinute, clock: clock)
        self.geminiConfig = geminiConfig
        self.ollamaConfig = ollamaConfig
        self.geminiClient = GeminiAdvisorClient(
            config: geminiConfig,
            transport: transport,
            clock: clock,
            rateLimiter: limiter,
            apiKeyProvider: apiKeyProvider
        )
        self.ollamaClient = OllamaAdvisorClient(config: ollamaConfig, transport: transport)
    }

    public func recommendNextTrack(
        currentTrack: TrackCacheEntry,
        availableTracks: [TrackCacheEntry]
    ) async throws -> AdvisorRecommendation {
        let prompt = try AdvisorPromptBuilder.make(currentTrack: currentTrack, availableTracks: availableTracks)
        let candidateFingerprints = availableTracks
            .filter { $0.isValid && $0.relativePath != currentTrack.relativePath }
            .sorted { $0.relativePath < $1.relativePath }
            .map(\.fileFingerprint)
        let cacheIdentity = (([currentTrack.fileFingerprint] + candidateFingerprints).joined(separator: "\u{0}"))
            + "\u{0}" + prompt
        let cacheKey = SHA256.hash(data: Data(cacheIdentity.utf8)).map { String(format: "%02x", $0) }.joined()
        if let cached = recommendationCache[cacheKey] {
            return cached
        }

        var geminiStatus: Int?
        if let key = geminiClient.apiKeyProvider(), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                let recommendation = try await geminiClient.recommend(
                    currentTrack: currentTrack,
                    availableTracks: availableTracks
                )
                cache(recommendation, for: cacheKey)
                return recommendation
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AIAdvisorError {
                if case .httpStatus(_, let status) = error { geminiStatus = status }
                if Task.isCancelled { throw CancellationError() }
            } catch {
                if Task.isCancelled { throw CancellationError() }
            }
        }

        guard ollamaConfig.isEnabled else {
            if geminiStatus == nil,
               let key = geminiClient.apiKeyProvider(),
               key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw AIAdvisorError.noProviderAvailable
            }
            throw AIAdvisorError.allProvidersUnavailable(cloudStatus: geminiStatus, localStatus: nil)
        }

        do {
            let recommendation = try await ollamaClient.recommend(
                currentTrack: currentTrack,
                availableTracks: availableTracks
            )
            cache(recommendation, for: cacheKey)
            return recommendation
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AIAdvisorError {
            if Task.isCancelled { throw CancellationError() }
            let localStatus: Int?
            if case .httpStatus(_, let status) = error {
                localStatus = status
            } else {
                localStatus = nil
            }
            throw AIAdvisorError.allProvidersUnavailable(cloudStatus: geminiStatus, localStatus: localStatus)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AIAdvisorError.allProvidersUnavailable(cloudStatus: geminiStatus, localStatus: nil)
        }
    }

    private func cache(_ recommendation: AdvisorRecommendation, for key: String) {
        recommendationCache[key] = recommendation
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        if cacheOrder.count > cacheCapacity {
            let expired = cacheOrder.removeFirst()
            recommendationCache.removeValue(forKey: expired)
        }
    }
}
