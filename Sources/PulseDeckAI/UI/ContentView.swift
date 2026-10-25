import SwiftUI
import AppKit
import PulseDeckCore

public struct ContentView: View {
    @EnvironmentObject var appState: AppState

    public init() {}

    public var body: some View {
        VStack(spacing: 8) {
            StatusHeaderView(appState: appState)

            OutputRoutingView(appState: appState)

            AudioMeterStatusView(appState: appState)

            DeckStudioView(appState: appState)

            WaveformEditorView(model: appState.waveformEditorModel)

            LibraryBrowserView(appState: appState)
                .frame(maxHeight: .infinity)

            ArchitectureStatusView()
        }
        .padding(12)
        .background(DJTheme.background.ignoresSafeArea())
        .onKeyPress(phases: [.down, .repeat]) { press in
            SoundboardKeyboardRouter.handleKeyPress(press, appState: appState)
        }
    }
}
