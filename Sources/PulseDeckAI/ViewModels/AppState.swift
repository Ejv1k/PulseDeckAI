import Foundation
import Combine
import AVFoundation
import PulseDeckCore

public enum TransitionMacroStyle: String, CaseIterable, Hashable, Identifiable, Sendable {
    case beatSyncedBassSwap = "BASS SWAP"
    case filterEchoWash = "FILTER ECHO"
    case hardCutOnDrop = "HARD CUT"

    public var id: String { rawValue }
}

@MainActor
public final class AppState: ObservableObject {
    @Published public var appVersion: String = PulseDeckCoreConfig.version
    @Published public var libraryRootURL: URL {
        didSet {
            if oldValue.standardizedFileURL != libraryRootURL.standardizedFileURL {
                stopPreview()
                previewTrackPath = nil
                previewDurationSeconds = 0.0
                previewErrorMessage = nil
                previewHasUsableBeatGrid = false
                previewIsReady = false
                preloadSoundboard()
            }
        }
    }
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
    @Published public var transitionMacroStyle: TransitionMacroStyle = .beatSyncedBassSwap
    @Published public var transitionPhraseBars: Int = 16
    @Published public private(set) var transitionProgress: Double = 0.0
    @Published public private(set) var activeTransitionState: TransitionExecutionState = .idle
    @Published public private(set) var isAutoPilotArmed: Bool = false
    @Published public private(set) var transitionErrorMessage: String?

    // Master-only Talkover State
    @Published public private(set) var isTalkoverActive: Bool = false
    @Published public private(set) var talkoverProgress: Double = 0.0

    // Master-only Soundboard State (F1–F8)
    @Published public private(set) var soundboardPads: [SoundboardPadSnapshot] = []
    @Published public private(set) var soundboardTotalRAMBytes: Int = 0
    @Published public private(set) var soundboardErrorMessage: String?

    // Library Audition & Compatibility State
    @Published public private(set) var previewTrackPath: String?
    @Published public private(set) var isPreviewPlaying: Bool = false
    @Published public private(set) var previewPositionSeconds: Double = 0.0
    @Published public private(set) var previewDurationSeconds: Double = 0.0
    @Published public private(set) var previewErrorMessage: String?
    @Published public private(set) var previewHasUsableBeatGrid: Bool = false
    @Published public var compatibilityReferenceDeck: DeckIdentifier = .deckA

    public let waveformEditorModel: WaveformEditorModel
    public let audioCoordinator: AudioEngineCoordinator?
    private let audioMetering: AudioMeteringService?

    private let scanner = LibraryScanner()
    private var scanGeneration: UInt64 = 0
    private var selectionGeneration: UInt64 = 0
    private var previewGeneration: UInt64 = 0
    private var previewLoadIsPending = false
    private var previewPlayRequested = false
    private var previewIsReady = false
    private var previewPollingTask: Task<Void, Never>?
    private var transitionObservationTask: Task<Void, Never>?
    private let beforePreviewFilePreparation: (@Sendable (URL) async -> Void)?
    private var loadedCacheRootURL: URL?
    private let cacheLoader: @Sendable (URL) async -> PulseDeckLibraryCache?

    public var isTransitionBusy: Bool {
        switch activeTransitionState {
        case .armed, .inProgress:
            return true
        case .idle, .completed, .cancelled:
            return false
        }
    }

    public var transitionIsReady: Bool {
        transitionReadinessMessage == nil
    }

    public var transitionReadinessMessage: String? {
        readinessMessage(autoPilot: false)
    }

    public var autoPilotReadinessMessage: String? {
        readinessMessage(autoPilot: true)
    }

