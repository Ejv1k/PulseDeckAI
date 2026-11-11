import SwiftUI
import AppKit
import PulseDeckCore

/// A bare executable starts as a background process; macOS then lets other apps cover its window.
final class PulseDeckAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Plain activate() does not take focus from the launching terminal; wait until the window exists.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true) // deprecated, but the cooperative activate() cannot take focus from a terminal
            NSApp.windows.first { $0.canBecomeMain && $0.isVisible }?.makeKeyAndOrderFront(nil)
        }
    }
}

@main
public struct PulseDeckApp: App {
    @NSApplicationDelegateAdaptor(PulseDeckAppDelegate.self) private var delegate
    @StateObject private var appState = AppState()
    @StateObject private var projectorViewModel = ProjectorViewModel()

    public init() {}

    @MainActor private static func confirmNewSet(_ state: AppState) {
        let alert = NSAlert()
        alert.messageText = "Start a new set?"
        alert.informativeText = "The list of tracks already played tonight is cleared. Up Next stays."
        alert.addButton(withTitle: "New Set")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { state.startNewSet() }
    }

    /// Shared by the actual startup/root-change hooks; never register an unresolved fallback with the media service.
    @MainActor
    static func updateProjectorLibrary(
        from appState: AppState, model: ProjectorViewModel,
        beforeDiscoveryForTesting: ((URL) -> Void)? = nil
    ) {
        guard let root = appState.resolvedLibraryRootURL else { return }
        beforeDiscoveryForTesting?(root)
        model.updateLibraryRoot(root)
    }

    public var body: some Scene {
        WindowGroup("PulseDeck AI") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(projectorViewModel)
                .frame(minWidth: 1024, idealWidth: 1200, minHeight: 680, idealHeight: 760)
                .preferredColorScheme(.dark) // Until Light appearance lands, keep the title bar matching the content.
                .onAppear {
                    Self.updateProjectorLibrary(from: appState, model: projectorViewModel)
                }
                .onChange(of: appState.resolvedLibraryRootURL) { _, _ in
                    Self.updateProjectorLibrary(from: appState, model: projectorViewModel)
                }
                .onKeyPress(phases: [.down, .repeat]) { press in
                    ProjectorKeyboardRouter.handleKeyPress(press, viewModel: projectorViewModel)
                }
                .sheet(isPresented: $projectorViewModel.isBannerEditorPresented) {
                    ProjectorBannerEditorView(viewModel: projectorViewModel, appState: appState)
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Library…") {
                    appState.openLibrary()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!appState.canOpenLibrary)
                .help(appState.libraryLocationUnavailableReason ?? "Choose the library root containing crate subfolders")

                Button("Rescan Library") {
                    projectorViewModel.refreshLibrary(from: appState)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(appState.isScanning)

                Button("New Set…") { Self.confirmNewSet(appState) }
                    .disabled(appState.playedTonight.isEmpty)
            }
            CommandGroup(after: .textEditing) {
                Button("Find Track…") {
                    NotificationCenter.default.post(name: .pulseDeckFocusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            CommandMenu("Playback") {
                // No bare-key menu shortcut: menus would fire it while typing. The studio handles T itself.
                Button("Toggle Master Talkover (T)") {
                    appState.toggleTalkover()
                }
            }
            CommandMenu("Soundboard") {
                ForEach(0..<8, id: \.self) { index in
                    Button("Trigger Pad \(index + 1)") {
                        appState.triggerSoundboardPad(index: index)
                    }
                }
                Divider()
                Button("Stop All Soundboard Pads") {
                    appState.stopAllSoundboardPads()
                }
            }
            CommandMenu("Projector") {
                Button(projectorViewModel.isWindowOpen ? "Close Projector Window" : "Open Projector Window") {
                    projectorViewModel.toggleWindow(appState: appState)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("Toggle Fullscreen") {
                    projectorViewModel.toggleFullscreen()
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
                .disabled(!projectorViewModel.isWindowOpen)

                Divider()

                Button("Mode 1: Audio Spectrum Visualizer") {
                    projectorViewModel.setMode(.fftVisualizer)
                }

                Button("Mode 2: Media Slideshow") {
                    projectorViewModel.setMode(.mediaSlideshow)
                }

                Button("Mode 3: Now Playing & Event Title") {
                    projectorViewModel.setMode(.nowPlaying)
                }

                Button("Mode 4: Blackout Screen") {
                    projectorViewModel.setMode(.blackout)
                }

                Divider()

                Button("Next Media Slide") {
                    projectorViewModel.nextSlide()
                }
                .disabled(projectorViewModel.mediaService.items.isEmpty)

                Button("Previous Media Slide") {
                    projectorViewModel.previousSlide()
                }
                .disabled(projectorViewModel.mediaService.items.isEmpty)

                Divider()

                Button("Configure Event Banner...") {
                    projectorViewModel.isBannerEditorPresented = true
                }
            }
        }

        Settings {
            SettingsView(appState: appState)
        }
    }
}
