import SwiftUI
import AppKit
import PulseDeckCore

public struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var projectorViewModel: ProjectorViewModel

    public init() {}

    public var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 6) {
                // Top Branding & Library Status Ribbon
                StatusHeaderView(appState: appState, projectorViewModel: projectorViewModel)

                // Master & Cue Hardware Output Device Binding
                OutputRoutingView(appState: appState)

                // Dual-Deck Performance Studio (Deck A, Center Mixer, Deck B)
                DeckStudioView(appState: appState)

                // Shared 60 FPS Multi-Band Waveform & Cue Editor
                WaveformEditorView(
                    model: appState.waveformEditorModel,
                    selectedTrackPath: appState.selectedTrackPath,
                    analysisStatus: appState.selectedTrackPath.flatMap { appState.analysisStatus(for: $0) }
                )

                // DJ Crates Sidebar & Track Browser
                LibraryBrowserView(appState: appState)
                    .frame(minHeight: 300, idealHeight: 380)

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
