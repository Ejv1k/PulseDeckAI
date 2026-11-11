import SwiftUI
import PulseDeckCore
import UniformTypeIdentifiers

public struct LibraryBrowserView: View {
    @ObservedObject var appState: AppState
    @FocusState private var isAuditionFocused: Bool
    @State private var order: LibraryOrder = .folder
    @State private var searchQuery = ""

    /// How the crate's track list is ordered; only changes the view, never the files.
    enum LibraryOrder: String, CaseIterable {
        case folder = "Folder"
        case bestMatch = "Best match"
        case setFlow = "Set flow"
    }

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        HStack(spacing: 12) {
            // Left Column: Crates Navigation List
            VStack(alignment: .leading, spacing: 6) {
                LibrarySearchField(query: $searchQuery)
                HStack {
                    Text("Crates (\(appState.scanSummary?.totalCrates ?? 0))")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(DJTheme.textSecondary)

                    Spacer()

                    if let summary = appState.scanSummary {
                        Text("\(summary.totalAudioTracks) files")
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
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
                                    searchQuery = ""
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
                                            Text(crate.title)
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundColor(appState.selectedCrate?.id == crate.id ? DJTheme.textPrimary : DJTheme.textSecondary)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)

                                            if !crate.isReadable {
                                                Text("Unreadable")
                                                    .font(.system(size: 9.5, weight: .semibold))
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
                                                .font(.system(size: 10.5, weight: .bold))
                                                .monospacedDigit()
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(appState.selectedCrate?.id == crate.id ? DJTheme.deckA.opacity(0.2) : DJTheme.cardHeader)
                                                .foregroundColor(appState.selectedCrate?.id == crate.id ? DJTheme.deckA : DJTheme.textMuted)
                                                .cornerRadius(DJTheme.chipRadius)
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(appState.selectedCrate?.id == crate.id ? DJTheme.cardHeader : Color.clear)
                                    .cornerRadius(DJTheme.controlRadius)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                                            .stroke(appState.selectedCrate?.id == crate.id ? DJTheme.deckA.opacity(0.4) : Color.clear, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        } else if appState.isScanning {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("Scanning library…")
                                    .font(.system(size: 10))
                                    .foregroundColor(DJTheme.textMuted)
                            }
                            .padding(8)
                        } else if let error = appState.scanSummary?.scanError {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Scan Error", systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundColor(.orange)
                                Text(error)
                                    .font(.system(size: 9.5))
                                    .foregroundColor(DJTheme.textSecondary)
                                    .lineLimit(4)
                            }
                            .padding(8)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("No Crates", systemImage: "folder.badge.questionmark")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundColor(DJTheme.textSecondary)
                                Text("Add crate subfolders:\nPulseDeck_Library/Favorites/track.mp3")
                                    .font(.system(size: 9.5))
                                    .foregroundColor(DJTheme.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(8)
                        }
                    }
                    .padding(4)
                }

                Divider().background(DJTheme.border)
                UpNextView(appState: appState)
            }
            .frame(width: 260)
            .background(DJTheme.cardBackground)
            .cornerRadius(DJTheme.cardRadius)
            .overlay(
                RoundedRectangle(cornerRadius: DJTheme.cardRadius)
                    .stroke(DJTheme.border.opacity(0.6), lineWidth: 1)
            )

            // Right Column: Crate Detail, Compatibility Badges, Track List & Audition Bar
            VStack(alignment: .leading, spacing: 8) {
                if let selected = appState.selectedCrate {
                    // Header Bar with Crate Info and Reference Deck Selector
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selected.title)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(DJTheme.textPrimary)
                                .help(selected.folderName)
                        }

                        Spacer()

