import SwiftUI
import AppKit
import PulseDeckCore

public struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var projectorViewModel: ProjectorViewModel
    @State private var isContractsExpanded: Bool = false

    public init() {}

    public var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 6) {
                // Top Branding & Library Status Ribbon
                StatusHeaderView(appState: appState, projectorViewModel: projectorViewModel)

                // Master & Cue Hardware Output Device Binding
                OutputRoutingView(appState: appState)

                // Output Level Metering
                AudioMeterStatusView(appState: appState)

                // Dual-Deck Performance Studio (Deck A, Center Mixer, Deck B)
                DeckStudioView(appState: appState)

                // Shared 60 FPS Multi-Band Waveform & Cue Editor
                WaveformEditorView(model: appState.waveformEditorModel)

                // DJ Crates Sidebar & Track Browser
                LibraryBrowserView(appState: appState)
                    .frame(minHeight: 240, idealHeight: 280)

                // Architectural Contracts Specification (Collapsible for Performance Focus)
                DisclosureGroup(isExpanded: $isContractsExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Label(PulseDeckCoreConfig.hardwareBaseline, systemImage: "cpu")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(DJTheme.textSecondary)

                            Divider().frame(height: 12)

                            Label("macOS 14+ / Swift 6", systemImage: "apple.terminal")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(DJTheme.textSecondary)
                        }
                        .padding(.horizontal, 4)

                        ArchitectureStatusView()
                    }
                    .padding(.top, 4)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "shield.checkerboard")
                            .font(.system(size: 10))
                            .foregroundColor(DJTheme.textSecondary)
                        Text("SYSTEM SPECIFICATIONS & CONTRACTS")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(DJTheme.textSecondary)
                    }
                }
                .padding(8)
                .background(DJTheme.cardBackground)
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(DJTheme.border, lineWidth: 1)
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .background(DJTheme.background.ignoresSafeArea())
        .onKeyPress(phases: [.down, .repeat]) { press in
            SoundboardKeyboardRouter.handleKeyPress(press, appState: appState)
        }
    }
}
