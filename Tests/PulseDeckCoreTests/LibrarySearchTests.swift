import XCTest
@testable import PulseDeckCore

final class LibrarySearchTests: XCTestCase {
    private func crate(_ folder: String, _ display: String, _ files: [String], readable: Bool = true) -> LibraryCrateInfo {
        LibraryCrateInfo(id: folder, folderName: folder, displayName: display, relativePath: folder, trackCount: files.count, hasGitKeep: false, audioFiles: files, isReadable: readable)
    }

    private var crates: [LibraryCrateInfo] {
        let crates = [crate("01_Retro", "Retro", ["Neil LeVang - Ghost Riders In The Sky.mp3", "Shania Twain - Man! I Feel Like A Woman!.mp3"]), crate("02_Party", "Party", ["Ghost_Town.wav", "Beyoncé - Texas Hold Em.m4a"]), crate("03_Hidden", "Hidden", ["Ghost Hidden.mp3"], readable: false)]
        return crates
    }

    func testWordsMatchInAnyOrderAcrossCrates() {
        XCTAssertEqual(
            LibrarySearch.search("riders ghost", in: crates),
            ["01_Retro/Neil LeVang - Ghost Riders In The Sky.mp3"]
        )
    }

    func testPrefixTitlesComeFirst() {
        XCTAssertEqual(
            LibrarySearch.search("ghost", in: crates),
            ["02_Party/Ghost_Town.wav", "01_Retro/Neil LeVang - Ghost Riders In The Sky.mp3"]
        )
    }

    func testCaseAndDiacriticsAreIgnored() {
        XCTAssertEqual(
            LibrarySearch.search("BEYONCE texas", in: crates),
            ["02_Party/Beyoncé - Texas Hold Em.m4a"]
        )
    }

    func testCrateNameMatches() {
        XCTAssertEqual(
            LibrarySearch.search("party texas", in: crates),
            ["02_Party/Beyoncé - Texas Hold Em.m4a"]
        )
    }

    func testBlankQueryAndNoMatchAndLimit() {
        XCTAssertEqual(LibrarySearch.search("   ", in: crates), [])
        XCTAssertEqual(LibrarySearch.search("zzz", in: crates), [])
        XCTAssertEqual(
            LibrarySearch.search("ghost", in: crates, limit: 1),
            ["02_Party/Ghost_Town.wav"]
        )
    }

    func testUnderscoreInQueryMatchesSpace() {
        XCTAssertEqual(LibrarySearch.search("ghost_town", in: crates), ["02_Party/Ghost_Town.wav"])
    }

    func testFileExtensionIsNotMatched() {
        XCTAssertEqual(LibrarySearch.search("mp3", in: crates), [])
    }
}
