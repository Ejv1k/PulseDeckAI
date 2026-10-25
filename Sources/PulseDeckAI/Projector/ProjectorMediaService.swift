import Foundation
import AppKit
import AVFoundation
import ImageIO

private final class MediaNotificationToken: @unchecked Sendable {
    var observer: (any NSObjectProtocol)?
    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

/// Service managing discovery, bounded downsampled caching, and muted playback of media
/// from `09_Visual_Backgrounds_Media`.
///
/// Guaranteed invariants:
/// - Strictly read-only operations on user directories.
/// - Supported formats: JPG, PNG, HEIC, WEBP, TIFF for photos; MP4, MOV, M4V for videos.
/// - Downsamples high-resolution photos off the main thread with finite RAM cache limits.
/// - Video AVPlayers are strictly muted (`isMuted = true`, `volume = 0.0`), preventing any audio interference.
/// - Cancels in-flight decoding and rejects stale completions across root switches or teardown.
@MainActor
public final class ProjectorMediaService: ObservableObject {
    public nonisolated static let mediaFolderName = "09_Visual_Backgrounds_Media"
    public nonisolated static let maxDiscoveredItems = 100
    public nonisolated static let maxCacheRAMBytes = 48 * 1024 * 1024 // 48 MB
    public nonisolated static let maxCachedPhotos = 20
    public nonisolated static let photoMaxPixelDimension: CGFloat = 1920

    public nonisolated static let supportedPhotoExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "webp", "tiff"
    ]
    public nonisolated static let supportedVideoExtensions: Set<String> = [
        "mp4", "mov", "m4v"
    ]

    @Published public private(set) var mediaState: ProjectorMediaState = .empty
    @Published public private(set) var items: [ProjectorMediaItem] = []
    @Published public private(set) var currentIndex: Int = 0
    @Published public private(set) var currentPhoto: NSImage?
    @Published public private(set) var currentVideoPlayer: AVPlayer?
    @Published public private(set) var isScanning: Bool = false

    private var libraryRootURL: URL?
    private var scanGeneration: UInt64 = 0
    private var photoCache: [URL: (image: NSImage, bytes: Int)] = [:]
    private var photoCacheTotalBytes: Int = 0
    private var playerDidPlayToEndToken: MediaNotificationToken?
    private var activeScanTask: Task<Void, Never>?

    public init() {}

    /// Sets the library root and scans `09_Visual_Backgrounds_Media`.
    public func setLibraryRoot(_ url: URL) {
        if libraryRootURL?.standardizedFileURL != url.standardizedFileURL {
            self.libraryRootURL = url
            rescan()
        }
    }

