import XCTest
@testable import PulseDeckAI

final class LibraryTrackTitleTests: XCTestCase {
    func testStripsExtensionAndVideoNoise() {
        XCTAssertEqual(LibraryTrackTitle.display("AC⧸DC - Highway to Hell (Official Video).mp3"), "AC⧸DC - Highway to Hell")
        XCTAssertEqual(LibraryTrackTitle.display("Queen - Don't Stop Me Now (Official Video Remastered 4K).mp3"), "Queen - Don't Stop Me Now")
        XCTAssertEqual(LibraryTrackTitle.display("Song [Lyrics].flac"), "Song")
    }

    func testKeepsMeaningfulParenthesesAndNeverReturnsEmpty() {
        XCTAssertEqual(LibraryTrackTitle.display("ABBA - Gimme! Gimme! Gimme! (A Man After Midnight).mp3"),
                       "ABBA - Gimme! Gimme! Gimme! (A Man After Midnight)")
        XCTAssertEqual(LibraryTrackTitle.display("(Official Video).mp3"), "(Official Video)")
    }
}
