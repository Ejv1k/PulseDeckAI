import SwiftUI
import AppKit
import PulseDeckCore

/// Dual-deck studio playback, transport, and crossfader control view.
@MainActor
public struct DeckStudioView: View {
    @ObservedObject var appState: AppState
    @StateObject private var safetyKeyboard: MasterSafetyLockKeyboardRouter
    @FocusState private var isStudioFocused: Bool
    @AppStorage("studio.soundboardExpanded") private var isSoundboardExpanded: Bool = false

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
        .focusEffectDisabled() // The ring is redrawn on every frame while playing and cost about half of the render time.
        .focused($isStudioFocused)
        .overlay { // Static focus cue; it changes only when focus moves, unlike the system ring.
            RoundedRectangle(cornerRadius: DJTheme.cardRadius)
                .stroke(DJTheme.textAccent.opacity(0.6), lineWidth: 1)
                .opacity(isStudioFocused ? 1 : 0)
                .allowsHitTesting(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pulseDeckFocusStudio)) { _ in isStudioFocused = true }
        .onKeyPress(phases: [.down, .repeat]) { press in
            if isStudioFocused, case .handled = safetyKeyboard.handleStudioKeyPress(press) {
                return .handled
            }
            return SoundboardKeyboardRouter.handleKeyPress(press, appState: appState)
        }
    }

    @ViewBuilder
    private func mixCountdown(deck: DeckIdentifier, track: TrackCacheEntry) -> some View {
        if let playhead = appState.deckPlayheadSeconds(deck),
           let bars = MixCountdown.barsRemaining(playhead: playhead, mixOut: track.cueMarkers.mixOutCue, bpm: track.bpm) {
            Text(bars <= 1 ? "Mix now" : "Mix in \(bars) bars")
                .font(.system(size: 9.5, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(bars <= 8 ? DJTheme.statusWarning : DJTheme.textSecondary)
                .help("Bars until this track reaches its mix-out cue")
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
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(color)

                Spacer()

                LibraryDeckLoadButton(appState: appState, deck: deck, title: title, color: color)
            }

            if appState.isMasterDeckOnAir(deck) {
                Label(appState.isMasterSafetyLockEnabled ? "On Air · Locked" : "On Air · Unlocked",
                      systemImage: appState.isMasterSafetyLockEnabled ? "lock.fill" : "lock.open")
                    .font(.system(size: 9.5, weight: .semibold))
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
                    Text(LibraryTrackTitle.display((track.relativePath as NSString).lastPathComponent))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DJTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 8) {
                        Text(formatDuration(track.duration))
                            .font(.system(size: 9.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundColor(DJTheme.textSecondary)

                        if track.bpm > 0 {
                            Text(String(format: "%.1f BPM", track.bpm))
                                .font(.system(size: 9.5, weight: .bold))
                                .monospacedDigit()
                                .foregroundColor(color)
                        }

                        if !track.musicalKey.isEmpty, track.musicalKey.caseInsensitiveCompare("Unknown") != .orderedSame {
                            Text(track.musicalKey)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(DJTheme.cue)
                        }

                        if track.analyzerVersion == "unanalysed-playback" {
                            Text("Not analyzed")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(DJTheme.textMuted)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .overlay(Capsule().stroke(DJTheme.border, lineWidth: 1))
                                .help("Analyze this track for BPM, key, waveform and cues")
                        }

                        autoGainBadge(deck: deck)

                        if isPlaying {
                            // 4 Hz is plenty for a bar count; the playhead is read on demand, not published.
                            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                                mixCountdown(deck: deck, track: track)
                            }
                        }
                    }
                } else {
                    Text("No Track Loaded")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DJTheme.textMuted)

                    Text("Select a track and click Load, or drag it here")
                        .font(.system(size: 9.5))
                        .foregroundColor(DJTheme.textMuted)
                }
            }
            .frame(height: 32, alignment: .leading)

            Divider()
                .background(DJTheme.border)

            DeckEQStrip(appState: appState, deck: deck, color: color)

            // Transport Controls
            HStack(spacing: 8) {
                Button(action: {
                    appState.focusMasterDeck(deck)
                    appState.toggleDeckPlay(deck: deck)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        Text(isPlaying ? "Pause" : "Play")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isPlaying ? DJTheme.background : DJTheme.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: DJTheme.minTouchTarget)
                    .background(isPlaying ? color : DJTheme.cardHeader)
                    .cornerRadius(DJTheme.controlRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                            .stroke(isPlaying ? color : DJTheme.border.opacity(0.8), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(StudioPressableStyle())
                .disabled(appState.isTransitionBusy)
                .accessibilityIdentifier("deckPlayPauseButton-\(deck.rawValue)")
                .accessibilityLabel(isPlaying ? "Pause \(title)" : "Play \(title)")
                .help("Play or pause. Keyboard: A or B picks the deck, Space plays or pauses it, Shift+Space pauses an on-air deck under Safety Lock.")

                Button {
                    appState.focusMasterDeck(deck)
                    appState.stopDeck(deck: deck)
                } label: {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(DJTheme.textPrimary)
                        .padding(.horizontal, 8)
                        .frame(minHeight: DJTheme.minTouchTarget)
                        .background(DJTheme.cardHeader)
                        .cornerRadius(DJTheme.controlRadius)
                        .overlay(RoundedRectangle(cornerRadius: DJTheme.controlRadius).stroke(DJTheme.border.opacity(0.8), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(StudioPressableStyle())
                .disabled(appState.isTransitionBusy)
                .accessibilityIdentifier("deckStopButton-\(deck.rawValue)")
                .accessibilityLabel("Stop \(title)")
                .help("Stop and rewind this deck. On-air decks require Safety Lock off.")

                Button(action: {
                    appState.setDeckCueActive(deck: deck, active: !isCueActive)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "headphones")
                        Text("Cue")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isCueActive ? DJTheme.background : DJTheme.cue)
                    .padding(.horizontal, 10)
                    .frame(minHeight: DJTheme.minTouchTarget)
                    .background(isCueActive ? DJTheme.cue : DJTheme.cardHeader)
                    .cornerRadius(DJTheme.controlRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                            .stroke(isCueActive ? DJTheme.cue : DJTheme.border.opacity(0.8), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(StudioPressableStyle())
                .accessibilityIdentifier("deckCueButton-\(deck.rawValue)")
                .accessibilityLabel("Cue \(title)")
                .help("Toggle Pre-Fader Listen (PFL) in headphones")
            }
        }
        .padding(10)
        .background(DJTheme.cardBackground)
        .cornerRadius(DJTheme.cardRadius)
        .overlay(
            RoundedRectangle(cornerRadius: DJTheme.cardRadius)
                .stroke(appState.focusedMasterDeck == deck ? color.opacity(0.8) : DJTheme.border.opacity(0.6), lineWidth: 1)
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

    @ViewBuilder
    private func autoGainBadge(deck: DeckIdentifier) -> some View {
        if appState.isAutoGainEnabled {
            if appState.isMeasuringLoudness(deck) {
                Text("Gain…")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(DJTheme.textMuted)
                    .help("Measuring loudness to level this track")
            } else if let gain = appState.autoGainDB(deck) {
                Text(abs(gain) < 0.05 ? "Gain 0 dB" : String(format: "Gain %+.1f dB", gain))
                    .font(.system(size: 9.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(DJTheme.textSecondary)
                    .help("Auto Gain levels every track to about -14 LUFS without clipping")
                    .accessibilityIdentifier("deckAutoGain-\(deck.rawValue)")
            }
        }
    }

    private func centerMixerStrip() -> some View {
        VStack(spacing: 6) {
            MasterSafetyLockButton(appState: appState)

            Toggle(isOn: $appState.isAutoGainEnabled) {
                Text("Auto Gain")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(DJTheme.textSecondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Level every track to the same loudness (EBU R128), so no song is suddenly louder or quieter")
            .accessibilityIdentifier("autoGainToggle")

            Text("Crossfader")
                .font(.system(size: 9.5, weight: .semibold))
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
                Text("Deck A")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(DJTheme.deckA)

                Spacer()

                Text("Center")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(DJTheme.textMuted)

                Spacer()

                Text("Deck B")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(DJTheme.deckB)
            }

            Divider()
                .background(DJTheme.border)

            Button(action: {
                appState.toggleTalkover()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: appState.isTalkoverActive ? "speaker.wave.2.bubble.fill" : "speaker.wave.2.bubble")
                    Text("Talkover")
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(appState.isTalkoverActive ? DJTheme.background : DJTheme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: DJTheme.minTouchTarget)
                .background(appState.isTalkoverActive ? Color.yellow : DJTheme.cardHeader)
                .cornerRadius(DJTheme.controlRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                        .stroke(appState.isTalkoverActive ? Color.yellow : DJTheme.border.opacity(0.8), lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(StudioPressableStyle())
            .help("Ducks Master music (-16.5 dB attenuation + vocal pocket EQ); microphone is external (Hotkey: T)")
        }
        .padding(8)
        .background(DJTheme.cardBackground)
        .cornerRadius(DJTheme.cardRadius)
        .overlay(
            RoundedRectangle(cornerRadius: DJTheme.cardRadius)
                .stroke(DJTheme.border.opacity(0.6), lineWidth: 1)
        )
    }

    private func transitionControls() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Transition")
                    .font(.system(size: 10, weight: .semibold))
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
                        Text("\(bars) Bars").tag(bars)
                    }
                }
                .labelsHidden()
                .frame(width: 90)
                .disabled(appState.isTransitionBusy)

                Button {
                    Task { await appState.executeTransition() }
                } label: {
                    Label("Execute", systemImage: "arrow.left.arrow.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(appState.transitionIsReady && !appState.isTransitionBusy ? DJTheme.master : DJTheme.textMuted)
                        .padding(.horizontal, 8)
                        .frame(minHeight: DJTheme.minTouchTarget)
                        .background(DJTheme.cardHeader)
                        .cornerRadius(DJTheme.controlRadius)
                        .overlay(
                            RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                                .stroke(appState.transitionIsReady && !appState.isTransitionBusy ? DJTheme.master.opacity(0.6) : DJTheme.border.opacity(0.7), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(StudioPressableStyle())
                .disabled(!appState.transitionIsReady || appState.isTransitionBusy)
                .help("Start the selected macro from the outgoing deck's current playhead")

                Button {
                    Task { await appState.toggleAutoPilot() }
                } label: {
                    Label(appState.isAutoPilotArmed ? "Disarm" : "Arm", systemImage: "autopilot")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(appState.isAutoPilotArmed ? DJTheme.cue : DJTheme.textPrimary)
                        .padding(.horizontal, 8)
                        .frame(minHeight: DJTheme.minTouchTarget)
                        .background(appState.isAutoPilotArmed ? DJTheme.cue.opacity(0.18) : DJTheme.cardHeader)
                        .cornerRadius(DJTheme.controlRadius)
                        .overlay(
                            RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                                .stroke(appState.isAutoPilotArmed ? DJTheme.cue.opacity(0.8) : DJTheme.border.opacity(0.7), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(StudioPressableStyle())
                .disabled(appState.isAutoPilotArmed ? false : (appState.autoPilotReadinessMessage != nil || appState.isTransitionBusy))
                .help(appState.isAutoPilotArmed
                    ? "Disarm the one-shot transition"
                    : (appState.autoPilotReadinessMessage ?? "Arm a one-shot transition at the outgoing mix-out cue"))

                if appState.isTransitionBusy {
                    Button {
                        Task { await appState.cancelTransition() }
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(DJTheme.statusError)
                            .padding(.horizontal, 8)
                            .frame(minHeight: DJTheme.minTouchTarget)
                            .background(DJTheme.cardHeader)
                            .cornerRadius(DJTheme.controlRadius)
                            .overlay(
                                RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                                    .stroke(DJTheme.statusError.opacity(0.6), lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(StudioPressableStyle())
                    .help("Cancel the armed transition or restore the outgoing deck after an active transition")
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Text(appState.transitionReadinessText)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(appState.transitionIsReady ? DJTheme.textSecondary : DJTheme.textMuted)
                    .lineLimit(1)

                if appState.isTransitionRunning {
                    ProgressView(value: appState.transitionProgress)
                        .frame(width: 120)
                    Text("\(Int(appState.transitionProgress * 100))%")
                        .font(.system(size: 9.5, weight: .bold))
                        .monospacedDigit()
                        .foregroundColor(DJTheme.textAccent)
                } else if appState.isAutoPilotArmed {
                    Text("AutoPilot Armed at Mix Out")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(DJTheme.textAccent)
                }

                if let error = appState.transitionErrorMessage {
                    Text(error)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(.red)
                        .lineLimit(1)
                        .help(error)
                }
            }
        }
        .padding(8)
        .background(DJTheme.cardBackground)
        .cornerRadius(DJTheme.cardRadius)
        .overlay(
            RoundedRectangle(cornerRadius: DJTheme.cardRadius)
                .stroke(DJTheme.border.opacity(0.6), lineWidth: 1)
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
                        .font(.system(size: 9.5))
                        .foregroundColor(DJTheme.textSecondary)
                    Text("Soundboard")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(DJTheme.textPrimary)

                    if !isSoundboardExpanded {
                        Text("F1–F8")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(DJTheme.textMuted)
                    }

                    Spacer()
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(DJTheme.cardBackground)
        .cornerRadius(DJTheme.cardRadius)
        .overlay(
            RoundedRectangle(cornerRadius: DJTheme.cardRadius)
                .stroke(DJTheme.border.opacity(0.6), lineWidth: 1)
        )
    }

    private func soundboardPadButton(pad: SoundboardPadSnapshot) -> some View {
        Button(action: {
            appState.triggerSoundboardPad(index: pad.index)
        }) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("[\(pad.keyLabel)]")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(pad.isPlaying ? DJTheme.background : DJTheme.textSecondary)

                    Spacer()

                    Circle()
                        .fill(pad.error != nil ? Color.orange : Color.clear) // Warn only for a file that failed; a playing pad lights up whole.
                        .frame(width: 5, height: 5)
                }

                Text(pad.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(pad.isPlaying ? DJTheme.background : DJTheme.textPrimary)
                    .lineLimit(1)

                HStack {
                    // No file in 08_Soundboard_SFX is the normal default, so this stays muted; orange marks a failed file.
                    if pad.isFallback {
                        Text(pad.error != nil ? "File failed · tone" : "Built-in tone")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(pad.isPlaying ? DJTheme.background.opacity(0.8) : DJTheme.textMuted)
                    }

                    Spacer()

                    Text(formatDuration(pad.durationSeconds))
                        .font(.system(size: 8, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(pad.isPlaying ? DJTheme.background.opacity(0.8) : DJTheme.textMuted)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(pad.isPlaying ? Color.yellow : DJTheme.cardHeader)
            .cornerRadius(DJTheme.controlRadius)
            .overlay(
                RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                    .stroke(pad.isPlaying ? Color.yellow : (pad.error != nil ? Color.orange.opacity(0.5) : DJTheme.border.opacity(0.7)), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioPressableStyle())
        .help(pad.error != nil
              ? "Play \(pad.title) (\(pad.keyLabel)). Its sound file could not be used, so a built-in tone plays instead."
              : pad.isFallback
                ? "Play \(pad.title) (\(pad.keyLabel)). Add your own sounds to the 08_Soundboard_SFX folder."
                : "Play \(pad.title) (\(pad.keyLabel))")
    }

    private func formatDuration(_ duration: Double) -> String {
        guard duration.isFinite, duration >= 0.0 else { return "0:00" }
        if duration < 1.0 {
            return String(format: "%.1fs", duration)
        }
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
            .buttonStyle(StudioPressableStyle())
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
            Label("Safety Lock", systemImage: appState.isMasterSafetyLockEnabled ? "lock.fill" : "lock.open")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(appState.isMasterSafetyLockEnabled ? DJTheme.cue : DJTheme.textSecondary)
                .padding(.horizontal, 6)
                .frame(minHeight: DJTheme.minTouchTarget)
                .contentShape(Rectangle())
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
            Label("Load", systemImage: "arrow.down.doc.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DJTheme.textPrimary)
                .padding(.horizontal, 7)
                .frame(minHeight: DJTheme.minTouchTarget)
                .background(color.opacity(0.18))
                .cornerRadius(DJTheme.chipRadius)
                .overlay(RoundedRectangle(cornerRadius: DJTheme.chipRadius).stroke(color.opacity(0.8), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .help(appState.selectedTrackPath == nil
              ? "Select a library track first. Analysis is optional."
              : "Load the selected library file into \(title). Analysis is optional; Safety Lock and automation still apply.")
        .accessibilityLabel("Load selected track into \(title)")
        .accessibilityIdentifier("deckLoadButton-\(deck.rawValue)")
    }

    var body: some View { button.buttonStyle(StudioPressableStyle()) }
}
