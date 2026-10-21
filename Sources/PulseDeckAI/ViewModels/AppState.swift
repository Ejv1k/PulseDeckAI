import Foundation
import Combine
import PulseDeckCore

@MainActor
public final class AppState: ObservableObject {
    @Published public var appVersion: String = PulseDeckCoreConfig.version
    @Published public var libraryRootURL: URL
    @Published public var scanSummary: LibraryScanSummary?
    @Published public var selectedCrate: LibraryCrateInfo?
    @Published public var isScanning: Bool = false
    @Published public var statusMessage: String = "Phase 0 Operational Shell Initialized"
    @Published public private(set) var meteringErrorMessage: String?
    @Published public private(set) var loadedCache: PulseDeckLibraryCache?
    @Published public var selectedTrackPath: String?
    public let waveformEditorModel: WaveformEditorModel
    private let audioCoordinator: AudioEngineCoordinator?
    private let audioMetering: AudioMeteringService?

    private let scanner = LibraryScanner()
    private var scanGeneration: UInt64 = 0
    private var selectionGeneration: UInt64 = 0
    private var loadedCacheRootURL: URL?
    private let cacheLoader: @Sendable (URL) async -> PulseDeckLibraryCache?

    public init() {
        let coordinator = AudioEngineCoordinator()
        self.audioCoordinator = coordinator
        let metering = AudioMeteringService(coordinator: coordinator)
        self.audioMetering = metering
        do {
            try metering.start()
        } catch {
            meteringErrorMessage = "Audio meters unavailable: \(error)"
        }

        // Resolve library folder relative to current working directory or bundle
        let cwd = FileManager.default.currentDirectoryPath
        let defaultURL = URL(fileURLWithPath: cwd).appendingPathComponent(PulseDeckCoreConfig.defaultLibraryFolderName)
        self.libraryRootURL = defaultURL
        let editor = WaveformEditorModel(libraryRootURL: defaultURL)
        self.waveformEditorModel = editor
        self.cacheLoader = { url in
            await Task.detached(priority: .userInitiated) {
                CachePersistence.load(from: url)
            }.value
        }
        connectEditorPersistence()
        refreshLibrary()
    }

    /// Initializes library/editor state without starting audio hardware; the production selection and save paths are shared.
    init(
        libraryRootURL: URL,
        waveformEditorModel: WaveformEditorModel,
        loadedCache: PulseDeckLibraryCache? = nil,
        cacheLoader: (@Sendable (URL) async -> PulseDeckLibraryCache?)? = nil
    ) {
        self.libraryRootURL = libraryRootURL
        self.waveformEditorModel = waveformEditorModel
        self.audioCoordinator = nil
        self.audioMetering = nil
        self.loadedCache = loadedCache
        self.loadedCacheRootURL = loadedCache != nil ? libraryRootURL.standardizedFileURL : nil
        self.cacheLoader = cacheLoader ?? { url in
            await Task.detached(priority: .userInitiated) {
                CachePersistence.load(from: url)
            }.value
        }
        connectEditorPersistence()
    }

    private func connectEditorPersistence() {
        waveformEditorModel.onTrackPersisted = { [weak self] _, cache, rootURL in
            guard let self, self.libraryRootURL.standardizedFileURL == rootURL.standardizedFileURL else { return }
            self.loadedCache = self.waveformEditorModel.applyingLocalEdits(to: cache, libraryRootURL: rootURL)
            self.loadedCacheRootURL = rootURL.standardizedFileURL
        }
    }

    /// Scans the library root and updates published state on MainActor.
    /// Strictly limits scanning to one in-flight operation and protects against stale results
    /// from out-of-order background task completion.
    public func refreshLibrary() {
        guard !self.isScanning else {
            // Drop concurrent rescan requests while a scan is actively running
            return
        }

        self.isScanning = true
        self.scanGeneration &+= 1
        let thisGeneration = self.scanGeneration
        let url = self.libraryRootURL
        let expectedCacheGeneration = waveformEditorModel.cachePublicationGeneration(for: url)

        // Perform scanner on background thread, deliver result to MainActor
        Task.detached(priority: .userInitiated) { [scanner, cacheLoader] in
            let summary = scanner.scan(libraryURL: url)
            let cacheURL = url.appendingPathComponent(PulseDeckCoreConfig.cacheFileName)
            let cache = await cacheLoader(cacheURL)

            await MainActor.run {
                // Ignore result if another scan generation was initiated
                guard self.scanGeneration == thisGeneration else {
                    return
                }
                guard self.libraryRootURL.standardizedFileURL == url.standardizedFileURL else {
                    self.isScanning = false
                    return
                }

                self.scanSummary = summary
                // A completed save can publish newer cache data while this refresh read is in flight.
                // Discard only the stale cache snapshot; filesystem scan results still complete normally.
                if self.waveformEditorModel.cachePublicationGeneration(for: url) == expectedCacheGeneration {
                    self.loadedCache = cache.map { self.waveformEditorModel.applyingLocalEdits(to: $0, libraryRootURL: url) }
                    self.loadedCacheRootURL = url.standardizedFileURL
                }
                self.waveformEditorModel.updateLibraryRoot(url)

                if self.selectedTrackPath == nil, self.waveformEditorModel.currentTrack == nil,
                   let firstTrack = self.loadedCache?.tracks.values.sorted(by: { $0.relativePath < $1.relativePath }).first {
                    self.waveformEditorModel.loadTrack(firstTrack)
                    self.selectedTrackPath = firstTrack.relativePath
                }

                if let currentId = self.selectedCrate?.id,
                   let updatedCrate = summary.crates.first(where: { $0.id == currentId }) {
                    self.selectedCrate = updatedCrate
                } else {
                    self.selectedCrate = summary.crates.first
                }

                self.isScanning = false

                if let error = summary.scanError {
                    self.statusMessage = "Library Error: \(error)"
                } else {
                    self.statusMessage = "Library Verified: \(summary.totalCrates) Crates, \(summary.totalAudioTracks) Tracks"
                }
            }
        }
    }

