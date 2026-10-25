import SwiftUI
import Combine
import AppKit
import AVFoundation
import PulseDeckCore

/// Central MainActor observable view model managing the secondary Projector display state,
/// mode selection (Keys 1–4), media playback, real-time FFT projection, and Now Playing card.
///
/// Guaranteed invariants:
/// - Stores projector state in a separate object without adding new stored properties to `AppState`.
/// - Mode changes and blackout NEVER alter audio gains, crossfader, talkover, or Cue audition.
/// - FFT projection consumes existing `AppState.meterSnapshot(for: .master)` with zero audio RT allocation.
/// - Muted background videos guarantee zero audio leakage to Master or Cue buses.
/// - Cancels stale background tasks and releases resources on mode switch, window close, or teardown.
@MainActor
public final class ProjectorViewModel: ObservableObject {
    @Published public var currentMode: ProjectorMode = .fftVisualizer {
        didSet {
            handleModeChanged(from: oldValue, to: currentMode)
        }
    }
    @Published public var isWindowOpen: Bool = false {
        didSet { if oldValue != isWindowOpen { synchronizeMediaActivity() } }
    }
    @Published public var isFullscreen: Bool = false
    @Published public var eventBannerText: String = "Sarah & Michael's Wedding — October 14, 2026"
    @Published public var isBannerEditorPresented: Bool = false

    // Mode 1: Spectrum Visualizer State
    @Published public private(set) var visualizerFrame: ProjectorVisualizerFrame = .zero
    public let spectrumAnalyzer = ProjectorSpectrumAnalyzer()

    // Mode 2: Media Slideshow & Muted Looping Video Service
    public let mediaService = ProjectorMediaService()
    private let slideshowInterval: Duration
    private var slideshowTask: Task<Void, Never>?
    private var mediaChanges: AnyCancellable?
    var isSlideshowRunning: Bool { slideshowTask != nil }

    // Mode 3: Now Playing Metadata State
    @Published public private(set) var nowPlayingMetadata: ProjectorNowPlayingMetadata = .idle

    // Window Management
    private var windowController: ProjectorWindowController?

