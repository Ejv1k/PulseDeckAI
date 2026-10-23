import SwiftUI
import PulseDeckCore

public struct LibraryBrowserView: View {
    @ObservedObject var appState: AppState
    @FocusState private var isAuditionFocused: Bool

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        HStack(spacing: 12) {
            // Left Column: Crates Navigation List
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("DJ CRATES (\(appState.scanSummary?.totalCrates ?? 0))")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(DJTheme.textSecondary)

                    Spacer()

                    if let summary = appState.scanSummary {
                        Text("\(summary.totalAudioTracks) files")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(DJTheme.deckA)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                ScrollView {
                    LazyVStack(spacing: 4) {
                        if let crates = appState.scanSummary?.crates {
                            ForEach(crates) { crate in
                                Button(action: {
                                    appState.selectCrate(crate)
                                }) {
                                    HStack(spacing: 8) {
                                        if !crate.isReadable {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .font(.system(size: 12))
                                                .foregroundColor(.orange)
                                        } else {
                                            Image(systemName: crate.trackCount > 0 ? "music.note.list" : "folder")
                                                .font(.system(size: 12))
                                                .foregroundColor(appState.selectedCrate?.id == crate.id ? DJTheme.deckA : DJTheme.textMuted)
                                        }

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(crate.displayName)
                                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                                .foregroundColor(appState.selectedCrate?.id == crate.id ? DJTheme.textPrimary : DJTheme.textSecondary)
                                                .lineLimit(1)

                                            HStack(spacing: 6) {
                                                if !crate.isReadable {
                                                    Text("Unreadable")
                                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                                        .foregroundColor(.orange)
                                                } else {
                                                    Text(crate.hasGitKeep ? ".gitkeep ✓" : "no .gitkeep")
                                                        .font(.system(size: 9, design: .monospaced))
                                                        .foregroundColor(DJTheme.textMuted)
                                                }
                                            }
                                        }

                                        Spacer()

                                        if !crate.isReadable {
                                            Image(systemName: "exclamationmark.triangle")
                                                .font(.system(size: 10))
                                                .foregroundColor(.orange)
                                        } else {
                                            Text("\(crate.trackCount)")
                                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(appState.selectedCrate?.id == crate.id ? DJTheme.deckA.opacity(0.3) : DJTheme.cardHeader)
                                                .foregroundColor(appState.selectedCrate?.id == crate.id ? DJTheme.deckA : DJTheme.textMuted)
                                                .cornerRadius(3)
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(appState.selectedCrate?.id == crate.id ? DJTheme.cardHeader : Color.clear)
                                    .cornerRadius(4)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(appState.selectedCrate?.id == crate.id ? DJTheme.deckA.opacity(0.5) : Color.clear, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(4)
                }
            }
            .frame(width: 260)
            .background(DJTheme.cardBackground)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(DJTheme.border, lineWidth: 1)
            )

            // Right Column: Crate Detail, Compatibility Badges, Track List & Audition Bar
            VStack(alignment: .leading, spacing: 8) {
                if let selected = appState.selectedCrate {
                    // Header Bar with Crate Info and Reference Deck Selector
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selected.displayName)
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundColor(DJTheme.textPrimary)

                            Text("Folder: \(selected.folderName)")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundColor(DJTheme.textMuted)
                        }

                        Spacer()

                        // Compatibility Reference Deck Selector
                        HStack(spacing: 6) {
                            Text("REF:")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundColor(DJTheme.textSecondary)

                            Button(action: {
                                appState.setCompatibilityReferenceDeck(.deckA)
                            }) {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(DJTheme.deckA)
                                        .frame(width: 5, height: 5)
                                    Text("DECK A")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(appState.compatibilityReferenceDeck == .deckA ? DJTheme.deckA.opacity(0.25) : DJTheme.cardHeader)
                                .foregroundColor(appState.compatibilityReferenceDeck == .deckA ? DJTheme.deckA : DJTheme.textMuted)
                                .cornerRadius(3)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(appState.compatibilityReferenceDeck == .deckA ? DJTheme.deckA : Color.clear, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)

                            Button(action: {
                                appState.setCompatibilityReferenceDeck(.deckB)
                            }) {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(DJTheme.deckB)
                                        .frame(width: 5, height: 5)
                                    Text("DECK B")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(appState.compatibilityReferenceDeck == .deckB ? DJTheme.deckB.opacity(0.25) : DJTheme.cardHeader)
                                .foregroundColor(appState.compatibilityReferenceDeck == .deckB ? DJTheme.deckB : DJTheme.textMuted)
                                .cornerRadius(3)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(appState.compatibilityReferenceDeck == .deckB ? DJTheme.deckB : Color.clear, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)

                            if let ref = appState.referenceTrack {
                                Text("\(ref.bpm > 0 ? String(format: "%.1f BPM", ref.bpm) : "BPM ?") • \(ref.musicalKey.isEmpty ? "KEY ?" : ref.musicalKey)")
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundColor(DJTheme.textSecondary)
                                    .lineLimit(1)
                            } else {
                                Text("(NO TRACK)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(DJTheme.textMuted)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(DJTheme.cardHeader)
                    .cornerRadius(4)

                    if !selected.isReadable {
                        VStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.orange)
                            Text("Crate Unreadable")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(DJTheme.textPrimary)
                            Text(selected.errorMessage ?? "Permission denied or directory listing failure")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(DJTheme.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    } else if selected.audioFiles.isEmpty {
                        VStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "opticaldisc")
                                .font(.system(size: 32))
                                .foregroundColor(DJTheme.textMuted)
                            Text("No audio files currently in this crate")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(DJTheme.textMuted)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        List {
                            ForEach(Array(selected.audioFiles.enumerated()), id: \.offset) { index, file in
                                let relPath = "\(selected.folderName)/\(file)"
                                let isSelected = appState.selectedTrackPath == relPath
                                let isPreviewing = appState.previewTrackPath == relPath
                                let trackEntry = appState.loadedCache?.tracks[relPath]
                                let comp = trackEntry.flatMap { appState.compatibility(for: $0) }

                                HStack(spacing: 10) {
                                    // Row index & track selection button
                                    Button(action: {
                                        appState.selectTrack(relativePath: relPath)
                                    }) {
                                        HStack(spacing: 8) {
                                            Text(String(format: "%02d", index + 1))
                                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                                .foregroundColor(isSelected ? DJTheme.master : DJTheme.deckA)
                                                .frame(width: 22, alignment: .leading)

                                            Image(systemName: isSelected ? "waveform.circle.fill" : "waveform")
                                                .font(.system(size: 11))
                                                .foregroundColor(isSelected ? DJTheme.deckA : DJTheme.textSecondary)

                                            Text(file)
                                                .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .monospaced))
                                                .foregroundColor(isSelected ? DJTheme.textPrimary : DJTheme.textSecondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .buttonStyle(.plain)

                                    Spacer()

                                    // Real cached BPM & Musical Key metadata
                                    if let track = trackEntry {
                                        HStack(spacing: 6) {
                                            if track.bpm > 0 {
                                                Text(String(format: "%.1f BPM", track.bpm))
                                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                                    .foregroundColor(DJTheme.deckA)
                                            } else {
                                                Text("BPM: UNKNOWN")
                                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                                    .foregroundColor(DJTheme.textMuted)
                                            }

                                            if !track.musicalKey.isEmpty && track.musicalKey.caseInsensitiveCompare("Unknown") != .orderedSame {
                                                Text(track.musicalKey)
                                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                                    .foregroundColor(DJTheme.cue)
                                            } else {
                                                Text("KEY: UNKNOWN")
                                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                                    .foregroundColor(DJTheme.textMuted)
                                            }
                                        }

                                        // Compatibility Badges against Reference Deck
                                        if let comp {
                                            HStack(spacing: 4) {
                                                // Harmonic Key Badge
                                                Text(comp.key.badgeLabel)
                                                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 2)
                                                    .background(comp.key.isHarmonic ? DJTheme.master.opacity(0.2) : (comp.key == .unknown ? DJTheme.cardHeader : Color.red.opacity(0.2)))
                                                    .foregroundColor(comp.key.isHarmonic ? DJTheme.master : (comp.key == .unknown ? DJTheme.textMuted : .red))
                                                    .cornerRadius(3)

                                                // Tempo Badge
                                                Text(comp.tempo.badgeLabel)
                                                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 2)
                                                    .background(comp.tempo.isCompatible ? DJTheme.deckA.opacity(0.2) : (comp.tempo == .unknown ? DJTheme.cardHeader : Color.orange.opacity(0.2)))
                                                    .foregroundColor(comp.tempo.isCompatible ? DJTheme.deckA : (comp.tempo == .unknown ? DJTheme.textMuted : .orange))
                                                    .cornerRadius(3)
                                            }
                                        } else {
                                            Text("NO REF")
                                                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(DJTheme.cardHeader)
                                                .foregroundColor(DJTheme.textMuted)
                                                .cornerRadius(3)
                                        }
                                    } else {
                                        Text("UNANALYZED")
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundColor(DJTheme.textMuted)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(DJTheme.cardHeader)
                                            .cornerRadius(3)
                                    }

                                    // Headphone Audition Cue Button
                                    Button(action: {
                                        if isPreviewing {
                                            appState.togglePreviewPlay()
                                        } else {
                                            appState.loadPreviewTrack(relativePath: relPath, playWhenReady: true)
                                        }
                                    }) {
                                        HStack(spacing: 3) {
                                            Image(systemName: (isPreviewing && appState.isPreviewPlaying) ? "pause.fill" : "headphones")
                                            Text((isPreviewing && appState.isPreviewPlaying) ? "PAUSE" : "CUE")
                                        }
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background((isPreviewing && appState.isPreviewPlaying) ? DJTheme.cue : DJTheme.cue.opacity(0.2))
                                        .foregroundColor((isPreviewing && appState.isPreviewPlaying) ? DJTheme.background : DJTheme.cue)
                                        .cornerRadius(3)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 3)
                                                .stroke(DJTheme.cue, lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .help("Audition in headphones via Cue output")
                                }
                                .padding(.vertical, 3)
                                .padding(.horizontal, 6)
                                .background(isSelected ? DJTheme.deckA.opacity(0.1) : Color.clear)
                                .cornerRadius(4)
                                .listRowBackground(DJTheme.cardBackground)
                            }
                        }
                        .listStyle(.plain)
                        .background(DJTheme.cardBackground)
                    }

                    // Dedicated Audition Transport & Scrub Strip
                    auditionControlBar
                } else {
                    Text("Select a crate from the library")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(DJTheme.textMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    }

    // MARK: - Dedicated Audition Control Bar

    private var auditionControlBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "headphones")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DJTheme.cue)

                if let previewPath = appState.previewTrackPath {
                    Text("AUDITION:")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(DJTheme.textSecondary)

                    Text(previewPath)
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundColor(DJTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("HEADPHONE AUDITION — SELECT TRACK OR CLICK CUE")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundColor(DJTheme.textMuted)
                }

                Spacer()

                if let error = appState.previewErrorMessage {
                    Text(error)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.red)
                        .lineLimit(1)
                }

                Text("\(formatTime(appState.previewPositionSeconds)) / \(formatTime(appState.previewDurationSeconds))")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(DJTheme.cue)
            }

            HStack(spacing: 8) {
                // Play / Pause Button
                Button(action: {
                    appState.togglePreviewPlay()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: appState.isPreviewPlaying ? "pause.fill" : "play.fill")
                        Text(appState.isPreviewPlaying ? "PAUSE" : "AUDITION")
                    }
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(appState.isPreviewPlaying ? DJTheme.cue : DJTheme.cardHeader)
                    .foregroundColor(appState.isPreviewPlaying ? DJTheme.background : DJTheme.textPrimary)
                    .cornerRadius(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(DJTheme.cue, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(appState.previewTrackPath == nil)

                // Stop Button
                Button(action: {
                    appState.stopPreview()
                }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                        .padding(5)
                        .background(DJTheme.cardHeader)
                        .foregroundColor(DJTheme.textSecondary)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .disabled(appState.previewTrackPath == nil)

                // Bounded Continuous Scrub Slider
                Slider(
                    value: Binding(
                        get: { appState.previewPositionSeconds },
                        set: { appState.seekPreview(to: $0) }
                    ),
                    in: 0.0...max(appState.previewDurationSeconds, 0.001)
                )
                .accentColor(DJTheme.cue)
                .disabled(appState.previewTrackPath == nil || appState.previewDurationSeconds <= 0)

                // Beat Step Buttons (disabled when authentic measured grid is absent)
                HStack(spacing: 4) {
                    Button("-4b") {
                        appState.stepPreview(beats: -4.0)
                    }
                    .help("Step backward 4 beats / 1 bar (Shift+Left)")
                    .buttonStyle(.plain)
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(DJTheme.cardHeader)
                    .foregroundColor(appState.previewHasUsableBeatGrid ? DJTheme.textPrimary : DJTheme.textMuted)
                    .cornerRadius(3)
                    .disabled(!appState.previewHasUsableBeatGrid)

                    Button("-1b") {
                        appState.stepPreview(beats: -1.0)
                    }
                    .help("Step backward 1 beat (Left)")
                    .buttonStyle(.plain)
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(DJTheme.cardHeader)
                    .foregroundColor(appState.previewHasUsableBeatGrid ? DJTheme.textPrimary : DJTheme.textMuted)
                    .cornerRadius(3)
                    .disabled(!appState.previewHasUsableBeatGrid)

                    Button("+1b") {
                        appState.stepPreview(beats: 1.0)
                    }
                    .help("Step forward 1 beat (Right)")
                    .buttonStyle(.plain)
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(DJTheme.cardHeader)
                    .foregroundColor(appState.previewHasUsableBeatGrid ? DJTheme.textPrimary : DJTheme.textMuted)
                    .cornerRadius(3)
                    .disabled(!appState.previewHasUsableBeatGrid)

                    Button("+4b") {
                        appState.stepPreview(beats: 4.0)
                    }
                    .help("Step forward 4 beats / 1 bar (Shift+Right)")
                    .buttonStyle(.plain)
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(DJTheme.cardHeader)
                    .foregroundColor(appState.previewHasUsableBeatGrid ? DJTheme.textPrimary : DJTheme.textMuted)
                    .cornerRadius(3)
                    .disabled(!appState.previewHasUsableBeatGrid)
                }
            }
        }
        .padding(8)
        .background(DJTheme.cardHeader)
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isAuditionFocused ? DJTheme.cue.opacity(0.8) : DJTheme.border, lineWidth: 1)
        )
        .focusable()
        .focused($isAuditionFocused)
        .onKeyPress(phases: .down) { press in
            handleAuditionKeyPress(press)
        }
    }

    // MARK: - Keyboard Handling for Audition Player

    private func handleAuditionKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard appState.previewTrackPath != nil else { return .ignored }

        if press.key == .leftArrow {
            if press.modifiers.contains(.shift) {
                appState.stepPreview(beats: -4.0)
            } else {
                appState.stepPreview(beats: -1.0)
            }
            return .handled
        } else if press.key == .rightArrow {
            if press.modifiers.contains(.shift) {
                appState.stepPreview(beats: 4.0)
            } else {
                appState.stepPreview(beats: 1.0)
            }
            return .handled
        } else if press.characters == " " {
            appState.togglePreviewPlay()
            return .handled
        }

        return .ignored
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00.00" }
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        let millis = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%d:%02d.%02d", minutes, secs, millis)
    }
}
