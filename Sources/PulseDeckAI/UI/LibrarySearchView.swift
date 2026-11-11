import SwiftUI
import PulseDeckCore

/// ⌘F searches every crate; Esc clears and returns to the selected crate.
struct LibrarySearchField: View {
    @Binding var query: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(DJTheme.textMuted)
            TextField("Search all crates", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($isFocused)
                .onExitCommand {
                    query = ""
                    isFocused = false
                    // Hand the keyboard back to the studio so Space and A/B work right away.
                    NotificationCenter.default.post(name: .pulseDeckFocusStudio, object: nil)
                }
                .accessibilityLabel("Search all crates")
                .accessibilityIdentifier("librarySearchField")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(DJTheme.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 28)
        .background(DJTheme.cardHeader)
        .cornerRadius(DJTheme.controlRadius)
        .overlay(
            RoundedRectangle(cornerRadius: DJTheme.controlRadius)
                .stroke(isFocused ? DJTheme.deckA.opacity(0.7) : DJTheme.border.opacity(0.6), lineWidth: 1)
        )
        .background {
            // Invisible menu-less shortcut target for ⌘F.
            Button("") { isFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .help("Search every crate (⌘F). Esc clears.")
    }
}

/// Results across all crates; covers the crate list while a query is typed.
struct LibrarySearchResultsView: View {
    @ObservedObject var appState: AppState
    let query: String

    @State private var results: [String] = []

    var body: some View {
        Group {
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { content }
        }
        // AppState publishes playback ticks; search only when the query or the library changes.
        .onChange(of: query, initial: true) { refresh() }
        .onChange(of: appState.scanSummary) { refresh() }
    }

    private func refresh() {
        results = LibrarySearch.search(query, in: appState.scanSummary?.crates ?? [])
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(results.isEmpty ? "No tracks match “\(query)”" : "\(results.count) \(results.count == 1 ? "track" : "tracks")")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(DJTheme.textSecondary)
                    .accessibilityAddTraits(.updatesFrequently)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(results, id: \.self) { path in
                            LibrarySearchRow(appState: appState, path: path)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(DJTheme.cardBackground)
            .cornerRadius(DJTheme.cardRadius)
            .accessibilityIdentifier("librarySearchResults")
    }
}

extension Notification.Name {
    static let pulseDeckFocusStudio = Notification.Name("PulseDeckFocusStudio")
}

private struct LibrarySearchRow: View {
    @ObservedObject var appState: AppState
    let path: String

    var body: some View {
        let file = (path as NSString).lastPathComponent
        let crateFolder = (path as NSString).deletingLastPathComponent
        let crateTitle = appState.scanSummary?.crates.first { $0.folderName == crateFolder }?.title ?? crateFolder
        let entry = appState.loadedCache?.tracks[path]
        let isSelected = appState.selectedTrackPath == path
        HStack(spacing: 10) {
            LibraryTrackSelectionButton(appState: appState, relativePath: path) {
                HStack(spacing: 8) {
                    Text(LibraryTrackTitle.display(file))
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? DJTheme.textPrimary : DJTheme.textSecondary)
                        .lineLimit(1)
                    Text(crateTitle)
                        .font(.system(size: 9.5))
                        .foregroundColor(DJTheme.textMuted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
            }
            if let bpm = entry?.bpm, bpm > 0 {
                Text(String(format: "%.1f BPM", bpm))
                    .font(.system(size: 9.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(DJTheme.deckA)
            }
            UpNextToggleButton(appState: appState, relativePath: path)
        }
        .padding(.horizontal, 6)
        .background(isSelected ? DJTheme.deckA.opacity(0.1) : Color.clear)
        .cornerRadius(DJTheme.controlRadius)
        .focusEffectDisabled()
        .contextMenu { UpNextMenu(appState: appState, relativePath: path) }
        .draggable(LibraryTrackTransfer(libraryRoot: appState.libraryRootURL, relativePath: path))
    }
}
