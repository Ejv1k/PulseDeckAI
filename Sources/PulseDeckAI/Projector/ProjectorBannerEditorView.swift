import SwiftUI
import PulseDeckCore

/// DJ-side control sheet for configuring the event banner, projector mode, and display settings.
///
/// Ensures editing controls never appear on the audience-facing projector screen.
public struct ProjectorBannerEditorView: View {
    @ObservedObject var viewModel: ProjectorViewModel
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    public init(viewModel: ProjectorViewModel, appState: AppState) {
        self.viewModel = viewModel
        self.appState = appState
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack {
                Text("PROJECTOR CONTROLS & EVENT BANNER")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(DJTheme.cue)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 4)

            // Mode Selector
            VStack(alignment: .leading, spacing: 8) {
                Text("ACTIVE PRESENTATION MODE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(DJTheme.textMuted)

                HStack(spacing: 8) {
                    ForEach(ProjectorMode.allCases) { mode in
                        Button(action: {
                            viewModel.setMode(mode)
                        }) {
                            VStack(spacing: 4) {
                                Text("[\(mode.keyLabel)]")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                Text(mode.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(viewModel.currentMode == mode ? DJTheme.cardHeader : DJTheme.cardBackground)
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(viewModel.currentMode == mode ? DJTheme.cue : DJTheme.border, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Event Banner Text Editor
            VStack(alignment: .leading, spacing: 8) {
                Text("EVENT BANNER TEXT (MODE 3)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(DJTheme.textMuted)

                TextField("Enter event title, wedding couple, or venue name", text: $viewModel.eventBannerText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, weight: .medium))

                Text("Appears at the top of the Mode 3 Now Playing presentation card.")
                    .font(.system(size: 11))
                    .foregroundColor(DJTheme.textMuted)
            }

            // Media Slideshow Controls
            VStack(alignment: .leading, spacing: 8) {
                Text("MEDIA SLIDESHOW (MODE 2)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(DJTheme.textMuted)

                HStack(spacing: 12) {
                    Button("Previous Slide") {
                        viewModel.previousSlide()
                    }
                    .disabled(viewModel.mediaService.items.isEmpty)

                    Button("Next Slide") {
                        viewModel.nextSlide()
                    }
                    .disabled(viewModel.mediaService.items.isEmpty)

                    Button("Rescan Media Crate") {
                        viewModel.rescanMedia()
                    }

                    Spacer()

                    Text("\(viewModel.mediaService.items.count) items loaded")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(DJTheme.textSecondary)
                }
            }

            Divider()
                .background(DJTheme.border)

            // Window Actions
            HStack(spacing: 12) {
                Button(viewModel.isWindowOpen ? "Close Projector Window" : "Open Projector Window") {
                    viewModel.toggleWindow(appState: appState)
                }

                Button("Toggle Fullscreen") {
                    viewModel.toggleFullscreen()
                }
                .disabled(!viewModel.isWindowOpen)

                Spacer()
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 360)
        .background(DJTheme.background)
    }
}
