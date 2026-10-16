import CoreFoundation
import Foundation

struct AdvisorHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

protocol AdvisorHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> AdvisorHTTPResponse
}

struct URLSessionAdvisorHTTPTransport: AdvisorHTTPTransport {
    let session: URLSession
    private let redirectDelegate: RedirectRejectingURLSessionDelegate

    init(configuration: URLSessionConfiguration = .ephemeral) {
        let redirectDelegate = RedirectRejectingURLSessionDelegate()
        self.redirectDelegate = redirectDelegate
        self.session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    func send(_ request: URLRequest) async throws -> AdvisorHTTPResponse {
        let (body, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AIAdvisorError.invalidHTTPResponse
        }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String else { continue }
            headers[key.lowercased()] = String(describing: value)
        }
        return AdvisorHTTPResponse(statusCode: response.statusCode, headers: headers, body: body)
    }
}

private final class RedirectRejectingURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

protocol AdvisorClock: Sendable {
    func monotonicNow() async -> TimeInterval
    func wallClockNow() async -> Date
    func sleep(for seconds: TimeInterval) async throws
}

struct SystemAdvisorClock: AdvisorClock {
    func monotonicNow() async -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    func wallClockNow() async -> Date {
        Date()
    }

    func sleep(for seconds: TimeInterval) async throws {
        guard seconds.isFinite, seconds > 0 else { return }
        try await Task.sleep(for: .seconds(seconds))
    }
}

actor GeminiRollingWindowRateLimiter {
    private let limit: Int
    private let windowSeconds: TimeInterval = 60
    private let clock: any AdvisorClock
    private var requestTimes: [TimeInterval] = []

    init(limit: Int, clock: any AdvisorClock) {
        self.limit = min(max(limit, 1), GeminiAdvisorConfig.maxRequestsPerMinute)
        self.clock = clock
    }

    func acquireRequestSlot() async throws {
        while true {
            try Task.checkCancellation()
            let now = await clock.monotonicNow()
            requestTimes.removeAll { now - $0 >= windowSeconds }
            if requestTimes.count < limit {
                requestTimes.append(now)
                return
            }

            guard let oldest = requestTimes.first else { continue }
            try await clock.sleep(for: max(0, oldest + windowSeconds - now))
        }
    }
}

enum AIAdvisorError: LocalizedError, Sendable, Equatable {
    case invalidHTTPResponse
    case invalidConfiguration
    case responseTooLarge
    case malformedProviderResponse
    case invalidRecommendation
    case httpStatus(provider: String, status: Int)
    case networkFailure(provider: String)
    case noProviderAvailable
    case allProvidersUnavailable(cloudStatus: Int?, localStatus: Int?)

    var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            return "Advisor returned a non-HTTP response"
        case .invalidConfiguration:
            return "Advisor endpoint, model, or timeout configuration is invalid"
        case .responseTooLarge:
            return "Advisor response exceeded the 1 MiB safety limit"
        case .malformedProviderResponse:
            return "Advisor response did not match the expected JSON structure"
        case .invalidRecommendation:
            return "Advisor recommendation failed track, number, or cue-bound validation"
        case .httpStatus(let provider, let status):
            return "\(provider) returned HTTP \(status)"
        case .networkFailure(let provider):
            return "\(provider) request failed"
        case .noProviderAvailable:
            return "No advisor provider is configured or available"
        case .allProvidersUnavailable(let cloudStatus, let localStatus):
            return "Advisor unavailable (Gemini HTTP \(cloudStatus.map(String.init) ?? "offline"); Ollama HTTP \(localStatus.map(String.init) ?? "offline"))"
        }
    }
}

enum AdvisorRecommendationValidator {
    static func validate(
        _ recommendation: AdvisorRecommendation,
        currentTrack: TrackCacheEntry,
        availableTracks: [TrackCacheEntry]
    ) throws -> AdvisorRecommendation {
        let promptedTracks = availableTracks
            .filter { $0.isValid && $0.relativePath != currentTrack.relativePath }
            .sorted { $0.relativePath < $1.relativePath }
            .prefix(100)
        guard currentTrack.isValid,
              let suggestedTrack = promptedTracks.first(where: { $0.relativePath == recommendation.suggestedTrackPath }),
              !recommendation.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              recommendation.rationale.count <= 2_000,
              !recommendation.harmonicCompatibility.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              recommendation.harmonicCompatibility.count <= 64,
              (1...64).contains(recommendation.transitionBars),
              recommendation.suggestedMixInSeconds.isFinite,
              (0...suggestedTrack.duration).contains(recommendation.suggestedMixInSeconds),
              !recommendation.energyProgression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              recommendation.energyProgression.count <= 256 else {
            throw AIAdvisorError.invalidRecommendation
        }
        return recommendation
    }
}