                        // Compatibility Reference Deck Selector
                        HStack(spacing: 6) {
                            Text("Ref:")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(DJTheme.textSecondary)

                            Button(action: {
                                appState.setCompatibilityReferenceDeck(.deckA)
                            }) {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(DJTheme.deckA)
                                        .frame(width: 5, height: 5)
                                    Text("Deck A")
                                        .font(.system(size: 9.5, weight: .semibold))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(appState.compatibilityReferenceDeck == .deckA ? DJTheme.deckA.opacity(0.2) : DJTheme.cardHeader)
                                .foregroundColor(appState.compatibilityReferenceDeck == .deckA ? DJTheme.deckA : DJTheme.textMuted)
                                .cornerRadius(DJTheme.chipRadius)
                                .overlay(
                                    RoundedRectangle(cornerRadius: DJTheme.chipRadius)
                                        .stroke(appState.compatibilityReferenceDeck == .deckA ? DJTheme.deckA.opacity(0.8) : DJTheme.border.opacity(0.6), lineWidth: 1)
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
                                    Text("Deck B")
                                        .font(.system(size: 9.5, weight: .semibold))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(appState.compatibilityReferenceDeck == .deckB ? DJTheme.deckB.opacity(0.2) : DJTheme.cardHeader)
                                .foregroundColor(appState.compatibilityReferenceDeck == .deckB ? DJTheme.deckB : DJTheme.textMuted)
                                .cornerRadius(DJTheme.chipRadius)
                                .overlay(
                                    RoundedRectangle(cornerRadius: DJTheme.chipRadius)
                                        .stroke(appState.compatibilityReferenceDeck == .deckB ? DJTheme.deckB.opacity(0.8) : DJTheme.border.opacity(0.6), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)

                            if let ref = appState.referenceTrack, ref.bpm <= 0,
                               ref.musicalKey.isEmpty || ref.musicalKey.caseInsensitiveCompare("Unknown") == .orderedSame {
                                Text("Analyze to match")
                                    .font(.system(size: 9.5))
                                    .foregroundColor(DJTheme.textMuted)
                                    .help("Analyze the reference deck's track to rank tracks by BPM and key")
                            } else if let ref = appState.referenceTrack {
                                Text("\(ref.bpm > 0 ? String(format: "%.1f BPM", ref.bpm) : "BPM —") • \(ref.musicalKey.isEmpty || ref.musicalKey.caseInsensitiveCompare("Unknown") == .orderedSame ? "Key —" : ref.musicalKey)")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundColor(DJTheme.textSecondary)
                                    .lineLimit(1)
                            } else {
                                Text("(No Track)")
                                    .font(.system(size: 9.5))
                                    .foregroundColor(DJTheme.textMuted)
                            }

                            orderPicker

                            Divider()
                                .frame(height: 12)
                                .background(DJTheme.border)

                            analyzeAllControl(for: selected)

                            HStack(spacing: 4) {
                                Text("Engine:")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundColor(DJTheme.textSecondary)

                                Button(action: {
                                    appState.selectedAnalysisMethod = .dsp
                                }) {
                                    Text("DSP")
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(appState.selectedAnalysisMethod == .dsp ? DJTheme.deckA.opacity(0.2) : DJTheme.cardHeader)
                                        .foregroundColor(appState.selectedAnalysisMethod == .dsp ? DJTheme.deckA : DJTheme.textMuted)
                                        .cornerRadius(DJTheme.chipRadius)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: DJTheme.chipRadius)
                                                .stroke(appState.selectedAnalysisMethod == .dsp ? DJTheme.deckA.opacity(0.8) : DJTheme.border.opacity(0.6), lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                                .help("Default DSP analyzer (heuristic onset autocorrelation)")
                                .accessibilityLabel("Select DSP analysis engine")

                                Button(action: {
                                    appState.selectedAnalysisMethod = .nativeModel
                                }) {
                                    Text("Model")
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .fixedSize()
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(appState.selectedAnalysisMethod == .nativeModel ? DJTheme.cue.opacity(0.2) : DJTheme.cardHeader)
                                        .foregroundColor(appState.selectedAnalysisMethod == .nativeModel ? DJTheme.cue : DJTheme.textMuted)
                                        .cornerRadius(DJTheme.chipRadius)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: DJTheme.chipRadius)
                                                .stroke(appState.selectedAnalysisMethod == .nativeModel ? DJTheme.cue.opacity(0.8) : DJTheme.border.opacity(0.6), lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                                .help("Beat This! beat and downbeat model with phrase-aligned cues and key detection.")
                                .accessibilityLabel("Select Native CoreML Model analysis engine")
                            }
                            .frame(minHeight: 28)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(DJTheme.cardHeader)
                    .cornerRadius(DJTheme.controlRadius)

                    if !selected.isReadable {
                        VStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.orange)
                            Text("Crate Unreadable")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(DJTheme.textPrimary)
                            Text(selected.errorMessage ?? "Permission denied or directory listing failure")
                                .font(.system(size: 11))
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
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(DJTheme.textMuted)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(Array(orderedFiles(selected).enumerated()), id: \.element) { index, file in
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
                                                    .font(.system(size: 10.5, weight: .semibold))
                                                    .monospacedDigit()
                                                    .foregroundColor(isSelected ? DJTheme.master : DJTheme.deckA)
                                                    .frame(width: 22, alignment: .leading)

                                                Image(systemName: isSelected ? "waveform.circle.fill" : "waveform")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(isSelected ? DJTheme.deckA : DJTheme.textSecondary)

                                                Text(LibraryTrackTitle.display(file))
                                                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                                    .foregroundColor(isSelected ? DJTheme.textPrimary : DJTheme.textSecondary)
                                                    .lineLimit(1)
                                            }
                                            .frame(minHeight: 28)
                                            .contentShape(Rectangle())
                                        }

                                        Spacer()

                                        if appState.playedTonight.contains(relPath) { PlayedLabel() }

                                        // Real cached BPM & Musical Key metadata
                                        if let track = trackEntry {
                                            HStack(spacing: 6) {
                                                if track.bpm > 0 {
                                                    Text(String(format: "%.1f BPM", track.bpm))
                                                        .font(.system(size: 9.5, weight: .semibold))
                                                        .monospacedDigit()
                                                        .foregroundColor(DJTheme.deckA)
                                                } else {
                                                    Text("BPM —")
                                                        .font(.system(size: 9, weight: .medium))
                                                        .foregroundColor(DJTheme.textMuted)
                                                }

                                                if !track.musicalKey.isEmpty && track.musicalKey.caseInsensitiveCompare("Unknown") != .orderedSame {
                                                    Text(track.musicalKey)
                                                        .font(.system(size: 9.5, weight: .semibold))
                                                        .foregroundColor(DJTheme.cue)
                                                }
                                            }

                                            // Compatibility Badges against Reference Deck
                                            if let comp {
                                                HStack(spacing: 4) {
                                                    // Harmonic Key Badge
                                                    Text(comp.key.badgeLabel)
                                                        .font(.system(size: 8.5, weight: .bold))
                                                        .padding(.horizontal, 5)
                                                        .padding(.vertical, 2)
                                                        .background(comp.key.isHarmonic ? DJTheme.master.opacity(0.2) : (comp.key == .unknown ? DJTheme.cardHeader : Color.red.opacity(0.2)))
                                                        .foregroundColor(comp.key.isHarmonic ? DJTheme.master : (comp.key == .unknown ? DJTheme.textMuted : .red))
                                                        .cornerRadius(DJTheme.chipRadius)

                                                    // Tempo Badge
                                                    Text(comp.tempoBadgeLabel)
                                                        .font(.system(size: 8.5, weight: .bold))
                                                        .padding(.horizontal, 5)
                                                        .padding(.vertical, 2)
                                                        .background(comp.tempo.isCompatible ? DJTheme.deckA.opacity(0.2) : (comp.tempo == .unknown ? DJTheme.cardHeader : Color.orange.opacity(0.2)))
                                                        .foregroundColor(comp.tempo.isCompatible ? DJTheme.deckA : (comp.tempo == .unknown ? DJTheme.textMuted : .orange))
                                                        .cornerRadius(DJTheme.chipRadius)
                                                }
                                            }
                                        }

                                        UpNextToggleButton(appState: appState, relativePath: relPath)

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
                                                Text((isPreviewing && appState.isPreviewPlaying) ? "Pause" : "Cue")
                                            }
                                            .font(.system(size: 9.5, weight: .semibold))
                                            .padding(.horizontal, 6)
                                            .frame(minHeight: DJTheme.minTouchTarget)
                                            .background((isPreviewing && appState.isPreviewPlaying) ? DJTheme.cue : (isSelected || isPreviewing ? DJTheme.cue.opacity(0.18) : Color.clear))
                                            .foregroundColor((isPreviewing && appState.isPreviewPlaying) ? DJTheme.background : (isSelected || isPreviewing ? DJTheme.cue : DJTheme.textSecondary))
                                            .cornerRadius(DJTheme.chipRadius)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: DJTheme.chipRadius)
                                                    .stroke(isSelected || isPreviewing ? DJTheme.cue.opacity(0.8) : DJTheme.border, lineWidth: 1)
                                            )
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(StudioPressableStyle())
                                        .help("Audition in headphones via Cue output")
                                    }
                                    .padding(.vertical, 2)
                                    .padding(.horizontal, 6)
                                    .background(isSelected ? DJTheme.deckA.opacity(0.1) : Color.clear)
                                    .cornerRadius(DJTheme.controlRadius)
                                    .contentShape(Rectangle())
                                    .contextMenu { UpNextMenu(appState: appState, relativePath: relPath) }
                                    .draggable(transfer)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .background(DJTheme.cardBackground)
                    }

