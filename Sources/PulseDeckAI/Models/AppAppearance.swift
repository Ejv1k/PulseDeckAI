import SwiftUI

/// Studio look: follow macOS, or force Light or Dark. The projector ignores it and stays dark.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String { self == .system ? "System" : rawValue.capitalized }
    var colorScheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
}
