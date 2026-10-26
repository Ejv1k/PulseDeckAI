import SwiftUI
import AppKit
import PulseDeckCore

/// Dual-deck studio playback, transport, and crossfader control view.
@MainActor
public struct DeckStudioView: View {
    @ObservedObject var appState: AppState
    @StateObject private var safetyKeyboard: MasterSafetyLockKeyboardRouter
    @FocusState private var isStudioFocused: Bool
    @State private var isSoundboardExpanded: Bool = false

    public init(appState: AppState) {
        self.appState = appState
        _safetyKeyboard = StateObject(wrappedValue: MasterSafetyLockKeyboardRouter(appState: appState))
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

            if let message = appState.masterSafetyLockMessage {
                Text(message)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DJTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("masterSafetyLockFeedback")
            }

            soundboardSection()
        }
        .background(MasterSafetyLockKeyboardBridge(router: safetyKeyboard))
        .focusable()
        .focused($isStudioFocused)
        .onKeyPress(phases: [.down, .repeat]) { press in
            if isStudioFocused, case .handled = safetyKeyboard.handleStudioKeyPress(press) {
                return .handled
            }
            return SoundboardKeyboardRouter.handleKeyPress(press, appState: appState)
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

                LibraryDeckLoadButton(appState: appState, deck: deck, title: title, color: color)
            }

            if appState.isMasterDeckOnAir(deck) {
                Label(appState.isMasterSafetyLockEnabled ? "ON AIR · LOCKED" : "ON AIR · UNLOCKED",
                      systemImage: appState.isMasterSafetyLockEnabled ? "lock.fill" : "lock.open")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
            }

