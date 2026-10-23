import Foundation

/// Musical key mode in the Camelot harmonic mixing system.
public enum CamelotMode: String, Sendable, Codable, Equatable, Hashable {
    case minor = "A"
    case major = "B"
}

/// Strongly-typed Camelot Wheel representation (1A through 12B).
public struct CamelotKey: Sendable, Codable, Equatable, Hashable {
    public let number: Int
    public let mode: CamelotMode

    public init?(number: Int, mode: CamelotMode) {
        guard (1...12).contains(number) else { return nil }
        self.number = number
        self.mode = mode
    }

    public var notation: String {
        "\(number)\(mode.rawValue)"
    }

    /// Parses a Camelot key string (e.g. "8A", "12B") or standard pitch key string (e.g. "Am", "C major").
    /// Returns nil for unrecognized strings, "Unknown", or empty text.
    public static func parse(_ raw: String) -> CamelotKey? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("Unknown") != .orderedSame else { return nil }

        let upper = trimmed.uppercased()

        // 1. Direct Camelot notation: 1A...12A, 1B...12B
        if upper.hasSuffix("A") || upper.hasSuffix("B") {
            let mode: CamelotMode = upper.hasSuffix("A") ? .minor : .major
            let numStr = upper.dropLast()
            if let num = Int(numStr), (1...12).contains(num) {
                return CamelotKey(number: num, mode: mode)
            }
        }

        // 2. Standard pitch mapping
        return parseStandardKey(upper)
    }

    private static func parseStandardKey(_ upper: String) -> CamelotKey? {
        let clean = upper
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")

        switch clean {
        // 1A / 1B: Abm, G#m / B
        case "ABM", "ABMIN", "ABMINOR", "G#M", "G#MIN", "G#MINOR": return CamelotKey(number: 1, mode: .minor)
        case "B", "BMAJ", "BMAJOR": return CamelotKey(number: 1, mode: .major)

        // 2A / 2B: Ebm, D#m / F#, Gb
        case "EBM", "EBMIN", "EBMINOR", "D#M", "D#MIN", "D#MINOR": return CamelotKey(number: 2, mode: .minor)
        case "F#", "F#MAJ", "F#MAJOR", "GB", "GBMAJ", "GBMAJOR": return CamelotKey(number: 2, mode: .major)

        // 3A / 3B: Bbm, A#m / Db, C#
        case "BBM", "BBMIN", "BBMINOR", "A#M", "A#MIN", "A#MINOR": return CamelotKey(number: 3, mode: .minor)
        case "DB", "DBMAJ", "DBMAJOR", "C#", "C#MAJ", "C#MAJOR": return CamelotKey(number: 3, mode: .major)

        // 4A / 4B: Fm / Ab, G#
        case "FM", "FMIN", "FMINOR": return CamelotKey(number: 4, mode: .minor)
        case "AB", "ABMAJ", "ABMAJOR", "G#", "G#MAJ", "G#MAJOR": return CamelotKey(number: 4, mode: .major)

        // 5A / 5B: Cm / Eb, D#
        case "CM", "CMIN", "CMINOR": return CamelotKey(number: 5, mode: .minor)
        case "EB", "EBMAJ", "EBMAJOR", "D#", "D#MAJ", "D#MAJOR": return CamelotKey(number: 5, mode: .major)

        // 6A / 6B: Gm / Bb, A#
        case "GM", "GMIN", "GMINOR": return CamelotKey(number: 6, mode: .minor)
        case "BB", "BBMAJ", "BBMAJOR", "A#", "A#MAJ", "A#MAJOR": return CamelotKey(number: 6, mode: .major)

        // 7A / 7B: Dm / F
        case "DM", "DMIN", "DMINOR": return CamelotKey(number: 7, mode: .minor)
        case "F", "FMAJ", "FMAJOR": return CamelotKey(number: 7, mode: .major)

        // 8A / 8B: Am / C
        case "AM", "AMIN", "AMINOR": return CamelotKey(number: 8, mode: .minor)
        case "C", "CMAJ", "CMAJOR": return CamelotKey(number: 8, mode: .major)

        // 9A / 9B: Em / G
        case "EM", "EMIN", "EMINOR": return CamelotKey(number: 9, mode: .minor)
        case "G", "GMAJ", "GMAJOR": return CamelotKey(number: 9, mode: .major)

        // 10A / 10B: Bm / D
        case "BM", "BMIN", "BMINOR": return CamelotKey(number: 10, mode: .minor)
        case "D", "DMAJ", "DMAJOR": return CamelotKey(number: 10, mode: .major)

        // 11A / 11B: F#m, Gbm / A
        case "F#M", "F#MIN", "F#MINOR", "GBM", "GBMIN", "GBMINOR": return CamelotKey(number: 11, mode: .minor)
        case "A", "AMAJ", "AMAJOR": return CamelotKey(number: 11, mode: .major)

        // 12A / 12B: C#m, Dbm / E
        case "C#M", "C#MIN", "C#MINOR", "DBM", "DBMIN", "DBMINOR": return CamelotKey(number: 12, mode: .minor)
        case "E", "EMAJ", "EMAJOR": return CamelotKey(number: 12, mode: .major)

        default:
            return nil
        }
    }
}

