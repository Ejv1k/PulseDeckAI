import XCTest
@testable import PulseDeckCore

final class LibraryScannerTests: XCTestCase {

    func testScanExistingLibrary() {
        let scanner = LibraryScanner()
        let cwd = FileManager.default.currentDirectoryPath
        let libraryURL = URL(fileURLWithPath: cwd).appendingPathComponent("PulseDeck_Library")

        let summary = scanner.scan(libraryURL: libraryURL)

        XCTAssertTrue(summary.hasCacheFile, "PulseDeck_Library should contain .pulsedeck_ai_cache.json")
        XCTAssertEqual(summary.cacheSchemaVersion, "1.0.0", "Cache schema should be 1.0.0")
        XCTAssertGreaterThanOrEqual(summary.totalCrates, 10, "Should detect at least 10 crates")

        // Verify each standard crate is detected with .gitkeep
        for expectedCrate in PulseDeckCoreConfig.standardCrates {
            let crate = summary.crates.first(where: { $0.folderName == expectedCrate })
            XCTAssertNotNil(crate, "Crate \(expectedCrate) must be detected")
            XCTAssertTrue(crate?.hasGitKeep ?? false, "Crate \(expectedCrate) must contain .gitkeep")
        }

        // Verify 00_Test_Tracks_Dev contains the 7 preserved test tracks
        let devCrate = summary.crates.first(where: { $0.folderName == "00_Test_Tracks_Dev" })
        XCTAssertNotNil(devCrate)
        XCTAssertEqual(devCrate?.trackCount, 7, "00_Test_Tracks_Dev should contain 7 test tracks")
        XCTAssertEqual(devCrate?.audioFiles.count, 7)
    }

    func testDisplayNameFormatting() {
        XCTAssertEqual(LibraryScanner.displayName(for: "00_Test_Tracks_Dev"), "[00] Test Tracks Dev")
        XCTAssertEqual(LibraryScanner.displayName(for: "05_MainStage_Dance_120_128BPM"), "[05] MainStage Dance 120 128BPM")
        XCTAssertEqual(LibraryScanner.displayName(for: "Custom_Crate"), "Custom Crate")
    }
}
