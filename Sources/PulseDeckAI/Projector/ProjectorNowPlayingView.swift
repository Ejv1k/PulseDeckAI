import SwiftUI
import PulseDeckCore

/// Mode 3: Elegant Now Playing card and customizable wedding/event banner.
///
/// Features smooth master deck handoff, clean typography, honest missing metadata display,
/// and live updating from `AppState` without modifying `AppState` stored properties.
public struct ProjectorNowPlayingView: View {
    @ObservedObject var viewModel: ProjectorViewModel
    @ObservedObject var appState: AppState

    public init(viewModel: ProjectorViewModel, appState: AppState) {
        self.viewModel = viewModel
        self.appState = appState
    }

    public var body: some View {
        cardContent
        .background(Color.black.ignoresSafeArea())
    }

    private var cardContent: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let meta = viewModel.nowPlayingMetadata

            VStack(spacing: 0) {
                // Top customizable event banner
                if !viewModel.eventBannerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(viewModel.eventBannerText.uppercased())
                        .font(.system(size: max(14, width * 0.016), weight: .bold, design: .serif))
                        .foregroundColor(DJTheme.cue)
                        .tracking(6)
                        .padding(.top, 48)
                        .padding(.horizontal, 32)
                        .multilineTextAlignment(.center)
                        .shadow(color: DJTheme.cue.opacity(0.4), radius: 8, y: 2)
                }

                Spacer()

                // Center Now Playing card
                VStack(spacing: 18) {
                    // Guests need what is playing, not which deck plays it.
                    if meta.deck != nil && meta.isMasterPlaying {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(DJTheme.master)
                                .frame(width: 8, height: 8)
                            Text("NOW PLAYING")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(DJTheme.master)
                                .tracking(2)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(DJTheme.cardBackground.opacity(0.8))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(DJTheme.master.opacity(0.4), lineWidth: 1)
                        )
                    }

                    // Track Title
                    Text(meta.title)
                        .font(.system(size: max(28, width * 0.038), weight: .heavy, design: .default))
                        .foregroundColor(DJTheme.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .shadow(color: Color.black.opacity(0.8), radius: 10, y: 4)

                    // Artist Name
                    if !meta.artist.isEmpty {
                        Text(meta.artist)
                            .font(.system(size: max(18, width * 0.022), weight: .medium, design: .default))
                            .foregroundColor(DJTheme.deckA)
                            .tracking(2)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 48)
                .animation(.easeInOut(duration: 0.5), value: meta)

                Spacer()

                // Subtle footer
                Text("PULSEDECK AI")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(DJTheme.textMuted.opacity(0.5))
                    .tracking(4)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
