import XCTest
@testable import PulseDeckCore
@testable import PulseDeckAI

@MainActor
final class DeckEQTests: XCTestCase {
    func testKnobPositionMapsLikeAMixer() {
        XCTAssertEqual(EQFader.position(for: 0), 0.5, accuracy: 1e-9, "0 dB sits at 12 o'clock")
        XCTAssertEqual(EQFader.position(for: -24), 0, accuracy: 1e-9)
        XCTAssertEqual(EQFader.position(for: 6), 1, accuracy: 1e-9)
        for gain: Float in [-24, -12, -3, 0, 2, 6] {
            XCTAssertEqual(EQFader.gain(for: EQFader.position(for: gain)), gain, accuracy: 1e-4)
        }
        XCTAssertEqual(EQFader.gain(for: -1), -24, "Turning past the stop stays killed")
        XCTAssertEqual(EQFader.gain(for: 2), 6)
    }

    func testDeckEQReachesBothGraphPathsAndIsClamped() throws {
        let audio = AudioEngineCoordinator(hal: MockAudioHardware())
        let root = FileManager.default.temporaryDirectory
        let app = AppState(libraryRootURL: root, waveformEditorModel: WaveformEditorModel(libraryRootURL: root),
                           audioCoordinator: audio, startCoordinator: false)
        XCTAssertTrue(app.setDeckEQ(deck: .deckB, eq: EQ3BandParameters(lowGainDB: -40, midGainDB: 3, highGainDB: 9)))
        XCTAssertEqual(app.deckBEQ, EQ3BandParameters(lowGainDB: -24, midGainDB: 3, highGainDB: 6))
        XCTAssertEqual(audio.deckBGraph.eqParameters, app.deckBEQ)
        XCTAssertEqual(audio.deckBGraph.masterEQNode.bands[0].gain, -24, "Master path gets the cut")
        XCTAssertEqual(audio.deckBGraph.cueEQNode.bands[0].gain, -24, "Headphones hear what the crowd hears")
        XCTAssertEqual(app.deckAEQ, EQ3BandParameters(), "The other channel is untouched")
    }
}
