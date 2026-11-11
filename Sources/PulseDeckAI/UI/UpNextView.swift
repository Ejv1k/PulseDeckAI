import SwiftUI
import PulseDeckCore

/// The DJ's short list of what plays next. Drag to reorder; a track leaves once it loads into a deck,
/// and a finished transition loads the first one into the deck it faded out.
struct UpNextView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Up Next")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(DJTheme.textSecondary)
                Spacer()
                if !appState.upNext.isEmpty {
                    Text("\(appState.upNext.count)")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(DJTheme.deckA)
                }
            }
            .padding(.horizontal, 8)

            if appState.upNext.isEmpty {
                Text("Add tracks with + or right-click › Play Next. After a transition, the first one loads into the free deck.")
                    .font(.system(size: 9.5))
                    .foregroundColor(DJTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            } else {
                List {
                    ForEach(Array(appState.upNext.enumerated()), id: \.element) { index, path in
                        row(index: index, path: path)
                            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    .onMove { appState.moveUpNext(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: min(CGFloat(appState.upNext.count) * 30 + 4, 160))
                .accessibilityIdentifier("upNextList")
            }
        }
        .padding(.vertical, 6)
    }

    private func row(index: Int, path: String) -> some View {
        let entry = appState.loadedCache?.tracks[path]
        let title = LibraryTrackTitle.display((path as NSString).lastPathComponent)
        return HStack(spacing: 6) {
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(index == 0 ? DJTheme.master : DJTheme.textMuted)
                .frame(width: 14, alignment: .trailing)
            Text(title)
                .font(.system(size: 11, weight: index == 0 ? .semibold : .regular))
                .foregroundColor(index == 0 ? DJTheme.textPrimary : DJTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if appState.upNextNeedsBridge(at: index) {
                Button {
                    appState.insertBridge(before: path)
                } label: {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DJTheme.statusWarning)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clashes in key or tempo with the track before it. Click to insert a bridge track that fits both.")
                .accessibilityLabel("Insert a bridge track before \(title)")
            }
            if let bpm = entry?.bpm, bpm > 0 {
                Text(String(format: "%.0f", bpm))
                    .font(.system(size: 9.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(DJTheme.textMuted)
            }
            Button {
                appState.removeFromUpNext(path)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DJTheme.textMuted)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(title) from Up Next")
        }
        .frame(minHeight: 26)
        .help(index == 0 ? "\(title) — loads after the next transition" : title)
    }
}

/// Library row control: adds the track to Up Next, or removes it when already queued.
struct UpNextToggleButton: View {
    @ObservedObject var appState: AppState
    let relativePath: String

    var body: some View {
        let isQueued = appState.upNext.contains(relativePath)
        Button {
            if isQueued { appState.removeFromUpNext(relativePath) } else { appState.addToUpNext(relativePath) }
        } label: {
            Image(systemName: isQueued ? "checkmark" : "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isQueued ? DJTheme.master : DJTheme.textSecondary)
                .frame(width: 24, height: DJTheme.minTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(StudioPressableStyle())
        .help(isQueued ? "In Up Next — click to remove" : "Add to Up Next (right-click for Play Next)")
        .accessibilityLabel(isQueued ? "Remove from Up Next" : "Add to Up Next")
        .accessibilityIdentifier("upNextToggle-\(relativePath)")
    }
}

/// Library row context menu entries for Up Next.
struct UpNextMenu: View {
    @ObservedObject var appState: AppState
    let relativePath: String

    var body: some View {
        let isQueued = appState.upNext.contains(relativePath)
        Button("Play Next") { appState.playNext(relativePath) }
        Button("Add to Up Next") { appState.addToUpNext(relativePath) }
            .disabled(isQueued)
        if isQueued {
            Button("Remove from Up Next") { appState.removeFromUpNext(relativePath) }
        }
    }
}