    public init(slideshowInterval: Duration = .seconds(8)) {
        self.slideshowInterval = slideshowInterval
        self.windowController = ProjectorWindowController(viewModel: self)
        mediaChanges = mediaService.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    deinit {
        // Timers and players are invalidated on teardown.
        slideshowTask?.cancel()
    }

    // MARK: - Mode Switching (Keys 1–4)

    /// Switches the active projector presentation mode.
    public func setMode(_ mode: ProjectorMode) {
        guard currentMode != mode else { return }
        self.currentMode = mode
    }

    private func handleModeChanged(from oldMode: ProjectorMode, to newMode: ProjectorMode) {
        guard oldMode != newMode else { return }
        synchronizeMediaActivity()
    }

    private func synchronizeMediaActivity() {
        let active = isWindowOpen && currentMode == .mediaSlideshow
        mediaService.setPresentationActive(active)
        if active { startSlideshowTimer() }
        else { stopSlideshowTimer() }
    }

    // MARK: - Spectrum Visualizer (Mode 1)

    /// Reads the shared UI cache without draining the audio meter queue.
    public func updateVisualizer(from appState: AppState) {
        updateVisualizer(snapshot: AudioMeterSnapshotDistributor.shared(for: appState).master)
    }

    func updateVisualizer(snapshot: AudioMeterSnapshot?) {
        let frame = spectrumAnalyzer.processSnapshot(snapshot)
        if frame != visualizerFrame { visualizerFrame = frame }
    }

    /// Runs outside view construction. SwiftUI cancels this task on mode change or window removal.
    func runPresentationUpdates(from appState: AppState) async {
        switch currentMode {
        case .fftVisualizer:
            let meters = AudioMeterSnapshotDistributor.shared(for: appState)
            async let _: Void = meters.observe()
            while !Task.isCancelled, isWindowOpen, currentMode == .fftVisualizer {
                updateVisualizer(snapshot: meters.master)
                do { try await Task.sleep(for: .seconds(1.0 / 30.0)) }
                catch { break }
            }
            // Leaving this scope cancels the child subscription, including the final polling owner.
        case .nowPlaying:
            while !Task.isCancelled, isWindowOpen, currentMode == .nowPlaying {
                updateNowPlaying(from: appState)
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { break }
            }
        case .mediaSlideshow, .blackout:
            break
        }
    }

    // MARK: - Media Slideshow (Mode 2)

    /// Starts scanning and preloading media from `09_Visual_Backgrounds_Media`.
    public func updateLibraryRoot(_ url: URL) {
        mediaService.setLibraryRoot(url)
    }

    /// Shared toolbar/menu action. Concurrent shortcut routes must produce only one refresh.
    public func refreshLibrary(from appState: AppState) {
        guard !appState.isScanning else { return }
        appState.refreshLibrary()
        rescanMedia()
    }

    /// Explicit refresh also discovers assets added beneath an unchanged library root.
    public func rescanMedia() {
        mediaService.rescan()
    }

    /// Advances to next media item manually or automatically.
    public func nextSlide() {
        mediaService.nextMediaItem()
    }

    /// Moves to previous media item.
    public func previousSlide() {
        mediaService.previousMediaItem()
    }

    private func startSlideshowTimer() {
        stopSlideshowTimer()
        let interval = slideshowInterval
        slideshowTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) }
                catch { return }
                guard !Task.isCancelled else { return }
                self?.advanceSlideshowIfNeeded()
            }
        }
    }

    func advanceSlideshowIfNeeded() {
        guard isWindowOpen, currentMode == .mediaSlideshow else { return }
        // Only advance automatically if current item is a photo (videos loop themselves)
        if mediaService.items.indices.contains(mediaService.currentIndex),
           mediaService.items[mediaService.currentIndex].type == .photo {
            mediaService.nextMediaItem()
        }
    }

    private func stopSlideshowTimer() {
        slideshowTask?.cancel()
        slideshowTask = nil
    }

    // MARK: - Now Playing Metadata (Mode 3)

    /// Determines current Master deck and updates Now Playing card metadata.
    public func updateNowPlaying(from appState: AppState) {
        let metadata = nowPlayingMetadata(from: appState)
        if metadata != nowPlayingMetadata { nowPlayingMetadata = metadata }
    }

    private func nowPlayingMetadata(from appState: AppState) -> ProjectorNowPlayingMetadata {
        let activeDeck = Self.determineMasterDeck(
            isDeckAPlaying: appState.isDeckAPlaying,
            isDeckBPlaying: appState.isDeckBPlaying,
            crossfaderPosition: appState.crossfaderPosition
        )

        let isPlaying = appState.isDeckAPlaying || appState.isDeckBPlaying
        guard let deck = activeDeck else {
            return ProjectorNowPlayingMetadata(
                title: "PulseDeck AI",
                artist: "Ready to Play",
                deck: nil,
                bpm: nil,
                musicalKey: nil,
                durationSeconds: nil,
                isMasterPlaying: false
            )
        }

        let track = (deck == .deckA) ? appState.deckATrack : appState.deckBTrack
        guard let entry = track else {
            return ProjectorNowPlayingMetadata(
                title: "Deck \(deck.rawValue.capitalized)",
                artist: "No Track Loaded",
                deck: deck,
                bpm: nil,
                musicalKey: nil,
                durationSeconds: nil,
                isMasterPlaying: isPlaying
            )
        }

        let parsed = Self.parseArtistAndTitle(from: entry.relativePath)
        return ProjectorNowPlayingMetadata(
            title: parsed.title,
            artist: parsed.artist,
            deck: deck,
            bpm: entry.bpm > 0 ? entry.bpm : nil,
            musicalKey: entry.musicalKey.isEmpty ? nil : entry.musicalKey,
            durationSeconds: entry.duration > 0 ? entry.duration : nil,
            isMasterPlaying: isPlaying
        )
    }

    /// Determines which deck is currently broadcasting to the Master PA.
    public static func determineMasterDeck(
        isDeckAPlaying: Bool,
        isDeckBPlaying: Bool,
        crossfaderPosition: Float
    ) -> DeckIdentifier? {
        if isDeckAPlaying && !isDeckBPlaying {
            return .deckA
        } else if isDeckBPlaying && !isDeckAPlaying {
            return .deckB
        } else if isDeckAPlaying && isDeckBPlaying {
            return crossfaderPosition <= 0.5 ? .deckA : .deckB
        }
        return nil
    }

    /// Extracts track title and artist from relative path or filename.
    public static func parseArtistAndTitle(from relativePath: String) -> (artist: String, title: String) {
        let fileName = URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
        guard !fileName.isEmpty else {
            return (artist: "PulseDeck AI", title: "Untitled Track")
        }

        // Common DJ filename convention: "Artist - Title"
        let parts = fileName.components(separatedBy: " - ")
        if parts.count >= 2 {
            let artist = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let title = parts[1...].joined(separator: " - ").trimmingCharacters(in: .whitespacesAndNewlines)
            return (artist: artist.isEmpty ? "Unknown Artist" : artist,
                    title: title.isEmpty ? fileName : title)
        }

        // Alternative convention: "Artist _ Title"
        let underscoreParts = fileName.components(separatedBy: " _ ")
        if underscoreParts.count >= 2 {
            let artist = underscoreParts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let title = underscoreParts[1...].joined(separator: " _ ").trimmingCharacters(in: .whitespacesAndNewlines)
            return (artist: artist.isEmpty ? "Unknown Artist" : artist,
                    title: title.isEmpty ? fileName : title)
        }

        return (artist: "PulseDeck AI", title: fileName)
    }

    // MARK: - Window Management

    public func showWindow(appState: AppState) {
        windowController?.showProjectorWindow(appState: appState)
    }

    public func closeWindow() {
        windowController?.closeProjectorWindow()
    }

    public func toggleWindow(appState: AppState) {
        windowController?.toggleProjectorWindow(appState: appState)
    }

    public func toggleFullscreen() {
        windowController?.toggleFullscreen()
    }

    // MARK: - Teardown & Resource Cleanup

    /// Fully cleans up all resources, video players, and timers.
    public func teardown() {
        stopSlideshowTimer()
        mediaService.teardown()
        spectrumAnalyzer.reset()
        windowController?.closeProjectorWindow()
        isWindowOpen = false
    }
}
