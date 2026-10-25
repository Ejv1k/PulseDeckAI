import SwiftUI
import PulseDeckCore

/// Root view for the secondary presentation window.
///
/// Switches between the 4 projector modes and captures local hotkeys 1–4 when focused.
public struct ProjectorWindowView: View {
    @ObservedObject var viewModel: ProjectorViewModel
    @ObservedObject var appState: AppState

    public init(viewModel: ProjectorViewModel, appState: AppState) {
        self.viewModel = viewModel
        self.appState = appState
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch viewModel.currentMode {
            case .fftVisualizer:
                ProjectorSpectrumView(viewModel: viewModel, appState: appState)
                    .transition(.opacity)

            case .mediaSlideshow:
                ProjectorSlideshowView(viewModel: viewModel)
                    .transition(.opacity)

            case .nowPlaying:
                ProjectorNowPlayingView(viewModel: viewModel, appState: appState)
                    .transition(.opacity)

            case .blackout:
                ProjectorBlackoutView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: viewModel.currentMode)
        .task(id: viewModel.currentMode) {
            await viewModel.runPresentationUpdates(from: appState)
        }
    }
}
