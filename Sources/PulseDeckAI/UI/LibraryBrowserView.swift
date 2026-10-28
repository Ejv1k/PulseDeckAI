import SwiftUI
import PulseDeckCore
import UniformTypeIdentifiers

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
                        if let crates = appState.scanSummary?.crates, !crates.isEmpty {
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
                                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                                .foregroundColor(appState.selectedCrate?.id == crate.id ? DJTheme.textPrimary : DJTheme.textSecondary)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)

                                            if !crate.isReadable {
                                                Text("Unreadable")
                                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                                    .foregroundColor(.orange)
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
                        } else if appState.isScanning {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("Scanning library...")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(DJTheme.textMuted)
                            }
                            .padding(8)
                        } else if let error = appState.scanSummary?.scanError {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Scan Error", systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.orange)
                                Text(error)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(DJTheme.textSecondary)
                                    .lineLimit(4)
                            }
                            .padding(8)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("No Crates", systemImage: "folder.badge.questionmark")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(DJTheme.textSecondary)
                                Text("Add crate subfolders:\nPulseDeck_Library/Favorites/track.mp3")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(DJTheme.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(8)
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
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(Array(selected.audioFiles.enumerated()), id: \.element) { index, file in
                                    let relPath = "\(selected.folderName)/\(file)"
                                    let isSelected = appState.selectedTrackPath == relPath
                                    let isPreviewing = appState.previewTrackPath == relPath
                                    let trackEntry = appState.loadedCache?.tracks[relPath]
                                    let comp = trackEntry.flatMap { appState.compatibility(for: $0) }
                                    let transfer = LibraryTrackTransfer(libraryRoot: appState.libraryRootURL, relativePath: relPath)

                                    HStack(spacing: 10) {
                                        // Row index & track selection button
                                        LibraryTrackSelectionButton(appState: appState, relativePath: relPath) {
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
                                            .frame(minHeight: 28)
                                            .contentShape(Rectangle())
                                        }

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

                                        LibraryTrackAnalysisButton(appState: appState, relativePath: relPath)

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
                                            .frame(minHeight: DJTheme.minTouchTarget)
                                            .background((isPreviewing && appState.isPreviewPlaying) ? DJTheme.cue : DJTheme.cue.opacity(0.2))
                                            .foregroundColor((isPreviewing && appState.isPreviewPlaying) ? DJTheme.background : DJTheme.cue)
                                            .cornerRadius(DJTheme.chipRadius)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: DJTheme.chipRadius)
                                                    .stroke(DJTheme.cue, lineWidth: 1)
                                            )
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(StudioPressableStyle())
                                        .help("Audition in headphones via Cue output")
                                    }
                                    .padding(.vertical, 2)
                                    .padding(.horizontal, 6)
                                    .background(isSelected ? DJTheme.deckA.opacity(0.1) : Color.clear)
                                    .cornerRadius(4)
                                    .contentShape(Rectangle())
                                    .draggable(transfer)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .background(DJTheme.cardBackground)
                    }

                    Text("Select a track, then LOAD A/B or drag onto a deck. Analyze locally for waveforms and beat tools; no account required.")
                        .font(.system(size: 10))
                        .foregroundStyle(DJTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Dedicated Audition Transport & Scrub Strip
                    auditionControlBar
                } else {
                    if appState.isScanning {
                        VStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Scanning library directory...")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(DJTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error = appState.scanSummary?.scanError {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.orange)
                            Text("Library Scan Error")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(DJTheme.textPrimary)
                            Text(error)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(DJTheme.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if (appState.scanSummary?.crates ?? []).isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "folder.badge.questionmark")
                                .font(.system(size: 28))
                                .foregroundColor(DJTheme.textMuted)
                            Text("No Crates Found in Library")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(DJTheme.textPrimary)
                            Text("Audio files must be placed inside subfolders of the library directory to form crates.\nExample: PulseDeck_Library/Favorites/track.mp3")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(DJTheme.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text("Select a crate from the library")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(DJTheme.textMuted)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// Shared production row selection control. Selecting a file does not require cached analysis.
@MainActor
struct LibraryTrackSelectionButton<Label: View>: View {
    @ObservedObject var appState: AppState
    let relativePath: String
    @ViewBuilder let label: () -> Label

    var button: some View {
        Button { appState.selectTrack(relativePath: relativePath) } label: { label() }
            .accessibilityIdentifier("trackSelectButton-\(relativePath)")
    }

    var body: some View {
        button.buttonStyle(NonBlockingRowButtonStyle())
    }
}

/// Primitive button style allowing pointer drag gestures to propagate to parent draggable containers
/// while preserving keyboard navigation (focus, Space/Return activation) and accessible default action.
struct NonBlockingRowButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowButtonContent(configuration: configuration)
    }

    private struct RowButtonContent: View {
        let configuration: Configuration
        @FocusState private var isFocused: Bool

        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .onTapGesture {
                    configuration.trigger()
                }
                .focusable()
                .focused($isFocused)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(isFocused ? DJTheme.deckA : Color.clear, lineWidth: 1.5)
                )
                .onKeyPress(phases: .down) { press in
                    if press.key == .space || press.key == .return {
                        configuration.trigger()
                        return .handled
                    }
                    return .ignored
                }
                .accessibilityAction(.default) {
                    configuration.trigger()
                }
        }
    }
}

