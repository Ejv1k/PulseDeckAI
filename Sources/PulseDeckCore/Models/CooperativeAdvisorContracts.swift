import Foundation

/// Operational mode for the AI DJ Adviser.
public enum AdvisorMode: String, Codable, Sendable, CaseIterable {
    /// Purely local inference. Cloud endpoints are never contacted.
    case localOnly = "Local Only"

    /// Local provisional recommendation followed by background Gemini cloud refinement.
    case cooperative = "Local + Cloud Refinement"

    /// Adviser is completely turned off.
    case disabled = "Disabled"
}

/// A unified two-phase recommendation result delivered to the DJ UI.
public struct CooperativeRecommendation: Sendable, Equatable {
    /// Monotonic generation ID that originated this advice. Stale results are rejected.
    public let generationID: UInt64

    /// The base track for which this recommendation was calculated.
    public let currentTrackPath: String

    /// Immediate provisional recommendation from the fast local provider.
    public let provisional: AdvisorRecommendation

    /// Label identifying the local model (e.g. "Ollama: gemma3:4b" or "MLX: embedded").
    public let localModelLabel: String

    /// Optional cloud refinement from Gemini for complex sets or energy arcs.
    public let refinement: AdvisorRecommendation?

    /// Label identifying the cloud model (e.g. "Gemini: gemini-2.5-flash").
    public let cloudModelLabel: String?

    /// True while background cloud refinement is actively in progress.
    public let isRefining: Bool

    /// Timestamp when this recommendation was finalized or generated.
    public let timestamp: Date

    public init(
        generationID: UInt64,
        currentTrackPath: String,
        provisional: AdvisorRecommendation,
        localModelLabel: String,
        refinement: AdvisorRecommendation? = nil,
        cloudModelLabel: String? = nil,
        isRefining: Bool = false,
        timestamp: Date = Date()
    ) {
        self.generationID = generationID
        self.currentTrackPath = currentTrackPath
        self.provisional = provisional
        self.localModelLabel = localModelLabel
        self.refinement = refinement
        self.cloudModelLabel = cloudModelLabel
        self.isRefining = isRefining
        self.timestamp = timestamp
    }

    /// The effective recommendation to display: refinement if present, otherwise provisional.
    public var activeRecommendation: AdvisorRecommendation {
        refinement ?? provisional
    }
}

/// Abstract protocol for local fast inference providers.
/// Enables seamless drop-in replacement by an embedded MLX runtime without changing orchestration.
public protocol LocalAdvisorProvider: Sendable {
    /// Display name of the local model or runtime engine.
    var modelIdentifier: String { get }

    /// Asynchronously queries whether the local inference engine is ready and available.
    var isAvailable: Bool { get async }

    /// Evaluates current track and candidates, returning a bounded recommendation.
    func recommend(
        currentTrack: TrackCacheEntry,
        candidates: [TrackCacheEntry]
    ) async throws -> AdvisorRecommendation
}

/// Bounded metadata disclosure showing the user exactly what is sent to the cloud.
/// Guarantees that raw audio, stems, and personal path hierarchies are never transmitted.
public struct AdvisorMetadataDisclosure: Sendable, Equatable {
    public struct CandidateSummary: Sendable, Equatable {
        public let relativePath: String
        public let durationSeconds: Double
        public let bpm: Double
        public let musicalKey: String

        public init(relativePath: String, durationSeconds: Double, bpm: Double, musicalKey: String) {
            self.relativePath = relativePath
            self.durationSeconds = durationSeconds
            self.bpm = bpm
            self.musicalKey = musicalKey
        }
    }

    public let currentTrack: CandidateSummary
    public let candidates: [CandidateSummary]
    public let totalCandidateCount: Int

    public init(currentTrack: TrackCacheEntry, candidates: [TrackCacheEntry]) {
        self.currentTrack = CandidateSummary(
            relativePath: currentTrack.relativePath,
            durationSeconds: currentTrack.duration,
            bpm: currentTrack.bpm,
            musicalKey: currentTrack.musicalKey
        )
        let prefixList = candidates.prefix(5)
        self.candidates = prefixList.map {
            CandidateSummary(
                relativePath: $0.relativePath,
                durationSeconds: $0.duration,
                bpm: $0.bpm,
                musicalKey: $0.musicalKey
            )
        }
        self.totalCandidateCount = candidates.count
    }
}
