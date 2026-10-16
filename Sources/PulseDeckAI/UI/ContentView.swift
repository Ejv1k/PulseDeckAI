import SwiftUI
import PulseDeckCore

public struct ContentView: View {
    @EnvironmentObject var appState: AppState

    public init() {}

    public var body: some View {
        VStack(spacing: 10) {
            StatusHeaderView(appState: appState)

            AudioMeterStatusView(appState: appState)

            LibraryBrowserView(appState: appState)
                .frame(maxHeight: .infinity)

            ArchitectureStatusView()
        }
        .padding(12)
        .background(DJTheme.background.ignoresSafeArea())
    }
}
