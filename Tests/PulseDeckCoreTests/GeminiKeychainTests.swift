import XCTest
@testable import PulseDeckCore

final class GeminiKeychainTests: XCTestCase {
    func testSaveReadReplaceDelete() throws {
        let keychain = GeminiKeychain(service: "PulseDeckAI-Gemini-Test-\(UUID().uuidString)", account: "api")
        defer { keychain.delete() }
        // Headless CI can lack a usable login Keychain; that is an environment fault, not a regression.
        try XCTSkipUnless(keychain.save("probe") && keychain.delete(), "Keychain unavailable")

        XCTAssertNil(keychain.read())
        XCTAssertFalse(keychain.hasKey)

        XCTAssertTrue(keychain.save("  key-one \n"))
        XCTAssertEqual(keychain.read(), "key-one")

        XCTAssertTrue(keychain.save("key-two"))
        XCTAssertEqual(keychain.read(), "key-two")

        XCTAssertTrue(keychain.delete())
        XCTAssertNil(keychain.read())

        XCTAssertTrue(keychain.delete())
    }

    func testBlankKeyIsRejected() throws {
        let keychain = GeminiKeychain(service: "PulseDeckAI-Gemini-Test-\(UUID().uuidString)", account: "api")
        defer { keychain.delete() }
        // Headless CI can lack a usable login Keychain; that is an environment fault, not a regression.
        try XCTSkipUnless(keychain.save("probe") && keychain.delete(), "Keychain unavailable")

        XCTAssertFalse(keychain.save("   "))
        XCTAssertNil(keychain.read())
    }
}
