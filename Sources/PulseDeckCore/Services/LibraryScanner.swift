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
    /// Distinguishes missing/non-directory/unreadable roots from valid empty libraries.
    public func scan(libraryURL: URL) -> LibraryScanSummary {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false

        guard fileManager.fileExists(atPath: libraryURL.path, isDirectory: &isDir) else {
            return LibraryScanSummary(
                libraryURL: libraryURL,
                totalCrates: 0,
                totalAudioTracks: 0,
                hasCacheFile: false,
                cacheSchemaVersion: nil,
                cachedTrackCount: 0,
                crates: [],
                scanError: "Library root directory not found at '\(libraryURL.path)'"
            )
        }

        guard isDir.boolValue else {
            return LibraryScanSummary(
                libraryURL: libraryURL,
                totalCrates: 0,
                totalAudioTracks: 0,
                hasCacheFile: false,
                cacheSchemaVersion: nil,
                cachedTrackCount: 0,
                crates: [],
                scanError: "Library path is a regular file, not a directory: '\(libraryURL.path)'"
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

        let items: [URL]
        do {
            items = try fileManager.contentsOfDirectory(at: libraryURL, includingPropertiesForKeys: [.isDirectoryKey])
        } catch {
            return LibraryScanSummary(
                libraryURL: libraryURL,
                totalCrates: 0,
                totalAudioTracks: 0,
                hasCacheFile: hasCache,
                cacheSchemaVersion: cacheSchema,
                cachedTrackCount: cachedTracks,
                crates: [],
                scanError: "Unable to read library directory '\(libraryURL.path)': \(error.localizedDescription)"
            )
        }

        var cratesList: [LibraryCrateInfo] = []
        var totalAudioTracks = 0

        let directories = items.filter { url in
            var subDir: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &subDir) && subDir.boolValue
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        for dir in directories {
            let folderName = dir.lastPathComponent
            let gitkeepURL = dir.appendingPathComponent(".gitkeep")
            let hasGitkeep = fileManager.fileExists(atPath: gitkeepURL.path)

            do {
                let files = try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
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
                    audioFiles: audioFiles,
                    isReadable: true,
                    errorMessage: nil
                )
                cratesList.append(info)
                totalAudioTracks += audioFiles.count
            } catch {
                let unreadableInfo = LibraryCrateInfo(
                    id: folderName,
                    folderName: folderName,
                    displayName: Self.displayName(for: folderName),
                    relativePath: folderName,
                    trackCount: 0,
                    hasGitKeep: hasGitkeep,
                    audioFiles: [],
                    isReadable: false,
                    errorMessage: "Permission or I/O error: \(error.localizedDescription)"
                )
                cratesList.append(unreadableInfo)
            }
        }

        return LibraryScanSummary(
            libraryURL: libraryURL,
            totalCrates: cratesList.count,
            totalAudioTracks: totalAudioTracks,
            hasCacheFile: hasCache,
            cacheSchemaVersion: cacheSchema,
            cachedTrackCount: cachedTracks,
            crates: cratesList,
            scanError: nil
        )
    }
}
