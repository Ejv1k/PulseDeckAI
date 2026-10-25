import SwiftUI
import PulseDeckCore

/// Mode 1: Real-time 24-band FFT spectrum visualizer.
///
/// Drains snapshots published by `AudioMeteringService` on Master and animates frequency bars
/// with smooth peak ballistics and zero audio real-time allocations.
public struct ProjectorSpectrumView: View {
    @ObservedObject var viewModel: ProjectorViewModel
    @ObservedObject var appState: AppState

    public init(viewModel: ProjectorViewModel, appState: AppState) {
        self.viewModel = viewModel
        self.appState = appState
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            let _ = viewModel.updateVisualizer(from: appState)
            visualizerCanvas
        }
        .background(Color.black.ignoresSafeArea())
    }

    private var visualizerCanvas: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let barCount = viewModel.visualizerFrame.bands.count
            let spacing: CGFloat = max(4.0, width * 0.008)
            let totalSpacing = spacing * CGFloat(barCount + 1)
            let barWidth = max(2.0, (width - totalSpacing) / CGFloat(barCount))
            let maxBarHeight = height * 0.72

            VStack(spacing: 0) {
                // Header indicator
                HStack {
                    Text("MASTER SPECTRUM")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(DJTheme.master)
                    Spacer()
                    if viewModel.visualizerFrame.isSilent {
                        Text("SILENT")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(DJTheme.textMuted)
                    } else {
                        Text(String(format: "RMS: %.2f  PEAK: %.2f", viewModel.visualizerFrame.rms, viewModel.visualizerFrame.peak))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(DJTheme.textSecondary)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)

                Spacer()

                // Bars container
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(0..<barCount, id: \.self) { index in
                        let bandValue = CGFloat(viewModel.visualizerFrame.bands[index])
                        let barHeight = max(4.0, bandValue * maxBarHeight)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(barGradient(for: index, total: barCount))
                            .frame(width: barWidth, height: barHeight)
                            .shadow(color: barGlowColor(for: index).opacity(Double(bandValue) * 0.5), radius: 6, y: -2)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, spacing)

                // Frequency band label baseline
                HStack {
                    Text("SUB")
                    Spacer()
                    Text("BASS")
                    Spacer()
                    Text("LOW-MID")
                    Spacer()
                    Text("HIGH-MID")
                    Spacer()
                    Text("TREBLE")
                    Spacer()
                    Text("AIR")
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(DJTheme.textMuted)
                .padding(.horizontal, 40)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
    }

    private func barGradient(for index: Int, total: Int) -> LinearGradient {
        let ratio = Double(index) / Double(max(1, total - 1))
        let topColor: Color
        if ratio < 0.25 {
            topColor = DJTheme.deckA
        } else if ratio < 0.55 {
            topColor = DJTheme.master
        } else if ratio < 0.8 {
            topColor = DJTheme.cue
        } else {
            topColor = DJTheme.deckB
        }

        return LinearGradient(
            gradient: Gradient(colors: [topColor, DJTheme.deckA.opacity(0.3)]),
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func barGlowColor(for index: Int) -> Color {
        let ratio = Double(index) / Double(max(1, ProjectorSpectrumAnalyzer.bandCount - 1))
        if ratio < 0.25 { return DJTheme.deckA }
        if ratio < 0.55 { return DJTheme.master }
        if ratio < 0.8 { return DJTheme.cue }
        return DJTheme.deckB
    }
}
