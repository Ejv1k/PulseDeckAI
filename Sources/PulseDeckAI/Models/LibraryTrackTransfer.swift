import AVFoundation
import CoreTransferable
import Foundation
import PulseDeckCore
import UniformTypeIdentifiers

/// A library identity, not an arbitrary external file URL. Drop receivers revalidate it.
struct LibraryTrackTransfer: Codable, Transferable, Sendable, Equatable {
    let libraryRoot: URL
    let relativePath: String

    init(libraryRoot: URL, relativePath: String) {
        self.libraryRoot = libraryRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.relativePath = relativePath
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pulseDeckLibraryTrack)
    }
}

extension UTType {
    static let pulseDeckLibraryTrack = UTType(exportedAs: "com.pulsedeckai.library-track")
}

enum LibraryTrackAnalysisStatus: Equatable {
    case running
    case complete
    case failed(String)

    var label: String {
        switch self {
        case .running: "Analyzing locally…"
        case .complete: "Analysis ready"
        case .failed(let reason): "Analysis failed: \(reason)"
        }
    }
}

/// Filesystem validation and header metadata only. No DSP, cache writes or playback.
enum LibraryTrackSource {
    static func url(relativePath: String, root: URL) throws -> URL {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard root.isFileURL, !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !relativePath.contains("\\"),
              LibraryScanner.supportedAudioExtensions.contains(URL(fileURLWithPath: relativePath).pathExtension.lowercased()) else {
            throw Failure("Choose a supported audio file inside the current library.")
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let file = canonicalRoot.appendingPathComponent(relativePath).standardizedFileURL
        let resolved = file.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(canonicalRoot.path + "/"), resolved == file else {
            throw Failure("The track redirects outside its library identity. Select the original library file.")
        }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
        guard values.isRegularFile == true, values.isReadable == true else {
            throw Failure("The audio file is missing, unreadable or not a regular file.")
        }
        return file
    }

    static func fingerprint(at url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values.fileSize, let date = values.contentModificationDate else {
            throw Failure("Cannot read the audio file's identity.")
        }
        return "\(size)-\(Int64(date.timeIntervalSince1970 * 1_000))"
    }

    static func metadata(at url: URL, relativePath: String) throws -> TrackCacheEntry {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let duration = Double(file.length) / format.sampleRate
        guard format.sampleRate.isFinite, (8_000...384_000).contains(format.sampleRate),
              (1...32).contains(format.channelCount), file.length > 0,
              duration.isFinite, duration <= 6 * 60 * 60 else {
            throw Failure("Audio must have a supported format and a duration between zero and six hours.")
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let emptyWaveform = WaveformMetadata(sampleCount: 0, downsampleFactor: 1, peakValues: [],
                                             lowBandPeaks: [], midBandPeaks: [], highBandPeaks: [])
        return TrackCacheEntry(
            relativePath: relativePath, fileFingerprint: try fingerprint(at: url),
            fileSizeBytes: Int64(values.fileSize ?? 0),
            fileModificationTime: ISO8601DateFormatter().string(from: values.contentModificationDate ?? .distantPast),
            duration: duration, sampleRate: format.sampleRate, channels: Int(format.channelCount), bitDepth: 0,
            bpm: 0, musicalKey: "Unknown", confidence: 0, waveformMetadata: emptyWaveform,
            beatGrid: BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 1, beatTimestamps: []),
            structure: TrackStructure(sections: [], vocalSegments: []),
            cueMarkers: CueMarkers(startTrimCue: 0, vocalEntryCue: 0, mixOutCue: duration, endTrimCue: duration),
            analyzerVersion: "unanalysed-playback", analysisTimestamp: "")
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
