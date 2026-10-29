import SwiftUI
import PulseDeckCore

public struct StatusHeaderView: View {
    @ObservedObject var appState: AppState
    let rescanLibrary: () -> Void

    public init(appState: AppState, projectorViewModel: ProjectorViewModel) {
        self.appState = appState
        self.rescanLibrary = { projectorViewModel.refreshLibrary(from: appState) }
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Brand and Pro Studio Identity
            HStack(spacing: 6) {
                Circle()
                    .fill(DJTheme.master)
                    .frame(width: 8, height: 8)
                    .shadow(color: DJTheme.master.opacity(0.6), radius: 2)

                Text("PulseDeck AI")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(DJTheme.textPrimary)

                Text("Studio")
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(DJTheme.deckA.opacity(0.12))
                    .foregroundColor(DJTheme.deckA)
                    .overlay(
                        RoundedRectangle(cornerRadius: DJTheme.chipRadius)
                            .stroke(DJTheme.deckA.opacity(0.4), lineWidth: 1)
                    )
            }

            Spacer(minLength: 6)

            // Location Error Banner (if any)
            if let error = appState.libraryLocationError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(DJTheme.chipRadius)
                .overlay(RoundedRectangle(cornerRadius: DJTheme.chipRadius).stroke(Color.orange.opacity(0.3), lineWidth: 1))
                .help("Library folder issue: \(error). Use Open Library to choose a valid directory.")
            }

            // Path & Status Ribbon
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("Library:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DJTheme.textMuted)

                    if let resolved = appState.resolvedLibraryRootURL {
                        Text(resolved.lastPathComponent)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(DJTheme.textSecondary)
                            .lineLimit(1)
                    } else {
                        HStack(spacing: 2) {
                            Text(appState.libraryRootURL.lastPathComponent)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(.orange)
                                .lineLimit(1)
                            Text("(Unresolved)")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(.orange)
                        }
                    }
                }
                .help(appState.resolvedLibraryRootURL?.standardizedFileURL.path ?? (appState.libraryLocationError ?? "Unresolved library path: \(appState.libraryRootURL.standardizedFileURL.path). Click Open Library… (⌘O) to choose a valid directory."))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(appState.resolvedLibraryRootURL != nil
                    ? "Library directory: \(appState.libraryRootURL.standardizedFileURL.path)"
                    : "Unresolved library directory: \(appState.libraryRootURL.standardizedFileURL.path)")

                Circle()
                    .fill(DJTheme.border)
                    .frame(width: 3, height: 3)

                HStack(spacing: 4) {
                    Text("Status:")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DJTheme.textMuted)

                    Text(appState.statusMessage)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(DJTheme.textPrimary)
                        .lineLimit(1)
                }
                .help(appState.statusMessage)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Status: \(appState.statusMessage)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DJTheme.cardBackground)
            .cornerRadius(DJTheme.controlRadius)
            .overlay(
                RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                    .stroke(DJTheme.border.opacity(0.7), lineWidth: 1)
            )

            Spacer(minLength: 6)

            // Library Actions Strip
            HStack(spacing: 6) {
                Button(action: {
                    appState.openLibrary()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text("Open Library…")
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(appState.canOpenLibrary ? DJTheme.textPrimary : DJTheme.textMuted)
                    .padding(.horizontal, 8)
                    .frame(minHeight: DJTheme.minTouchTarget)
                    .background(DJTheme.cardHeader)
                    .cornerRadius(DJTheme.controlRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                            .stroke(DJTheme.border.opacity(0.8), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(StudioPressableStyle())
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!appState.canOpenLibrary)
                .help(appState.libraryLocationUnavailableReason ?? "Choose library root folder containing crates (⌘O)")
                .accessibilityLabel("Open Library")

                Button(action: rescanLibrary) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text(appState.isScanning ? "Scanning…" : "Rescan (⌘R)")
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(appState.isScanning ? DJTheme.deckA : DJTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .frame(minHeight: DJTheme.minTouchTarget)
                    .background(DJTheme.cardHeader)
                    .cornerRadius(DJTheme.controlRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                            .stroke(appState.isScanning ? DJTheme.deckA.opacity(0.7) : DJTheme.border.opacity(0.8), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(StudioPressableStyle())
                .keyboardShortcut("r", modifiers: .command)
                .disabled(appState.isScanning)
                .opacity(appState.isScanning ? 0.7 : 1.0)
                .accessibilityLabel("Rescan Library")
                .accessibilityHint("Scans library directory for new audio tracks and crates")
                .help("Rescan library directory (⌘R)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(DJTheme.background)
    }
}
