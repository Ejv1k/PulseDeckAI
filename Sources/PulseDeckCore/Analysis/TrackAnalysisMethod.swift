import Foundation

/// User-selectable analysis method for track rhythm and metadata extraction.
public enum TrackAnalysisMethod: String, CaseIterable, Identifiable, Sendable {
    case dsp = "DSP"
    case nativeModel = "Model"

    public var id: String { rawValue }
    public var displayName: String { rawValue }

    public var helpText: String {
        switch self {
        case .dsp:
            return "Fast DSP heuristic (onset autocorrelation). Key is not detected."
        case .nativeModel:
            return "Beat This! beat and downbeat model with phrase-aligned cues and key detection."
        }
    }
}