    private func readinessMessage(autoPilot: Bool) -> String? {
        guard let coordinator = audioCoordinator else { return "Audio coordinator unavailable" }
        guard coordinator.masterAudioEngine.isRunning else { return "Master output is stopped" }
        guard let trackA = trackEntry(for: .deckA), let trackB = trackEntry(for: .deckB) else {
            return "Load a track on both decks"
        }
        guard let pathA = coordinator.deckAGraph.loadedTrackURL,
              pathA.standardizedFileURL == libraryRootURL.appendingPathComponent(trackA.relativePath).standardizedFileURL else {
            return "Deck A audio does not match its loaded track"
        }
        guard let pathB = coordinator.deckBGraph.loadedTrackURL,
              pathB.standardizedFileURL == libraryRootURL.appendingPathComponent(trackB.relativePath).standardizedFileURL else {
            return "Deck B audio does not match its loaded track"
        }

        let aPlaying = coordinator.deckAGraph.isMasterPlaying
        let bPlaying = coordinator.deckBGraph.isMasterPlaying
        guard aPlaying != bPlaying else { return "Play exactly one outgoing deck" }
        let outgoingWeight = aPlaying ? coordinator.deckAGraph.crossfaderWeight : coordinator.deckBGraph.crossfaderWeight
        guard outgoingWeight > 1e-3 else { return "Move the crossfader toward the playing deck" }
        let planner = TransitionPlanner()
        let outgoingDescriptor = TrackTransitionDescriptor(deck: aPlaying ? .deckA : .deckB, cacheEntry: aPlaying ? trackA : trackB)
        let incomingDescriptor = TrackTransitionDescriptor(deck: aPlaying ? .deckB : .deckA, cacheEntry: aPlaying ? trackB : trackA)
        switch transitionMacroStyle {
        case .beatSyncedBassSwap where !planner.isUsableBeatGrid(descriptor: outgoingDescriptor):
            return "Bass Swap needs a measured beat grid on the outgoing deck"
        case .beatSyncedBassSwap where !planner.isUsableBeatGrid(descriptor: incomingDescriptor):
            return "Bass Swap needs a measured beat grid on the incoming deck"
        case .hardCutOnDrop where !planner.isUsableBeatGrid(descriptor: outgoingDescriptor):
            return "Hard Cut needs a measured beat grid on the outgoing deck"
        default:
            break
        }
        do {
            let request = try buildTransitionRequest(coordinator: coordinator, autoPilot: autoPilot)
            _ = try planner.plan(request)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public var transitionReadinessText: String {
        transitionReadinessMessage ?? "Ready for \(audioCoordinator?.deckAGraph.isMasterPlaying == true ? "Deck A" : "Deck B") → next deck"
    }

    public var isTransitionRunning: Bool {
        if case .inProgress = activeTransitionState { return true }
        return false
    }

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
        self.beforePreviewFilePreparation = nil
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
        startCoordinator: Bool = true,
        beforePreviewFilePreparation: (@Sendable (URL) async -> Void)? = nil
    ) {
        self.libraryRootURL = libraryRootURL
        self.waveformEditorModel = waveformEditorModel
        self.audioCoordinator = audioCoordinator
        self.beforePreviewFilePreparation = beforePreviewFilePreparation
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
        self.soundboardPads = self.audioCoordinator?.soundboardController.padSnapshots ?? Self.defaultSoundboardSnapshots()
        self.soundboardTotalRAMBytes = self.audioCoordinator?.soundboardController.totalRAMBytes ?? 0
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
        coordinator.talkoverController.onStateChanged = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isTalkoverActive = state.isActive
                self.talkoverProgress = state.progress
            }
        }
        coordinator.soundboardController.onPadsChanged = { [weak self] pads in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.soundboardPads = pads
                self.soundboardTotalRAMBytes = coordinator.soundboardController.totalRAMBytes
            }
        }
        self.soundboardPads = coordinator.soundboardController.padSnapshots
        self.soundboardTotalRAMBytes = coordinator.soundboardController.totalRAMBytes
        coordinator.soundboardController.preload(from: libraryRootURL)
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
        guard !isTransitionBusy,
              let selectedPath = selectedTrackPath,
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
                try coordinator.monitor.performOnControlQueue {
                    try coordinator.deckA.loadTrack(url: trackURL)
                    coordinator.deckA.volume = 1.0
                }
                self.deckATrack = track
                self.isDeckAPlaying = false
            case .deckB:
                try coordinator.monitor.performOnControlQueue {
                    try coordinator.deckB.loadTrack(url: trackURL)
                    coordinator.deckB.volume = 1.0
                }
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
        guard !isTransitionBusy else { return }
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
            if coordinator.deckAGraph.isMasterPlaying {
                coordinator.deckA.pause()
                isDeckAPlaying = false
            } else {
                coordinator.monitor.performOnControlQueue {
                    coordinator.deckA.volume = 1.0
                    coordinator.deckA.play()
                }
                isDeckAPlaying = true
            }
        case .deckB:
            if coordinator.deckBGraph.isMasterPlaying {
                coordinator.deckB.pause()
                isDeckBPlaying = false
            } else {
                coordinator.monitor.performOnControlQueue {
                    coordinator.deckB.volume = 1.0
                    coordinator.deckB.play()
                }
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

    /// Toggles Master-only talkover ducking state.
    public func toggleTalkover() {
        guard let coordinator = self.audioCoordinator else {
            isTalkoverActive.toggle()
            talkoverProgress = isTalkoverActive ? 1.0 : 0.0
            return
        }
        coordinator.toggleTalkover()
        self.isTalkoverActive = coordinator.talkoverController.isTargetActive
    }

    /// Sets Master-only talkover ducking state.
    public func setTalkover(active: Bool) {
        guard let coordinator = self.audioCoordinator else {
            isTalkoverActive = active
            talkoverProgress = active ? 1.0 : 0.0
            return
        }
        coordinator.setTalkover(active: active)
        self.isTalkoverActive = active
    }

    // MARK: - Soundboard Macro Controls (F1–F8)

    private static func defaultSoundboardSnapshots() -> [SoundboardPadSnapshot] {
        let fallbackDefs = ProceduralSFXGenerator.fallbackTones()
        let format = ProceduralSFXGenerator.standardFormat
        return fallbackDefs.enumerated().map { index, def in
            let frameCount = AVAudioFrameCount(format.sampleRate * def.durationSeconds)
            let ram = Int(frameCount) * Int(format.channelCount) * MemoryLayout<Float>.size
            return SoundboardPadSnapshot(
                index: index,
                keyLabel: SoundboardController.keyLabels[index],
                title: def.title,
                source: .procedural(toneDescription: def.description, durationSeconds: def.durationSeconds),
                isPlaying: false,
                error: nil,
                durationSeconds: def.durationSeconds,
                ramBytes: ram
            )
        }
    }

    /// Preloads soundboard audio assets from current library root directory.
    public func preloadSoundboard() {
        audioCoordinator?.soundboardController.preload(from: libraryRootURL)
    }

    private var lastSoundboardTriggerTimestamp: TimeInterval = 0.0
    private var lastSoundboardTriggerIndex: Int = -1

    /// Triggers playback of the designated Soundboard pad (0..<8).
    ///
    /// Includes held key / duplicate route suppression to ensure exactly one trigger per user intent.
    public func triggerSoundboardPad(index: Int) {
        guard index >= 0 && index < SoundboardController.padCount else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if index == lastSoundboardTriggerIndex && (now - lastSoundboardTriggerTimestamp) < 0.05 {
            return
        }
        lastSoundboardTriggerTimestamp = now
        lastSoundboardTriggerIndex = index

        if let coordinator = audioCoordinator {
            coordinator.soundboardController.triggerPad(index: index)
            self.soundboardPads = coordinator.soundboardController.padSnapshots
        }
    }

    /// Stops playback on a specific soundboard pad.
    public func stopSoundboardPad(index: Int) {
        if let coordinator = audioCoordinator {
            coordinator.soundboardController.stopPad(index: index)
            self.soundboardPads = coordinator.soundboardController.padSnapshots
        }
    }

    /// Stops all currently playing soundboard pads.
    public func stopAllSoundboardPads() {
        if let coordinator = audioCoordinator {
            coordinator.soundboardController.stopAllPads()
            self.soundboardPads = coordinator.soundboardController.padSnapshots
        }
    }

    /// Starts the selected macro from the outgoing deck's current playhead.
    public func executeTransition() async {
        do {
            guard let coordinator = audioCoordinator else {
                throw TransitionExecutionServiceError.invalidRequest("Audio coordinator unavailable")
            }
            let request = try makeTransitionRequest(coordinator: coordinator, autoPilot: false)
            let service = coordinator.transitionExecutionService
            _ = try await service.startTransition(request: request)
            transitionErrorMessage = nil
            await refreshTransitionSnapshot(using: service)
            observeTransition(using: service)
        } catch {
            transitionErrorMessage = error.localizedDescription
        }
    }

    /// Arms or disarms the selected macro at the outgoing track's mix-out cue.
    public func toggleAutoPilot() async {
        guard let coordinator = audioCoordinator else {
            transitionErrorMessage = "Audio coordinator unavailable"
            return
        }
        let service = coordinator.transitionExecutionService
        if isAutoPilotArmed {
            await service.disableAutoPilot()
            transitionErrorMessage = nil
            await refreshTransitionSnapshot(using: service)
            if isTransitionBusy {
                observeTransition(using: service)
            } else {
                stopTransitionObservation()
            }
            return
        }

        do {
            let request = try makeTransitionRequest(coordinator: coordinator, autoPilot: true)
            _ = try await service.armAutoPilot(request: request)
            transitionErrorMessage = nil
            await refreshTransitionSnapshot(using: service)
            observeTransition(using: service)
        } catch {
            transitionErrorMessage = error.localizedDescription
        }
    }

    /// Cancels an armed AutoPilot or active transition and synchronizes published transport state.
    public func cancelTransition() async {
        guard let coordinator = audioCoordinator else { return }
        let service = coordinator.transitionExecutionService
        _ = await service.cancelTransition()
        transitionErrorMessage = nil
        await refreshTransitionSnapshot(using: service)
        isDeckAPlaying = coordinator.deckAGraph.isMasterPlaying
        isDeckBPlaying = coordinator.deckBGraph.isMasterPlaying
        stopTransitionObservation()
    }

    private func makeTransitionRequest(
        coordinator: AudioEngineCoordinator,
        autoPilot: Bool
    ) throws -> TransitionRequest {
        let readiness = autoPilot ? autoPilotReadinessMessage : transitionReadinessMessage
        guard readiness == nil else {
            throw TransitionExecutionServiceError.invalidRequest(readiness ?? "Transition is not ready")
        }
        return try buildTransitionRequest(coordinator: coordinator, autoPilot: autoPilot)
    }

    private func buildTransitionRequest(
        coordinator: AudioEngineCoordinator,
        autoPilot: Bool
    ) throws -> TransitionRequest {
        let outgoingDeck: DeckIdentifier = coordinator.deckAGraph.isMasterPlaying ? .deckA : .deckB
        let incomingDeck: DeckIdentifier = outgoingDeck == .deckA ? .deckB : .deckA
        guard let outgoingEntry = trackEntry(for: outgoingDeck),
              let incomingEntry = trackEntry(for: incomingDeck) else {
            throw TransitionExecutionServiceError.invalidRequest("Both decks need cached track metadata")
        }

        let outgoingGraph = outgoingDeck == .deckA ? coordinator.deckAGraph : coordinator.deckBGraph
        let outgoingDescriptor = TrackTransitionDescriptor(deck: outgoingDeck, cacheEntry: outgoingEntry)
        let incomingDescriptor = TrackTransitionDescriptor(deck: incomingDeck, cacheEntry: incomingEntry)
        let style: TransitionStyle
        switch transitionMacroStyle {
        case .beatSyncedBassSwap:
            style = .beatSyncedBassSwap(bars: transitionPhraseBars, allowFallbackToFilter: false)
        case .filterEchoWash:
            let bpm = outgoingEntry.bpm.isFinite && (40...240).contains(outgoingEntry.bpm) ? outgoingEntry.bpm : 120.0
            let duration = Double(transitionPhraseBars) * 4.0 * 60.0 / bpm
            style = .filterEchoWash(durationSeconds: duration, echoSend: 0.5)
        case .hardCutOnDrop:
            style = .hardCutOnDrop(bars: transitionPhraseBars, allowFallbackToFilter: false)
        }

        let trigger = autoPilot ? nil : outgoingGraph.currentMasterPlayheadSeconds()
        guard autoPilot || (trigger?.isFinite == true) else {
            throw TransitionExecutionServiceError.invalidRequest("Outgoing playhead is unavailable")
        }
        if autoPilot {
            let playhead = outgoingGraph.currentMasterPlayheadSeconds()
            guard playhead.isFinite, playhead < outgoingEntry.cueMarkers.mixOutCue else {
                throw TransitionExecutionServiceError.playheadPastTrigger(
                    current: playhead,
                    trigger: outgoingEntry.cueMarkers.mixOutCue
                )
            }
        }

        return TransitionRequest(
            outgoingTrack: outgoingDescriptor,
            incomingTrack: incomingDescriptor,
            style: style,
            triggerPositionSeconds: trigger,
            outgoingPlaybackRate: outgoingGraph.timePitchParameters.rate
        )
    }

    private func trackEntry(for deck: DeckIdentifier) -> TrackCacheEntry? {
        let loadedEntry: TrackCacheEntry?
        switch deck {
        case .deckA: loadedEntry = deckATrack
        case .deckB: loadedEntry = deckBTrack
        }
        guard let loadedEntry,
              loadedCacheRootURL == libraryRootURL.standardizedFileURL,
              let currentEntry = loadedCache?.tracks[loadedEntry.relativePath],
              currentEntry.fileFingerprint == loadedEntry.fileFingerprint else {
            return nil
        }
        return currentEntry
    }

    private func observeTransition(using service: TransitionExecutionService) {
        guard transitionObservationTask == nil else { return }
        transitionObservationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let snapshot = await service.currentSnapshot()
                guard let self else { return }
                self.applyTransitionSnapshot(snapshot)
                switch snapshot.state {
                case .armed, .inProgress:
                    try? await Task.sleep(nanoseconds: 100_000_000)
                case .idle, .completed, .cancelled:
                    self.transitionObservationTask = nil
                    return
                }
            }
            self?.transitionObservationTask = nil
        }
    }

    private func refreshTransitionSnapshot(using service: TransitionExecutionService) async {
        applyTransitionSnapshot(await service.currentSnapshot())
    }

    private func applyTransitionSnapshot(_ snapshot: TransitionExecutionSnapshot) {
        activeTransitionState = snapshot.state
        transitionProgress = min(max(snapshot.progress.isFinite ? snapshot.progress : 0.0, 0.0), 1.0)
        isAutoPilotArmed = snapshot.isAutoPilotArmed
        if let coordinator = audioCoordinator {
            isDeckAPlaying = coordinator.deckAGraph.isMasterPlaying
            isDeckBPlaying = coordinator.deckBGraph.isMasterPlaying
            crossfaderPosition = coordinator.crossfaderPosition
        }
    }

    private func stopTransitionObservation() {
        transitionObservationTask?.cancel()
        transitionObservationTask = nil
    }

    // MARK: - Library Audition & Headphone Cue Preview

    /// Loads a library track into the headphone audition preview player on the Cue audio engine.
    /// Runs audio file I/O off the MainActor to prevent UI hitches, and tracks generation to drop stale loads.
    @discardableResult
    public func loadPreviewTrack(relativePath: String, playWhenReady: Bool = false) -> Task<Void, Never> {
        let rootURL = self.libraryRootURL
        let standardizedRoot = rootURL.standardizedFileURL
        let fileURL = rootURL.appendingPathComponent(relativePath)
        previewGeneration &+= 1
        let generation = previewGeneration
        self.previewTrackPath = relativePath
        self.previewErrorMessage = nil
        self.isPreviewPlaying = false
        self.previewPositionSeconds = 0.0
        self.previewDurationSeconds = 0.0
        previewLoadIsPending = false
        previewPlayRequested = playWhenReady
        previewIsReady = false
        stopPreviewPolling()

        let cachedTrack = (self.loadedCacheRootURL == standardizedRoot) ? self.loadedCache?.tracks[relativePath] : nil
        self.previewHasUsableBeatGrid = cachedTrack.map { TrackCompatibility.isAuthenticMeasuredGrid(track: $0) } ?? false

        guard let coordinator = self.audioCoordinator else {
            if let cachedTrack {
                self.previewDurationSeconds = cachedTrack.duration
            }
            return Task {}
        }

        // Capture ownership before asynchronous preparation. No background work may mutate the player.
        let requestID = coordinator.cuePreview.beginLoad()
        previewLoadIsPending = true
        let beforePreparation = beforePreviewFilePreparation
        return Task { [weak self] in
            do {
                let file = try await Self.preparePreviewFile(url: fileURL, beforePreparation: beforePreparation)

                guard let self,
                      self.previewGeneration == generation,
                      self.libraryRootURL.standardizedFileURL == standardizedRoot,
                      self.previewTrackPath == relativePath else {
                    return
                }
                self.previewLoadIsPending = false
                // MainActor identity remains stable through this synchronous control-queue installation.
                // The player checks request ownership again on that queue, including stop invalidation.
                guard !Task.isCancelled,
                      coordinator.cuePreview.load(file: file, requestID: requestID) else {
                    self.previewPlayRequested = false
                    return
                }
                self.previewIsReady = true
                self.previewDurationSeconds = coordinator.cuePreview.trackDurationSeconds
                self.previewPositionSeconds = 0.0
                if self.previewPlayRequested {
                    self.previewPlayRequested = false
                    self.togglePreviewPlay()
                }
            } catch {
                guard let self,
                      self.previewGeneration == generation,
                      self.libraryRootURL.standardizedFileURL == standardizedRoot,
                      self.previewTrackPath == relativePath else {
                    return
                }
                self.previewLoadIsPending = false
                self.previewPlayRequested = false
                self.previewIsReady = false
                self.previewDurationSeconds = 0.0
                self.previewPositionSeconds = 0.0
                self.isPreviewPlaying = false
                self.previewErrorMessage = "Preview load failed: \(error.localizedDescription)"
            }
        }
    }

    /// Nonisolated async work runs on the generic executor, then transfers unique file ownership.
    /// `sending` also supports SDKs where AVAudioFile has no Sendable conformance.
    nonisolated private static func preparePreviewFile(
        url: URL,
        beforePreparation: (@Sendable (URL) async -> Void)?
    ) async throws -> sending AVAudioFile {
        await beforePreparation?(url)
        return try AVAudioFile(forReading: url)
    }

    /// Toggles play / pause state for the headphone audition preview player.
    /// If the current preview track failed or is not ready, re-triggers file loading and arms playback on completion.
    @discardableResult
    public func togglePreviewPlay() -> Task<Void, Never>? {
        guard let coordinator = self.audioCoordinator else {
            isPreviewPlaying.toggle()
            return nil
        }

        if isPreviewPlaying {
            coordinator.cuePreview.pause()
            isPreviewPlaying = false
            stopPreviewPolling()
            previewPositionSeconds = coordinator.cuePreview.currentPositionSeconds
            return nil
        }

        // Start Cue audio engine safely if stopped without interrupting live Master engine
        if !coordinator.cueAudioEngine.isRunning {
            do {
                try coordinator.monitor.performOnControlQueue {
                    if !coordinator.cueAudioEngine.isRunning {
                        if coordinator.masterAudioEngine.isRunning {
                            try coordinator.cueAudioEngine.start()
                        } else {
                            try coordinator.start()
                        }
                    }
                }
            } catch {
                self.previewErrorMessage = "Failed to start cue output: \(error.localizedDescription)"
                return nil
            }
        }

        guard coordinator.cueAudioEngine.isRunning else {
            self.previewErrorMessage = "Cue output engine is not running"
            return nil
        }

        if previewLoadIsPending {
            previewPlayRequested.toggle()
            return nil
        }
        guard previewIsReady else {
            if let path = self.previewTrackPath {
                return loadPreviewTrack(relativePath: path, playWhenReady: true)
            }
            return nil
        }

        coordinator.cuePreview.play()
        let playing = coordinator.cuePreview.isPlaying
        self.isPreviewPlaying = playing
        if playing {
            self.previewErrorMessage = nil
            startPreviewPolling()
        }
        return nil
    }

    /// Stops headphone audition preview playback and resets playhead to 0.
    public func stopPreview() {
        previewGeneration &+= 1
        if previewLoadIsPending { previewIsReady = false }
        previewLoadIsPending = false
        previewPlayRequested = false
        audioCoordinator?.cuePreview.stop()
        isPreviewPlaying = false
        previewPositionSeconds = 0.0
        stopPreviewPolling()
    }

    /// Seeks the headphone audition playhead strictly bounded to [0.0, previewDurationSeconds].
    public func seekPreview(to seconds: Double) {
        guard seconds.isFinite, !previewLoadIsPending else { return }
        if audioCoordinator != nil && !previewIsReady { return }
        let clamped = min(max(seconds, 0.0), max(previewDurationSeconds, 0.0))
        audioCoordinator?.cuePreview.seek(to: clamped)
        previewPositionSeconds = clamped
    }

    /// Steps preview playback by a number of beats (e.g. +/-1 beat or +/-4 beats).
    /// Disabled if the track lacks an authentic measured beat grid (e.g. unknown-tempo 1.0s sentinel).
    public func stepPreview(beats: Double) {
        guard beats.isFinite && beats != 0 else { return }
        guard previewHasUsableBeatGrid,
              let path = previewTrackPath,
              let track = loadedCache?.tracks[path],
              track.bpm > 0 else {
            return
        }
        let beatInterval = 60.0 / track.bpm
        let current = audioCoordinator?.cuePreview.currentPositionSeconds ?? previewPositionSeconds
        seekPreview(to: current + (beats * beatInterval))
    }

    /// Synchronizes the current preview playhead from the Cue preview engine.
    public func updatePreviewPosition() {
        guard let coordinator = self.audioCoordinator else { return }
        let isPlaying = coordinator.cuePreview.isPlaying
        let position = coordinator.cuePreview.currentPositionSeconds
        self.previewPositionSeconds = position
        if self.isPreviewPlaying != isPlaying {
            self.isPreviewPlaying = isPlaying
            if !isPlaying {
                stopPreviewPolling()
            }
        }
    }

    private func startPreviewPolling() {
        stopPreviewPolling()
        previewPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled else { break }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.updatePreviewPosition()
                }
            }
        }
    }

    private func stopPreviewPolling() {
        previewPollingTask?.cancel()
        previewPollingTask = nil
    }

    // MARK: - Compatibility Reference & Inspection

    /// Currently loaded track on the active reference deck, if any.
    public var referenceTrack: TrackCacheEntry? {
        switch compatibilityReferenceDeck {
        case .deckA: return deckATrack
        case .deckB: return deckBTrack
        }
    }

    /// Computes compatibility between a library track and the active reference deck.
    public func compatibility(for track: TrackCacheEntry) -> TrackCompatibility? {
        guard let ref = referenceTrack else { return nil }
        return TrackCompatibility.evaluate(candidate: track, reference: ref)
    }

    /// Updates the reference deck used for library compatibility badges.
    public func setCompatibilityReferenceDeck(_ deck: DeckIdentifier) {
        self.compatibilityReferenceDeck = deck
    }

    /// Updates the library root URL and resets any audition preview state.
    public func updateLibraryRootURL(_ newURL: URL) {
        self.libraryRootURL = newURL
        self.waveformEditorModel.updateLibraryRoot(newURL)
        refreshLibrary()
    }
}