    /// Rescans the visual media directory, rejecting stale work from previous scans.
    public func rescan() {
        scanGeneration &+= 1
        let currentGen = scanGeneration

        activeScanTask?.cancel()
        cleanupPlayer()
        currentPhoto = nil
        mediaState = .loading
        isScanning = true

        guard let rootURL = libraryRootURL else {
            mediaState = .empty
            items = []
            isScanning = false
            return
        }

        let mediaDirectoryURL: URL
        if rootURL.lastPathComponent == Self.mediaFolderName {
            mediaDirectoryURL = rootURL
        } else {
            mediaDirectoryURL = rootURL.appendingPathComponent(Self.mediaFolderName)
        }

        activeScanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let discovered = Self.discoverMediaItems(in: mediaDirectoryURL)

            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self, self.scanGeneration == currentGen else { return }
                self.isScanning = false
                self.items = discovered

                if discovered.isEmpty {
                    self.mediaState = .empty
                    self.currentIndex = 0
                    self.currentPhoto = nil
                    self.cleanupPlayer()
                } else {
                    self.mediaState = .ready(items: discovered)
                    self.currentIndex = 0
                    self.loadMedia(at: 0)
                }
            }
        }
    }

    /// Discovers media items in the target directory safely on background threads.
    public nonisolated static func discoverMediaItems(in directoryURL: URL) -> [ProjectorMediaItem] {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false

        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [ProjectorMediaItem] = []

        // Deterministic alphabetical sort by filename
        let sortedURLs = contents.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        for fileURL in sortedURLs {
            if results.count >= maxDiscoveredItems {
                break
            }

            let fileName = fileURL.lastPathComponent
            if fileName.hasPrefix(".") || fileName == ".gitkeep" {
                continue
            }

            let ext = fileURL.pathExtension.lowercased()
            let type: ProjectorMediaType
            if supportedPhotoExtensions.contains(ext) {
                type = .photo
            } else if supportedVideoExtensions.contains(ext) {
                type = .video
            } else {
                continue
            }

            let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

            results.append(ProjectorMediaItem(
                id: fileURL.path,
                fileName: fileName,
                fileURL: fileURL,
                type: type,
                fileSizeBytes: Int64(fileSize)
            ))
        }

        return results
    }

    /// Loads and activates the media item at the specified index.
    public func loadMedia(at index: Int) {
        guard !items.isEmpty, index >= 0, index < items.count else {
            cleanupPlayer()
            currentPhoto = nil
            return
        }

        self.currentIndex = index
        let item = items[index]
        scanGeneration &+= 1
        let currentGen = scanGeneration

        switch item.type {
        case .photo:
            cleanupPlayer()
            loadPhoto(item: item, generation: currentGen)

        case .video:
            currentPhoto = nil
            loadMutedVideo(item: item)
        }
    }

    /// Advances to the next media item.
    public func nextMediaItem() {
        guard !items.isEmpty else { return }
        let nextIndex = (currentIndex + 1) % items.count
        loadMedia(at: nextIndex)
    }

    /// Moves to the previous media item.
    public func previousMediaItem() {
        guard !items.isEmpty else { return }
        let prevIndex = (currentIndex - 1 + items.count) % items.count
        loadMedia(at: prevIndex)
    }

    /// Stops playback, cancels tasks, and releases player and cached image memory.
    public func teardown() {
        scanGeneration &+= 1
        activeScanTask?.cancel()
        activeScanTask = nil
        cleanupPlayer()
        currentPhoto = nil
        photoCache.removeAll()
        photoCacheTotalBytes = 0
        mediaState = .empty
    }

    // MARK: - Private Photo Loader

    private func loadPhoto(item: ProjectorMediaItem, generation: UInt64) {
        if let cached = photoCache[item.fileURL] {
            self.currentPhoto = cached.image
            return
        }

        let maxDim = Self.photoMaxPixelDimension
        Task.detached(priority: .userInitiated) { [weak self] in
            let downsampled = Self.downsampleImage(at: item.fileURL, maxDimension: maxDim)

            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self, self.scanGeneration == generation else { return }
                guard let image = downsampled else {
                    self.currentPhoto = nil
                    return
                }

                // Estimate memory footprint
                let approxBytes = Int(image.size.width * image.size.height * 4)
                self.evictPhotoCacheIfNeeded(incomingBytes: approxBytes)
                self.photoCache[item.fileURL] = (image, approxBytes)
                self.photoCacheTotalBytes += approxBytes

                self.currentPhoto = image
            }
        }
    }

    /// Downsamples high-resolution photos using CoreGraphics image source thumbnail creation.
    public nonisolated static func downsampleImage(at fileURL: URL, maxDimension: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, options as CFDictionary) else {
            return nil
        }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else {
            return nil
        }

        let size = NSSize(width: cgImage.width, height: cgImage.height)
        return NSImage(cgImage: cgImage, size: size)
    }

    private func evictPhotoCacheIfNeeded(incomingBytes: Int) {
        while (photoCacheTotalBytes + incomingBytes > Self.maxCacheRAMBytes || photoCache.count >= Self.maxCachedPhotos),
              let firstKey = photoCache.keys.first {
            if let entry = photoCache.removeValue(forKey: firstKey) {
                photoCacheTotalBytes -= entry.bytes
            }
        }
    }

    // MARK: - Private Video Loader & Looper

    private func loadMutedVideo(item: ProjectorMediaItem) {
        cleanupPlayer()

        let playerItem = AVPlayerItem(url: item.fileURL)
        let player = AVPlayer(playerItem: playerItem)

        // STRICT INVARIANT: Video player must be completely muted so it NEVER affects Master or Cue.
        player.isMuted = true
        player.volume = 0.0

        // Install seamless looping observer
        let token = MediaNotificationToken()
        token.observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
        self.playerDidPlayToEndToken = token

        self.currentVideoPlayer = player
        player.play()
    }

    private func cleanupPlayer() {
        playerDidPlayToEndToken = nil
        currentVideoPlayer?.pause()
        currentVideoPlayer = nil
    }
}
