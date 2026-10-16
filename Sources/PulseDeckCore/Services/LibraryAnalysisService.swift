import Foundation

public enum LibraryAnalysisServiceError: Error, LocalizedError, Equatable {
    case invalidExistingCache

    public var errorDescription: String? { "Existing library cache failed schema validation" }
}

/// Serializes local analysis and cache read/merge/write operations for one library.
public actor LibraryAnalysisService {
    private let libraryRoot: URL
    private let analyzer: LocalTrackAnalyzer
    private let cacheURL: URL

    public init(libraryRoot: URL, analyzer: LocalTrackAnalyzer = LocalTrackAnalyzer()) {
        self.libraryRoot = libraryRoot
        self.analyzer = analyzer
        self.cacheURL = libraryRoot.appendingPathComponent(PulseDeckCoreConfig.cacheFileName)
    }

    public func analyzeTrack(at url: URL) async throws -> TrackCacheEntry {
        let root = libraryRoot
        let analyzer = self.analyzer
        let entry = try await Task.detached(priority: .utility) {
            try analyzer.analyze(url: url, libraryRoot: root)
        }.value
        var cache: PulseDeckLibraryCache
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            guard let existing = CachePersistence.load(from: cacheURL) else {
                throw LibraryAnalysisServiceError.invalidExistingCache
            }
            cache = existing
        } else {
            cache = PulseDeckLibraryCache(libraryRoot: libraryRoot.lastPathComponent)
        }
        CachePersistence.upsertTrack(entry, in: &cache)
        cache.generatedAt = ISO8601DateFormatter().string(from: Date())
        try CachePersistence.saveAtomic(cache: cache, to: cacheURL)
        return cache.tracks[entry.relativePath] ?? entry
    }
}
