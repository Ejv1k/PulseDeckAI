import SwiftUI
import PulseDeckCore

/// Dual-deck studio playback, transport, and crossfader control view.
public struct DeckStudioView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                deckPanel(
                    deck: .deckA,
                    title: "DECK A",
                    color: DJTheme.deckA,
                    track: appState.deckATrack,
                    isPlaying: appState.isDeckAPlaying,
                    isCueActive: appState.isDeckACueActive
                )

                // Center Crossfader Mixer Strip
                centerMixerStrip()
                    .frame(width: 140)

                deckPanel(
                    deck: .deckB,
                    title: "DECK B",
                    color: DJTheme.deckB,
                    track: appState.deckBTrack,
                    isPlaying: appState.isDeckBPlaying,
                    isCueActive: appState.isDeckBCueActive
                )
            }

            transitionControls()
        }
    }

    private func deckPanel(
        deck: DeckIdentifier,
        title: String,
        color: Color,
        track: TrackCacheEntry?,
        isPlaying: Bool,
        isCueActive: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Deck Header
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)

                Text(title)
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundColor(color)

                Spacer()

                Button(action: {
                    appState.loadSelectedTrackIntoDeck(deck: deck)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.doc.fill")
                        Text("LOAD")
                    }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(DJTheme.textPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.2))
                    .cornerRadius(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(color, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(appState.selectedTrackPath == nil || appState.isTransitionBusy)
                .help("Load selected library track into \(title)")
            }

            // Track metadata
            VStack(alignment: .leading, spacing: 2) {
                if let track {
                    Text(track.relativePath)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(DJTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 8) {
                        Text(formatDuration(track.duration))
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundColor(DJTheme.textSecondary)

                        if track.bpm > 0 {
                            Text(String(format: "%.1f BPM", track.bpm))
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundColor(color)
                        }

                        if !track.musicalKey.isEmpty {
                            Text(track.musicalKey)
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundColor(DJTheme.cue)
                        }
                    }
                } else {
                    Text("No Track Loaded")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(DJTheme.textMuted)

                    Text("Select a track and click LOAD")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(DJTheme.textMuted)
                }
            }
            .frame(height: 32, alignment: .leading)

            Divider()
                .background(DJTheme.border)

            // Transport Controls
            HStack(spacing: 8) {
                Button(action: {
                    appState.toggleDeckPlay(deck: deck)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        Text(isPlaying ? "PAUSE" : "PLAY")
                    }
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(isPlaying ? DJTheme.background : DJTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(isPlaying ? color : DJTheme.cardHeader)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(color, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(appState.isTransitionBusy)

                Button(action: {
                    appState.setDeckCueActive(deck: deck, active: !isCueActive)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "headphones")
                        Text("CUE")
                    }
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(isCueActive ? DJTheme.background : DJTheme.cue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(isCueActive ? DJTheme.cue : DJTheme.cardHeader)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(DJTheme.cue, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Toggle Pre-Fader Listen (PFL) in headphones")
            }
        }
        .padding(10)
        .background(DJTheme.cardBackground)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(color.opacity(0.35), lineWidth: 1)
        )
    }

    private func centerMixerStrip() -> some View {
        VStack(spacing: 6) {
            Text("CROSSFADER")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundColor(DJTheme.textMuted)

            Slider(
                value: Binding(
                    get: { Double(appState.crossfaderPosition) },
                    set: { appState.updateCrossfader(position: Float($0)) }
                ),
                in: 0.0...1.0
            )
            .accentColor(DJTheme.textAccent)
            .disabled(appState.isTransitionBusy)

            HStack {
                Text("DECK A")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(DJTheme.deckA)

                Spacer()

                Text("CENTER")
                    .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                    .foregroundColor(DJTheme.textMuted)

                Spacer()

                Text("DECK B")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(DJTheme.deckB)
            }
        }
        .padding(8)
        .background(DJTheme.cardBackground)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(DJTheme.border, lineWidth: 1)
        )
    }

    private func transitionControls() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("TRANSITION")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(DJTheme.textMuted)

                Picker("Macro", selection: $appState.transitionMacroStyle) {
                    ForEach(TransitionMacroStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .labelsHidden()
                .frame(width: 132)
                .disabled(appState.isTransitionBusy)

                Picker("Phrase bars", selection: $appState.transitionPhraseBars) {
                    ForEach([8, 16, 32], id: \.self) { bars in
                        Text("\(bars) BARS").tag(bars)
                    }
                }
                .labelsHidden()
                .frame(width: 90)
                .disabled(appState.isTransitionBusy)

                Button {
                    Task { await appState.executeTransition() }
                } label: {
                    Label("EXECUTE", systemImage: "arrow.left.arrow.right")
                }
                .disabled(!appState.transitionIsReady || appState.isTransitionBusy)
                .help("Start the selected macro from the outgoing deck's current playhead")

                Button {
                    Task { await appState.toggleAutoPilot() }
                } label: {
                    Label(appState.isAutoPilotArmed ? "DISARM" : "ARM", systemImage: "autopilot")
                }
                .disabled(appState.isAutoPilotArmed ? false : (appState.autoPilotReadinessMessage != nil || appState.isTransitionBusy))
                .help(appState.isAutoPilotArmed
                    ? "Disarm the one-shot transition"
                    : (appState.autoPilotReadinessMessage ?? "Arm a one-shot transition at the outgoing mix-out cue"))

                if appState.isTransitionBusy {
                    Button {
                        Task { await appState.cancelTransition() }
                    } label: {
                        Label("CANCEL", systemImage: "xmark.circle")
                    }
                    .help("Cancel the armed transition or restore the outgoing deck after an active transition")
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Text(appState.transitionReadinessText)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(appState.transitionIsReady ? DJTheme.textSecondary : DJTheme.textMuted)
                    .lineLimit(1)

                if appState.isTransitionRunning {
                    ProgressView(value: appState.transitionProgress)
                        .frame(width: 120)
                    Text("\(Int(appState.transitionProgress * 100))%")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(DJTheme.textAccent)
                } else if appState.isAutoPilotArmed {
                    Text("AUTOPILOT ARMED AT MIX OUT")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(DJTheme.textAccent)
                }

                if let error = appState.transitionErrorMessage {
                    Text(error)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.red)
                        .lineLimit(1)
                        .help(error)
                }
            }
        }
        .padding(8)
        .background(DJTheme.cardBackground)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(DJTheme.border, lineWidth: 1)
        )
    }

    private func formatDuration(_ duration: Double) -> String {
        guard duration.isFinite, duration >= 0.0 else { return "0:00" }
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
