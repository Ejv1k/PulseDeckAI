import SwiftUI

/// Asks Gemini to pre-select the transition style and length. It never starts a transition.
struct AskAITransitionButton: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Button {
            Task { await appState.askTransitionAdvice() }
        } label: {
            HStack(spacing: 4) {
                if appState.isAskingTransitionAdvice {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "sparkles")
                }
                Text("Ask AI")
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(DJTheme.textPrimary)
            .padding(.horizontal, 8)
            .frame(minHeight: DJTheme.minTouchTarget)
            .background(DJTheme.cardHeader)
            .cornerRadius(DJTheme.controlRadius)
            .overlay(
                RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                    .stroke(DJTheme.border.opacity(0.7), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioPressableStyle())
        .disabled(appState.isTransitionBusy || appState.isAskingTransitionAdvice)
        .help("Ask Gemini which transition and length fit these two tracks. It only pre-selects; you still press Execute or Arm.")
        .accessibilityLabel("Ask AI for a transition")
    }
}
