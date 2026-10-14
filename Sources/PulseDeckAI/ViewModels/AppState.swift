import Foundation
import Combine
import PulseDeckCore

@MainActor
public final class AppState: ObservableObject {
    @Published public var appVersion: String = PulseDeckCoreConfig.version
    @Published public var libraryRootURL: URL
    @Published public var scanSummary: LibraryScanSummary?
    @Published public var selectedCrate: LibraryCrateInfo?
    @Published public var isScanning: Bool = false
    @Published public var statusMessage: String = "Phase 0 Operational Shell Initialized"

    private let scanner = LibraryScanner()

    public init() {
        // Resolve library folder relative to current working directory or bundle
        let cwd = FileManager.default.currentDirectoryPath
        let defaultURL = URL(fileURLWithPath: cwd).appendingPathComponent(PulseDeckCoreConfig.defaultLibraryFolderName)
        self.libraryRootURL = defaultURL
        refreshLibrary()
    }

    /// Scans the library root and updates published state on MainActor.
    public func refreshLibrary() {
        self.isScanning = true
        let url = self.libraryRootURL

        // Perform scanner on background thread, deliver result to MainActor
        Task.detached(priority: .userInitiated) { [scanner] in
            let summary = scanner.scan(libraryURL: url)
            await MainActor.run {
                self.scanSummary = summary
                if self.selectedCrate == nil || !summary.crates.contains(where: { $0.id == self.selectedCrate?.id }) {
                    self.selectedCrate = summary.crates.first
                }
                self.isScanning = false
                self.statusMessage = "Library Verified: \(summary.totalCrates) Crates, \(summary.totalAudioTracks) Tracks"
            }
        }
    }

    /// Selects a crate for viewing.
    public func selectCrate(_ crate: LibraryCrateInfo) {
        self.selectedCrate = crate
    }
}
