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

    /// Base URL for the Gemini v1beta generateContent API.
    public static let defaultEndpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta")!

    /// Strict rate limit ceiling: 12 Requests Per Minute.
    public static let maxRequestsPerMinute: Int = 12

    /// Average spacing at a sustained 12 RPM; the rolling limiter allows short bursts.
    public static let minRequestIntervalSeconds: Double = 5.0

    /// Maximum retry attempts on transient network or 429 errors.
    public static let maxRetries: Int = 3

    /// Base delay for exponential backoff in seconds.
    public static let baseBackoffSeconds: Double = 1.0

    /// Maximum cap on backoff delay in seconds.
    public static let maxBackoffSeconds: Double = 30.0

    public let model: String
    public let endpoint: URL
    public let requestsPerMinute: Int
    public let apiKeyEnvironmentVariable: String
    public let requestTimeoutSeconds: Double
    public let maxRetries: Int

    public init(
        model: String = defaultModel,
        requestsPerMinute: Int = maxRequestsPerMinute,
        endpoint: URL = defaultEndpoint,
        apiKeyEnvironmentVariable: String = "GEMINI_API_KEY",
        requestTimeoutSeconds: Double = 30,
        maxRetries: Int = Self.maxRetries
    ) {
        self.model = model
        self.endpoint = endpoint
        self.requestsPerMinute = min(max(requestsPerMinute, 1), Self.maxRequestsPerMinute)
        self.apiKeyEnvironmentVariable = apiKeyEnvironmentVariable
        self.requestTimeoutSeconds = requestTimeoutSeconds.isFinite
            ? min(max(requestTimeoutSeconds, 1), 120)
            : 30
        self.maxRetries = min(max(maxRetries, 0), Self.maxRetries)
    }

    /// Calculates deterministic exponential backoff for a given retry attempt.
    public func backoffDelaySeconds(forAttempt attempt: Int) -> Double {
        guard attempt >= 0 else { return Self.baseBackoffSeconds }
        let exponent = min(attempt, 30)
        let exponential = Self.baseBackoffSeconds * pow(2.0, Double(exponent))
        return min(exponential, Self.maxBackoffSeconds)
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
    public let requestTimeoutSeconds: Double

    public init(
        endpoint: URL = defaultEndpoint,
        model: String = defaultModel,
        isEnabled: Bool = true,
        requestTimeoutSeconds: Double = 15
    ) {
        self.endpoint = endpoint
        self.model = model
        self.isEnabled = isEnabled
        self.requestTimeoutSeconds = requestTimeoutSeconds.isFinite
            ? min(max(requestTimeoutSeconds, 1), 120)
            : 15
    }
}

/// Architectural contract for the AI DJ advisor service (Phase 2+).
///
/// Security & Privacy Guarantees:
/// 1. No API keys stored in repo, code, or cache files. Keys are loaded from user environment only.
/// 2. Offline-First: Local Accelerate DSP always performs core analysis; AI Advisor is purely advisory.
/// 3. Rate-Limiting: All cloud attempts, including retries, stay within 12 per rolling 60 seconds.
/// 4. Local Caching: Recommendations stay in a bounded in-memory cache keyed by track fingerprints.
public protocol AIAdvisorServiceContract: AnyObject, Sendable {
    /// Current Gemini advisor configuration.
    var geminiConfig: GeminiAdvisorConfig { get }

    /// Current local Ollama fallback configuration.
    var ollamaConfig: OllamaFallbackConfig { get }

    /// Queries advisor for next track transition recommendation.
    /// Implementation must enforce the rolling request limit and bounded local recommendation caching.
    func recommendNextTrack(
        currentTrack: TrackCacheEntry,
        availableTracks: [TrackCacheEntry]
    ) async throws -> AdvisorRecommendation
}
