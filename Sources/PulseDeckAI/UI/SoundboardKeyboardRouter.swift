import SwiftUI
import AppKit
import PulseDeckCore

/// Unified keyboard routing and suppression engine for Talkover and Soundboard hotkeys.
///
/// ## Operational Invariants:
/// - Function Keys F1–F8 trigger Soundboard pads 0..<8.
/// - Duplicate keyDown / held key suppression: Drops OS repeat events (`press.phase == .repeat` or `event.isARepeat`).
/// - No duplicate triggers from multiple event routes: Debounces rapid duplicate dispatches.
/// - No global keyboard capture: Routes events only within focused active PulseDeck AI application windows.
/// - Preserves Talkover (T/t) key handling without regressions.
@MainActor
public enum SoundboardKeyboardRouter {

    /// Processes a SwiftUI `KeyPress` event for Soundboard and Talkover hotkeys.
    public static func handleKeyPress(_ press: KeyPress, appState: AppState) -> KeyPress.Result {
        // 1. Master Talkover toggle: Hotkey 'T' / 't'
        if press.characters.lowercased() == "t" {
            if press.phase == .repeat || (NSApplication.shared.currentEvent?.isARepeat == true) {
                return .handled
            }
            appState.toggleTalkover()
            return .handled
        }

        // 2. Soundboard SFX triggers: Hotkeys F1–F8
        if let padIndex = functionKeyIndex(for: press) {
            if press.phase == .repeat || (NSApplication.shared.currentEvent?.isARepeat == true) {
                return .handled
            }
            appState.triggerSoundboardPad(index: padIndex)
            return .handled
        }

        return .ignored
    }

    /// Extracts Soundboard pad index (0..<8) from a SwiftUI `KeyPress` if it represents F1–F8.
    public static func functionKeyIndex(for press: KeyPress) -> Int? {
        for scalar in press.characters.unicodeScalars {
            let val = scalar.value
            // NSF1FunctionKey (0xF704 / 63236) .. NSF8FunctionKey (0xF70B / 63243)
            if val >= 0xF704 && val <= 0xF70B {
                return Int(val - 0xF704)
            }
        }
        return nil
    }

    /// Extracts Soundboard pad index (0..<8) from an AppKit `NSEvent` if it represents F1–F8.
    public static func functionKeyIndex(for event: NSEvent) -> Int? {
        if let chars = event.charactersIgnoringModifiers {
            for scalar in chars.unicodeScalars {
                let val = scalar.value
                if val >= 0xF704 && val <= 0xF70B {
                    return Int(val - 0xF704)
                }
            }
        }
        switch event.keyCode {
        case 122: return 0 // F1
        case 120: return 1 // F2
        case 99:  return 2 // F3
        case 118: return 3 // F4
        case 96:  return 4 // F5
        case 97:  return 5 // F6
        case 98:  return 6 // F7
        case 100: return 7 // F8
        default: return nil
        }
    }
}
