import SwiftUI
import AVKit
import PulseDeckCore

/// Mode 2: Ken Burns photo slideshow and muted looping video presentation.
///
/// Features smooth zoom/pan animations for wedding/event photos, seamless video looping,
/// and honest ambient idle fallback when `09_Visual_Backgrounds_Media` is empty or corrupt.
public struct ProjectorSlideshowView: View {
    @ObservedObject var viewModel: ProjectorViewModel

    public init(viewModel: ProjectorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch viewModel.mediaService.mediaState {
            case .loading:
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: DJTheme.deckA))
                    .scaleEffect(1.5)

            case .ready(let items):
                if items.isEmpty {
                    idleFallbackView
                } else {
                    activeMediaView
                }

            case .empty, .error:
                idleFallbackView
            }
        }
    }

    @ViewBuilder
    private var activeMediaView: some View {
        let items = viewModel.mediaService.items
        let index = viewModel.mediaService.currentIndex

        if items.indices.contains(index) {
            let item = items[index]
            switch item.type {
            case .photo:
                if let image = viewModel.mediaService.currentPhoto {
                    ProjectorPhotoView(image: image, mediaID: item.id)
                        .id(item.id)
                        .transition(.opacity)
                } else {
                    idleFallbackView
                }

            case .video:
                if let player = viewModel.mediaService.currentVideoPlayer {
                    MutedVideoPlayerView(player: player)
                        .transition(.opacity)
                } else {
                    idleFallbackView
                }
            }
        } else {
            idleFallbackView
        }
    }

    private var idleFallbackView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [DJTheme.deckA.opacity(0.25), Color.clear]),
                            center: .center,
                            startRadius: 20,
                            endRadius: 140
                        )
                    )
                    .frame(width: 280, height: 280)

                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 64, weight: .light))
                    .foregroundColor(DJTheme.deckA.opacity(0.8))
            }

            Text("PULSEDECK VISUALS")
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(DJTheme.textPrimary)
                .tracking(4)

            Text("Add photos and video loops to PulseDeck_Library/09_Visual_Backgrounds_Media")
                .font(.system(size: 13, weight: .medium, design: .default))
                .foregroundColor(DJTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .padding(40)
    }
}

/// Per-photo state belongs to the mounted image, rather than the loading/fallback container.
@MainActor
final class ProjectorPhotoAnimation: ObservableObject {
    @Published private(set) var scale: CGFloat = 1
    private var startTask: Task<Void, Never>?

    deinit { startTask?.cancel() }

    func start() {
        reset()
        startTask = Task { @MainActor [weak self] in
            // onAppear has mounted the unscaled image before this new animation transaction.
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) {
                self.scale = 1.08
            }
            self.startTask = nil
        }
    }

    func reset() {
        startTask?.cancel()
        startTask = nil
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if scale != 1 { scale = 1 }
        }
    }
}

struct ProjectorPhotoView: View {
    let image: NSImage
    let mediaID: String
    @StateObject private var animation: ProjectorPhotoAnimation

    init(image: NSImage, mediaID: String, animation: ProjectorPhotoAnimation? = nil) {
        self.image = image
        self.mediaID = mediaID
        _animation = StateObject(wrappedValue: animation ?? ProjectorPhotoAnimation())
    }

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .scaleEffect(animation.scale)
            .onAppear { animation.start() }
            .onChange(of: mediaID) { _, _ in animation.start() }
            .onDisappear { animation.reset() }
    }
}

/// NSViewRepresentable wrapping an `AVPlayerView` with zero onscreen controls and muted audio.
public struct MutedVideoPlayerView: NSViewRepresentable {
    public let player: AVPlayer

    public init(player: AVPlayer) {
        self.player = player
    }

    public func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.showsFrameSteppingButtons = false
        view.showsSharingServiceButton = false
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspectFill
        return view
    }

    public func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player != player {
            nsView.player = player
        }
    }
}