    /// Selects a crate for viewing.
    public func selectCrate(_ crate: LibraryCrateInfo) {
        self.selectedCrate = crate
    }

    /// Selects a track by relative path and loads it into the waveform editor.
    /// Preserves any pending edits and ensures the latest cached state is loaded,
    /// reloading from disk if the shared in-memory cache is out of date.
    @discardableResult
    public func selectTrack(relativePath: String) -> Task<Void, Never> {
        let rootURL = libraryRootURL
        let standardizedRoot = rootURL.standardizedFileURL
        let isSameTrackAlreadySelected = (selectedTrackPath == relativePath &&
            waveformEditorModel.libraryRootURL.standardizedFileURL == standardizedRoot &&
            waveformEditorModel.currentTrack?.relativePath == relativePath)

        waveformEditorModel.updateLibraryRoot(rootURL)

        if !isSameTrackAlreadySelected {
            waveformEditorModel.finishActiveDrag()
            self.selectedTrackPath = relativePath
            let knownCache = loadedCacheRootURL == standardizedRoot ? loadedCache : nil
            if let track = waveformEditorModel.entryForSelection(relativePath: relativePath, cache: knownCache, libraryRootURL: rootURL) {
                waveformEditorModel.loadTrack(track)
            } else {
                waveformEditorModel.clearTrack()
            }
        }

        selectionGeneration &+= 1
        let generation = selectionGeneration
        let selectionRevision = waveformEditorModel.interactionRevision
        let expectedCacheGeneration = waveformEditorModel.cachePublicationGeneration(for: rootURL)

        // Reload latest cache from disk to ensure freshest state if disk was updated
        return Task { [weak self] in
            let cacheURL = rootURL.appendingPathComponent(PulseDeckCoreConfig.cacheFileName)
            let freshCache = await self?.cacheLoader(cacheURL)
            guard let self, self.selectionGeneration == generation,
                  self.libraryRootURL.standardizedFileURL == standardizedRoot,
                  self.selectedTrackPath == relativePath else { return }
            guard self.waveformEditorModel.cachePublicationGeneration(for: rootURL) == expectedCacheGeneration else {
                return
            }
            if let freshCache {
                self.loadedCache = self.waveformEditorModel.applyingLocalEdits(to: freshCache, libraryRootURL: rootURL)
                self.loadedCacheRootURL = standardizedRoot
            }
            let currentCache = self.loadedCacheRootURL == standardizedRoot ? self.loadedCache : nil
            if let track = self.waveformEditorModel.entryForSelection(relativePath: relativePath, cache: currentCache, libraryRootURL: rootURL) {
                let isDirtyOrInteracting = self.waveformEditorModel.hasActiveInteraction(
                    since: selectionRevision,
                    relativePath: relativePath,
                    libraryRootURL: rootURL
                )
                if !isDirtyOrInteracting {
                    let isSameTrack = (self.waveformEditorModel.libraryRootURL.standardizedFileURL == standardizedRoot &&
                                       self.waveformEditorModel.currentTrack?.relativePath == relativePath)
                    if isSameTrack {
                        self.waveformEditorModel.updateLoadedTrack(track)
                    } else {
                        self.waveformEditorModel.loadTrack(track)
                    }
                }
                self.statusMessage = "Loaded \(track.relativePath) into Waveform Editor"
            } else {
                self.statusMessage = "Track '\(relativePath)' not yet analyzed in cache"
            }
        }
    }

    /// Reads the newest output meter on the control queue; callers stay on MainActor.
    public func meterSnapshot(for role: AudioEngineRole) -> AudioMeterSnapshot? {
        audioMetering?.drainLatest(for: role)
    }
}
