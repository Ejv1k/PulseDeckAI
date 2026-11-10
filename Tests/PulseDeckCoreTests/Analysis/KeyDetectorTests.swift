import XCTest
@testable import PulseDeckCore

final class KeyDetectorTests: XCTestCase {
    private let sampleRate = 22050.0

    /// Sums equal-level sines (Hz) for `seconds`.
    private func chord(_ frequencies: [Double], seconds: Double = 4) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { i in
            let t = Double(i) / sampleRate
            return Float(frequencies.reduce(0) { $0 + sin(2 * .pi * $1 * t) } / Double(frequencies.count))
        }
    }

    func testMajorTriadIsDetected() throws {
        // C4 E4 G4 plus C3 root
        XCTAssertEqual(try KeyDetector.detectKey(samples: chord([130.81, 261.63, 329.63, 392.00]), sampleRate: sampleRate), "C")
    }

    func testMinorTriadIsDetected() throws {
        // A3 C4 E4 plus A2 root
        XCTAssertEqual(try KeyDetector.detectKey(samples: chord([110.00, 220.00, 261.63, 329.63]), sampleRate: sampleRate), "Am")
    }

    func testSilenceAndTooShortAudioHaveNoKey() throws {
        XCTAssertNil(try KeyDetector.detectKey(samples: [Float](repeating: 0, count: 100_000), sampleRate: sampleRate))
        XCTAssertNil(try KeyDetector.detectKey(samples: [Float](repeating: 0.1, count: 1_000), sampleRate: sampleRate))
    }

    func testDetectedNamesParseAsCamelotKeys() {
        for name in KeyDetector.majorNames + KeyDetector.minorNames {
            XCTAssertNotNil(CamelotKey.parse(name), name)
        }
    }
}
