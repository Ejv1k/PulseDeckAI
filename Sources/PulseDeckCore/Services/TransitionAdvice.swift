import Foundation

/// The three transitions PulseDeck can execute; the advisor may only pick one of these.
public enum TransitionAdviceStyle: String, Sendable, CaseIterable {
    /// Beat-synced bass swap: a gradual blend over the phrase.
    case bassSwap
    /// Filter and echo wash out of the old track: covers key or energy changes.
    case echoOut
    /// Hard cut on the incoming drop: instant energy change.
    case dropCut
}

/// Advisor verdict for one transition. The app only pre-selects it; the DJ still executes.
public struct TransitionAdvice: Sendable, Equatable {
    public let style: TransitionAdviceStyle
    public let bars: Int
    public let reason: String

    public static let allowedBars = [8, 16, 32]

    public init(style: TransitionAdviceStyle, bars: Int, reason: String) {
        self.style = style
        self.bars = bars
        self.reason = reason
    }
}

enum TransitionAdvicePrompt {
    static func make(outgoing: TrackCacheEntry, incoming: TrackCacheEntry) -> String {
        let context: [String: Any] = ["outgoing": describe(outgoing), "incoming": describe(incoming)]
        let json = (try? JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        You advise a live wedding and party DJ. Pick how to move from the outgoing track to the incoming one. \
        Allowed styles: "bassSwap" (beat-matched blend, swaps the bass on the phrase; for similar tempo and \
        compatible key), "echoOut" (filter and echo wash out of the outgoing track; covers key clashes or big \
        tempo or genre jumps), "dropCut" (hard cut straight into the incoming drop or chorus; for energy lifts). \
        Allowed bars: 8, 16 or 32. Use what you know about these songs (genre, era, feel) together with the \
        analysis data. Do not invent analysis values. Reply with one JSON object: style, bars, reason \
        (one short sentence for the DJ, max 140 characters). Context: \(json)
        """
    }

    private static func describe(_ track: TrackCacheEntry) -> [String: Any] {
        var info: [String: Any] = [
            "title": ((track.relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
                .replacingOccurrences(of: "_", with: " "),
            "durationSeconds": (track.duration * 10).rounded() / 10
        ]
        if TrackCompatibility.isAuthenticMeasuredGrid(track: track) { info["bpm"] = (track.bpm * 10).rounded() / 10 }
        if CamelotKey.parse(track.musicalKey) != nil { info["camelotKey"] = track.musicalKey }
        if let energy = SetPlanner.energy(track) { info["energy0to1"] = (energy * 100).rounded() / 100 }
        let sections = track.structure.sections.prefix(12).map {
            ["name": $0.name, "start": $0.startSeconds.rounded(), "end": $0.endSeconds.rounded()] as [String: Any]
        }
        if !sections.isEmpty { info["sections"] = sections }
        return info
    }

    static func schema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "style": ["type": "string", "enum": TransitionAdviceStyle.allCases.map(\.rawValue)],
                "bars": ["type": "integer", "enum": TransitionAdvice.allowedBars],
                "reason": ["type": "string"]
            ],
            "required": ["style", "bars", "reason"],
            "additionalProperties": false
        ]
    }

    /// Accepts the bare JSON object, also when wrapped in a Markdown code fence; rejects anything off-menu.
    static func parse(_ text: String) throws -> TransitionAdvice {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let styleName = object["style"] as? String,
              let style = TransitionAdviceStyle(rawValue: styleName),
              let barsNumber = object["bars"] as? NSNumber,
              CFGetTypeID(barsNumber) != CFBooleanGetTypeID(),
              TransitionAdvice.allowedBars.contains(barsNumber.intValue),
              Double(barsNumber.intValue) == barsNumber.doubleValue,
              let rawReason = object["reason"] as? String else {
            throw AIAdvisorError.malformedProviderResponse
        }
        let reason = rawReason.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !reason.isEmpty else { throw AIAdvisorError.malformedProviderResponse }
        return TransitionAdvice(style: style, bars: barsNumber.intValue,
                                reason: reason.count > 200 ? String(reason.prefix(199)) + "…" : reason)
    }
}
