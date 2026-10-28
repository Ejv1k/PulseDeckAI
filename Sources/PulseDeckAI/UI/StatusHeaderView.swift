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
            // Brand and Phase Badge
            HStack(spacing: 6) {
                Circle()
                    .fill(DJTheme.master)
                    .frame(width: 8, height: 8)
                    .shadow(color: DJTheme.master.opacity(0.8), radius: 3)

                Text("PulseDeck AI")
                    .font(.system(size: 15, weight: .black, design: .monospaced))
                    .foregroundColor(DJTheme.textPrimary)

                Text("STUDIO")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(DJTheme.deckA.opacity(0.2))
                    .foregroundColor(DJTheme.deckA)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(DJTheme.deckA, lineWidth: 1)
                    )
            }

            Spacer(minLength: 6)

            // Path & Status Ribbon
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("LIB:")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(DJTheme.textMuted)

                    Text(appState.libraryRootURL.lastPathComponent)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(DJTheme.textSecondary)
                        .lineLimit(1)
                }
                .help(appState.libraryRootURL.standardizedFileURL.path)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Library directory: \(appState.libraryRootURL.standardizedFileURL.path)")

                Circle()
                    .fill(DJTheme.border)
                    .frame(width: 3, height: 3)

                HStack(spacing: 4) {
                    Text("STATUS:")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(DJTheme.textMuted)

                    Text(appState.statusMessage)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(DJTheme.deckA)
                        .lineLimit(1)
                }
                .help(appState.statusMessage)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Status: \(appState.statusMessage)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(DJTheme.cardBackground)
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(DJTheme.border, lineWidth: 1)
            )

            Spacer(minLength: 6)

            Button(action: rescanLibrary) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                    Text(appState.isScanning ? "Scanning..." : "Rescan (⌘R)")
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(appState.isScanning ? DJTheme.deckA : DJTheme.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(DJTheme.cardHeader)
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(appState.isScanning ? DJTheme.deckA : DJTheme.border, lineWidth: 1)
                )
            }
            .buttonStyle(StudioPressableStyle())
            .keyboardShortcut("r", modifiers: .command)
            .disabled(appState.isScanning)
            .opacity(appState.isScanning ? 0.7 : 1.0)
            .accessibilityLabel("Rescan Library")
            .accessibilityHint("Scans library directory for new audio tracks and crates")
            .help("Rescan library directory (⌘R)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(DJTheme.background)
    }
}
