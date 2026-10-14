import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Thread-safe service for atomic loading, serializing, and saving PulseDeck library cache.
public enum CachePersistence: Sendable {

    /// Loads and decodes the library cache from disk.
    /// Strictly validates schema invariants (schemaVersion == "1.0.0", non-empty libraryRoot,
    /// finite non-negative duration, confidence in 0...1, and valid cue bounds).
    /// Returns nil if file is nonexistent, decoding fails, or schema validation fails.
    /// Does not convert schema validation failures into an empty cache (empty default cache is
    /// returned solely for a 0-byte file).
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
            let decoded = try decoder.decode(PulseDeckLibraryCache.self, from: data)
            // Strictly validate schema invariants with parity to Python loader
            try decoded.validate()
            return decoded
        } catch {
            // Return nil on malformed JSON or schema validation failure
            return nil
        }
    }

    /// Atomically persists the library cache to disk using temporary file staging,
    /// synchronous hardware flush (F_FULLFSYNC on macOS / fsync on Linux) before atomic file replacement,
    /// and parent directory sync to ensure crash-safe durability.
    public static func saveAtomic(cache: PulseDeckLibraryCache, to targetURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cache)

        let fileManager = FileManager.default
        let directoryURL = targetURL.deletingLastPathComponent()

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let tempURL = directoryURL.appendingPathComponent(".cache_tmp_\(UUID().uuidString).json")

        // Write data to temporary file
        try data.write(to: tempURL)

        // Ensure data bytes are physically committed to storage before atomic replacement
        let fileDescriptor = open(tempURL.path, O_RDWR)
        if fileDescriptor >= 0 {
            #if os(macOS)
            _ = fcntl(fileDescriptor, F_FULLFSYNC)
            #else
            _ = fsync(fileDescriptor)
            #endif
            close(fileDescriptor)
        }

        // Atomic POSIX replace
        if fileManager.fileExists(atPath: targetURL.path) {
            _ = try fileManager.replaceItemAt(targetURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: targetURL)
        }

        // Synchronize directory metadata
        let dirDescriptor = open(directoryURL.path, O_RDONLY)
        if dirDescriptor >= 0 {
            _ = fsync(dirDescriptor)
            close(dirDescriptor)
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
