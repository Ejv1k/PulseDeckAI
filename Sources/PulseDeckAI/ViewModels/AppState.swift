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
    private let audioCoordinator: AudioEngineCoordinator
    private let audioMetering: AudioMeteringService

    private let scanner = LibraryScanner()
    private var scanGeneration: UInt64 = 0

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
        self.waveformEditorModel = WaveformEditorModel(libraryRootURL: defaultURL)
        refreshLibrary()
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

        // Perform scanner on background thread, deliver result to MainActor
        Task.detached(priority: .userInitiated) { [scanner] in
            let summary = scanner.scan(libraryURL: url)
            let cacheURL = url.appendingPathComponent(PulseDeckCoreConfig.cacheFileName)
            let cache = CachePersistence.load(from: cacheURL)

            await MainActor.run {
                // Ignore result if another scan generation was initiated
                guard self.scanGeneration == thisGeneration else {
                    return
                }

                self.scanSummary = summary
                self.loadedCache = cache
                self.waveformEditorModel.updateLibraryRoot(url)

                if self.waveformEditorModel.currentTrack == nil,
                   let firstTrack = cache?.tracks.values.sorted(by: { $0.relativePath < $1.relativePath }).first {
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

    /// Selects a track by relative path and loads it into the waveform editor if cached.
    public func selectTrack(relativePath: String) {
        self.selectedTrackPath = relativePath
        if let track = loadedCache?.tracks[relativePath] {
            self.waveformEditorModel.loadTrack(track)
            self.statusMessage = "Loaded \(track.relativePath) into Waveform Editor"
        } else {
            self.statusMessage = "Track '\(relativePath)' not yet analyzed in cache"
        }
    }

    /// Reads the newest output meter on the control queue; callers stay on MainActor.
    public func meterSnapshot(for role: AudioEngineRole) -> AudioMeterSnapshot? {
        audioMetering.drainLatest(for: role)
    }
}
