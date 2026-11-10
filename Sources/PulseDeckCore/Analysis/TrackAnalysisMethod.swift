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
            return "DSP baseline (heuristic onset autocorrelation). Key remains unknown."
        case .nativeModel:
            return "Native CoreML rhythm tracking via Beat This! small0 (fixed-1500 adapted). Key remains unknown."
        }
    }
}
