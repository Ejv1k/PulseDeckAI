import Foundation

/// Four strictly ordered and bounded cue markers for a track.
/// Contract: 0.0 <= startTrimCue <= vocalEntryCue <= mixOutCue <= endTrimCue <= duration
public struct CueMarkers: Codable, Sendable, Equatable {
    /// Timestamp in seconds where active audio starts (trims introductory silence or DJ clutter).
    public var startTrimCue: Double

    /// Timestamp in seconds where the first vocal segment begins.
    public var vocalEntryCue: Double

    /// Timestamp in seconds where the outro transition should begin mixing out.
    public var mixOutCue: Double

    /// Timestamp in seconds where active audio ends (trims trailing silence or dead air).
    public var endTrimCue: Double

    public init(
        startTrimCue: Double,
        vocalEntryCue: Double,
        mixOutCue: Double,
        endTrimCue: Double
    ) {
        self.startTrimCue = startTrimCue
        self.vocalEntryCue = vocalEntryCue
        self.mixOutCue = mixOutCue
        self.endTrimCue = endTrimCue
    }

    /// Verifies strict ordering and bounds against the track's total duration.
    public func isValid(forDuration duration: Double) -> Bool {
        guard duration >= 0 else { return false }
        return 0.0 <= startTrimCue
            && startTrimCue <= vocalEntryCue
            && vocalEntryCue <= mixOutCue
            && mixOutCue <= endTrimCue
            && endTrimCue <= duration
    }

    /// Clamps and orders cues safely to fit within track duration without inversion.
    public func clamped(toDuration duration: Double) -> CueMarkers {
        let maxDur = max(0.0, duration)
        let s = min(max(0.0, startTrimCue), maxDur)
        let v = min(max(s, vocalEntryCue), maxDur)
        let m = min(max(v, mixOutCue), maxDur)
        let e = min(max(m, endTrimCue), maxDur)
        return CueMarkers(startTrimCue: s, vocalEntryCue: v, mixOutCue: m, endTrimCue: e)
    }
}

/// Provenance metadata tracking manual adjustments made by a human DJ.
public struct ManualOverrides: Codable, Sendable, Equatable {
    /// True if the user manually adjusted any cue, BPM, key, or trim setting.
    public var isManual: Bool

    /// List of property names that have been manually overridden (e.g. ["cueMarkers", "bpm"]).
    public var overriddenFields: [String]

    /// ISO 8601 timestamp of the last manual change.
    public var updatedAt: String?

    /// Identifier of the DJ session or user making the change.
    public var author: String?

    /// Optional notes or rationale for the manual override.
    public var notes: String?

    public init(
        isManual: Bool = false,
        overriddenFields: [String] = [],
        updatedAt: String? = nil,
        author: String? = nil,
        notes: String? = nil
    ) {
        self.isManual = isManual
        self.overriddenFields = overriddenFields
        self.updatedAt = updatedAt
        self.author = author
        self.notes = notes
    }
}

/// Visual waveform downsampled peak data for rendering multi-band visualizers.
public struct WaveformMetadata: Codable, Sendable, Equatable {
    public let sampleCount: Int
    public let downsampleFactor: Int
    public let peakValues: [Float]
    public let lowBandPeaks: [Float]
    public let midBandPeaks: [Float]
    public let highBandPeaks: [Float]

    public init(
        sampleCount: Int,
        downsampleFactor: Int,
        peakValues: [Float],
        lowBandPeaks: [Float],
        midBandPeaks: [Float],
        highBandPeaks: [Float]
    ) {
        self.sampleCount = sampleCount
        self.downsampleFactor = downsampleFactor
        self.peakValues = peakValues
        self.lowBandPeaks = lowBandPeaks
        self.midBandPeaks = midBandPeaks
        self.highBandPeaks = highBandPeaks
    }
}

/// Detected beat grid timestamps and tempo timing.
public struct BeatGrid: Codable, Sendable, Equatable {
    public let firstBeatOffsetSeconds: Double
    public let beatIntervalSeconds: Double
    public let beatTimestamps: [Double]

    public init(
        firstBeatOffsetSeconds: Double,
        beatIntervalSeconds: Double,
        beatTimestamps: [Double]
    ) {
        self.firstBeatOffsetSeconds = firstBeatOffsetSeconds
        self.beatIntervalSeconds = beatIntervalSeconds
        self.beatTimestamps = beatTimestamps
    }
}

/// Structural musical section (Intro, Verse, Chorus, Breakdown, Drop, Outro).
public struct StructureSection: Codable, Sendable, Equatable {
    public let name: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let energyLevel: Double

    public init(name: String, startSeconds: Double, endSeconds: Double, energyLevel: Double) {
        self.name = name
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.energyLevel = energyLevel
    }
}

/// Vocal segment detection with boundary timestamps and confidence.
public struct VocalSegment: Codable, Sendable, Equatable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let confidence: Double

    public init(startSeconds: Double, endSeconds: Double, confidence: Double) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.confidence = confidence
    }
}

/// High-level structure analysis comprising macro-sections and vocal activity.
public struct TrackStructure: Codable, Sendable, Equatable {
    public let sections: [StructureSection]
    public let vocalSegments: [VocalSegment]

