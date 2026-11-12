import SwiftUI
import PulseDeckCore

/// Vertical EQ fader: the notch in the middle is 0 dB, the bottom is a -24 dB kill, the top +6 dB.
/// Drag up or down from anywhere on it (it moves by the distance dragged and never jumps to the click),
/// double-click to reset, VoiceOver steps 1 dB.
struct EQFader: View {
    let label: String
    let gainDB: Float
    let color: Color
    let isEnabled: Bool
    let onChange: (Float) -> Void

    static let minDB: Float = -24, maxDB: Float = 6
    private static let trackHeight: CGFloat = 72
    /// Thumb big enough to grab on a trackpad without looking.
    private static let thumbSize = CGSize(width: 34, height: 20)
    /// Drag distance for the whole -24...+6 dB range, larger than the drawn track so a quick trackpad
    /// flick cannot slam a band to +6 dB: the boost half needs 80 pt, the cut side moves 0.3 dB per point.
    static let dragTravel: CGFloat = 160

    @GestureState private var dragStart: Double? // Resets itself even when a drag is cancelled.

    /// Unequal halves, like real mixers: the cut side gets as much travel as the boost side.
    static func position(for gain: Float) -> Double {
        gain <= 0 ? 0.5 * Double(1 - gain / minDB) : 0.5 + 0.5 * Double(gain / maxDB)
    }

    static func gain(for position: Double) -> Float {
        let p = min(max(position, 0), 1)
        return p <= 0.5 ? minDB * Float(1 - 2 * p) : maxDB * Float(2 * p - 1)
    }

    /// Gain after dragging `translation` points (down is positive) from travel `start`.
    static func gain(dragging translation: CGFloat, from start: Double) -> Float {
        let next = start - Double(translation / dragTravel)
        // Detent at 0 dB (in travel, not dB: the two halves have different dB per point).
        return abs(next - 0.5) < 0.03 ? 0 : gain(for: next)
    }

    private var position: Double { Self.position(for: gainDB) }
    private var isKilled: Bool { gainDB <= Self.minDB }
    private var valueText: String {
        if isKilled { return "KILL" }
        if abs(gainDB) < 0.05 { return "0" }
        return String(format: "%+.1f", gainDB)
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DJTheme.textSecondary)
                Text(valueText)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundColor(isKilled ? DJTheme.statusError : DJTheme.textSecondary)
            }
            track
                .frame(width: 56, height: Self.trackHeight + Self.thumbSize.height)
                .allowsHitTesting(isEnabled)
                .contentShape(Rectangle())
                .padding(.bottom, 4) // A killed band's thumb must not touch the Play row.
                .gesture(drag)
                .simultaneousGesture(TapGesture(count: 2).onEnded { if isEnabled { onChange(0) } })
        }
        .opacity(isEnabled ? 1 : 0.45)
        .help("\(label) EQ: drag up or down, double-click resets to 0 dB. All the way down kills the band.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) EQ")
        .accessibilityValue(isKilled ? "Killed" : String(format: "%.1f decibels", gainDB))
        .accessibilityAction(named: "Reset to 0 dB") { if isEnabled { onChange(0) } }
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: onChange(min(Self.maxDB, gainDB + 1))
            case .decrement: onChange(max(Self.minDB, gainDB - 1))
            @unknown default: break
            }
        }
    }

    private var track: some View {
        let thumbY = (1 - position) * Self.trackHeight // 0 = top of the travel
        return ZStack(alignment: .top) {
            let inset = Self.thumbSize.height / 2
            Capsule().fill(DJTheme.border).frame(width: 5, height: Self.trackHeight).offset(y: inset)
            Rectangle().fill(DJTheme.textMuted).frame(width: 18, height: 1)
                .offset(y: inset - 0.5 + Self.trackHeight / 2) // The 0 dB notch.
            Capsule().fill(isKilled ? DJTheme.statusError : color)
                .frame(width: 5, height: abs(Self.trackHeight / 2 - thumbY))
                .offset(y: inset + min(thumbY, Self.trackHeight / 2))
            RoundedRectangle(cornerRadius: 4).fill(DJTheme.textPrimary)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(DJTheme.borderActive, lineWidth: 1))
                .overlay(Rectangle().fill(DJTheme.background.opacity(0.6)).frame(width: 18, height: 1.5)) // Grip line.
                .frame(width: Self.thumbSize.width, height: Self.thumbSize.height)
                .offset(y: thumbY)
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 3)
            .updating($dragStart) { _, start, _ in
                if start == nil { start = position }
            }
            .onChanged { value in
                guard isEnabled else { return }
                onChange(Self.gain(dragging: value.translation.height, from: dragStart ?? position))
            }
    }
}

/// HI / MID / LOW strip for one deck channel.
struct DeckEQStrip: View {
    @ObservedObject var appState: AppState
    let deck: DeckIdentifier
    let color: Color

    var body: some View {
        let eq = appState.deckEQ(deck)
        let enabled = !appState.isEQAutomated
        HStack(spacing: 10) {
            EQFader(label: "HI", gainDB: eq.highGainDB, color: color, isEnabled: enabled) { value in
                var next = appState.deckEQ(deck); next.highGainDB = value
                appState.setDeckEQ(deck: deck, eq: next)
            }
            EQFader(label: "MID", gainDB: eq.midGainDB, color: color, isEnabled: enabled) { value in
                var next = appState.deckEQ(deck); next.midGainDB = value
                appState.setDeckEQ(deck: deck, eq: next)
            }
            EQFader(label: "LOW", gainDB: eq.lowGainDB, color: color, isEnabled: enabled) { value in
                var next = appState.deckEQ(deck); next.lowGainDB = value
                appState.setDeckEQ(deck: deck, eq: next)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !enabled { Text("Auto").font(.system(size: 9, weight: .semibold)).foregroundColor(DJTheme.textSecondary) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deckEQ-\(deck.rawValue)")
        .help(enabled ? "Channel EQ" : "Transition automation is controlling the EQ")
    }
}