enum AdvisorPromptBuilder {
    static func decodeRecommendation(_ data: Data) throws -> AdvisorRecommendation {
        let required: Set<String> = [
            "suggestedTrackPath", "rationale", "harmonicCompatibility",
            "transitionBars", "suggestedMixInSeconds", "energyProgression"
        ]
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == required,
              object["suggestedTrackPath"] is String,
              object["rationale"] is String,
              object["harmonicCompatibility"] is String,
              object["energyProgression"] is String,
              let bars = object["transitionBars"] as? NSNumber,
              CFGetTypeID(bars) != CFBooleanGetTypeID(),
              bars.doubleValue.isFinite,
              bars.doubleValue.rounded() == bars.doubleValue,
              let mixIn = object["suggestedMixInSeconds"] as? NSNumber,
              CFGetTypeID(mixIn) != CFBooleanGetTypeID(),
              mixIn.doubleValue.isFinite,
              let recommendation = try? JSONDecoder().decode(AdvisorRecommendation.self, from: data) else {
            throw AIAdvisorError.malformedProviderResponse
        }
        return recommendation
    }

    static func make(currentTrack: TrackCacheEntry, availableTracks: [TrackCacheEntry]) throws -> String {
        let entries = availableTracks
            .filter { $0.isValid && $0.relativePath != currentTrack.relativePath }
            .sorted { $0.relativePath < $1.relativePath }
            .prefix(100)
            .map { track in
                [
                    "path": track.relativePath,
                    "durationSeconds": track.duration,
                    "bpm": track.bpm,
                    "musicalKey": track.musicalKey,
                    "confidence": track.confidence
                ] as [String: Any]
            }
        guard currentTrack.isValid, !entries.isEmpty else {
            throw AIAdvisorError.invalidRecommendation
        }
        let current = [
            "path": currentTrack.relativePath,
            "durationSeconds": currentTrack.duration,
            "bpm": currentTrack.bpm,
            "musicalKey": currentTrack.musicalKey,
            "confidence": currentTrack.confidence
        ] as [String: Any]
        let context: [String: Any] = ["currentTrack": current, "availableTracks": Array(entries)]
        guard JSONSerialization.isValidJSONObject(context),
              let data = try? JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            throw AIAdvisorError.invalidConfiguration
        }
        return """
        Recommend one different track from availableTracks for the next DJ transition. Use only exact available path values. Do not invent tracks or musical facts. Return one JSON object with fields suggestedTrackPath, rationale, harmonicCompatibility, transitionBars, suggestedMixInSeconds, energyProgression. suggestedMixInSeconds must be within the selected track's duration. Do not modify or overwrite track data. Context: \(json)
        """
    }

    static func recommendationJSONSchema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "suggestedTrackPath": ["type": "string"],
                "rationale": ["type": "string"],
                "harmonicCompatibility": ["type": "string"],
                "transitionBars": ["type": "integer"],
                "suggestedMixInSeconds": ["type": "number"],
                "energyProgression": ["type": "string"]
            ],
            "required": [
                "suggestedTrackPath", "rationale", "harmonicCompatibility",
                "transitionBars", "suggestedMixInSeconds", "energyProgression"
            ],
            "additionalProperties": false,
            "propertyOrdering": [
                "suggestedTrackPath", "rationale", "harmonicCompatibility",
                "transitionBars", "suggestedMixInSeconds", "energyProgression"
            ]
        ]
    }

    static func ollamaRecommendationJSONSchema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "suggestedTrackPath": ["type": "string"],
                "rationale": ["type": "string"],
                "harmonicCompatibility": ["type": "string"],
                "transitionBars": ["type": "integer"],
                "suggestedMixInSeconds": ["type": "number"],
                "energyProgression": ["type": "string"]
            ],
            "required": [
                "suggestedTrackPath", "rationale", "harmonicCompatibility",
                "transitionBars", "suggestedMixInSeconds", "energyProgression"
            ],
            "additionalProperties": false
        ]
    }
}
