import Foundation

/// Service for inspecting and scanning the PulseDeck library filesystem structure.
public struct LibraryScanner: Sendable {
    public static let supportedAudioExtensions: Set<String> = [
        "mp3", "wav", "flac", "m4a", "mp4", "aif", "aiff", "aac", "ogg"
    ]

    public init() {}

    /// Formats a raw crate directory name into a clean DJ display label.
    public static func displayName(for crateFolderName: String) -> String {
        let parts = crateFolderName.split(separator: "_", maxSplits: 1)
        if parts.count == 2, let number = Int(parts[0]) {
            let title = parts[1].replacingOccurrences(of: "_", with: " ")
            return String(format: "[%02d] %@", number, title)
        }
        return crateFolderName.replacingOccurrences(of: "_", with: " ")
    }

    /// Scans a library root folder URL and constructs a comprehensive summary.
    public func scan(libraryURL: URL) -> LibraryScanSummary {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: libraryURL.path) else {
            return LibraryScanSummary(
                libraryURL: libraryURL,
                totalCrates: 0,
                totalAudioTracks: 0,
                hasCacheFile: false,
                cacheSchemaVersion: nil,
                cachedTrackCount: 0,
                crates: []
            )
        }

        let cacheURL = libraryURL.appendingPathComponent(PulseDeckCoreConfig.cacheFileName)
        let hasCache = fileManager.fileExists(atPath: cacheURL.path)
        var cacheSchema: String? = nil
        var cachedTracks = 0

        if hasCache, let cache = CachePersistence.load(from: cacheURL) {
            cacheSchema = cache.schemaVersion
            cachedTracks = cache.tracks.count
        }

        var cratesList: [LibraryCrateInfo] = []
        var totalAudioTracks = 0

        // Determine all subdirectories in libraryURL
        let items = (try? fileManager.contentsOfDirectory(at: libraryURL, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        let directories = items.filter { url in
            var isDir: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        for dir in directories {
            let folderName = dir.lastPathComponent
            let gitkeepURL = dir.appendingPathComponent(".gitkeep")
            let hasGitkeep = fileManager.fileExists(atPath: gitkeepURL.path)

            let files = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let audioFiles = files.filter { file in
                let ext = file.pathExtension.lowercased()
                return Self.supportedAudioExtensions.contains(ext)
            }.map { $0.lastPathComponent }.sorted()

            let info = LibraryCrateInfo(
                id: folderName,
                folderName: folderName,
                displayName: Self.displayName(for: folderName),
                relativePath: folderName,
                trackCount: audioFiles.count,
                hasGitKeep: hasGitkeep,
                audioFiles: audioFiles
            )
            cratesList.append(info)
            totalAudioTracks += audioFiles.count
        }

        return LibraryScanSummary(
            libraryURL: libraryURL,
            totalCrates: cratesList.count,
            totalAudioTracks: totalAudioTracks,
            hasCacheFile: hasCache,
            cacheSchemaVersion: cacheSchema,
            cachedTrackCount: cachedTracks,
            crates: cratesList
        )
    }
}
