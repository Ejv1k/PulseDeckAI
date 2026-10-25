import PulseDeckCore
import SwiftUI

/// Minimal metering consumer. Timeline polling drains snapshots on the UI side only.
/// Polling now belongs to the shared distributor; this view only reads cached snapshots.
public struct AudioMeterStatusView: View {
    @ObservedObject private var appState: AppState
    @ObservedObject private var meters: AudioMeterSnapshotDistributor

    public init(appState: AppState) {
        self.appState = appState
        self.meters = .shared(for: appState)
    }

    public var body: some View {
        Group {
            if let error = appState.meteringErrorMessage {
                Text(error)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(DJTheme.textMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else {
                let master = meters.master
                let cue = meters.cue
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
        .task { await meters.observe() }
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
