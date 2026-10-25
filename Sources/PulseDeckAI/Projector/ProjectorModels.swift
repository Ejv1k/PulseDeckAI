import Foundation
import CoreGraphics
import PulseDeckCore

/// Media format category for the background slideshow/video engine.
public enum ProjectorMediaType: String, Sendable, Equatable, CaseIterable {
    case photo
    case video
}

/// Metadata descriptor for a discovered media item in `09_Visual_Backgrounds_Media`.
public struct ProjectorMediaItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let fileName: String
    public let fileURL: URL
    public let type: ProjectorMediaType
    public let fileSizeBytes: Int64

    public init(
        id: String,
        fileName: String,
        fileURL: URL,
        type: ProjectorMediaType,
        fileSizeBytes: Int64
    ) {
        self.id = id
        self.fileName = fileName
        self.fileURL = fileURL
        self.type = type
        self.fileSizeBytes = fileSizeBytes
    }
}

/// Operational state of the media scanner and loader.
public enum ProjectorMediaState: Sendable, Equatable {
    case loading
    case ready(items: [ProjectorMediaItem])
    case empty
    case error(message: String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var isEmpty: Bool {
        if case .empty = self { return true }
        return false
    }
}

/// Information about a connected display screen.
public struct ProjectorDisplayDescriptor: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let isMain: Bool
    public let bounds: CGRect
    public let resolution: CGSize

    public init(
        id: String,
        name: String,
        isMain: Bool,
        bounds: CGRect,
        resolution: CGSize
    ) {
        self.id = id
        self.name = name
        self.isMain = isMain
        self.bounds = bounds
        self.resolution = resolution
    }
}

/// Snapshot of frequency bands and volume metrics for Mode 1 spectrum visualizer.
public struct ProjectorVisualizerFrame: Sendable, Equatable {
    public let bands: [Float]
    public let rms: Float
    public let peak: Float
    public let timestamp: UInt64
    public let isSilent: Bool

    public init(
        bands: [Float],
        rms: Float,
        peak: Float,
        timestamp: UInt64,
        isSilent: Bool
    ) {
        self.bands = bands
        self.rms = rms
        self.peak = peak
        self.timestamp = timestamp
        self.isSilent = isSilent
    }

    public static let zero = ProjectorVisualizerFrame(
        bands: Array(repeating: 0.0, count: 24),
        rms: 0.0,
        peak: 0.0,
        timestamp: 0,
        isSilent: true
    )
}

/// Track metadata rendered on the Mode 3 Now Playing card.
public struct ProjectorNowPlayingMetadata: Sendable, Equatable {
    public let title: String
    public let artist: String
    public let deck: DeckIdentifier?
    public let bpm: Double?
    public let musicalKey: String?
    public let durationSeconds: Double?
    public let isMasterPlaying: Bool

    public init(
        title: String,
        artist: String,
        deck: DeckIdentifier?,
        bpm: Double?,
        musicalKey: String?,
        durationSeconds: Double?,
        isMasterPlaying: Bool
    ) {
        self.title = title
        self.artist = artist
        self.deck = deck
        self.bpm = bpm
        self.musicalKey = musicalKey
        self.durationSeconds = durationSeconds
        self.isMasterPlaying = isMasterPlaying
    }

    public static let idle = ProjectorNowPlayingMetadata(
        title: "PulseDeck AI",
        artist: "Ready to Play",
        deck: nil,
        bpm: nil,
        musicalKey: nil,
        durationSeconds: nil,
        isMasterPlaying: false
    )
}
