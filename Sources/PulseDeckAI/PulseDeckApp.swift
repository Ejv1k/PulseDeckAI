import SwiftUI
import PulseDeckCore

@main
public struct PulseDeckApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var projectorViewModel = ProjectorViewModel()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(projectorViewModel)
                .frame(minWidth: 1024, idealWidth: 1200, minHeight: 680, idealHeight: 760)
                .onAppear {
                    projectorViewModel.updateLibraryRoot(appState.libraryRootURL)
                }
                .onChange(of: appState.libraryRootURL) { _, newURL in
                    projectorViewModel.updateLibraryRoot(newURL)
                }
                .onKeyPress(phases: [.down, .repeat]) { press in
                    ProjectorKeyboardRouter.handleKeyPress(press, viewModel: projectorViewModel)
                }
                .sheet(isPresented: $projectorViewModel.isBannerEditorPresented) {
                    ProjectorBannerEditorView(viewModel: projectorViewModel, appState: appState)
                }
        }
        .windowStyle(.hiddenTitleBar)
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
            }
            CommandMenu("Playback") {
                Button("Toggle Master Talkover") {
                    appState.toggleTalkover()
                }
                .keyboardShortcut("t", modifiers: [])
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
    }
}