@MainActor
struct LibraryTrackAnalysisButton: View {
    @ObservedObject var appState: AppState
    let relativePath: String

    var button: some View {
        Button { appState.analyzeTrack(relativePath: relativePath) } label: {
            HStack(spacing: 4) {
                if let state = appState.analysisStatus(for: relativePath) {
                    switch state {
                    case .running:
                        ProgressView().controlSize(.mini)
                        Text("RUNNING")
                    case .complete:
                        Image(systemName: "checkmark")
                        Text("ANALYZE")
                    case .failed:
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("RETRY")
                    }
                } else {
                    Image(systemName: "waveform.path")
                    Text("ANALYZE")
                }
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(buttonForegroundColor)
            .padding(.horizontal, 6)
            .frame(minHeight: DJTheme.minTouchTarget)
            .background(buttonBackgroundColor)
            .cornerRadius(DJTheme.chipRadius)
            .overlay(
                RoundedRectangle(cornerRadius: DJTheme.chipRadius)
                    .stroke(buttonBorderColor, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .disabled(appState.isAnalyzingLibraryTrack)
        .help(buttonHelp)
        .accessibilityLabel("Analyze \(relativePath) locally")
        .accessibilityIdentifier("trackAnalyzeButton-\(relativePath)")
    }

    private var buttonForegroundColor: Color {
        if let state = appState.analysisStatus(for: relativePath) {
            switch state {
            case .running:
                return DJTheme.deckA
            case .complete:
                return DJTheme.textSecondary
            case .failed:
                return .orange
            }
        }
        return appState.isAnalyzingLibraryTrack ? DJTheme.textMuted : DJTheme.deckA
    }

    private var buttonBackgroundColor: Color {
        if let state = appState.analysisStatus(for: relativePath) {
            switch state {
            case .running:
                return DJTheme.deckA.opacity(0.2)
            case .complete:
                return DJTheme.cardHeader
            case .failed:
                return Color.orange.opacity(0.15)
            }
        }
        return DJTheme.deckA.opacity(0.15)
    }

    private var buttonBorderColor: Color {
        if let state = appState.analysisStatus(for: relativePath) {
            switch state {
            case .running:
                return DJTheme.deckA
            case .complete:
                return DJTheme.border
            case .failed:
                return Color.orange
            }
        }
        return DJTheme.deckA.opacity(0.5)
    }

    private var buttonHelp: String {
        if let state = appState.analysisStatus(for: relativePath) {
            switch state {
            case .running:
                return "Analysis in progress for this track. Playback remains available."
            case .complete:
                return "Analysis complete. Click to re-run local analysis."
            case .failed(let reason):
                return "Analysis failed: \(reason). Click to retry."
            }
        }
        return appState.isAnalyzingLibraryTrack
            ? "One local analysis is running. Playback and library selection remain available."
            : "Analyze this file locally for waveform, trim estimates and heuristic tempo. No cloud credentials; key remains unknown."
    }

    var body: some View {
        button.buttonStyle(StudioPressableStyle())
    }
}

extension LibraryTrackTransfer {
    var itemProvider: NSItemProvider {
        let provider = NSItemProvider()
        if let data = try? JSONEncoder().encode(self) {
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.pulseDeckLibraryTrack.identifier,
                visibility: .all
            ) { completion in
                completion(data, nil)
                return nil
            }
        }
        return provider
    }
}