/// Harmonic relationship category on the Camelot Wheel.
public enum HarmonicRelationship: String, Sendable, Equatable {
    case exact = "EXACT"
    case relative = "RELATIVE"
    case adjacentPlus = "+1 ADJACENT"
    case adjacentMinus = "-1 ADJACENT"
    case clash = "CLASH"

    public var isHarmonic: Bool {
        switch self {
        case .exact, .relative, .adjacentPlus, .adjacentMinus:
            return true
        case .clash:
            return false
        }
    }
}

/// Evaluated musical key compatibility against a reference track.
public enum KeyCompatibility: Sendable, Equatable {
    case harmonic(key: CamelotKey, relationship: HarmonicRelationship)
    case clash(key: CamelotKey)
    case unknown

    public var isHarmonic: Bool {
        if case .harmonic = self { return true }
        return false
    }

    public var badgeLabel: String {
        switch self {
        case .harmonic(let key, let rel):
            return "\(key.notation) \(rel.rawValue)"
        case .clash(let key):
            return "\(key.notation) CLASH"
        case .unknown:
            return "KEY UNKNOWN"
        }
    }
}

/// Evaluated tempo compatibility against a reference track.
public enum TempoCompatibility: Sendable, Equatable {
    case compatible(deltaPercent: Double)
    case mismatch(deltaPercent: Double)
    case unknown

    public var isCompatible: Bool {
        if case .compatible = self { return true }
        return false
    }

    public var badgeLabel: String {
        switch self {
        case .compatible(let delta):
            return String(format: "%+.1f%%", delta)
        case .mismatch(let delta):
            return String(format: "%+.1f%% MISMATCH", delta)
        case .unknown:
            return "BPM UNKNOWN"
        }
    }
}

/// Combined compatibility verdict between a candidate track and reference track.
public struct TrackCompatibility: Sendable, Equatable {
    public let key: KeyCompatibility
    public let tempo: TempoCompatibility

    public init(key: KeyCompatibility, tempo: TempoCompatibility) {
        self.key = key
        self.tempo = tempo
    }

    public var isOverallCompatible: Bool {
        key.isHarmonic && tempo.isCompatible
    }

    public var isOverallUnknown: Bool {
        key == .unknown || tempo == .unknown
    }

    /// Evaluates compatibility between candidate and reference track entries.
    public static func evaluate(candidate: TrackCacheEntry, reference: TrackCacheEntry) -> TrackCompatibility {
        let keyComp: KeyCompatibility
        if let candKey = CamelotKey.parse(candidate.musicalKey),
           let refKey = CamelotKey.parse(reference.musicalKey) {
            let rel = evaluateHarmonicRelationship(candidate: candKey, reference: refKey)
            if rel.isHarmonic {
                keyComp = .harmonic(key: candKey, relationship: rel)
            } else {
                keyComp = .clash(key: candKey)
            }
        } else {
            keyComp = .unknown
        }

        let candGridValid = isAuthenticMeasuredGrid(track: candidate)
        let refGridValid = isAuthenticMeasuredGrid(track: reference)

        let tempoComp: TempoCompatibility
        if candGridValid && refGridValid && reference.bpm > 0 {
            let delta = (candidate.bpm - reference.bpm) / reference.bpm
            if abs(delta) < TransitionPlanner.maxTempoDifferential {
                tempoComp = .compatible(deltaPercent: delta * 100.0)
            } else {
                tempoComp = .mismatch(deltaPercent: delta * 100.0)
            }
        } else {
            tempoComp = .unknown
        }

        return TrackCompatibility(key: keyComp, tempo: tempoComp)
    }

    /// Computes the deterministic Camelot harmonic relationship.
    public static func evaluateHarmonicRelationship(candidate: CamelotKey, reference: CamelotKey) -> HarmonicRelationship {
        if candidate == reference {
            return .exact
        }
        if candidate.number == reference.number && candidate.mode != reference.mode {
            return .relative
        }
        if candidate.mode == reference.mode {
            let diff = (candidate.number - reference.number + 12) % 12
            if diff == 1 {
                return .adjacentPlus
            } else if diff == 11 {
                return .adjacentMinus
            }
        }
        return .clash
    }

    /// Verifies authentic measured beat grid exists (rejecting 1.0s unknown-tempo sentinels, empty grids, or invalid values).
    /// Accepts realistic audio analysis transient jitter while preserving monotonicity and bounds.
    public static func isAuthenticMeasuredGrid(track: TrackCacheEntry) -> Bool {
        let grid = track.beatGrid
        guard track.duration.isFinite, track.duration > 0,
              track.bpm.isFinite, track.bpm > 0,
              track.confidence.isFinite, (0...1).contains(track.confidence), track.confidence > 0,
              grid.firstBeatOffsetSeconds.isFinite, grid.firstBeatOffsetSeconds >= 0, grid.firstBeatOffsetSeconds <= track.duration,
              grid.beatIntervalSeconds.isFinite, grid.beatIntervalSeconds > 0,
              grid.beatTimestamps.count >= 2 else {
            return false
        }
        let tolerance = max(1e-4, grid.beatIntervalSeconds * 0.01)
        guard abs(grid.beatIntervalSeconds - 60.0 / track.bpm) <= tolerance else {
            return false
        }
        var previous = -Double.infinity
        for timestamp in grid.beatTimestamps {
            guard timestamp.isFinite, timestamp >= 0, timestamp <= track.duration,
                  timestamp > previous else {
                return false
            }
            previous = timestamp
        }
        return true
    }
}
