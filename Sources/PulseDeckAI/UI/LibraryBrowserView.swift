import SwiftUI
import PulseDeckCore

public struct LibraryBrowserView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        HStack(spacing: 12) {
            // Left Column: Crates Navigation List
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("DJ CRATES (10)")
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
                                        Image(systemName: crate.trackCount > 0 ? "music.note.list" : "folder")
                                            .font(.system(size: 12))
                                            .foregroundColor(appState.selectedCrate?.id == crate.id ? DJTheme.deckA : DJTheme.textMuted)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(crate.displayName)
                                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                                .foregroundColor(appState.selectedCrate?.id == crate.id ? DJTheme.textPrimary : DJTheme.textSecondary)
                                                .lineLimit(1)

                                            HStack(spacing: 6) {
                                                Text(crate.hasGitKeep ? ".gitkeep ✓" : "no .gitkeep")
                                                    .font(.system(size: 9, design: .monospaced))
                                                    .foregroundColor(DJTheme.textMuted)
                                            }
                                        }

                                        Spacer()

                                        Text("\(crate.trackCount)")
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(appState.selectedCrate?.id == crate.id ? DJTheme.deckA.opacity(0.3) : DJTheme.cardHeader)
                                            .foregroundColor(appState.selectedCrate?.id == crate.id ? DJTheme.deckA : DJTheme.textMuted)
                                            .cornerRadius(3)
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
            .frame(width: 280)
            .background(DJTheme.cardBackground)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(DJTheme.border, lineWidth: 1)
            )

            // Right Column: Crate Detail & Track List
            VStack(alignment: .leading, spacing: 8) {
                if let selected = appState.selectedCrate {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selected.displayName)
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(DJTheme.textPrimary)

                            Text("Folder: \(selected.folderName)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(DJTheme.textMuted)
                        }

                        Spacer()

                        Text("\(selected.trackCount) TRACKS DETECTED")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(selected.trackCount > 0 ? DJTheme.master : DJTheme.textMuted)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(DJTheme.cardHeader)
                    .cornerRadius(4)

                    if selected.audioFiles.isEmpty {
                        VStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "opticaldisc")
                                .font(.system(size: 32))
                                .foregroundColor(DJTheme.textMuted)
                            Text("No audio files currently in this crate")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(DJTheme.textMuted)
                            Text("Tracks placed here will be tracked by .pulsedeck_ai_cache.json in Phase 2")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(DJTheme.textMuted.opacity(0.7))
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        List {
                            ForEach(Array(selected.audioFiles.enumerated()), id: \.offset) { index, file in
                                HStack(spacing: 12) {
                                    Text(String(format: "%02d", index + 1))
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(DJTheme.deckA)
                                        .frame(width: 24, alignment: .leading)

                                    Image(systemName: "waveform")
                                        .font(.system(size: 12))
                                        .foregroundColor(DJTheme.textSecondary)

                                    Text(file)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundColor(DJTheme.textPrimary)
                                        .lineLimit(1)

                                    Spacer()

                                    Text("MEDIA PRESERVED (GIT-IGNORED)")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(DJTheme.master)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(DJTheme.master.opacity(0.15))
                                        .cornerRadius(3)
                                }
                                .padding(.vertical, 4)
                                .listRowBackground(DJTheme.cardBackground)
                            }
                        }
                        .listStyle(.plain)
                        .background(DJTheme.cardBackground)
                    }
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
}
