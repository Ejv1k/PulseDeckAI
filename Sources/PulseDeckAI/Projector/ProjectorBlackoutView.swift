import SwiftUI

/// Mode 4: True blackout screen for speeches, formal dinner toasts, and venue downtime.
///
/// Guaranteed invariants:
/// - Renders solid pitch black (`Color.black`) across the entire window frame.
/// - Emits zero controls, buttons, borders, or light leakage onto the projector screen.
/// - Controls and mode switching remain entirely in the DJ's main application context.
public struct ProjectorBlackoutView: View {
    public init() {}

    public var body: some View {
        Color.black
            .ignoresSafeArea()
    }
}