    public init(sections: [StructureSection], vocalSegments: [VocalSegment]) {
        self.sections = sections
        self.vocalSegments = vocalSegments
    }
}

/// Complete cached analysis and metadata entry for a single audio track.
public struct TrackCacheEntry: Codable, Sendable, Equatable {
    /// Relative path within PulseDeck_Library (e.g. "00_Test_Tracks_Dev/song.mp3").
    public let relativePath: String

    /// Content fingerprint (e.g. SHA-256 or size+mtime hash) to detect file edits.
    public let fileFingerprint: String

    /// File size in bytes.
    public let fileSizeBytes: Int64

    /// ISO 8601 file modification timestamp.
    public let fileModificationTime: String

    /// Total audio duration in seconds.
    public let duration: Double

    /// Audio sample rate in Hz.
    public let sampleRate: Double

    /// Number of audio channels.
    public let channels: Int

    /// Audio bit depth (e.g. 16 or 24).
    public let bitDepth: Int

    /// Detected Beats Per Minute.
    public var bpm: Double

    /// Musical key in Camelot (e.g. "8A") or standard notation.
    public var musicalKey: String

    /// Detection confidence score (0.0 to 1.0).
    public let confidence: Double

    /// Downsampled multi-band waveform peaks.
    public let waveformMetadata: WaveformMetadata

    /// Beat grid positions.
    public let beatGrid: BeatGrid

    /// Macro song structure and vocal activity.
    public let structure: TrackStructure

    /// Four ordered cue markers.
    public var cueMarkers: CueMarkers

    /// When true, automated AI trim points are bypassed during playback.
    public var aiTrimBypass: Bool

    /// Provenance tracking manual DJ adjustments.
    public var manualOverrides: ManualOverrides

    /// Identifier of the DSP/AI analyzer version used.
    public let analyzerVersion: String

    /// ISO 8601 timestamp of analysis execution.
    public let analysisTimestamp: String

    public init(
        relativePath: String,
        fileFingerprint: String,
        fileSizeBytes: Int64,
        fileModificationTime: String,
        duration: Double,
        sampleRate: Double,
        channels: Int,
        bitDepth: Int,
        bpm: Double,
        musicalKey: String,
        confidence: Double,
        waveformMetadata: WaveformMetadata,
        beatGrid: BeatGrid,
        structure: TrackStructure,
        cueMarkers: CueMarkers,
        aiTrimBypass: Bool = false,
        manualOverrides: ManualOverrides = ManualOverrides(),
        analyzerVersion: String,
        analysisTimestamp: String
    ) {
        self.relativePath = relativePath
        self.fileFingerprint = fileFingerprint
        self.fileSizeBytes = fileSizeBytes
        self.fileModificationTime = fileModificationTime
        self.duration = duration
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitDepth = bitDepth
        self.bpm = bpm
        self.musicalKey = musicalKey
        self.confidence = confidence
        self.waveformMetadata = waveformMetadata
        self.beatGrid = beatGrid
        self.structure = structure
        self.cueMarkers = cueMarkers
        self.aiTrimBypass = aiTrimBypass
        self.manualOverrides = manualOverrides
        self.analyzerVersion = analyzerVersion
        self.analysisTimestamp = analysisTimestamp
    }

    /// Determines if the cache entry remains valid for the current file on disk and analyzer algorithm.
    public func isValid(currentFingerprint: String, targetAnalyzerVersion: String) -> Bool {
        return self.fileFingerprint == currentFingerprint
            && self.analyzerVersion == targetAnalyzerVersion
    }

    /// Merges new automated analysis results into this entry while strictly preserving manual DJ overrides.
    /// Contract: Automated analysis NEVER clobbers manual edits.
    public func mergingPreservingOverrides(with newAnalysis: TrackCacheEntry) -> TrackCacheEntry {
        guard self.manualOverrides.isManual else {
            return newAnalysis
        }

        var merged = newAnalysis
        merged.manualOverrides = self.manualOverrides
        merged.aiTrimBypass = self.aiTrimBypass

        if self.manualOverrides.overriddenFields.contains("cueMarkers") {
            merged.cueMarkers = self.cueMarkers
        }
        if self.manualOverrides.overriddenFields.contains("bpm") {
            merged.bpm = self.bpm
        }
        if self.manualOverrides.overriddenFields.contains("musicalKey") {
            merged.musicalKey = self.musicalKey
        }

        return merged
    }
}

/// The root dictionary and metadata structure of `.pulsedeck_ai_cache.json`.
public struct PulseDeckLibraryCache: Codable, Sendable, Equatable {
    public enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case schemaVersion
        case generatedAt
        case libraryRoot
        case tracks
    }

    public var schema: String?
    public var schemaVersion: String
    public var generatedAt: String?
    public var libraryRoot: String
    public var tracks: [String: TrackCacheEntry]

    public init(
        schema: String? = "../docs/cache_schema_v1.json",
        schemaVersion: String = PulseDeckCoreConfig.cacheSchemaVersion,
        generatedAt: String? = nil,
        libraryRoot: String = PulseDeckCoreConfig.defaultLibraryFolderName,
        tracks: [String: TrackCacheEntry] = [:]
    ) {
        self.schema = schema
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.libraryRoot = libraryRoot
        self.tracks = tracks
    }
}
