import CryptoKit
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Thread-safe service for atomic loading, serializing, and saving PulseDeck library cache.
public enum CachePersistence: Sendable {

    /// Loads and decodes the library cache from disk.
    /// Strictly validates schema invariants (schemaVersion == "1.0.0", non-empty libraryRoot).
    /// Tracks that fail duration, confidence, or cue bounds are dropped so one bad entry cannot
    /// block every edit; the original bytes are first kept in a hidden backup next to the cache.
    /// Returns nil if file is nonexistent, decoding fails, schema validation fails, or the backup
    /// cannot be written. Does not convert failures into an empty cache (empty default cache is
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
            var decoded = try decoder.decode(PulseDeckLibraryCache.self, from: data)
            let invalidPaths = decoded.tracks.compactMap { path, track in
                (try? PulseDeckLibraryCache.validate(track: track, path: path)) == nil ? path : nil
            }
            if !invalidPaths.isEmpty {
                try keepInvalidTrackBackup(of: data, besides: fileURL)
                for path in invalidPaths { decoded.tracks[path] = nil }
            }
            // Strictly validate schema invariants with parity to Python loader
            try decoded.validate()
            return decoded
        } catch {
            // Return nil on malformed JSON or schema validation failure
            return nil
        }
    }

    /// Backup of a cache whose invalid tracks were dropped on load, named by content hash so
    /// repeated loads of the same file reuse one backup and a later bad file never replaces it.
    public static func invalidTrackBackupURL(for data: Data, besides fileURL: URL) -> URL {
        let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        return fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).invalid-\(digest).bak")
    }

    private static func keepInvalidTrackBackup(of data: Data, besides fileURL: URL) throws {
        let backupURL = invalidTrackBackupURL(for: data, besides: fileURL)
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
        try data.write(to: backupURL, options: .atomic)
    }

    /// Atomically persists the library cache to disk using temporary file staging,
    /// synchronous hardware flush (F_FULLFSYNC on macOS / fsync on Linux) before atomic file replacement,
    /// and parent directory sync to ensure crash-safe durability.
    public static func saveAtomic(cache: PulseDeckLibraryCache, to targetURL: URL) throws {
        // Enforce strict schema and track bounds validation before creating temp file or touching destination
        try cache.validate()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cache)

        let fileManager = FileManager.default
        let directoryURL = targetURL.deletingLastPathComponent()

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let tempURL = directoryURL.appendingPathComponent(".cache_tmp_\(UUID().uuidString).json")

        var replaced = false
        defer {
            if !replaced {
                try? fileManager.removeItem(at: tempURL)
            }
        }

        // Write data to temporary file
        try data.write(to: tempURL)

        // Ensure data bytes are physically committed to storage before atomic replacement
        let fileDescriptor = open(tempURL.path, O_RDWR)
        guard fileDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        #if os(macOS)
        let flushResult = fcntl(fileDescriptor, F_FULLFSYNC)
        #else
        let flushResult = fsync(fileDescriptor)
        #endif
        close(fileDescriptor)

        guard flushResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        // Atomic POSIX replace
        if fileManager.fileExists(atPath: targetURL.path) {
            _ = try fileManager.replaceItemAt(targetURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: targetURL)
        }
        replaced = true

        // Synchronize directory metadata
        let dirDescriptor = open(directoryURL.path, O_RDONLY)
        if dirDescriptor >= 0 {
            let dirSyncResult = fsync(dirDescriptor)
            close(dirDescriptor)
            guard dirSyncResult == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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
