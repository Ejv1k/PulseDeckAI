import SwiftUI

/// High-contrast dark theme design system for PulseDeck AI.
public enum DJTheme {
    public static let background = Color(red: 0.04, green: 0.04, blue: 0.06)
    public static let cardBackground = Color(red: 0.08, green: 0.09, blue: 0.12)
    public static let cardHeader = Color(red: 0.11, green: 0.12, blue: 0.16)
    public static let border = Color(red: 0.16, green: 0.18, blue: 0.24)

    // Deck Accents
    public static let deckA = Color(red: 0.00, green: 0.90, blue: 1.00) // Electric Cyan
    public static let deckB = Color(red: 1.00, green: 0.43, blue: 0.00) // Neon Orange
    public static let master = Color(red: 0.00, green: 0.90, blue: 0.46) // Emerald Green
    public static let cue = Color(red: 1.00, green: 0.84, blue: 0.00) // Gold Amber

    // Typography Colors
    public static let textPrimary = Color.white
    public static let textSecondary = Color(red: 0.65, green: 0.68, blue: 0.76)
    public static let textMuted = Color(red: 0.42, green: 0.45, blue: 0.54)
    public static let textAccent = Color(red: 0.38, green: 0.65, blue: 1.00)

    // Elevated Studio Surfaces
    public static let surfaceRaised = Color(red: 0.10, green: 0.11, blue: 0.15)
    public static let surfaceActive = Color(red: 0.14, green: 0.15, blue: 0.20)
    public static let borderActive = Color(red: 0.24, green: 0.27, blue: 0.36)
}

/// Tactile button style providing responsive scale feedback on press (Emil Kowalski / Apple Design).
public struct StudioPressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
