import AppKit
import SwiftUI

/// Window-scoped confirmation routing. Unmodified Space stays in the focused studio;
/// audition, text editing, menu shortcuts and unrelated keys keep their own routes.
@MainActor
final class MasterSafetyLockKeyboardRouter: ObservableObject {
    private weak var appState: AppState?
    private weak var window: NSWindow?
    private weak var anchor: NSView?
    private var monitor: MasterSafetyLockEventMonitor?
    private var lastHandledStroke: Stroke?

    private struct Stroke: Equatable {
        let timestamp: TimeInterval
        let keyCode: UInt16
        init(_ event: NSEvent) {
            timestamp = event.timestamp
            keyCode = event.keyCode
        }
    }

    init(appState: AppState) { self.appState = appState }

    func attach(to window: NSWindow, anchor: NSView) {
        guard self.window !== window || self.anchor !== anchor else { return }
        monitor = nil
        self.window = window
        self.anchor = anchor
        lastHandledStroke = nil
        if let token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp], handler: { [weak self] event in
            guard Thread.isMainThread else { return event }
            return MainActor.assumeIsolated { () -> MasterSafetyLockMonitoredEvent in
                guard let self else { return MasterSafetyLockMonitoredEvent(event: event) }
                return MasterSafetyLockMonitoredEvent(event: self.handleWindowEvent(event))
            }.event
        }) {
            monitor = MasterSafetyLockEventMonitor(token)
        }
    }

    func detach(from anchor: NSView) {
        guard self.anchor === anchor else { return }
        monitor = nil
        window = nil
        self.anchor = nil
        lastHandledStroke = nil
    }

    private var isEditingText: Bool {
        if let text = window?.firstResponder as? NSText { return text.isEditable }
        if let field = window?.firstResponder as? NSTextField { return field.isEditable }
        return false
    }

    /// Called by the local monitor before preview/button handlers can interpret Shift+Space.
    func handleWindowEvent(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, event.keyCode == 49 else { return event }
        if event.type == .keyUp {
            lastHandledStroke = nil
            return event
        }
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control, .function])
        guard event.type == .keyDown, window.isKeyWindow, modifiers == .shift, !isEditingText else { return event }
        return dispatchSpace(shift: true, isRepeat: event.isARepeat, event: event) ? nil : event
    }

    /// AppKit adapter also used by dispatched-key integration tests.
    func handleStudioEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 49, !isEditingText else { return false }
        if let window, event.window !== window { return false }
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control, .function])
        guard modifiers.isEmpty || modifiers == .shift else { return false }
        return dispatchSpace(shift: modifiers.contains(.shift), isRepeat: event.isARepeat, event: event)
    }

    func handleStudioKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard press.key == .space, !isEditingText else { return .ignored }
        guard press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
        let event = NSApplication.shared.currentEvent
        guard event?.modifierFlags.contains(.function) != true else { return .ignored }
        let handled = dispatchSpace(shift: press.modifiers.contains(.shift),
                                    isRepeat: press.phase == .repeat || event?.isARepeat == true, event: event)
        return handled ? .handled : .ignored
    }

    private func dispatchSpace(shift: Bool, isRepeat: Bool, event: NSEvent?) -> Bool {
        guard let appState else { return false }
        if isRepeat { return true }
        if let event {
            let stroke = Stroke(event)
            if lastHandledStroke == stroke { return true }
            lastHandledStroke = stroke
        }
        if shift {
            appState.forcePauseFocusedMasterDeck()
        } else {
            appState.toggleDeckPlay(deck: appState.focusedMasterDeck)
        }
        return true
    }
}

/// Local monitors execute synchronously on the AppKit main thread; this wrapper
/// carries their optional return through MainActor.assumeIsolated without sending NSEvent.
private struct MasterSafetyLockMonitoredEvent: @unchecked Sendable {
    let event: NSEvent?
}

/// The registration owns its token even if SwiftUI releases the router off-main.
private final class MasterSafetyLockEventMonitor: @unchecked Sendable {
    private struct Token: @unchecked Sendable { let value: Any }
    private let token: Token
    init(_ value: Any) { token = Token(value: value) }
    deinit {
        let token = token
        if Thread.isMainThread {
            MainActor.assumeIsolated { NSEvent.removeMonitor(token.value) }
        } else {
            DispatchQueue.main.async { NSEvent.removeMonitor(token.value) }
        }
    }
}

@MainActor
struct MasterSafetyLockKeyboardBridge: NSViewRepresentable {
    let router: MasterSafetyLockKeyboardRouter
    final class AnchorView: NSView {
        weak var router: MasterSafetyLockKeyboardRouter?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { router?.attach(to: window, anchor: self) }
            else { router?.detach(from: self) }
        }
    }
    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.router = router
        return view
    }
    func updateNSView(_ view: AnchorView, context: Context) {
        if view.router !== router {
            view.router?.detach(from: view)
            view.router = router
        }
        if let window = view.window { router.attach(to: window, anchor: view) }
    }
    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.router?.detach(from: view)
    }
}
