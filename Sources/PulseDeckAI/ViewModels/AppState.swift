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
    @Published public private(set) var coordinatorErrorMessage: String?
    @Published public private(set) var loadedCache: PulseDeckLibraryCache?
    @Published public var selectedTrackPath: String?

    // Audio Output Routing State
    @Published public private(set) var availableOutputDevices: [AudioDeviceDescriptor] = []
    @Published public private(set) var masterOutputUID: String?
    @Published public private(set) var cueOutputUID: String?
    @Published public private(set) var masterDeviceDescriptor: AudioDeviceDescriptor?
    @Published public private(set) var cueDeviceDescriptor: AudioDeviceDescriptor?
    @Published public private(set) var isMasterFallback: Bool = false
    @Published public private(set) var isCueFallback: Bool = false
    @Published public private(set) var masterRoutingError: String?
    @Published public private(set) var cueRoutingError: String?
    @Published public private(set) var masterWarning: String?
    @Published public private(set) var cueWarning: String?

    // Dual-Deck Studio State
    @Published public private(set) var deckATrack: TrackCacheEntry?
    @Published public private(set) var deckBTrack: TrackCacheEntry?
    @Published public private(set) var isDeckAPlaying: Bool = false
    @Published public private(set) var isDeckBPlaying: Bool = false
    @Published public private(set) var isDeckACueActive: Bool = false
    @Published public private(set) var isDeckBCueActive: Bool = false
    @Published public var crossfaderPosition: Float = 0.5

    public let waveformEditorModel: WaveformEditorModel
    public let audioCoordinator: AudioEngineCoordinator?
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
        do {
            try coordinator.start()
        } catch {
            coordinatorErrorMessage = "Audio engine startup failed: \(error.localizedDescription)"
            statusMessage = "Audio Startup Error: \(error.localizedDescription)"
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
        connectAudioCoordinator()
        refreshOutputDevices()
        refreshLibrary()
    }

    /// Initializes library/editor state with optional injected audio coordinator.
    init(
        libraryRootURL: URL,
        waveformEditorModel: WaveformEditorModel,
        loadedCache: PulseDeckLibraryCache? = nil,
        cacheLoader: (@Sendable (URL) async -> PulseDeckLibraryCache?)? = nil,
        audioCoordinator: AudioEngineCoordinator? = nil,
        startCoordinator: Bool = true
    ) {
        self.libraryRootURL = libraryRootURL
        self.waveformEditorModel = waveformEditorModel
        self.audioCoordinator = audioCoordinator
        self.audioMetering = audioCoordinator.map { AudioMeteringService(coordinator: $0) }
        self.loadedCache = loadedCache
        self.loadedCacheRootURL = loadedCache != nil ? libraryRootURL.standardizedFileURL : nil
        self.cacheLoader = cacheLoader ?? { url in
            await Task.detached(priority: .userInitiated) {
                CachePersistence.load(from: url)
            }.value
        }
        if startCoordinator, let coordinator = self.audioCoordinator {
            do {
                try coordinator.start()
            } catch {
                self.coordinatorErrorMessage = "Audio engine startup failed: \(error.localizedDescription)"
                self.statusMessage = "Audio Startup Error: \(error.localizedDescription)"
            }
        }
        connectEditorPersistence()
        connectAudioCoordinator()
        refreshOutputDevices()
    }

    private func connectEditorPersistence() {
        waveformEditorModel.onTrackPersisted = { [weak self] _, cache, rootURL in
            guard let self, self.libraryRootURL.standardizedFileURL == rootURL.standardizedFileURL else { return }
            self.loadedCache = self.waveformEditorModel.applyingLocalEdits(to: cache, libraryRootURL: rootURL)
            self.loadedCacheRootURL = rootURL.standardizedFileURL
        }
    }

    private func connectAudioCoordinator() {
        guard let coordinator = self.audioCoordinator else { return }
        coordinator.onDevicesChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshOutputDevices()
            }
        }
        coordinator.onDeviceError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.handleDeviceError(error)
            }
        }
    }

    private func handleDeviceError(_ error: CoreAudioError) {
        self.statusMessage = "Audio Device Notice: \(error.localizedDescription)"
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

    // MARK: - Audio Output Routing

    /// Refreshes the list of available output devices and synchronizes bound states.
    public func refreshOutputDevices() {
        guard let coordinator = self.audioCoordinator else { return }
        let devices = coordinator.enumerateOutputDevices()
        self.availableOutputDevices = devices

        let masterDesc = coordinator.boundDevice(for: .master)
        let cueDesc = coordinator.boundDevice(for: .cue)

        self.masterDeviceDescriptor = masterDesc
        self.cueDeviceDescriptor = cueDesc
        self.masterOutputUID = masterDesc?.id
        self.cueOutputUID = cueDesc?.id

        self.isMasterFallback = coordinator.isFallbackActive(for: .master)
        self.isCueFallback = coordinator.isFallbackActive(for: .cue)

        if let masterDesc, masterDesc.isBluetooth {
            self.masterWarning = BluetoothConstraints.warningMessage
        } else {
            self.masterWarning = nil
        }

        if let cueDesc, cueDesc.isBluetooth {
            self.cueWarning = BluetoothConstraints.warningMessage
        } else {
            self.cueWarning = nil
        }
    }

    /// Assigns engine output to a specific CoreAudio device ID via HAL.
    public func selectOutputDevice(role: AudioEngineRole, uid: String) {
        guard let coordinator = self.audioCoordinator else { return }
        do {
            try coordinator.setOutputDevice(role: role, uid: uid)
            switch role {
            case .master:
                self.masterRoutingError = nil
            case .cue:
                self.cueRoutingError = nil
            }
            refreshOutputDevices()
        } catch {
            let errorText = "Routing failed: \(error.localizedDescription)"
            switch role {
            case .master:
                self.masterRoutingError = errorText
            case .cue:
                self.cueRoutingError = errorText
            }
        }
    }

    // MARK: - Dual-Deck Studio Controls

    /// Loads the currently selected library track into the designated deck.
    public func loadSelectedTrackIntoDeck(deck: DeckIdentifier) {
        guard let selectedPath = selectedTrackPath,
              let track = loadedCache?.tracks[selectedPath] else {
            return
        }
        let trackURL = libraryRootURL.appendingPathComponent(selectedPath)
        guard let coordinator = self.audioCoordinator else {
            switch deck {
            case .deckA:
                self.deckATrack = track
                self.isDeckAPlaying = false
            case .deckB:
                self.deckBTrack = track
                self.isDeckBPlaying = false
            }
            return
        }

        do {
            switch deck {
            case .deckA:
                try coordinator.deckA.loadTrack(url: trackURL)
                self.deckATrack = track
                self.isDeckAPlaying = false
            case .deckB:
                try coordinator.deckB.loadTrack(url: trackURL)
                self.deckBTrack = track
                self.isDeckBPlaying = false
            }
            self.statusMessage = "Loaded \(track.relativePath) into \(deck.rawValue)"
        } catch {
            self.statusMessage = "Failed to load \(track.relativePath) into \(deck.rawValue): \(error.localizedDescription)"
        }
    }

    /// Toggles play / pause state for the specified deck.
    public func toggleDeckPlay(deck: DeckIdentifier) {
        guard let coordinator = self.audioCoordinator else {
            switch deck {
            case .deckA:
                isDeckAPlaying.toggle()
            case .deckB:
                isDeckBPlaying.toggle()
            }
            return
        }

        // Start coordinator on-demand if stopped; do not publish true against stopped engine
        if !coordinator.masterAudioEngine.isRunning {
            do {
                try coordinator.start()
            } catch {
                self.coordinatorErrorMessage = "Failed to start audio engine: \(error.localizedDescription)"
                self.statusMessage = "Audio Start Error: \(error.localizedDescription)"
                return
            }
        }

        guard coordinator.masterAudioEngine.isRunning else {
            self.statusMessage = "Audio engine is not running"
            return
        }
        if coordinator.cueAudioEngine.isRunning {
            acknowledgeAudioStartupRecovery()
        }

        switch deck {
        case .deckA:
            if isDeckAPlaying {
                coordinator.deckA.pause()
                isDeckAPlaying = false
            } else {
                coordinator.deckA.play()
                isDeckAPlaying = true
            }
        case .deckB:
            if isDeckBPlaying {
                coordinator.deckB.pause()
                isDeckBPlaying = false
            } else {
                coordinator.deckB.play()
                isDeckBPlaying = true
            }
        }
    }

    /// Sets the pre-fader listen (PFL) cue routing for the specified deck.
    public func setDeckCueActive(deck: DeckIdentifier, active: Bool) {
        guard let coordinator = self.audioCoordinator else {
            switch deck {
            case .deckA:
                isDeckACueActive = active
            case .deckB:
                isDeckBCueActive = active
            }
            return
        }
        var cueActive = active
        if active {
            do {
                // Keep the startup decision on the AV control queue. A cue-only failure must
                // never enter coordinator.start()'s rollback path while master is live.
                cueActive = try coordinator.monitor.performOnControlQueue {
                    if !coordinator.cueAudioEngine.isRunning {
                        if coordinator.masterAudioEngine.isRunning {
                            try coordinator.cueAudioEngine.start()
                        } else {
                            try coordinator.start()
                        }
                    }
                    return coordinator.cueAudioEngine.isRunning
                }
                if cueActive {
                    if coordinator.masterAudioEngine.isRunning {
                        acknowledgeAudioStartupRecovery()
                    }
                } else {
                    coordinatorErrorMessage = "Cue audio engine is not running"
                    statusMessage = "Audio Cue Start Error: Cue audio engine is not running"
                }
            } catch {
                cueActive = false
                coordinatorErrorMessage = "Failed to start cue audio engine: \(error.localizedDescription)"
                statusMessage = "Audio Cue Start Error: \(error.localizedDescription)"
            }
        }
        switch deck {
        case .deckA:
            coordinator.deckA.isCueActive = cueActive
            isDeckACueActive = cueActive
        case .deckB:
            coordinator.deckB.isCueActive = cueActive
            isDeckBCueActive = cueActive
        }
    }

    private func acknowledgeAudioStartupRecovery() {
        coordinatorErrorMessage = nil
        if statusMessage.hasPrefix("Audio Startup Error:") ||
            statusMessage.hasPrefix("Audio Start Error:") ||
            statusMessage.hasPrefix("Audio Cue Start Error:") {
            statusMessage = "Audio engines running"
        }
    }

    /// Adjusts the crossfader position from 0.0 (full Deck A) to 1.0 (full Deck B).
    public func updateCrossfader(position: Float) {
        let clamped = position.isFinite ? min(max(position, 0.0), 1.0) : 0.5
        self.crossfaderPosition = clamped
        self.audioCoordinator?.setCrossfader(position: clamped)
    }
}
