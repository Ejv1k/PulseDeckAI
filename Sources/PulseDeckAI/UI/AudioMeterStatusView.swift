import PulseDeckCore
import SwiftUI

/// Minimal metering consumer. Timeline polling drains snapshots on the UI side only.
public struct AudioMeterStatusView: View {
    @ObservedObject private var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            if let error = appState.meteringErrorMessage {
                Text(error)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(DJTheme.textMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else {
                let master = appState.meterSnapshot(for: .master)
                let cue = appState.meterSnapshot(for: .cue)
                HStack(spacing: 16) {
                    meter("MASTER", snapshot: master, color: DJTheme.master)
                    meter("CUE", snapshot: cue, color: DJTheme.cue)
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(DJTheme.cardBackground)
            }
        }
    }

    private func meter(_ title: String, snapshot: AudioMeterSnapshot?, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundColor(DJTheme.textMuted)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(DJTheme.border)
                    Rectangle()
                        .fill(color)
                        .frame(width: proxy.size.width * CGFloat(min(max(snapshot?.peak ?? 0, 0), 1)))
                }
            }
            .frame(width: 100, height: 8)
            Text(String(format: "RMS %.3f", snapshot?.rms ?? 0))
                .foregroundColor(DJTheme.textSecondary)
                .frame(width: 86, alignment: .trailing)
        }
    }
}
