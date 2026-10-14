import Foundation

/// Thread-safe service for atomic loading, serializing, and saving PulseDeck library cache.
public enum CachePersistence: Sendable {

    /// Loads and decodes the library cache from disk.
    public static func load(from fileURL: URL) -> PulseDeckLibraryCache? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: fileURL)
            // If the file is 0 bytes or empty, return a fresh empty cache
            if data.isEmpty {
                return PulseDeckLibraryCache()
            }
            let decoder = JSONDecoder()
            return try decoder.decode(PulseDeckLibraryCache.self, from: data)
        } catch {
            // If decode fails, return nil or handle gracefully
            return nil
        }
    }

    /// Atomically persists the library cache to disk using temporary file write + atomic rename.
    /// Guarantees that partial writes or sudden power loss never corrupt the cache.
    public static func saveAtomic(cache: PulseDeckLibraryCache, to targetURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cache)

        let fileManager = FileManager.default
        let directoryURL = targetURL.deletingLastPathComponent()

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let tempURL = directoryURL.appendingPathComponent(".cache_tmp_\(UUID().uuidString).json")

        // Write data to temporary file
        try data.write(to: tempURL, options: .atomic)

        // Atomic replace
        if fileManager.fileExists(atPath: targetURL.path) {
            _ = try fileManager.replaceItemAt(targetURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: targetURL)
        }
    }

    /// Updates or inserts a track entry into the cache while strictly preserving manual overrides.
    public static func upsertTrack(
        _ newEntry: TrackCacheEntry,
        in cache: inout PulseDeckLibraryCache
    ) {
        if let existing = cache.tracks[newEntry.relativePath] {
            cache.tracks[newEntry.relativePath] = existing.mergingPreservingOverrides(with: newEntry)
        } else {
            cache.tracks[newEntry.relativePath] = newEntry
        }
    }
}
