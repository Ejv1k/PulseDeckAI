import Foundation

/// Recommendation payload returned by the AI DJ Advisor.
public struct AdvisorRecommendation: Codable, Sendable, Equatable {
    /// Recommended next track relative path or title.
    public let suggestedTrackPath: String

    /// Transition rationale (e.g. harmonic compatibility, energy progression).
    public let rationale: String

    /// Harmonic compatibility rating (Camelot wheel match).
    public let harmonicCompatibility: String

    /// Recommended transition duration in bars (e.g. 16 or 32 bars).
    public let transitionBars: Int

    /// Suggested mix-in cue timestamp.
    public let suggestedMixInSeconds: Double

    /// Energy rating progression (e.g. "+1 energy lift").
    public let energyProgression: String

    public init(
        suggestedTrackPath: String,
        rationale: String,
        harmonicCompatibility: String,
        transitionBars: Int,
        suggestedMixInSeconds: Double,
        energyProgression: String
    ) {
        self.suggestedTrackPath = suggestedTrackPath
        self.rationale = rationale
        self.harmonicCompatibility = harmonicCompatibility
        self.transitionBars = transitionBars
        self.suggestedMixInSeconds = suggestedMixInSeconds
        self.energyProgression = energyProgression
    }
}

/// Configuration and safety limits for the Google Gemini cloud advisor.
public struct GeminiAdvisorConfig: Sendable, Equatable {
    /// Default advisor model: gemini-2.5-flash.
    public static let defaultModel = "gemini-2.5-flash"

    /// Strict rate limit ceiling: 12 Requests Per Minute.
    public static let maxRequestsPerMinute: Int = 12

    /// Minimum interval between subsequent API calls in seconds (60.0 / 12 = 5.0 seconds).
    public static let minRequestIntervalSeconds: Double = 5.0

    /// Maximum retry attempts on transient network or 429 errors.
    public static let maxRetries: Int = 3

    /// Base delay for exponential backoff in seconds.
    public static let baseBackoffSeconds: Double = 1.0

    /// Maximum cap on backoff delay in seconds.
    public static let maxBackoffSeconds: Double = 30.0

    public let model: String
    public let requestsPerMinute: Int

    public init(model: String = defaultModel, requestsPerMinute: Int = maxRequestsPerMinute) {
        self.model = model
        self.requestsPerMinute = min(requestsPerMinute, Self.maxRequestsPerMinute)
    }

    /// Calculates exponential backoff with pseudo-random jitter for a given retry attempt.
    /// Exponential delay with +/- 20% jitter is strictly capped at `maxBackoffSeconds` (30.0s)
    /// AFTER jitter is applied to guarantee the wait duration never exceeds the ceiling.
    public func backoffDelaySeconds(forAttempt attempt: Int) -> Double {
        let exponential = Self.baseBackoffSeconds * pow(2.0, Double(attempt))
        let jittered = exponential * Double.random(in: 0.8...1.2)
        // Strictly cap after jitter at maxBackoffSeconds (30.0s)
        return min(jittered, Self.maxBackoffSeconds)
    }
}

/// Configuration for offline local Ollama fallback.
public struct OllamaFallbackConfig: Sendable, Equatable {
    /// Local Ollama daemon base endpoint.
    public static let defaultEndpoint = URL(string: "http://localhost:11434")!

    /// Default recommended local model for musical analysis.
    public static let defaultModel = "llama3:latest"

    public let endpoint: URL
    public let model: String
    public let isEnabled: Bool

    public init(
        endpoint: URL = defaultEndpoint,
        model: String = defaultModel,
        isEnabled: Bool = true
    ) {
        self.endpoint = endpoint
        self.model = model
        self.isEnabled = isEnabled
    }
}

/// Architectural contract for the AI DJ advisor service (Phase 2+).
///
/// Security & Privacy Guarantees:
/// 1. No API keys stored in repo, code, or cache files. Keys are loaded from user environment only.
/// 2. Offline-First: Local Accelerate DSP always performs core analysis; AI Advisor is purely advisory.
/// 3. Rate-Limiting: Capped at <= 12 RPM with client-side token bucket.
/// 4. Local Caching: Results are keyed by track fingerprint; duplicate queries are served locally from cache.
public protocol AIAdvisorServiceContract: AnyObject, Sendable {
    /// Current Gemini advisor configuration.
    var geminiConfig: GeminiAdvisorConfig { get }

    /// Current local Ollama fallback configuration.
    var ollamaConfig: OllamaFallbackConfig { get }

    /// Queries advisor for next track transition recommendation.
    /// Implementation must enforce 12 RPM rate limit and track fingerprint caching.
    func recommendNextTrack(
        currentTrack: TrackCacheEntry,
        availableTracks: [TrackCacheEntry]
    ) async throws -> AdvisorRecommendation
}
