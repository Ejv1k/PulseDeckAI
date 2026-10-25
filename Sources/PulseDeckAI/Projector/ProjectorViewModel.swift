import SwiftUI
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
    @Published public var isWindowOpen: Bool = false
    @Published public var isFullscreen: Bool = false
    @Published public var eventBannerText: String = "Sarah & Michael's Wedding — October 14, 2026"
    @Published public var isBannerEditorPresented: Bool = false

    // Mode 1: Spectrum Visualizer State
    @Published public private(set) var visualizerFrame: ProjectorVisualizerFrame = .zero
    public let spectrumAnalyzer = ProjectorSpectrumAnalyzer()

    // Mode 2: Media Slideshow & Muted Looping Video Service
    public let mediaService = ProjectorMediaService()
    private var slideshowTimer: Timer?

    // Mode 3: Now Playing Metadata State
    @Published public private(set) var nowPlayingMetadata: ProjectorNowPlayingMetadata = .idle

    // Window Management
    private var windowController: ProjectorWindowController?

    public init() {
        self.windowController = ProjectorWindowController(viewModel: self)
    }

    deinit {
        // Timers and players are invalidated on teardown.
    }

    // MARK: - Mode Switching (Keys 1–4)

    /// Switches the active projector presentation mode.
    public func setMode(_ mode: ProjectorMode) {
        guard currentMode != mode else { return }
        self.currentMode = mode
    }

    private func handleModeChanged(from oldMode: ProjectorMode, to newMode: ProjectorMode) {
        if oldMode == .mediaSlideshow && newMode != .mediaSlideshow {
            stopSlideshowTimer()
        } else if newMode == .mediaSlideshow {
            startSlideshowTimer()
        }
    }

    // MARK: - Spectrum Visualizer (Mode 1)

    /// Polls the master audio meter snapshot from AppState and updates the 24-band spectrum visualizer.
    public func updateVisualizer(from appState: AppState) {
        let snapshot = appState.meterSnapshot(for: .master)
        self.visualizerFrame = spectrumAnalyzer.processSnapshot(snapshot)
    }

    // MARK: - Media Slideshow (Mode 2)

    /// Starts scanning and preloading media from `09_Visual_Backgrounds_Media`.
    public func updateLibraryRoot(_ url: URL) {
        mediaService.setLibraryRoot(url)
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
        slideshowTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentMode == .mediaSlideshow else { return }
                // Only advance automatically if current item is a photo (videos loop themselves)
                if let item = self.mediaService.items.indices.contains(self.mediaService.currentIndex) ? self.mediaService.items[self.mediaService.currentIndex] : nil {
                    if item.type == .photo {
                        self.mediaService.nextMediaItem()
                    }
                }
            }
        }
    }

    private func stopSlideshowTimer() {
        slideshowTimer?.invalidate()
        slideshowTimer = nil
    }

    // MARK: - Now Playing Metadata (Mode 3)

    /// Determines current Master deck and updates Now Playing card metadata.
    public func updateNowPlaying(from appState: AppState) {
        let activeDeck = Self.determineMasterDeck(
            isDeckAPlaying: appState.isDeckAPlaying,
            isDeckBPlaying: appState.isDeckBPlaying,
            crossfaderPosition: appState.crossfaderPosition
        )

        let isPlaying = appState.isDeckAPlaying || appState.isDeckBPlaying
        guard let deck = activeDeck else {
            self.nowPlayingMetadata = ProjectorNowPlayingMetadata(
                title: "PulseDeck AI",
                artist: "Ready to Play",
                deck: nil,
                bpm: nil,
                musicalKey: nil,
                durationSeconds: nil,
                isMasterPlaying: false
            )
            return
        }

        let track = (deck == .deckA) ? appState.deckATrack : appState.deckBTrack
        guard let entry = track else {
            self.nowPlayingMetadata = ProjectorNowPlayingMetadata(
                title: "Deck \(deck.rawValue.capitalized)",
                artist: "No Track Loaded",
                deck: deck,
                bpm: nil,
                musicalKey: nil,
                durationSeconds: nil,
                isMasterPlaying: isPlaying
            )
            return
        }

        let parsed = Self.parseArtistAndTitle(from: entry.relativePath)
        self.nowPlayingMetadata = ProjectorNowPlayingMetadata(
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
        windowController = nil
        isWindowOpen = false
    }
}
