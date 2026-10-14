import Foundation

/// Representation of a library crate directory.
public struct LibraryCrateInfo: Sendable, Equatable, Identifiable {
    public let id: String
    public let folderName: String
    public let displayName: String
    public let relativePath: String
    public let trackCount: Int
    public let hasGitKeep: Bool
    public let audioFiles: [String]

    public init(
        id: String,
        folderName: String,
        displayName: String,
        relativePath: String,
        trackCount: Int,
        hasGitKeep: Bool,
        audioFiles: [String] = []
    ) {
        self.id = id
        self.folderName = folderName
        self.displayName = displayName
        self.relativePath = relativePath
        self.trackCount = trackCount
        self.hasGitKeep = hasGitKeep
        self.audioFiles = audioFiles
    }
}

/// Overall summary of the scanned PulseDeck library.
public struct LibraryScanSummary: Sendable, Equatable {
    public let libraryURL: URL
    public let totalCrates: Int
    public let totalAudioTracks: Int
    public let hasCacheFile: Bool
    public let cacheSchemaVersion: String?
    public let cachedTrackCount: Int
    public let crates: [LibraryCrateInfo]

    public init(
        libraryURL: URL,
        totalCrates: Int,
        totalAudioTracks: Int,
        hasCacheFile: Bool,
        cacheSchemaVersion: String?,
        cachedTrackCount: Int,
        crates: [LibraryCrateInfo]
    ) {
        self.libraryURL = libraryURL
        self.totalCrates = totalCrates
        self.totalAudioTracks = totalAudioTracks
        self.hasCacheFile = hasCacheFile
        self.cacheSchemaVersion = cacheSchemaVersion
        self.cachedTrackCount = cachedTrackCount
        self.crates = crates
    }
}
