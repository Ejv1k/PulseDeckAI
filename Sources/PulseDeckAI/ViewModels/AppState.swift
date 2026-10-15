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
    private var scanGeneration: UInt64 = 0

    public init() {
        // Resolve library folder relative to current working directory or bundle
        let cwd = FileManager.default.currentDirectoryPath
        let defaultURL = URL(fileURLWithPath: cwd).appendingPathComponent(PulseDeckCoreConfig.defaultLibraryFolderName)
        self.libraryRootURL = defaultURL
        refreshLibrary()
    }

    /// Scans the library root and updates published state on MainActor.
    /// Strictly limits scanning to one in-flight operation and protects against stale results
    /// from out-of-order background task completion.
    public func refreshLibrary() {
        guard !self.isScanning else {
            // Drop concurrent rescan requests while a scan is actively running
            return
        }

        self.isScanning = true
        self.scanGeneration &+= 1
        let thisGeneration = self.scanGeneration
        let url = self.libraryRootURL

        // Perform scanner on background thread, deliver result to MainActor
        Task.detached(priority: .userInitiated) { [scanner] in
            let summary = scanner.scan(libraryURL: url)
            await MainActor.run {
                // Ignore result if another scan generation was initiated
                guard self.scanGeneration == thisGeneration else {
                    return
                }

                self.scanSummary = summary

                if let currentId = self.selectedCrate?.id,
                   let updatedCrate = summary.crates.first(where: { $0.id == currentId }) {
                    self.selectedCrate = updatedCrate
                } else {
                    self.selectedCrate = summary.crates.first
                }

                self.isScanning = false

                if let error = summary.scanError {
                    self.statusMessage = "Library Error: \(error)"
                } else {
                    self.statusMessage = "Library Verified: \(summary.totalCrates) Crates, \(summary.totalAudioTracks) Tracks"
                }
            }
        }
    }

    /// Selects a crate for viewing.
    public func selectCrate(_ crate: LibraryCrateInfo) {
        self.selectedCrate = crate
    }
}
