import AppKit
import SwiftUI
import PulseDeckCore

private final class ProjectorNotificationToken: @unchecked Sendable {
    var observer: (any NSObjectProtocol)?
    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

/// Window controller managing the presentation lifecycle, external display binding,
/// and full-screen state of the secondary projector display.
@MainActor
public final class ProjectorWindowController: NSObject, NSWindowDelegate {
    private weak var viewModel: ProjectorViewModel?
    private var window: NSWindow?
    private var screenChangeToken: ProjectorNotificationToken?

    public init(viewModel: ProjectorViewModel) {
        self.viewModel = viewModel
        super.init()
        observeScreenChanges()
    }

    // MARK: - Display Detection & Selection

    /// Returns all currently connected physical or virtual displays.
    public static func enumerateDisplays() -> [ProjectorDisplayDescriptor] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [] }

        return screens.enumerated().map { index, screen in
            let isMain = screen == NSScreen.main
            let name = screen.localizedName.isEmpty ? "Display \(index + 1)" : screen.localizedName
            return ProjectorDisplayDescriptor(
                id: "\(index)_\(screen.frame.origin.x)_\(screen.frame.origin.y)",
                name: name,
                isMain: isMain,
                bounds: screen.frame,
                resolution: screen.frame.size
            )
        }
    }

    /// Selects the best screen for presentation: prefers secondary non-main display,
    /// falling back to the main display if only one screen is attached.
    public static func selectPresentationScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        // Find first external (non-main) display
        if let external = screens.first(where: { $0 != NSScreen.main }) {
            return external
        }

        // Fallback to main display
        return NSScreen.main ?? screens.first
    }

    // MARK: - Window Lifecycle

    /// Opens or brings the projector window to the front on the designated display.
    public func showProjectorWindow(appState: AppState) {
        guard let viewModel else { return }

        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            viewModel.isWindowOpen = true
            return
        }

        let targetScreen = Self.selectPresentationScreen()
        let initialFrame: NSRect
        if let screen = targetScreen {
            initialFrame = screen.frame
        } else {
            initialFrame = NSRect(x: 100, y: 100, width: 1280, height: 720)
        }

        let newWindow = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false,
            screen: targetScreen
        )

        newWindow.title = "PulseDeck AI Projector"
        newWindow.backgroundColor = .black
        newWindow.isOpaque = true
        newWindow.titleVisibility = .hidden
        newWindow.titlebarAppearsTransparent = true
        newWindow.collectionBehavior = [.fullScreenPrimary, .canJoinAllSpaces]
        newWindow.delegate = self

        let rootView = ProjectorWindowView(viewModel: viewModel, appState: appState)
        newWindow.contentView = NSHostingView(rootView: rootView)

        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        viewModel.isWindowOpen = true
    }

    /// Closes the projector window safely without terminating playback.
    public func closeProjectorWindow() {
        guard let win = window else { return }
        win.close()
        self.window = nil
        viewModel?.isWindowOpen = false
    }

    /// Toggles the projector window open or closed.
    public func toggleProjectorWindow(appState: AppState) {
        if window?.isVisible == true {
            closeProjectorWindow()
        } else {
            showProjectorWindow(appState: appState)
        }
    }

    /// Toggles standard macOS fullscreen mode for the projector window.
    public func toggleFullscreen() {
        guard let win = window else { return }
        win.toggleFullScreen(nil)
        viewModel?.isFullscreen = win.styleMask.contains(.fullScreen)
    }

    // MARK: - NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        self.window = nil
        viewModel?.isWindowOpen = false
    }

    public func windowDidEnterFullScreen(_ notification: Notification) {
        viewModel?.isFullscreen = true
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        viewModel?.isFullscreen = false
    }

    // MARK: - Display Disconnect Handling

    private func observeScreenChanges() {
        let token = ProjectorNotificationToken()
        token.observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenParametersChanged()
            }
        }
        self.screenChangeToken = token
    }

    /// Handles hot-plug or disconnect of external projectors safely.
    public func handleScreenParametersChanged() {
        guard let win = window, win.isVisible else { return }

        let currentScreens = NSScreen.screens
        guard !currentScreens.isEmpty else { return }

        // If the window's screen was disconnected, safely reposition to an available display
        if let windowScreen = win.screen, !currentScreens.contains(windowScreen) {
            let fallback = NSScreen.main ?? currentScreens[0]
            win.setFrame(fallback.frame, display: true)
        }
    }
}