                    // First-run guidance only; once a track is selected the row actions speak for themselves.
                    if appState.selectedTrackPath == nil {
                        Text("Select a track, then Load A/B or drag onto a deck. Analyze locally for waveforms and beat tools; no account required.")
                            .font(.system(size: 10))
                            .foregroundStyle(DJTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Dedicated Audition Transport & Scrub Strip
                    auditionControlBar
                } else {
                    if appState.isScanning {
                        VStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Scanning library directory…")
                                .font(.system(size: 11))
                                .foregroundColor(DJTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error = appState.scanSummary?.scanError {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.orange)
                            Text("Library Scan Error")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(DJTheme.textPrimary)
                            Text(error)
                                .font(.system(size: 10.5))
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
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(DJTheme.textPrimary)
                            Text("Audio files must be placed inside subfolders of the library directory to form crates.\nExample: PulseDeck_Library/Favorites/track.mp3")
                                .font(.system(size: 10.5))
                                .foregroundColor(DJTheme.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text("Select a crate from the library")
                            .font(.system(size: 11.5))
                            .foregroundColor(DJTheme.textMuted)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .overlay { LibrarySearchResultsView(appState: appState, query: searchQuery) }
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
                    Text("Audition:")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DJTheme.textSecondary)

                    Text(previewPath)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(DJTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Headphone audition — select track or click Cue")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DJTheme.textMuted)
                }

                Spacer()

                if let error = appState.previewErrorMessage {
                    Text(error)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(.red)
                        .lineLimit(1)
                }

                Text("\(formatTime(appState.previewPositionSeconds)) / \(formatTime(appState.previewDurationSeconds))")
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(DJTheme.cue)
            }

            HStack(spacing: 8) {
                // Play / Pause Button
                Button(action: {
                    appState.togglePreviewPlay()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: appState.isPreviewPlaying ? "pause.fill" : "play.fill")
                        Text(appState.isPreviewPlaying ? "Pause" : "Audition")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .frame(minHeight: DJTheme.minTouchTarget)
                    .background(appState.isPreviewPlaying ? DJTheme.cue : DJTheme.cardHeader)
                    .foregroundColor(appState.isPreviewPlaying ? DJTheme.background : DJTheme.textPrimary)
                    .cornerRadius(DJTheme.controlRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                            .stroke(DJTheme.cue.opacity(0.8), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(StudioPressableStyle())
                .disabled(appState.previewTrackPath == nil)

                // Stop Button
                Button(action: {
                    appState.stopPreview()
                }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                        .padding(6)
                        .frame(minHeight: DJTheme.minTouchTarget)
                        .background(DJTheme.cardHeader)
                        .foregroundColor(DJTheme.textSecondary)
                        .cornerRadius(DJTheme.controlRadius)
                        .overlay(
                            RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                                .stroke(DJTheme.border.opacity(0.7), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(StudioPressableStyle())
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
                    Button(action: {
                        appState.stepPreview(beats: -4.0)
                    }) {
                        Text("-4b")
                            .font(.system(size: 9, weight: .semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .frame(minHeight: DJTheme.minTouchTarget)
                            .background(DJTheme.cardHeader)
                            .foregroundColor(appState.previewHasUsableBeatGrid ? DJTheme.textPrimary : DJTheme.textMuted)
                            .cornerRadius(DJTheme.chipRadius)
                            .overlay(
                                RoundedRectangle(cornerRadius: DJTheme.chipRadius)
                                    .stroke(DJTheme.border.opacity(0.7), lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(StudioPressableStyle())
                    .disabled(!appState.previewHasUsableBeatGrid)
                    .help("Step backward 4 beats / 1 bar (Shift+Left)")

                    Button(action: {
                        appState.stepPreview(beats: -1.0)
                    }) {
                        Text("-1b")
                            .font(.system(size: 9, weight: .semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .frame(minHeight: DJTheme.minTouchTarget)
                            .background(DJTheme.cardHeader)
                            .foregroundColor(appState.previewHasUsableBeatGrid ? DJTheme.textPrimary : DJTheme.textMuted)
                            .cornerRadius(DJTheme.chipRadius)
                            .overlay(
                                RoundedRectangle(cornerRadius: DJTheme.chipRadius)
                                    .stroke(DJTheme.border.opacity(0.7), lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(StudioPressableStyle())
                    .disabled(!appState.previewHasUsableBeatGrid)
                    .help("Step backward 1 beat (Left)")

                    Button(action: {
                        appState.stepPreview(beats: 1.0)
                    }) {
                        Text("+1b")
                            .font(.system(size: 9, weight: .semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .frame(minHeight: DJTheme.minTouchTarget)
                            .background(DJTheme.cardHeader)
                            .foregroundColor(appState.previewHasUsableBeatGrid ? DJTheme.textPrimary : DJTheme.textMuted)
                            .cornerRadius(DJTheme.chipRadius)
                            .overlay(
                                RoundedRectangle(cornerRadius: DJTheme.chipRadius)
                                    .stroke(DJTheme.border.opacity(0.7), lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(StudioPressableStyle())
                    .disabled(!appState.previewHasUsableBeatGrid)
                    .help("Step forward 1 beat (Right)")

                    Button(action: {
                        appState.stepPreview(beats: 4.0)
                    }) {
                        Text("+4b")
                            .font(.system(size: 9, weight: .semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .frame(minHeight: DJTheme.minTouchTarget)
                            .background(DJTheme.cardHeader)
                            .foregroundColor(appState.previewHasUsableBeatGrid ? DJTheme.textPrimary : DJTheme.textMuted)
                            .cornerRadius(DJTheme.chipRadius)
                            .overlay(
                                RoundedRectangle(cornerRadius: DJTheme.chipRadius)
                                    .stroke(DJTheme.border.opacity(0.7), lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(StudioPressableStyle())
                    .disabled(!appState.previewHasUsableBeatGrid)
                    .help("Step forward 4 beats / 1 bar (Shift+Right)")
                }
            }
        }
        .padding(8)
        .background(DJTheme.cardHeader)
        .cornerRadius(DJTheme.controlRadius)
        .overlay(
            RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                .stroke(isAuditionFocused ? DJTheme.cue.opacity(0.8) : DJTheme.border.opacity(0.7), lineWidth: 1)
        )
        .focusable()
        .focusEffectDisabled() // The ring is redrawn on every frame while playing and cost about half of the render time.
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

    // Split out of `body` so the type checker stays within its time limit on slower CI machines.
    private var orderPicker: some View {
            Picker("Order", selection: $order) {
                ForEach(LibraryOrder.allCases, id: \.self) { option in
                    Text(option.rawValue)
                        .tag(option)
                        .disabled(option == .bestMatch && appState.referenceTrack == nil)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("Folder order, best match with the reference deck, or a warm-up → peak → cool-down set")
    }

    @ViewBuilder
    private func analyzeAllControl(for selected: LibraryCrateInfo) -> some View {
            if let progress = appState.crateAnalysisProgress {
                HStack(spacing: 4) {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .frame(width: 50)
                    Text("\(progress.done)/\(progress.total)")
                        .font(.system(size: 9.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(DJTheme.textSecondary)
                    Button("Stop") { appState.cancelCrateAnalysis() }
                        .controlSize(.small)
                }
            } else {
                Button {
                    appState.analyzeCrate(selected)
                } label: {
                    Label("Analyze All", systemImage: "waveform.badge.magnifyingglass")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(DJTheme.deckA)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!selected.isReadable || selected.audioFiles.isEmpty || appState.isAnalyzingLibraryTrack)
                .help("Analyze every track in this crate that has no current analysis, one at a time")
            }
    }

    /// Crate files, optionally ordered best match first against the reference deck.
    /// Unanalyzed tracks and the reference track itself go last; ties keep folder order.
    private func orderedFiles(_ crate: LibraryCrateInfo) -> [String] {
        if order == .setFlow {
            let entries = crate.audioFiles.compactMap { appState.loadedCache?.tracks["\(crate.folderName)/\($0)"] }
            let planned = SetPlanner.order(entries).map { ($0.relativePath as NSString).lastPathComponent }
            return planned + crate.audioFiles.filter { !planned.contains($0) }
        }
        guard order == .bestMatch, let reference = appState.referenceTrack else { return crate.audioFiles }
        func score(_ file: String) -> Double {
            let path = "\(crate.folderName)/\(file)"
            guard path != reference.relativePath,
                  let entry = appState.loadedCache?.tracks[path],
                  let compatibility = appState.compatibility(for: entry) else { return -1 }
            return compatibility.matchScore
        }
        func played(_ file: String) -> Bool { appState.playedTonight.contains("\(crate.folderName)/\(file)") }
        // Already-played tracks sink below fresh ones but stay visible: guests ask for repeats.
        return crate.audioFiles.enumerated()
            .map { (offset: $0.offset, file: $0.element, score: score($0.element), played: played($0.element)) }
            .sorted {
                if $0.played != $1.played { return !$0.played }
                return $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset
            }
            .map(\.file)
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
                .focusEffectDisabled() // The ring is redrawn on every frame while playing and cost about half of the render time.
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
                        Text(appState.activeAnalysisMethod[relativePath]?.displayName ?? "Running")
                    case .complete:
                        Image(systemName: "checkmark")
                        Text(engineLabel)
                    case .failed:
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Retry")
                    }
                } else if let entry = appState.loadedCache?.tracks[relativePath] {
                    Image(systemName: "checkmark")
                    Text(entry.analyzerVersion.contains("model") ? "Model" : "DSP")
                } else {
                    Image(systemName: "waveform.path")
                    Text("Analyze")
                }
            }
            .font(.system(size: 9.5, weight: .semibold))
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
        .contextMenu {
            Button("Analyze with DSP (Fast Heuristic)") {
                appState.analyzeTrack(relativePath: relativePath, method: .dsp)
            }
            Button("Analyze with Model (Beat This!)") {
                appState.analyzeTrack(relativePath: relativePath, method: .nativeModel)
            }
        }
        .disabled(appState.isAnalyzingLibraryTrack)
        .help(buttonHelp)
        .accessibilityLabel("Analyze \(relativePath) using \(engineLabel)")
        .accessibilityIdentifier("trackAnalyzeButton-\(relativePath)")
    }

    private var engineLabel: String {
        if let entry = appState.loadedCache?.tracks[relativePath] {
            if entry.analyzerVersion.contains("model") {
                return "Model"
            } else if entry.analyzerVersion.contains("dsp") {
                return "DSP"
            }
        }
        return "Analyze"
    }

    private var buttonForegroundColor: Color {
        if let state = appState.analysisStatus(for: relativePath) {
            switch state {
            case .running:
                return appState.activeAnalysisMethod[relativePath] == .nativeModel ? DJTheme.cue : DJTheme.deckA
            case .complete:
                return DJTheme.textSecondary
            case .failed:
                return .orange
            }
        } else if let entry = appState.loadedCache?.tracks[relativePath] {
            return entry.analyzerVersion.contains("model") ? DJTheme.cue : DJTheme.textSecondary
        }
        if appState.isAnalyzingLibraryTrack { return DJTheme.textMuted }
        return isSelectedRow ? DJTheme.deckA : DJTheme.textSecondary
    }

    private var buttonBackgroundColor: Color {
        if let state = appState.analysisStatus(for: relativePath) {
            switch state {
            case .running:
                return (appState.activeAnalysisMethod[relativePath] == .nativeModel ? DJTheme.cue : DJTheme.deckA).opacity(0.2)
            case .complete:
                return DJTheme.cardHeader
            case .failed:
                return Color.orange.opacity(0.15)
            }
        } else if let entry = appState.loadedCache?.tracks[relativePath] {
            return entry.analyzerVersion.contains("model") ? DJTheme.cue.opacity(0.12) : DJTheme.cardHeader
        }
        return isSelectedRow ? DJTheme.deckA.opacity(0.15) : Color.clear
    }

    private var isSelectedRow: Bool { appState.selectedTrackPath == relativePath }

    private var buttonBorderColor: Color {
        if let state = appState.analysisStatus(for: relativePath) {
            switch state {
            case .running:
                return appState.activeAnalysisMethod[relativePath] == .nativeModel ? DJTheme.cue : DJTheme.deckA
            case .complete:
                return DJTheme.border
            case .failed:
                return Color.orange
            }
        } else if let entry = appState.loadedCache?.tracks[relativePath] {
            return entry.analyzerVersion.contains("model") ? DJTheme.cue.opacity(0.5) : DJTheme.border
        }
        return isSelectedRow ? DJTheme.deckA.opacity(0.5) : DJTheme.border
    }

    private var buttonHelp: String {
        if let state = appState.analysisStatus(for: relativePath) {
            switch state {
            case .running:
                return "Analysis in progress with \(appState.activeAnalysisMethod[relativePath]?.displayName ?? "local engine"). Playback remains available."
            case .complete:
                return "Analysis complete with \(engineLabel). Right-click to switch engine."
            case .failed(let reason):
                return "Analysis failed: \(reason). Click to retry."
            }
        } else if let entry = appState.loadedCache?.tracks[relativePath] {
            let engine = entry.analyzerVersion.contains("model") ? "Beat This! small0 CoreML" : "DSP baseline"
            return "Analyzed with \(engine). Click or right-click to re-analyze."
        }
        return appState.isAnalyzingLibraryTrack
            ? "One local analysis is running. Playback and library selection remain available."
            : "Analyze this file with \(appState.selectedAnalysisMethod.displayName). Right-click to choose method."
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


/// Display-only names; identity and paths always use the raw file and folder names.
enum LibraryTrackTitle {
    /// "ABBA - Gimme! (Official Video).mp3" -> "ABBA - Gimme!"
    static func display(_ fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        let cleaned = base.replacing(/\s*[\(\[][^\)\]]*(official|video|lyrics|audio|remaster|4k|hd)[^\)\]]*[\)\]]/.ignoresCase(), with: "")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? base : cleaned
    }
}

extension LibraryCrateInfo {
    /// Crate name without the "[NN] " ordering prefix; folder order already sorts the list.
    var title: String { displayName.replacing(/^\[\d+\]\s*/, with: "") }
}

/// Quiet marker for a track already heard tonight.
private struct PlayedLabel: View {
    var body: some View {
        Text("Played")
            .font(.system(size: 9.5, weight: .medium))
            .foregroundColor(DJTheme.textMuted)
    }
}
