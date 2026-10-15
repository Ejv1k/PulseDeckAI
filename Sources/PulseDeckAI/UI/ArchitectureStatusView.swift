import SwiftUI
import PulseDeckCore

public struct ArchitectureStatusView: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PHASE 0 ARCHITECTURAL CONTRACTS VERIFICATION")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(DJTheme.textSecondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                // Contract 1: Dual Output Engines
                contractCard(
                    title: "DUAL OUTPUT ENGINES",
                    badge: "STRICT OUTPUT-ONLY",
                    badgeColor: DJTheme.master,
                    icon: "speaker.wave.3.fill",
                    lines: [
                        "• Exactly 2 independent AVAudioEngines (Master + Cue)",
                        "• Absolutely NEVER touch inputNode / microphone",
                        "• CoreAudio HAL device selection & hotplug routing",
                        "• Deck A/B: TimePitch, 3-Band EQ, Resonant Filter"
                    ]
                )

                // Contract 2: Audio Thread Safety & Latency
                contractCard(
                    title: "AUDIO-THREAD SAFETY",
                    badge: "ZERO LOCKS / ALLOCS",
                    badgeColor: DJTheme.deckA,
                    icon: "bolt.shield.fill",
                    lines: [
                        "• Render callback: 0 mallocs, 0 locks, 0 ObjC/ARC",
                        "• Bounded lock-free ring buffers (SPSC)",
                        "• Latency: -300..+300ms via path delay injection",
                        "• Bluetooth: explicit advisory & variable drift warning"
                    ]
                )

                // Contract 3: Versioned Cache & AI Advisor
                contractCard(
                    title: "CACHE & AI ADVISOR",
                    badge: "SCHEMA V1.0.0",
                    badgeColor: DJTheme.cue,
                    icon: "sparkles.rectangle.stack.fill",
                    lines: [
                        "• Ordered cues: startTrim ≤ vocalEntry ≤ mixOut ≤ endTrim",
                        "• Atomic serialized save; manual overrides preserved",
                        "• Gemini 2.5 Flash: strict 12 RPM cap & backoff",
                        "• Offline Accelerate DSP + Ollama :11434 fallback"
                    ]
                )
            }
        }
        .padding(10)
        .background(DJTheme.cardBackground)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(DJTheme.border, lineWidth: 1)
        )
    }

    private func contractCard(
        title: String,
        badge: String,
        badgeColor: Color,
        icon: String,
        lines: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(badgeColor)

                Text(title)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(DJTheme.textPrimary)

                Spacer()

                Text(badge)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(badgeColor.opacity(0.15))
                    .foregroundColor(badgeColor)
                    .cornerRadius(2)
            }

            Divider()
                .background(DJTheme.border)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(DJTheme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(8)
        .background(DJTheme.cardHeader)
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(DJTheme.border.opacity(0.6), lineWidth: 1)
        )
    }
}
