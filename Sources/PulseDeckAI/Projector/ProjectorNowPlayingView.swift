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
                if !viewModel.eventBannerText.isEmpty {
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
                    // On-air Master badge
                    if let deck = meta.deck {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(meta.isMasterPlaying ? DJTheme.master : DJTheme.textMuted)
                                .frame(width: 8, height: 8)
                            Text("ON AIR — DECK \(deck.rawValue.uppercased())")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(meta.isMasterPlaying ? DJTheme.master : DJTheme.textMuted)
                                .tracking(2)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(DJTheme.cardBackground.opacity(0.8))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(meta.isMasterPlaying ? DJTheme.master.opacity(0.4) : DJTheme.border, lineWidth: 1)
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

                    // Metadata Pill Badges (BPM / Key)
                    HStack(spacing: 12) {
                        if let bpm = meta.bpm {
                            HStack(spacing: 4) {
                                Text("BPM")
                                    .foregroundColor(DJTheme.textMuted)
                                Text(String(format: "%.1f", bpm))
                                    .foregroundColor(DJTheme.textPrimary)
                            }
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(DJTheme.cardBackground)
                            .cornerRadius(6)
                        }

                        if let key = meta.musicalKey {
                            HStack(spacing: 4) {
                                Text("KEY")
                                    .foregroundColor(DJTheme.textMuted)
                                Text(key)
                                    .foregroundColor(DJTheme.textPrimary)
                            }
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(DJTheme.cardBackground)
                            .cornerRadius(6)
                        }
                    }
                    .padding(.top, 6)
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
