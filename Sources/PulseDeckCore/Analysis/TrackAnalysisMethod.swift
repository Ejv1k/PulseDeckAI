import Foundation

/// User-selectable analysis method for track rhythm and metadata extraction.
public enum TrackAnalysisMethod: String, CaseIterable, Identifiable, Sendable {
    case dsp = "DSP"
    case nativeModel = "Model"

    public var id: String { rawValue }
    /// Plain name in the UI; `rawValue` stays the stored identifier.
    public var displayName: String { self == .dsp ? "Quick" : "Accurate" }

    public var helpText: String {
        switch self {
        case .dsp:
            return "Quick analysis: fast tempo and cue estimate. No key."
        case .nativeModel:
            return "Accurate analysis: beat model with bar-aligned cues, key and singing detection."
        }
    }
}
