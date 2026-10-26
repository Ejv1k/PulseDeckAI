import SwiftUI
import AppKit
import PulseDeckCore

public struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var projectorViewModel: ProjectorViewModel

    public init() {}

    public var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 8) {
                StatusHeaderView(appState: appState, projectorViewModel: projectorViewModel)

                OutputRoutingView(appState: appState)

                AudioMeterStatusView(appState: appState)

                DeckStudioView(appState: appState)

                WaveformEditorView(model: appState.waveformEditorModel)

                // Keep the nested crate/track scrollers finite inside the root's vertical content.
                LibraryBrowserView(appState: appState)
                    .frame(height: 300)

                ArchitectureStatusView()
            }
            .padding(12)
            .frame(maxWidth: .infinity)
        }
        .background(DJTheme.background.ignoresSafeArea())
        .onKeyPress(phases: [.down, .repeat]) { press in
            SoundboardKeyboardRouter.handleKeyPress(press, appState: appState)
        }
    }
}
