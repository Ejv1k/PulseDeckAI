import Foundation
import Combine
import AVFoundation
import AppKit
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
                scanGeneration &+= 1
                isScanning = false
                analysisTask?.cancel()
                // Relative paths of a running batch would resolve against the new root.
                cancelCrateAnalysis()
                for task in deckAnalysisValidationTasks.values { task.cancel() }
                deckAnalysisValidationTasks.removeAll()
                deckAnalysisValidationIDs.removeAll()
                for task in loudnessTasks.values { task.cancel() }
                loudnessTasks.removeAll()
                loudnessRequestIDs.removeAll()
                for deck in [DeckIdentifier.deckA, .deckB] where isMeasuringLoudness(deck) {
                    setAutoGain(nil, measuring: false, deck: deck)
                    applyAutoGain(deck: deck)
                }
                for task in deckLoadTasks.values { task.cancel() }
                deckLoadTasks.removeAll()
                deckLoadRequestIDs.removeAll()
                analysisStatuses = [:]
                deckLoadMessages = [:]
                loadedCache = nil
                loadedCacheRootURL = nil
                selectedTrackPath = nil
                selectedCrate = nil
                scanSummary = nil
                waveformEditorModel.updateLibraryRoot(libraryRootURL)
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
    @Published public private(set) var libraryLocationError: String?
    private var libraryLocationStore: LibraryLocationStore?
    private var libraryLaunchIssue: LibraryLaunchLocation.Issue?
    private var beforeSoundboardPreloadForTesting: (@MainActor (URL) -> Void)?

    /// Only this root may be consumed by library asset loaders. An unresolved display path is not active.
    public var resolvedLibraryRootURL: URL? {
        libraryLaunchIssue == nil ? libraryRootURL : nil
    }
    private var chooseLibraryDirectory: @MainActor () -> URL? = { LibraryLocationPicker.chooseDirectory() }

    public var libraryLocationUnavailableReason: String? {
        isTransitionBusy || pendingSafetyLockAutomationCommands > 0
            ? "Finish or cancel the transition before changing libraries."
            : nil
    }

    public var canOpenLibrary: Bool { libraryLocationUnavailableReason == nil }

    @Published public var scanSummary: LibraryScanSummary?
    @Published public var selectedCrate: LibraryCrateInfo?
    @Published public var isScanning: Bool = false
    @Published public var statusMessage: String = "Phase 0 Operational Shell Initialized"
    @Published public private(set) var meteringErrorMessage: String?
    @Published public private(set) var coordinatorErrorMessage: String?
    @Published public private(set) var loadedCache: PulseDeckLibraryCache?
    @Published public var selectedTrackPath: String?

    @Published private var deckLoadMessages: [DeckIdentifier: String] = [:]
    @Published private var analysisStatuses: [String: LibraryTrackAnalysisStatus] = [:]
    @Published private(set) var isAnalyzingLibraryTrack = false
    /// Beat This! is the default: on real tracks it is markedly more accurate than the DSP heuristic.
    @Published public var selectedAnalysisMethod: TrackAnalysisMethod = .nativeModel
    @Published public private(set) var activeAnalysisMethod: [String: TrackAnalysisMethod] = [:]
    /// Unique identity token of the currently active in-flight analysis request across all tracks and methods.
    private var activeAnalysisToken: UUID? = nil
    /// Track path of the in-flight analysis; `activeAnalysisMethod` keeps history per path, this is only the live one.
    private var activeAnalysisPath: String? = nil
    private var analysisTask: Task<Void, Never>?
    /// "Analyze crate" progress while running, nil when idle.
    @Published private(set) var crateAnalysisProgress: (done: Int, total: Int)?
    private(set) var crateAnalysisTask: Task<Void, Never>?
    /// Track analysis the batch is currently waiting on, so Stop never cancels a user's own run.
    private var crateCurrentTrackTask: Task<Void, Never>?
    private var crateBatchID: UUID?
    private var deckAnalysisValidationTasks: [DeckIdentifier: Task<Void, Never>] = [:]
    private var deckAnalysisValidationIDs: [DeckIdentifier: UUID] = [:]
    private var deckLoadTasks: [DeckIdentifier: Task<Void, Never>] = [:]
    private var deckLoadRequestIDs: [DeckIdentifier: UUID] = [:]
    /// App preferences; nil for injected (test) instances so they never touch the user's settings.
    private var preferences: UserDefaults?
    private var loudnessTasks: [DeckIdentifier: Task<Void, Never>] = [:]
    private var loudnessRequestIDs: [DeckIdentifier: UUID] = [:]
    /// Auto gain per deck once measured (dB toward -14 LUFS); nil while measuring or for silent/unreadable audio.
    @Published public private(set) var deckAAutoGainDB: Double?
    @Published public private(set) var deckBAutoGainDB: Double?
    @Published public private(set) var deckAAutoGainMeasuring = false
    @Published public private(set) var deckBAutoGainMeasuring = false
    /// Every track plays at a similar loudness (EBU R128). Persisted; on by default.
    @Published public var isAutoGainEnabled: Bool = true {
        didSet {
            guard oldValue != isAutoGainEnabled else { return }
            preferences?.set(isAutoGainEnabled, forKey: "autoGainEnabled")
            for deck in [DeckIdentifier.deckA, .deckB] { applyAutoGain(deck: deck) }
        }
    }
    var beforeDeckLoadPreparationForTesting: (@Sendable (String) async -> Void)?
    private var deckLoadedSourceIdentities: [DeckIdentifier: LibraryTrackSource.Identity] = [:]
    var beforeCachedFingerprintValidationForTesting: (@Sendable () async -> Void)?

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
    @Published public var transitionPhraseBars: Int = 8
    @Published public private(set) var transitionProgress: Double = 0.0
    @Published public private(set) var activeTransitionState: TransitionExecutionState = .idle
    /// Channel EQ per deck as the DJ set it (or as automation left it after a transition).
    @Published public private(set) var deckAEQ = EQ3BandParameters()
    @Published public private(set) var deckBEQ = EQ3BandParameters()
    @Published public private(set) var isAutoPilotArmed: Bool = false
    @Published public private(set) var transitionErrorMessage: String?
    /// Tracks lined up to play next, as library-relative paths. A track leaves the list once it loads into a deck.
    /// Saved with the played history so a set survives a restart (see `saveSet`).
    @Published public private(set) var upNext: [String] = [] { didSet { saveSet() } }
    /// Tracks started on a deck in this set; saved between launches until "New Set". Crossfader position is ignored.
    @Published public private(set) var playedTonight: Set<String> = [] { didSet { saveSet() } }
    /// Deck a running transition fades out; after completion it is free for the next queued track.
    private var transitionOutgoingDeck: DeckIdentifier?
    private var upNextLoadTask: Task<Void, Never>?
    /// Service generation whose completion already fed the queue; `.completed` is reported until the next start.
    private var queueHandledGeneration: UInt64?

    // Manual Master transport protection; internal engine cleanup never passes through this policy.
    @Published public private(set) var isMasterSafetyLockEnabled = true
    @Published public private(set) var masterSafetyLockMessage: String?
    @Published public private(set) var focusedMasterDeck: DeckIdentifier = .deckA

    // Master-only Talkover State
    @Published public private(set) var isTalkoverActive: Bool = false
    @Published public private(set) var talkoverProgress: Double = 0.0

    // Master-only Soundboard State (F1–F8)
    @Published public private(set) var soundboardPads: [SoundboardPadSnapshot] = []
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
    private var pendingSafetyLockAutomationCommands = 0
    /// Installed before a test request to hold a validated start at its actor handoff.
    var safetyLockBeforeTransitionStartForTesting: (@MainActor () async -> Void)?
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
        guard deckAnalysisValidationTasks.isEmpty else { return "Validating cached analysis; playback remains available." }
        guard let trackA = trackEntry(for: .deckA), let trackB = trackEntry(for: .deckB) else {
            return deckATrack != nil && deckBTrack != nil
                ? "Analyze both loaded tracks locally for waveform and beat tools."
                : "Load a track on both decks"
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

    static func cueUnavailableMessage(_ error: Error) -> String {
        "Headphone cue unavailable; master output is running: \(error.localizedDescription)"
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
            if let cueError = try coordinator.start(requireCue: false) {
                coordinatorErrorMessage = Self.cueUnavailableMessage(cueError)
            }
        } catch {
            coordinatorErrorMessage = "Audio engine startup failed: \(error.localizedDescription)"
            statusMessage = "Audio Startup Error: \(error.localizedDescription)"
        }

        self.preferences = .standard
        self.isAutoGainEnabled = UserDefaults.standard.object(forKey: "autoGainEnabled") as? Bool ?? true

        let locationStore = LibraryLocationStore.applicationStore()
        let location = LibraryLocation.resolve(
            arguments: ProcessInfo.processInfo.arguments,
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            store: locationStore)
        self.libraryLocationStore = locationStore
        self.libraryLocationError = location.error
        self.libraryLaunchIssue = location.issue
        self.libraryRootURL = location.root
        let editor = WaveformEditorModel(libraryRootURL: location.root)
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
        restoreSet()
        refreshLibrary()
    }

    private struct SavedSet: Codable { var upNext: [String]; var played: [String] }
    private static let savedSetKey = "savedSets"
    private var isRestoringSet = false

    /// Sets are kept per library folder (paths are library-relative), so switching folders never overwrites another one's set.
    private func savedSets() -> [String: SavedSet] {
        preferences?.data(forKey: Self.savedSetKey).flatMap { try? JSONDecoder().decode([String: SavedSet].self, from: $0) } ?? [:]
    }

    private func saveSet() {
        guard let preferences, !isRestoringSet else { return }
        var all = savedSets()
        all[libraryRootURL.standardizedFileURL.path] = SavedSet(upNext: upNext, played: playedTonight.sorted())
        preferences.set(try? JSONEncoder().encode(all), forKey: Self.savedSetKey)
    }

    private func restoreSet() {
        guard let set = savedSets()[libraryRootURL.standardizedFileURL.path] else { return }
        isRestoringSet = true
        upNext = set.upNext
        playedTonight = Set(set.played)
        isRestoringSet = false
    }

    /// Forgets what already played, so Best match and bridges treat every track as fresh again. Up Next stays.
    public func startNewSet() { playedTonight = [] }

    /// Initializes library/editor state with optional injected audio coordinator.
    init(
        libraryRootURL: URL,
        waveformEditorModel: WaveformEditorModel,
        loadedCache: PulseDeckLibraryCache? = nil,
        cacheLoader: (@Sendable (URL) async -> PulseDeckLibraryCache?)? = nil,
        audioCoordinator: AudioEngineCoordinator? = nil,
        startCoordinator: Bool = true,
        beforePreviewFilePreparation: (@Sendable (URL) async -> Void)? = nil,
        libraryLocationStore: LibraryLocationStore? = nil,
        libraryLaunchIssue: LibraryLaunchLocation.Issue? = nil,
        beforeSoundboardPreloadForTesting: (@MainActor (URL) -> Void)? = nil,
        chooseLibraryDirectory: @escaping @MainActor () -> URL? = { LibraryLocationPicker.chooseDirectory() },
        autoGainEnabled: Bool = false
    ) {
        // Explicitly injected roots win; this initializer never restores normal app preferences.
        self.isAutoGainEnabled = autoGainEnabled
        self.libraryLocationStore = libraryLocationStore
        self.libraryLaunchIssue = libraryLaunchIssue
        self.beforeSoundboardPreloadForTesting = beforeSoundboardPreloadForTesting
        self.libraryLocationError = libraryLaunchIssue?.message
        self.chooseLibraryDirectory = chooseLibraryDirectory
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
                if let cueError = try coordinator.start(requireCue: false) {
                    self.coordinatorErrorMessage = Self.cueUnavailableMessage(cueError)
                }
            } catch {
                self.coordinatorErrorMessage = "Audio engine startup failed: \(error.localizedDescription)"
                self.statusMessage = "Audio Startup Error: \(error.localizedDescription)"
            }
        }
        self.soundboardPads = self.audioCoordinator?.soundboardController.padSnapshots ?? Self.defaultSoundboardSnapshots()
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
            }
        }
        self.soundboardPads = coordinator.soundboardController.padSnapshots
        preloadSoundboard()
    }

    private func handleDeviceError(_ error: CoreAudioError) {
        self.statusMessage = "Audio Device Notice: \(error.localizedDescription)"
    }

    /// Scans the library root and updates published state on MainActor.
    /// Strictly limits scanning to one in-flight operation and protects against stale results
    /// from out-of-order background task completion.
    @discardableResult
    public func refreshLibrary() -> Task<Void, Never>? {
        if case .malformedOverride = libraryLaunchIssue { return nil }
        guard !self.isScanning else {
            // Drop concurrent rescan requests while a scan is actively running
            return nil
        }

        do {
            _ = try LibraryLocation.validate(libraryRootURL)
            libraryLaunchIssue = nil
            libraryLocationError = nil
        } catch {
            libraryLaunchIssue = .unavailableRoot(error.localizedDescription)
            libraryLocationError = error.localizedDescription
            return nil
        }

        self.isScanning = true
        self.scanGeneration &+= 1
        let thisGeneration = self.scanGeneration
        let url = self.libraryRootURL
        let expectedCacheGeneration = waveformEditorModel.cachePublicationGeneration(for: url)

        // Perform scanner on background thread, deliver result to MainActor
        return Task.detached(priority: .userInitiated) { [scanner, cacheLoader] in
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
                    self.preloadSoundboard()
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
        guard resolvedLibraryRootURL != nil else { return Task {} }
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
                self.statusMessage = "Selected \(relativePath)"
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

    public func setMasterSafetyLockEnabled(_ enabled: Bool) {
        isMasterSafetyLockEnabled = enabled
        masterSafetyLockMessage = enabled
            ? "Master Safety Lock on — on-air decks are protected."
            : "Master Safety Lock off — manual on-air changes are allowed outside automation."
    }

    public func focusMasterDeck(_ deck: DeckIdentifier) {
        focusedMasterDeck = deck
    }

    public func isMasterDeckOnAir(_ deck: DeckIdentifier) -> Bool {
        guard let coordinator = audioCoordinator else { return false }
        return coordinator.monitor.performOnControlQueue {
            let graph = deck == .deckA ? coordinator.deckAGraph : coordinator.deckBGraph
            return MasterSafetyLock.isOnAir(
                masterIsRunning: coordinator.masterAudioEngine.isRunning,
                isPlaying: graph.isMasterPlaying, hasLoadedTrack: graph.loadedTrackURL != nil,
                channelVolume: graph.volume, crossfaderWeight: graph.crossfaderWeight)
        }
    }

    public func isMasterDeckProtected(_ deck: DeckIdentifier) -> Bool {
        isMasterSafetyLockEnabled && isMasterDeckOnAir(deck)
    }

    /// The check and mutation share the audio control queue, so a crossfade cannot
    /// move a deck on air between authorization and its transport change.
    private func performManualDeckMutation(
        deck: DeckIdentifier,
        action: MasterSafetyLockAction,
        confirmedPause: Bool = false,
        mutation: @Sendable (DeckAudioGraph) throws -> Void
    ) -> Bool {
        guard !isTransitionBusy, pendingSafetyLockAutomationCommands == 0 else {
            masterSafetyLockMessage = "Automation owns deck transport; finish or cancel it first."
            return false
        }
        guard let coordinator = audioCoordinator else { return false }
        let locked = isMasterSafetyLockEnabled
        do {
            let result = try coordinator.monitor.performOnControlQueue { () throws -> MasterSafetyLockMutationResult in
                let graph = deck == .deckA ? coordinator.deckAGraph : coordinator.deckBGraph
                let onAir = MasterSafetyLock.isOnAir(
                    masterIsRunning: coordinator.masterAudioEngine.isRunning,
                    isPlaying: graph.isMasterPlaying, hasLoadedTrack: graph.loadedTrackURL != nil,
                    channelVolume: graph.volume, crossfaderWeight: graph.crossfaderWeight)
                if confirmedPause && !onAir { return .notOnAir }
                if locked && onAir && !confirmedPause { return .blocked }
                try mutation(graph)
                return .applied(isPlaying: graph.isMasterPlaying)
            }
            switch result {
            case .blocked:
                masterSafetyLockMessage = "Master Safety Lock blocked \(action.rawValue) on \(deck.rawValue). Use Shift+Space for one pause, or switch the lock off."
                return false
            case .notOnAir:
                masterSafetyLockMessage = "\(deck.rawValue) is not on air; no forced pause was needed."
                return false
            case .applied(let playing):
                if deck == .deckA { isDeckAPlaying = playing } else { isDeckBPlaying = playing }
                masterSafetyLockMessage = confirmedPause
                    ? "Confirmed pause on \(deck.rawValue). Master Safety Lock remains \(locked ? "on" : "off")."
                    : nil
                return true
            }
        } catch {
            statusMessage = "Deck \(action.rawValue) failed: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    public func pauseDeck(deck: DeckIdentifier) -> Bool {
        performManualDeckMutation(deck: deck, action: .pause) { $0.pause() }
    }

    @discardableResult
    public func stopDeck(deck: DeckIdentifier) -> Bool {
        performManualDeckMutation(deck: deck, action: .stop) { $0.stop() }
    }

    @discardableResult
    public func seekDeck(deck: DeckIdentifier, to seconds: Double) -> Bool {
        guard seconds.isFinite else { return false }
        return performManualDeckMutation(deck: deck, action: .seek) { $0.seek(to: seconds) }
    }

    /// One explicit pause only; this does not unlock transport or override automation.
    @discardableResult
    public func forcePauseFocusedMasterDeck() -> Bool {
        performManualDeckMutation(deck: focusedMasterDeck, action: .pause, confirmedPause: true) { $0.pause() }
    }

    /// Loads the selected file. Analysis is optional and never gates basic playback.
    public func loadSelectedTrackIntoDeck(deck: DeckIdentifier) {
        guard let path = selectedTrackPath else {
            reportDeckLoadFailure("Select a library track, then click LOAD or drag it onto this deck.", deck: deck)
            return
        }
        startTrackLoad(relativePath: path, deck: deck)
    }

    func deckLoadMessage(for deck: DeckIdentifier) -> String? { deckLoadMessages[deck] }

    private func reportDeckLoadFailure(_ reason: String, deck: DeckIdentifier) {
        deckLoadMessages[deck] = reason
        statusMessage = "\(deck.rawValue): \(reason)"
    }

    /// Everything a deck load needs from disk, gathered before touching any deck.
    private struct PreparedDeckLoad {
        let file: URL
        let identity: LibraryTrackSource.Identity
        let basic: TrackCacheEntry
        let masterFile: AVAudioFile
        let cueFile: AVAudioFile
    }

    /// File I/O only; safe off MainActor. Slow USB/NAS volumes block here, not the UI.
    nonisolated private static func prepareDeckLoad(relativePath: String, root: URL) throws -> sending PreparedDeckLoad {
        let file = try LibraryTrackSource.url(relativePath: relativePath, root: root)
        let identity = try LibraryTrackSource.identity(at: file)
        // Opening a header is enough to load fresh files. Do not synthesize measured analysis.
        let basic = try LibraryTrackSource.metadata(at: file, relativePath: relativePath)
        let masterFile = try AVAudioFile(forReading: file)
        let cueFile = try AVAudioFile(forReading: file)
        guard identity == (try LibraryTrackSource.identity(at: file)), basic.fileFingerprint == identity.fingerprint else {
            throw LibraryTrackSource.Failure("The file changed while loading. Wait for the copy to finish and load again.")
        }
        return PreparedDeckLoad(file: file, identity: identity, basic: basic, masterFile: masterFile, cueFile: cueFile)
    }

    /// Nonisolated async runs on the generic executor, like preview preparation.
    nonisolated private static func prepareDeckLoadInBackground(
        relativePath: String, root: URL, beforePreparation: (@Sendable (String) async -> Void)?
    ) async throws -> sending PreparedDeckLoad {
        await beforePreparation?(relativePath)
        return try prepareDeckLoad(relativePath: relativePath, root: root)
    }

    /// Cheap refusals that need no disk access. The commit re-checks atomically.
    private func deckLoadRefusal(deck: DeckIdentifier) -> String? {
        guard resolvedLibraryRootURL != nil else { return libraryLocationError ?? "Open Library to choose a library root." }
        guard !isTransitionBusy, pendingSafetyLockAutomationCommands == 0 else {
            return "Automation owns deck transport; finish or cancel it before loading."
        }
        guard audioCoordinator != nil else { return "Audio engine is unavailable; check output routing before loading." }
        return nil
    }

    /// Any newer load request, even a refused one, supersedes a load still preparing.
    private func cancelPendingDeckLoad(deck: DeckIdentifier) {
        deckLoadTasks[deck]?.cancel()
        deckLoadTasks[deck] = nil
        deckLoadRequestIDs[deck] = nil
    }

    /// Synchronous load, kept for scripted callers and tests. UI controls use `startTrackLoad`.
    @discardableResult
    public func loadTrack(relativePath: String, deck: DeckIdentifier) -> Bool {
        cancelPendingDeckLoad(deck: deck)
        if let reason = deckLoadRefusal(deck: deck) {
            reportDeckLoadFailure(reason, deck: deck)
            return false
        }
        do {
            return commitDeckLoad(try Self.prepareDeckLoad(relativePath: relativePath, root: libraryRootURL),
                                  relativePath: relativePath, deck: deck)
        } catch {
            reportDeckLoadFailure("Unable to load \(relativePath): \(error.localizedDescription)", deck: deck)
            return false
        }
    }

    /// The single entry point shared by the real LOAD control and native library drops.
    /// Returns false only for immediate refusals; disk failures arrive later as the deck message.
    @discardableResult
    func startTrackLoad(relativePath: String, deck: DeckIdentifier, focusOnSuccess: Bool = false) -> Bool {
        cancelPendingDeckLoad(deck: deck)
        if let reason = deckLoadRefusal(deck: deck) {
            reportDeckLoadFailure(reason, deck: deck)
            return false
        }
        if isMasterDeckProtected(deck) {
            masterSafetyLockMessage = "Master Safety Lock blocked \(MasterSafetyLockAction.replace.rawValue) on \(deck.rawValue). Use Shift+Space for one pause, or switch the lock off."
            reportDeckLoadFailure(masterSafetyLockMessage ?? "", deck: deck)
            return false
        }
        let request = UUID()
        let root = libraryRootURL.standardizedFileURL
        deckLoadRequestIDs[deck] = request
        deckLoadMessages[deck] = "Loading \(relativePath)…"
        let beforePreparation = beforeDeckLoadPreparationForTesting
        deckLoadTasks[deck] = Task { [weak self] in
            let prepared: Result<PreparedDeckLoad, any Error>
            do {
                prepared = .success(try await Self.prepareDeckLoadInBackground(
                    relativePath: relativePath, root: root, beforePreparation: beforePreparation))
            } catch {
                prepared = .failure(error)
            }
            // A newer load, a root change or cancellation owns the deck now; drop this result.
            guard let self, !Task.isCancelled, self.deckLoadRequestIDs[deck] == request,
                  self.libraryRootURL.standardizedFileURL == root else { return }
            self.deckLoadRequestIDs[deck] = nil
            self.deckLoadTasks[deck] = nil
            switch prepared {
            case .success(let load):
                if let reason = self.deckLoadRefusal(deck: deck) {
                    self.reportDeckLoadFailure(reason, deck: deck)
                } else if self.commitDeckLoad(load, relativePath: relativePath, deck: deck), focusOnSuccess {
                    self.focusMasterDeck(deck)
                }
            case .failure(let error):
                self.reportDeckLoadFailure("Unable to load \(relativePath): \(error.localizedDescription)", deck: deck)
            }
        }
        return true
    }

    func autoGainDB(_ deck: DeckIdentifier) -> Double? { deck == .deckA ? deckAAutoGainDB : deckBAutoGainDB }
    func isMeasuringLoudness(_ deck: DeckIdentifier) -> Bool { deck == .deckA ? deckAAutoGainMeasuring : deckBAutoGainMeasuring }

    /// Measures integrated loudness in the background after a load. Until it finishes the deck plays at
    /// unity trim; a result for a track that has since been replaced is dropped.
    private func measureLoudness(deck: DeckIdentifier, file: URL) {
        loudnessTasks[deck]?.cancel()
        let request = UUID()
        loudnessRequestIDs[deck] = request
        setAutoGain(nil, measuring: true, deck: deck)
        applyAutoGain(deck: deck)
        loudnessTasks[deck] = Task { [weak self] in
            let measurement = Task.detached(priority: .utility) { try? LoudnessMeter.measure(url: file) }
            // A detached task does not inherit cancellation; forward it so a superseded load stops decoding.
            let measured = await withTaskCancellationHandler { await measurement.value } onCancel: { measurement.cancel() }
            guard let self, !Task.isCancelled, self.loudnessRequestIDs[deck] == request else { return }
            self.loudnessTasks[deck] = nil
            self.loudnessRequestIDs[deck] = nil
            self.setAutoGain(measured.map { LoudnessMeter.autoGainDB(for: $0) }, measuring: false, deck: deck)
            self.applyAutoGain(deck: deck)
        }
    }

    func waitForPendingLoudness(deck: DeckIdentifier) async {
        await loudnessTasks[deck]?.value
    }

    private func setAutoGain(_ gain: Double?, measuring: Bool, deck: DeckIdentifier) {
        if deck == .deckA { deckAAutoGainDB = gain; deckAAutoGainMeasuring = measuring }
        else { deckBAutoGainDB = gain; deckBAutoGainMeasuring = measuring }
    }

    private func applyAutoGain(deck: DeckIdentifier) {
        guard let coordinator = audioCoordinator else { return }
        let gain = Float(isAutoGainEnabled ? (autoGainDB(deck) ?? 0) : 0)
        coordinator.monitor.performOnControlQueue {
            (deck == .deckA ? coordinator.deckAGraph : coordinator.deckBGraph).rampTrimGain(to: gain)
        }
    }

    func waitForPendingDeckLoad(deck: DeckIdentifier) async {
        await deckLoadTasks[deck]?.value
    }

    /// MainActor half of a load: cache lookup, safety-checked graph swap, published state.
    private func commitDeckLoad(_ load: sending PreparedDeckLoad, relativePath: String, deck: DeckIdentifier) -> Bool {
        let cache = loadedCacheRootURL == libraryRootURL.standardizedFileURL ? loadedCache : nil
        let cached = waveformEditorModel.entryForSelection(relativePath: relativePath, cache: cache, libraryRootURL: libraryRootURL)
        let durationMatches = cached.map { abs($0.duration - load.basic.duration) < 0.01 } ?? false
        let entry = durationMatches && cached?.fileFingerprint == load.identity.fingerprint ? (cached ?? load.basic) : load.basic
        let file = load.file
        // `sending` gave this call sole ownership; older SDKs mark AVAudioFile non-Sendable.
        nonisolated(unsafe) let masterFile = load.masterFile
        nonisolated(unsafe) let cueFile = load.cueFile
        // Safety and automation authorization remain atomic with both actual graph loads.
        masterSafetyLockMessage = nil
        guard performManualDeckMutation(deck: deck, action: .replace, mutation: { graph in
            graph.loadTrack(masterFile: masterFile, cueFile: cueFile, url: file)
            graph.volume = 1
        }) else {
            reportDeckLoadFailure(masterSafetyLockMessage ?? statusMessage, deck: deck)
            return false
        }
        deckAnalysisValidationTasks[deck]?.cancel()
        deckAnalysisValidationTasks[deck] = nil
        deckAnalysisValidationIDs[deck] = nil
        deckLoadedSourceIdentities[deck] = load.identity
        measureLoudness(deck: deck, file: file)
        if deck == .deckA { deckATrack = entry } else { deckBTrack = entry }
        // Success needs no banner: the deck shows the title. Only failures and pending work speak up.
        deckLoadMessages[deck] = nil
        upNext.removeAll { $0 == relativePath }
        statusMessage = "\(deck.rawValue): loaded \(relativePath)"
        // The deck no longer prints a success banner, so VoiceOver gets the confirmation explicitly.
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: "\(deck.rawValue) loaded \(LibraryTrackTitle.display((relativePath as NSString).lastPathComponent))",
            .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        if durationMatches, let cached, LibraryTrackSource.isSHA256(cached.fileFingerprint) {
            validateSHAAnalysis(cached, file: file, identity: load.identity, deck: deck)
        }
        return true
    }

    /// Full-file hashing stays off the UI/control queues. Until it succeeds, header-only
    /// metadata prevents automation from seeing a previous file's grid or cues.
    private func validateSHAAnalysis(_ cached: TrackCacheEntry, file: URL, identity: LibraryTrackSource.Identity, deck: DeckIdentifier) {
        let request = UUID()
        let root = libraryRootURL.standardizedFileURL
        deckAnalysisValidationIDs[deck] = request
        deckLoadMessages[deck] = "Validating cached analysis… Playback is ready."
        let beforeValidation = beforeCachedFingerprintValidationForTesting
        deckAnalysisValidationTasks[deck] = Task { [weak self] in
            defer {
                if self?.deckAnalysisValidationIDs[deck] == request {
                    self?.deckAnalysisValidationTasks[deck] = nil
                    self?.deckAnalysisValidationIDs[deck] = nil
                }
            }
            do {
                try Task.checkCancellation()
                let verification = Task.detached(priority: .utility) {
                    await beforeValidation?()
                    return try LibraryTrackSource.matchesSHA256(cached.fileFingerprint, at: file, identity: identity)
                }
                let valid = try await withTaskCancellationHandler {
                    try await verification.value
                } onCancel: { verification.cancel() }
                try Task.checkCancellation()
                guard let self, self.deckAnalysisValidationIDs[deck] == request,
                      self.libraryRootURL.standardizedFileURL == root,
                      self.loadedCacheRootURL == root,
                      try LibraryTrackSource.identity(at: file) == identity else { return }
                let graph = deck == .deckA ? self.audioCoordinator?.deckAGraph : self.audioCoordinator?.deckBGraph
                let displayed = deck == .deckA ? self.deckATrack : self.deckBTrack
                guard graph?.loadedTrackURL?.standardizedFileURL == file.standardizedFileURL,
                      displayed?.relativePath == cached.relativePath,
                      displayed?.fileFingerprint == identity.fingerprint,
                      displayed?.analyzerVersion == "unanalysed-playback" else { return }
                guard valid,
                      let latest = self.waveformEditorModel.entryForSelection(relativePath: cached.relativePath,
                          cache: self.loadedCache, libraryRootURL: root),
                      latest.fileFingerprint == cached.fileFingerprint,
                      abs(latest.duration - (displayed?.duration ?? 0)) < 0.01 else {
                    self.deckLoadMessages[deck] = "Cached analysis is stale. Analyze to restore waveform and beat tools."
                    return
                }
                if deck == .deckA { self.deckATrack = latest } else { self.deckBTrack = latest }
                self.deckLoadMessages[deck] = nil
            } catch {
                guard let self, self.deckAnalysisValidationIDs[deck] == request,
                      self.libraryRootURL.standardizedFileURL == root else { return }
                self.deckLoadMessages[deck] = "Cached analysis unavailable: \(error.localizedDescription). Analyze to retry."
            }
        }
    }

    func waitForPendingDeckAnalysisValidation(deck: DeckIdentifier) async {
        await deckAnalysisValidationTasks[deck]?.value
    }

    @discardableResult
    func loadDroppedTracks(_ items: [LibraryTrackTransfer], deck: DeckIdentifier) -> Bool {
        guard items.count == 1, let item = items.first else {
            reportDeckLoadFailure("Drop exactly one library track onto a deck.", deck: deck)
            return false
        }
        guard item.libraryRoot == libraryRootURL.standardizedFileURL.resolvingSymlinksInPath() else {
            reportDeckLoadFailure("This drag belongs to another library. Select a track from the current library.", deck: deck)
            return false
        }
        return startTrackLoad(relativePath: item.relativePath, deck: deck, focusOnSuccess: true)
    }

    func analysisStatus(for path: String) -> LibraryTrackAnalysisStatus? { analysisStatuses[path] }

    /// Analyzes, one at a time with the selected method, every track in the crate that lacks a
    /// current analysis. Manual overrides survive through the normal re-analysis merge.
    func analyzeCrate(_ crate: LibraryCrateInfo) {
        guard crateAnalysisTask == nil else { return }
        let method = selectedAnalysisMethod
        let paths = crate.audioFiles.map { "\(crate.folderName)/\($0)" }.filter { path in
            guard let entry = loadedCache?.tracks[path], entry.analyzerVersion != "unanalysed-playback" else { return true }
            switch method {
            case .nativeModel:
                return entry.analyzerVersion != NativeRhythmTrackAnalyzer.analyzerVersion
            case .dsp:
                // Refresh older DSP results (e.g. pre-key ones); never downgrade a model analysis to DSP.
                return entry.analyzerVersion.hasPrefix("local-dsp") && entry.analyzerVersion != LocalTrackAnalyzer.analyzerVersion
            }
        }
        guard !paths.isEmpty else {
            statusMessage = "Every track in \(crate.title) is already analyzed."
            return
        }
        let batchID = UUID()
        let root = libraryRootURL
        crateBatchID = batchID
        crateAnalysisProgress = (0, paths.count)
        crateAnalysisTask = Task { [weak self] in
            for (index, path) in paths.enumerated() {
                guard let self, !Task.isCancelled, self.crateBatchID == batchID,
                      self.libraryRootURL.standardizedFileURL == root.standardizedFileURL else { break }
                let task = self.analyzeTrack(relativePath: path, method: method)
                self.crateCurrentTrackTask = task
                await task.value
                // Our run was cancelled by a manual Analyze elsewhere: stop the batch instead of fighting it.
                if task.isCancelled { break }
                guard self.crateBatchID == batchID else { break }
                self.crateAnalysisProgress = (index + 1, paths.count)
            }
            guard let self, self.crateBatchID == batchID else { return }
            self.finishCrateAnalysis()
        }
    }

    /// Stops a running crate analysis and the track it is analyzing; a separate user run is left alone.
    func cancelCrateAnalysis() {
        guard crateAnalysisTask != nil else { return }
        crateAnalysisTask?.cancel()
        if let current = crateCurrentTrackTask, current == analysisTask { current.cancel() }
        finishCrateAnalysis()
    }

    private func finishCrateAnalysis() {
        crateBatchID = nil
        crateAnalysisTask = nil
        crateCurrentTrackTask = nil
        crateAnalysisProgress = nil
    }

    /// Master playhead of a deck with a loaded track; read on demand by the UI, never published.
    /// True while a deck still sends music to the room (a track that played to its end does not count).
    var isMusicAudible: Bool {
        guard let coordinator = audioCoordinator else { return false }
        return coordinator.deckAGraph.isMasterAudible || coordinator.deckBGraph.isMasterAudible
    }

    func deckPlayheadSeconds(_ deck: DeckIdentifier) -> Double? {
        let graph = deck == .deckA ? audioCoordinator?.deckAGraph : audioCoordinator?.deckBGraph
        guard let graph, graph.loadedTrackURL != nil else { return nil }
        return graph.currentMasterPlayheadSeconds()
    }

    /// One bounded local analysis at a time; cache writes share the editor's persistence queue.
    /// Captures the requested analysis method (or selectedAnalysisMethod default) into the request identity.
    /// Cancels any existing in-flight task when a different method or re-analysis is requested.
    @discardableResult
    func analyzeTrack(relativePath: String, method: TrackAnalysisMethod? = nil) -> Task<Void, Never> {
        guard resolvedLibraryRootURL != nil else { return Task {} }
        let methodToUse = method ?? selectedAnalysisMethod
        if let existing = analysisTask {
            if isAnalyzingLibraryTrack && activeAnalysisPath == relativePath && activeAnalysisMethod[relativePath] == methodToUse {
                return existing
            }
            existing.cancel()
            // The cancelled task exits through its token guard without touching statuses, so settle it here.
            if let previous = activeAnalysisPath, previous != relativePath, analysisStatuses[previous] == .running {
                analysisStatuses[previous] = .failed("Analysis cancelled.")
            }
        }
        let root = libraryRootURL
        let selectedRevision = waveformEditorModel.interactionRevision
        let token = UUID()
        activeAnalysisToken = token
        activeAnalysisMethod[relativePath] = methodToUse
        activeAnalysisPath = relativePath
        isAnalyzingLibraryTrack = true
        analysisStatuses[relativePath] = .running

        let startMessage: String
        switch methodToUse {
        case .dsp:
            startMessage = "Analyzing locally with DSP: \(relativePath). Playback remains available."
        case .nativeModel:
            startMessage = "Analyzing with Native CoreML rhythm: \(relativePath). Playback remains available."
        }
        statusMessage = startMessage

        let task = Task { [weak self] in
            defer {
                if let self, self.activeAnalysisToken == token {
                    self.activeAnalysisToken = nil
                    self.activeAnalysisPath = nil
                    self.analysisTask = nil
                    self.isAnalyzingLibraryTrack = false
                }
            }
            do {
                let url = try LibraryTrackSource.url(relativePath: relativePath, root: root)
                let fingerprint = try LibraryTrackSource.fingerprint(at: url)
                // Detached work does not inherit cancellation; forward it so a superseded run stops early.
                let work: Task<TrackCacheEntry, Error>
                switch methodToUse {
                case .dsp:
                    work = Task.detached(priority: .utility) {
                        try LocalTrackAnalyzer().analyze(url: url, libraryRoot: root)
                    }
                case .nativeModel:
                    work = Task.detached(priority: .utility) {
                        try await NativeRhythmTrackAnalyzer().analyze(url: url, libraryRoot: root)
                    }
                }
                let entry = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                try Task.checkCancellation()
                guard let self, self.libraryRootURL.standardizedFileURL == root.standardizedFileURL else { return }
                guard self.activeAnalysisToken == token else { return }
                guard entry.fileFingerprint == fingerprint, try LibraryTrackSource.fingerprint(at: url) == fingerprint else {
                    throw LibraryTrackSource.Failure("The file changed during analysis. Analyze it again after the copy completes.")
                }
                try await self.waveformEditorModel.persistAnalyzedTrack(entry, libraryRootURL: root)
                guard !Task.isCancelled, self.libraryRootURL.standardizedFileURL == root.standardizedFileURL else { return }
                guard self.activeAnalysisToken == token else { return }

                self.analysisStatuses[relativePath] = .complete
                if let current = self.loadedCache?.tracks[relativePath] {
                    let currentIdentity = try LibraryTrackSource.identity(at: url)
                    for deck in [DeckIdentifier.deckA, .deckB] {
                        let graph = deck == .deckA ? self.audioCoordinator?.deckAGraph : self.audioCoordinator?.deckBGraph
                        guard graph?.loadedTrackURL?.standardizedFileURL == url.standardizedFileURL,
                              self.deckLoadedSourceIdentities[deck] == currentIdentity else { continue }
                        self.deckAnalysisValidationTasks[deck]?.cancel()
                        self.deckAnalysisValidationTasks[deck] = nil
                        self.deckAnalysisValidationIDs[deck] = nil
                        if deck == .deckA { self.deckATrack = current } else { self.deckBTrack = current }
                        self.deckLoadMessages[deck] = nil
                    }
                }
                if self.selectedTrackPath == relativePath,
                   !self.waveformEditorModel.hasActiveInteraction(since: selectedRevision, relativePath: relativePath, libraryRootURL: root),
                   let fresh = self.loadedCache?.tracks[relativePath] {
                    self.waveformEditorModel.updateLoadedTrack(fresh)
                }
                switch methodToUse {
                case .dsp:
                    self.statusMessage = "Local analysis ready: \(relativePath). Tempo is heuristic; key is not detected by DSP."
                case .nativeModel:
                    self.statusMessage = "Native rhythm analysis ready: \(relativePath). Tempo, phrase cues and key estimated on-device."
                }
            } catch {
                guard let self, self.libraryRootURL.standardizedFileURL == root.standardizedFileURL else { return }
                guard self.activeAnalysisToken == token else { return }
                let reason = error is CancellationError ? "Analysis cancelled." : error.localizedDescription
                self.analysisStatuses[relativePath] = .failed(reason)
                self.statusMessage = "\(methodToUse.displayName) analysis failed: \(reason)"
            }
        }
        analysisTask = task
        return task
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
            if deck == .deckA ? isDeckAPlaying : isDeckBPlaying { markPlayed(deck) }
            return
        }

        // Start coordinator on-demand if stopped; do not publish true against stopped engine
        if !coordinator.masterAudioEngine.isRunning {
            do {
                if let cueError = try coordinator.start(requireCue: false) {
                    self.coordinatorErrorMessage = Self.cueUnavailableMessage(cueError)
                    // Master is up, so an earlier start error in the status line is stale.
                    if statusMessage.hasPrefix("Audio Start Error:") || statusMessage.hasPrefix("Audio Startup Error:") {
                        statusMessage = "Audio engines running"
                    }
                }
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

        nonisolated(unsafe) var started = false
        let applied = performManualDeckMutation(deck: deck, action: .pause) { graph in
            if graph.isMasterPlaying {
                graph.pause()
            } else {
                graph.volume = 1
                graph.play()
                started = true
            }
        }
        if applied && started { markPlayed(deck) }
    }

    func markPlayedForTesting(_ path: String) { playedTonight.insert(path) }

    private func markPlayed(_ deck: DeckIdentifier) {
        if let path = (deck == .deckA ? deckATrack : deckBTrack)?.relativePath { playedTonight.insert(path) }
    }

    public func deckEQ(_ deck: DeckIdentifier) -> EQ3BandParameters { deck == .deckA ? deckAEQ : deckBEQ }

    /// True while transition automation drives the EQ. An armed AutoPilot leaves the knobs to the DJ.
    public var isEQAutomated: Bool {
        if case .inProgress = activeTransitionState { return true }
        return false
    }

    /// Manual channel EQ (HI / MID / LOW). Refused while a transition runs: its automation owns the EQ.
    @discardableResult
    public func setDeckEQ(deck: DeckIdentifier, eq: EQ3BandParameters) -> Bool {
        guard !isEQAutomated else { return false }
        guard eq != deckEQ(deck) else { return true }
        var applied = eq
        if let coordinator = audioCoordinator {
            // Decided on the control queue, the same queue that runs automation commands: a transition the UI
            // has not observed yet still wins.
            let gate = coordinator.transitionExecutionService.automationGate
            guard let result = coordinator.monitor.performOnControlQueue({ () -> EQ3BandParameters? in
                guard !gate.isActive else { return nil }
                let graph = deck == .deckA ? coordinator.deckAGraph : coordinator.deckBGraph
                graph.eqParameters = eq
                return graph.eqParameters // clamped
            }) else { return false }
            applied = result
        }
        if deck == .deckA { deckAEQ = applied } else { deckBEQ = applied }
        return true
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
        guard let root = resolvedLibraryRootURL, let coordinator = audioCoordinator else { return }
        beforeSoundboardPreloadForTesting?(root)
        coordinator.soundboardController.preload(from: root)
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
        pendingSafetyLockAutomationCommands += 1
        defer { pendingSafetyLockAutomationCommands -= 1 }
        do {
            guard let coordinator = audioCoordinator else {
                throw TransitionExecutionServiceError.invalidRequest("Audio coordinator unavailable")
            }
            let request = try makeTransitionRequest(coordinator: coordinator, autoPilot: false)
            let service = coordinator.transitionExecutionService
            if let beforeStart = safetyLockBeforeTransitionStartForTesting { await beforeStart() }
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
        pendingSafetyLockAutomationCommands += 1
        defer { pendingSafetyLockAutomationCommands -= 1 }
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
        pendingSafetyLockAutomationCommands += 1
        defer { pendingSafetyLockAutomationCommands -= 1 }
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
            let bpm = outgoingEntry.bpm.isFinite && (40...360).contains(outgoingEntry.bpm) ? outgoingEntry.bpm : 120.0
            let duration = Double(transitionPhraseBars) * outgoingEntry.beatsPerBar * 60.0 / bpm
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
        // The service keeps reporting `.completed` until the next transition; act once per generation.
        let completedJustNow = snapshot.state == .completed && snapshot.generation != queueHandledGeneration
        if completedJustNow { queueHandledGeneration = snapshot.generation }
        activeTransitionState = snapshot.state
        switch snapshot.state {
        case .armed, .inProgress:
            if let outgoing = snapshot.outgoingDeck { transitionOutgoingDeck = outgoing }
        case .completed:
            // The outgoing deck was stopped by the transition; line up the next track on it.
            // Counted at completion, so a cancelled transition does not mark the incoming track.
            if completedJustNow, let incoming = snapshot.incomingDeck { markPlayed(incoming) }
            if completedJustNow, let deck = transitionOutgoingDeck ?? snapshot.outgoingDeck, !upNext.isEmpty {
                loadUpNext(into: deck)
            }
            transitionOutgoingDeck = nil
        case .cancelled, .idle:
            transitionOutgoingDeck = nil
        }
        transitionProgress = min(max(snapshot.progress.isFinite ? snapshot.progress : 0.0, 0.0), 1.0)
        isAutoPilotArmed = snapshot.isAutoPilotArmed
        if let notice = snapshot.autoPilotNotice, !snapshot.isAutoPilotArmed {
            transitionErrorMessage = notice
        }
        if let coordinator = audioCoordinator {
            isDeckAPlaying = coordinator.deckAGraph.isMasterPlaying
            isDeckBPlaying = coordinator.deckBGraph.isMasterPlaying
            // Transition automation moves the EQ; the knobs must show where it left them.
            let eqA = coordinator.deckAGraph.eqParameters, eqB = coordinator.deckBGraph.eqParameters
            if eqA != deckAEQ { deckAEQ = eqA }
            if eqB != deckBEQ { deckBEQ = eqB }
            crossfaderPosition = coordinator.crossfaderPosition
        }
    }

    private func stopTransitionObservation() {
        transitionObservationTask?.cancel()
        transitionObservationTask = nil
    }

    // MARK: - Up Next

    /// The command that observed completion still holds the automation token, so wait for it to finish.
    private func loadUpNext(into deck: DeckIdentifier) {
        let finishedTrack = (deck == .deckA ? deckATrack : deckBTrack)?.relativePath
        upNextLoadTask?.cancel()
        upNextLoadTask = Task { @MainActor [weak self] in
            for _ in 0..<250 {
                guard let self, !Task.isCancelled else { return }
                if self.pendingSafetyLockAutomationCommands == 0 { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard let self, !Task.isCancelled, self.pendingSafetyLockAutomationCommands == 0,
                  !self.isTransitionBusy, let next = self.upNext.first else { return }
            // A track the DJ loaded meanwhile wins over the queue.
            guard (deck == .deckA ? self.deckATrack : self.deckBTrack)?.relativePath == finishedTrack else { return }
            // Automatic loads never replace a deck that plays or is audible, whatever the Safety Lock says.
            let graph = deck == .deckA ? self.audioCoordinator?.deckAGraph : self.audioCoordinator?.deckBGraph
            guard graph?.isMasterPlaying == false, !self.isMasterDeckOnAir(deck) else { return }
            guard self.startTrackLoad(relativePath: next, deck: deck) else { return }
            await self.waitForPendingDeckLoad(deck: deck)
            // A track that failed to load must not block the queue behind it; the deck shows why.
            // A load the DJ superseded meanwhile succeeds and clears the message, so it is not a failure.
            if self.deckLoadRequestIDs[deck] == nil, self.deckLoadMessage(for: deck) != nil,
               (deck == .deckA ? self.deckATrack : self.deckBTrack)?.relativePath != next, self.upNext.first == next {
                self.upNext.removeFirst()
                self.statusMessage = "Up Next skipped \(LibraryTrackTitle.display((next as NSString).lastPathComponent)): it could not be loaded."
            }
        }
    }

    /// Analysis of the track that plays right before Up Next entry `index`:
    /// the previous queue entry, else the loaded deck waiting to play, else the deck on air.
    /// With nothing playing, the only loaded deck counts; two idle loaded decks are ambiguous.
    func upNextPredecessor(at index: Int) -> TrackCacheEntry? {
        guard upNext.indices.contains(index) else { return nil }
        if index > 0 { return loadedCache?.tracks[upNext[index - 1]] }
        let playing: TrackCacheEntry? = isDeckAPlaying ? deckATrack : (isDeckBPlaying ? deckBTrack : nil)
        let waiting: TrackCacheEntry? = isDeckAPlaying ? deckBTrack : (isDeckBPlaying ? deckATrack : nil)
        let idle = [deckATrack, deckBTrack].compactMap { $0 }
        let path = (waiting ?? playing ?? (idle.count == 1 ? idle.first : nil))?.relativePath
        return path.flatMap { loadedCache?.tracks[$0] }
    }

    /// True when analysis proves Up Next entry `index` clashes in key or tempo with the track before it.
    public func upNextNeedsBridge(at index: Int) -> Bool {
        guard let previous = upNextPredecessor(at: index),
              let next = loadedCache?.tracks[upNext[index]] else { return false }
        return BridgeFinder.needsBridge(from: previous, to: next)
    }

    /// Inserts the best-fitting library track before a clashing entry. Searched on demand, not per frame.
    @discardableResult
    public func insertBridge(before relativePath: String) -> Bool {
        // By path, not row index: the queue may have changed since the row was drawn.
        guard let index = upNext.firstIndex(of: relativePath), let previous = upNextPredecessor(at: index),
              let next = loadedCache?.tracks[upNext[index]] else { return false }
        let planned = playedTonight.union(upNext + [deckATrack?.relativePath, deckBTrack?.relativePath].compactMap { $0 })
        let candidates = (loadedCache?.tracks.values).map { $0.filter { !planned.contains($0.relativePath) } } ?? []
        guard let bridge = BridgeFinder.bestBridge(from: previous, to: next, candidates: candidates) else {
            statusMessage = "No analyzed track fits between these two in key and tempo."
            return false
        }
        upNext.insert(bridge.relativePath, at: index)
        return true
    }

    public func addToUpNext(_ relativePath: String) {
        guard !upNext.contains(relativePath) else { return }
        upNext.append(relativePath)
    }

    /// A guest request jumps the line: it becomes the next track to load.
    public func playNext(_ relativePath: String) {
        upNext.removeAll { $0 == relativePath }
        upNext.insert(relativePath, at: 0)
    }

    public func removeFromUpNext(_ relativePath: String) {
        upNext.removeAll { $0 == relativePath }
    }

    /// Same contract as SwiftUI's `onMove`: `destination` indexes the list before removal.
    public func moveUpNext(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.filter { upNext.indices.contains($0) }.map { upNext[$0] }
        var rest = upNext.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: min(max(insertAt, 0), rest.count))
        upNext = rest
    }

    // MARK: - Library Audition & Headphone Cue Preview

    /// Loads a library track into the headphone audition preview player on the Cue audio engine.
    /// Runs audio file I/O off the MainActor to prevent UI hitches, and tracks generation to drop stale loads.
    @discardableResult
    public func loadPreviewTrack(relativePath: String, playWhenReady: Bool = false) -> Task<Void, Never> {
        guard resolvedLibraryRootURL != nil else { return Task {} }
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

    /// Presents the native folder chooser. Cancel and automation ownership leave the library untouched.
    public func openLibrary() {
        guard canOpenLibrary, let chosen = chooseLibraryDirectory() else { return }
        // The modal panel runs a nested event loop; recheck ownership when it returns.
        guard canOpenLibrary else { return }
        do {
            let root = try LibraryLocation.validate(chosen)
            libraryLocationStore?.remember(root)
            updateLibraryRootURL(root)
        } catch {
            libraryLocationError = error.localizedDescription
        }
    }

    /// Updates the library root URL and resets any audition preview state.
    public func updateLibraryRootURL(_ newURL: URL) {
        libraryLaunchIssue = nil
        libraryLocationError = nil
        self.libraryRootURL = newURL
        self.waveformEditorModel.updateLibraryRoot(newURL)
        upNextLoadTask?.cancel()
        isRestoringSet = true // clearing must not overwrite the new folder's saved set
        upNext = []
        playedTonight = []
        isRestoringSet = false
        restoreSet()
        refreshLibrary()
    }
}
