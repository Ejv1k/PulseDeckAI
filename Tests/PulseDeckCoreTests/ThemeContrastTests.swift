import XCTest
@testable import PulseDeckAI

/// WCAG 2.x contrast: text colours must reach 4.5:1 on every surface they sit on, in Light and in Dark.
final class ThemeContrastTests: XCTestCase {
    private func luminance(_ c: ThemeColor.RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    private func ratio(_ a: ThemeColor.RGB, _ b: ThemeColor.RGB) -> Double {
        let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (hi + 0.05) / (lo + 0.05)
    }

    func testTextAndAccentsReadOnEverySurface() {
        typealias P = DJTheme.Palette
        let text: [(String, ThemeColor)] = [
            ("textPrimary", P.textPrimary), ("textSecondary", P.textSecondary), ("textMuted", P.textMuted),
            ("textAccent", P.textAccent), ("deckA", P.deckA), ("deckB", P.deckB), ("master", P.master),
            ("cue", P.cue), ("statusWarning", P.statusWarning), ("statusError", P.statusError),
            ("statusSuccess", P.statusSuccess)]
        let surfaces: [(String, ThemeColor)] = [
            ("background", P.background), ("cardBackground", P.cardBackground),
            ("cardHeader", P.cardHeader), ("surfaceRaised", P.surfaceRaised), ("surfaceActive", P.surfaceActive)]
        for (name, fg) in text {
            for (surfaceName, bg) in surfaces {
                XCTAssertGreaterThanOrEqual(ratio(fg.light, bg.light), 4.5, "\(name) on \(surfaceName), light")
                XCTAssertGreaterThanOrEqual(ratio(fg.dark, bg.dark), 4.5, "\(name) on \(surfaceName), dark")
            }
        }
    }

    func testBordersAreVisible() {
        typealias P = DJTheme.Palette
        XCTAssertGreaterThanOrEqual(ratio(P.borderActive.light, P.cardBackground.light), 3)
        XCTAssertGreaterThanOrEqual(ratio(P.borderActive.dark, P.cardBackground.dark), 1.5, "Dark borders stay subtle")
    }
}