            if let message = appState.deckLoadMessage(for: deck) {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(DJTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("deckLoadFeedback-\(deck.rawValue)")
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

                    Text("Select a track and click LOAD, or drag it here")
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
                    appState.focusMasterDeck(deck)
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
                .accessibilityIdentifier("deckPlayPauseButton-\(deck.rawValue)")
                .accessibilityLabel(isPlaying ? "Pause \(title)" : "Play \(title)")

                Button {
                    appState.focusMasterDeck(deck)
                    appState.stopDeck(deck: deck)
                } label: {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(DJTheme.textPrimary)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .disabled(appState.isTransitionBusy)
                .accessibilityIdentifier("deckStopButton-\(deck.rawValue)")
                .accessibilityLabel("Stop \(title)")
                .help("Stop and rewind this deck. On-air decks require Safety Lock off.")

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
                .accessibilityIdentifier("deckCueButton-\(deck.rawValue)")
                .accessibilityLabel("Cue \(title)")
                .help("Toggle Pre-Fader Listen (PFL) in headphones")
            }
        }
        .padding(10)
        .background(DJTheme.cardBackground)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(color.opacity(appState.focusedMasterDeck == deck ? 0.9 : 0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deckPanel-\(deck.rawValue)")
        .accessibilityLabel(title)
        .dropDestination(for: LibraryTrackTransfer.self) { items, _ in
            appState.loadDroppedTracks(items, deck: deck)
        }
        .simultaneousGesture(TapGesture().onEnded {
            appState.focusMasterDeck(deck)
            isStudioFocused = true
        })
    }

    private func centerMixerStrip() -> some View {
        VStack(spacing: 6) {
            MasterSafetyLockButton(appState: appState)

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
            .accessibilityIdentifier("crossfaderSlider")
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

            Divider()
                .background(DJTheme.border)

            Button(action: {
                appState.toggleTalkover()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: appState.isTalkoverActive ? "mic.fill" : "mic")
                    Text("TALKOVER")
                }
                .font(.system(size: 9.5, weight: .black, design: .monospaced))
                .foregroundColor(appState.isTalkoverActive ? DJTheme.background : DJTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(appState.isTalkoverActive ? Color.yellow : DJTheme.cardHeader)
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(appState.isTalkoverActive ? Color.yellow : DJTheme.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help("Toggle Master Talkover ducking (-16.5 dB attenuation + vocal pocket EQ, Hotkey: T)")
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

    private func soundboardSection() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            DisclosureGroup(isExpanded: $isSoundboardExpanded) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(appState.soundboardPads) { pad in
                        soundboardPadButton(pad: pad)
                    }
                }
                .padding(.top, 4)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.3x3.fill")
                        .font(.system(size: 9))
                        .foregroundColor(DJTheme.textSecondary)
                    Text("RAM SOUNDBOARD SFX [F1–F8]")
                        .font(.system(size: 9.5, weight: .black, design: .monospaced))
                        .foregroundColor(DJTheme.textPrimary)

                    if !isSoundboardExpanded {
                        Text("· 8 PADS ACTIVE (HOTKEYS ON)")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(DJTheme.textMuted)
                    }

                    Spacer()

                    if appState.soundboardTotalRAMBytes > 0 {
                        Text("\(Double(appState.soundboardTotalRAMBytes) / 1024.0 / 1024.0, specifier: "%.1f") MB RAM")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(DJTheme.textMuted)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(DJTheme.cardBackground)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(DJTheme.border, lineWidth: 1)
        )
    }

    private func soundboardPadButton(pad: SoundboardPadSnapshot) -> some View {
        Button(action: {
            appState.triggerSoundboardPad(index: pad.index)
        }) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("[\(pad.keyLabel)]")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundColor(pad.isPlaying ? DJTheme.background : DJTheme.textSecondary)

                    Spacer()

                    Circle()
                        .fill(pad.isPlaying ? Color.yellow : (pad.isFallback ? Color.orange : Color.green))
                        .frame(width: 5, height: 5)
                }

                Text(pad.title)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(pad.isPlaying ? DJTheme.background : DJTheme.textPrimary)
                    .lineLimit(1)

                HStack {
                    Text(pad.isFallback ? "FALLBACK" : "RAM")
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundColor(pad.isPlaying ? DJTheme.background.opacity(0.8) : DJTheme.textMuted)

                    Spacer()

                    Text(formatDuration(pad.durationSeconds))
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundColor(pad.isPlaying ? DJTheme.background.opacity(0.8) : DJTheme.textMuted)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity)
            .background(pad.isPlaying ? Color.yellow : DJTheme.cardHeader)
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(pad.isPlaying ? Color.yellow : (pad.isFallback ? Color.orange.opacity(0.5) : DJTheme.border), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Trigger Pad \(pad.index + 1) (\(pad.title)) - Hotkey: \(pad.keyLabel)")
    }

    private func formatDuration(_ duration: Double) -> String {
        guard duration.isFinite, duration >= 0.0 else { return "0:00" }
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// The production control owns activation semantics; an event source makes pointer,
/// keyboard and assistive activation reproducible without global AppKit mutation.
@MainActor
struct MasterSafetyLockButton: View {
    @ObservedObject var appState: AppState
    private let currentEvent: @MainActor () -> NSEvent?

    init(appState: AppState, currentEvent: @escaping @MainActor () -> NSEvent? = { NSApplication.shared.currentEvent }) {
        self.appState = appState
        self.currentEvent = currentEvent
    }

    var body: some View {
        button
            .buttonStyle(.plain)
            .accessibilityLabel("Master Safety Lock")
            .accessibilityValue(appState.isMasterSafetyLockEnabled ? "On" : "Off")
            .help("Protect on-air deck transport. Shift+Space confirms one pause on the focused deck without unlocking.")
    }

    // Keep the real Button available for an in-process primitive-style activation test.
    var button: some View {
        Button {
            if let event = currentEvent(),
               (event.type == .keyDown || event.type == .keyUp),
               event.isARepeat {
                return
            }
            appState.setMasterSafetyLockEnabled(!appState.isMasterSafetyLockEnabled)
        } label: {
            Label("SAFETY LOCK", systemImage: appState.isMasterSafetyLockEnabled ? "lock.fill" : "lock.open")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(appState.isMasterSafetyLockEnabled ? DJTheme.cue : DJTheme.textSecondary)
                .padding(.vertical, 5)
        }
    }
}

/// The deck header's production load control; its public SwiftUI action is also used in own-view tests.
@MainActor
struct LibraryDeckLoadButton: View {
    @ObservedObject var appState: AppState
    let deck: DeckIdentifier
    let title: String
    let color: Color

    var button: some View {
        Button {
            appState.focusMasterDeck(deck)
            appState.loadSelectedTrackIntoDeck(deck: deck)
        } label: {
            Label("LOAD", systemImage: "arrow.down.doc.fill")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(DJTheme.textPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(color.opacity(0.2))
                .cornerRadius(3)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: 1))
        }
        .help(appState.selectedTrackPath == nil
              ? "Select a library track first. Analysis is optional."
              : "Load the selected library file into \(title). Analysis is optional; Safety Lock and automation still apply.")
        .accessibilityLabel("Load selected track into \(title)")
        .accessibilityIdentifier("deckLoadButton-\(deck.rawValue)")
    }

    var body: some View { button.buttonStyle(.plain) }
}
