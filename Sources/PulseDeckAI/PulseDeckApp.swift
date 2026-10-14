import SwiftUI
import PulseDeckCore

@main
public struct PulseDeckApp: App {
    @StateObject private var appState = AppState()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 1024, idealWidth: 1200, minHeight: 680, idealHeight: 760)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Rescan Library") {
                    appState.refreshLibrary()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(appState.isScanning)
            }
        }
    }
}
