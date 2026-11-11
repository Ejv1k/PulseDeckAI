import SwiftUI

/// An sRGB colour with a light and a dark variant; the variant follows the window's appearance.
public struct ThemeColor: Sendable {
    public typealias RGB = (r: Double, g: Double, b: Double)
    public let light: RGB
    public let dark: RGB

    public var color: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        })
    }
}

/// Look of the whole app. System/Light/Dark is chosen in View > Appearance; the projector always stays dark.
public enum DJTheme {
    // Palette: the single source for colours and the WCAG contrast test.
    public enum Palette {
        public static let background = ThemeColor(light: (0.95, 0.95, 0.97), dark: (0.04, 0.04, 0.06))
        public static let cardBackground = ThemeColor(light: (1.00, 1.00, 1.00), dark: (0.08, 0.09, 0.12))
        public static let cardHeader = ThemeColor(light: (0.93, 0.94, 0.96), dark: (0.11, 0.12, 0.16))
        public static let border = ThemeColor(light: (0.80, 0.82, 0.87), dark: (0.16, 0.18, 0.24))
        public static let deckA = ThemeColor(light: (0.00, 0.40, 0.55), dark: (0.00, 0.90, 1.00)) // Cyan
        public static let deckB = ThemeColor(light: (0.68, 0.26, 0.00), dark: (1.00, 0.43, 0.00)) // Orange
        public static let master = ThemeColor(light: (0.00, 0.45, 0.22), dark: (0.00, 0.90, 0.46)) // Green
        public static let cue = ThemeColor(light: (0.52, 0.38, 0.00), dark: (1.00, 0.84, 0.00)) // Amber
        public static let textPrimary = ThemeColor(light: (0.07, 0.08, 0.11), dark: (1.00, 1.00, 1.00))
        public static let textSecondary = ThemeColor(light: (0.28, 0.31, 0.38), dark: (0.65, 0.68, 0.76))
        public static let textMuted = ThemeColor(light: (0.38, 0.41, 0.48), dark: (0.57, 0.60, 0.68))
        public static let textAccent = ThemeColor(light: (0.05, 0.33, 0.78), dark: (0.38, 0.65, 1.00))
        public static let surfaceRaised = ThemeColor(light: (0.97, 0.97, 0.99), dark: (0.10, 0.11, 0.15))
        public static let surfaceActive = ThemeColor(light: (0.90, 0.92, 0.96), dark: (0.14, 0.15, 0.20))
        public static let borderActive = ThemeColor(light: (0.50, 0.54, 0.62), dark: (0.24, 0.27, 0.36))
        public static let statusWarning = ThemeColor(light: (0.60, 0.29, 0.00), dark: (1.00, 0.62, 0.04))
        public static let statusError = ThemeColor(light: (0.78, 0.10, 0.10), dark: (1.00, 0.35, 0.35))
        public static let statusSuccess = ThemeColor(light: (0.04, 0.48, 0.24), dark: (0.20, 0.85, 0.50))
    }

    public static let background = Palette.background.color
    public static let cardBackground = Palette.cardBackground.color
    public static let cardHeader = Palette.cardHeader.color
    public static let border = Palette.border.color

    // Deck Accents
    public static let deckA = Palette.deckA.color
    public static let deckB = Palette.deckB.color
    public static let master = Palette.master.color
    public static let cue = Palette.cue.color

    // Typography Colors
    public static let textPrimary = Palette.textPrimary.color
    public static let textSecondary = Palette.textSecondary.color
    public static let textMuted = Palette.textMuted.color
    public static let textAccent = Palette.textAccent.color

    // Elevated Studio Surfaces
    public static let surfaceRaised = Palette.surfaceRaised.color
    public static let surfaceActive = Palette.surfaceActive.color
    public static let borderActive = Palette.borderActive.color

    // Semantic Status Colors
    public static let statusWarning = Palette.statusWarning.color
    public static let statusError = Palette.statusError.color
    public static let statusSuccess = Palette.statusSuccess.color

    // Studio Layout Foundations
    public static let controlRadius: CGFloat = 4
    public static let cardRadius: CGFloat = 6
    public static let chipRadius: CGFloat = 3
    public static let minTouchTarget: CGFloat = 28
}

/// Tactile button style providing responsive scale feedback on press (Emil Kowalski / Apple Design).
public struct StudioPressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}
