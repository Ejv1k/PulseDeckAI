import SwiftUI
import AppKit

/// Unified keyboard routing and duplicate suppression engine for Projector mode hotkeys (Keys 1–4).
///
/// ## Operational Invariants:
/// - Plain keys 1, 2, 3, 4 switch Projector modes (Spectrum, Slideshow, Now Playing, Blackout).
/// - Context sensitive: Never steals digits when focus is in a text field, banner editor, or search bar.
/// - Duplicate held/repeat suppression: Drops OS repeat events (`press.phase == .repeat` or `event.isARepeat`).
/// - Debounces rapid multi-route dispatches within 120 ms.
/// - Preserves all existing hotkeys (T, F1–F8, Space, A, B, Q, W, I, O, Y) by returning `.ignored` for non-1–4 keys.
/// - Zero global keyboard capture outside active application windows.
@MainActor
public enum ProjectorKeyboardRouter {

    private static var lastTriggerTimestamp: TimeInterval = 0.0
    private static var lastTriggeredMode: ProjectorMode?

    /// Checks if the first responder in the active window is actively editing text.
    public static func isEditingText(in window: NSWindow? = NSApplication.shared.keyWindow) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder is NSTextView || responder is NSTextField || responder is NSText {
            return true
        }
        return false
    }

    /// Handles a SwiftUI `KeyPress` event for Projector mode hotkeys.
    public static func handleKeyPress(_ press: KeyPress, viewModel: ProjectorViewModel) -> KeyPress.Result {
        // If user is actively typing in a text field or banner editor, DO NOT steal digits.
        guard !isEditingText() else {
            return .ignored
        }

        guard let targetMode = mode(for: press) else {
            return .ignored
        }

        // Drop OS repeat events when a key is held down
        if press.phase == .repeat || (NSApplication.shared.currentEvent?.isARepeat == true) {
            return .handled
        }

        // Debounce rapid duplicate event dispatches from multiple view layers
        let now = ProcessInfo.processInfo.systemUptime
        if targetMode == lastTriggeredMode && (now - lastTriggerTimestamp) < 0.12 {
            return .handled
        }

        lastTriggerTimestamp = now
        lastTriggeredMode = targetMode

        viewModel.setMode(targetMode)
        return .handled
    }

    /// Handles an AppKit `NSEvent` key event for Projector mode hotkeys.
    public static func handleNSEvent(_ event: NSEvent, viewModel: ProjectorViewModel) -> Bool {
        guard !isEditingText(in: event.window) else {
            return false
        }

        guard let targetMode = mode(for: event) else {
            return false
        }

        if event.isARepeat {
            return true
        }

        let now = ProcessInfo.processInfo.systemUptime
        if targetMode == lastTriggeredMode && (now - lastTriggerTimestamp) < 0.12 {
            return true
        }

        lastTriggerTimestamp = now
        lastTriggeredMode = targetMode

        viewModel.setMode(targetMode)
        return true
    }

    /// Extracts target `ProjectorMode` from a SwiftUI `KeyPress` if it matches '1'...'4'.
    public static func mode(for press: KeyPress) -> ProjectorMode? {
        // Ignore if modifier keys (Command, Control, Option) are held
        let mods = press.modifiers
        guard !mods.contains(.command) && !mods.contains(.control) && !mods.contains(.option) else {
            return nil
        }

        switch press.characters {
        case "1": return .fftVisualizer
        case "2": return .mediaSlideshow
        case "3": return .nowPlaying
        case "4": return .blackout
        default: return nil
        }
    }

    /// Extracts target `ProjectorMode` from an AppKit `NSEvent` if it represents keys 1–4.
    public static func mode(for event: NSEvent) -> ProjectorMode? {
        let modifierFlags = event.modifierFlags.intersection([.command, .control, .option])
        guard modifierFlags.isEmpty else {
            return nil
        }

        if let characters = event.charactersIgnoringModifiers {
            switch characters {
            case "1": return .fftVisualizer
            case "2": return .mediaSlideshow
            case "3": return .nowPlaying
            case "4": return .blackout
            default: break
            }
        }

        // Standard ANSI KeyCodes for number row 1, 2, 3, 4
        switch event.keyCode {
        case 18: return .fftVisualizer // Key '1'
        case 19: return .mediaSlideshow // Key '2'
        case 20: return .nowPlaying    // Key '3'
        case 21: return .blackout      // Key '4'
        default: return nil
        }
    }

    /// Resets debounce state for tests.
    public static func resetDebounceForTesting() {
        lastTriggerTimestamp = 0.0
        lastTriggeredMode = nil
    }
}
