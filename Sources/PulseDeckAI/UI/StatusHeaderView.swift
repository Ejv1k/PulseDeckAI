import SwiftUI
import PulseDeckCore

public struct StatusHeaderView: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 14) {
                // Brand and Phase Badge
                HStack(spacing: 8) {
                    Circle()
                        .fill(DJTheme.master)
                        .frame(width: 10, height: 10)
                        .shadow(color: DJTheme.master.opacity(0.8), radius: 4)

                    Text("PulseDeck AI")
                        .font(.system(size: 20, weight: .black, design: .monospaced))
                        .foregroundColor(DJTheme.textPrimary)

                    Text("PHASE 3B STUDIO")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DJTheme.deckA.opacity(0.2))
                        .foregroundColor(DJTheme.deckA)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(DJTheme.deckA, lineWidth: 1)
                        )
                }

                Spacer()

                // Hardware & Runtime Specs
                HStack(spacing: 12) {
                    Label(PulseDeckCoreConfig.hardwareBaseline, systemImage: "cpu")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(DJTheme.textSecondary)

                    Divider()
                        .frame(height: 14)
                        .background(DJTheme.border)

                    Label("macOS 14+ / Swift 6", systemImage: "apple.terminal")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(DJTheme.textSecondary)

                    Divider()
                        .frame(height: 14)
                        .background(DJTheme.border)

                    Button(action: {
                        appState.refreshLibrary()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text(appState.isScanning ? "Scanning..." : "Rescan (⌘R)")
                        }
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
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
                    .buttonStyle(.plain)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(appState.isScanning)
                    .opacity(appState.isScanning ? 0.7 : 1.0)
                    .help("Rescan library directory (⌘R)")
                }
            }

            // Path & Status Ribbon
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Text("LIBRARY:")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(DJTheme.textMuted)

                    Text(appState.libraryRootURL.path)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(DJTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                HStack(spacing: 6) {
                    Text("STATUS:")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(DJTheme.textMuted)

                    Text(appState.statusMessage)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(DJTheme.deckA)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(DJTheme.cardBackground)
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(DJTheme.border, lineWidth: 1)
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(DJTheme.background)
    }
}
