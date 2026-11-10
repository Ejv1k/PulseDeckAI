import SwiftUI
import PulseDeckCore

/// DJ-mixer style rotary knob: 12 o'clock is 0 dB, fully left is a -24 dB kill, fully right +6 dB.
/// Drag vertically to turn, double-click to reset, arrow keys / VoiceOver step 1 dB.
struct EQKnob: View {
    let label: String
    let gainDB: Float
    let color: Color
    let isEnabled: Bool
    let onChange: (Float) -> Void

    static let minDB: Float = -24, maxDB: Float = 6
    private static let sweepDegrees: Double = 270
    private static let dragPointsForFullTurn: CGFloat = 160

    @GestureState private var dragStart: Double? // Resets itself even when a drag is cancelled.

    /// Unequal halves, like real mixers: the cut side gets as much travel as the boost side.
    static func position(for gain: Float) -> Double {
        gain <= 0 ? 0.5 * Double(1 - gain / minDB) : 0.5 + 0.5 * Double(gain / maxDB)
    }

    static func gain(for position: Double) -> Float {
        let p = min(max(position, 0), 1)
        return p <= 0.5 ? minDB * Float(1 - 2 * p) : maxDB * Float(2 * p - 1)
    }

    private var position: Double { Self.position(for: gainDB) }
    private var isKilled: Bool { gainDB <= Self.minDB + 0.5 }
    private var valueText: String {
        if isKilled { return "KILL" }
        if abs(gainDB) < 0.05 { return "0" }
        return String(format: "%+.1f", gainDB)
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().fill(DJTheme.surfaceRaised)
                    .overlay(Circle().stroke(DJTheme.borderActive, lineWidth: 1))
                // Track and value arc, measured from the 0 dB notch at 12 o'clock.
                arc(from: 0, to: 1).stroke(DJTheme.border, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                arc(from: min(0.5, position), to: max(0.5, position))
                    .stroke(isKilled ? DJTheme.statusError : color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                Capsule().fill(DJTheme.textPrimary)
                    .frame(width: 2, height: 9)
                    .offset(y: -8)
                    .rotationEffect(.degrees(-Self.sweepDegrees / 2 + position * Self.sweepDegrees))
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
            .gesture(drag)
            .onTapGesture(count: 2) { if isEnabled { onChange(0) } }

            Text(label)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundColor(DJTheme.textMuted)
            Text(valueText)
                .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                .foregroundColor(isKilled ? DJTheme.statusError : DJTheme.textSecondary)
        }
        .opacity(isEnabled ? 1 : 0.45)
        .help("\(label) EQ: drag to turn, double-click resets to 0 dB. Fully left kills the band.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) EQ")
        .accessibilityValue(isKilled ? "Killed" : String(format: "%.1f decibels", gainDB))
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: onChange(min(Self.maxDB, gainDB + 1))
            case .decrement: onChange(max(Self.minDB, gainDB - 1))
            @unknown default: break
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1)
            .updating($dragStart) { _, start, _ in
                if start == nil { start = position }
            }
            .onChanged { value in
                guard isEnabled else { return }
                let start = dragStart ?? position
                let next = start - Double(value.translation.height / Self.dragPointsForFullTurn)
                var gain = Self.gain(for: next)
                if abs(gain) < 0.4 { gain = 0 } // Detent at 0 dB, like the centre click of a mixer knob.
                onChange(gain)
            }
    }

    private func arc(from start: Double, to end: Double) -> Path {
        Path { path in
            let base = -90 - Self.sweepDegrees / 2
            path.addArc(center: CGPoint(x: 15, y: 15), radius: 13,
                        startAngle: .degrees(base + start * Self.sweepDegrees),
                        endAngle: .degrees(base + end * Self.sweepDegrees), clockwise: false)
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
        HStack(spacing: 14) {
            EQKnob(label: "HI", gainDB: eq.highGainDB, color: color, isEnabled: enabled) { value in
                var next = appState.deckEQ(deck); next.highGainDB = value
                appState.setDeckEQ(deck: deck, eq: next)
            }
            EQKnob(label: "MID", gainDB: eq.midGainDB, color: color, isEnabled: enabled) { value in
                var next = appState.deckEQ(deck); next.midGainDB = value
                appState.setDeckEQ(deck: deck, eq: next)
            }
            EQKnob(label: "LOW", gainDB: eq.lowGainDB, color: color, isEnabled: enabled) { value in
                var next = appState.deckEQ(deck); next.lowGainDB = value
                appState.setDeckEQ(deck: deck, eq: next)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deckEQ-\(deck.rawValue)")
        .help(enabled ? "Channel EQ" : "Transition automation is controlling the EQ")
    }
}
