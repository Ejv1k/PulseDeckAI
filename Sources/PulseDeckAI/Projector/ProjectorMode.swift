import Foundation

/// Four real-time presentation modes supported by the secondary projector window.
public enum ProjectorMode: Int, CaseIterable, Identifiable, Sendable {
    /// Mode 1 (Key 1): Real-time multi-band FFT audio spectrum visualizer responding to Master output.
    case fftVisualizer = 1

    /// Mode 2 (Key 2): Ambient Ken Burns photo slideshow and muted looping video backgrounds from `09_Visual_Backgrounds_Media`.
    case mediaSlideshow = 2

    /// Mode 3 (Key 3): Elegant Now Playing metadata card (title/artist) with customizable event banner.
    case nowPlaying = 3

    /// Mode 4 (Key 4): True blackout screen without controls for speeches, toasts, or venue downtime.
    case blackout = 4

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .fftVisualizer:
            return "FFT Spectrum Visualizer"
        case .mediaSlideshow:
            return "Media Slideshow"
        case .nowPlaying:
            return "Now Playing & Banner"
        case .blackout:
            return "Blackout Screen"
        }
    }

    public var keyLabel: String {
        String(rawValue)
    }

    public var modeDescription: String {
        switch self {
        case .fftVisualizer:
            return "Multi-band audio visualizer dancing to dancefloor Master output"
        case .mediaSlideshow:
            return "Ambient photo slideshow with Ken Burns effect and muted video loops"
        case .nowPlaying:
            return "On-air track title, artist, and wedding/event title banner"
        case .blackout:
            return "Solid black display with zero controls or light leakage"
        }
    }
}
