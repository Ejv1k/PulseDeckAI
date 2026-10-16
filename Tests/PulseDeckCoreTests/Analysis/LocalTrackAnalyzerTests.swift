import AVFoundation
import Foundation
import XCTest
@testable import PulseDeckCore

final class LocalTrackAnalyzerTests: XCTestCase {
    private let sampleRate = 8_000.0

    func testSilenceProducesValidBoundedCuesAndNoTempo() throws {
        let fixture = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let track = fixture.root.appendingPathComponent("00_Test_Tracks_Dev/silence.wav")
        try writeAudio(track, duration: 4) { _ in 0 }

        let entry = try LocalTrackAnalyzer().analyze(url: track, libraryRoot: fixture.root)
        XCTAssertEqual(entry.bpm, 0)
        XCTAssertEqual(entry.duration, 4, accuracy: 0.001)
        XCTAssertEqual(entry.sampleRate, sampleRate)
        XCTAssertEqual(entry.channels, 1)
        XCTAssertEqual(entry.waveformMetadata.sampleCount, Int(entry.duration * sampleRate))
        XCTAssertTrue(entry.cueMarkers.isValid(forDuration: entry.duration))
        XCTAssertEqual(entry.waveformMetadata.peakValues.count, 80)
        XCTAssertEqual(entry.confidence, 0)
    }

    func testClickTrackEstimatesTempoAndBeatGrid() throws {
        let fixture = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let track = fixture.root.appendingPathComponent("01_House/clicks.wav")
        try FileManager.default.createDirectory(at: track.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeAudio(track, duration: 120) { time in
            let beatPosition = (time * 2).truncatingRemainder(dividingBy: 1)
            return beatPosition < 0.008 ? 0.9 : 0
        }

        let entry = try LocalTrackAnalyzer().analyze(url: track, libraryRoot: fixture.root)
        XCTAssertEqual(entry.bpm, 120, accuracy: 1e-9)
        XCTAssertFalse(entry.beatGrid.beatTimestamps.isEmpty)
        XCTAssertEqual(entry.beatGrid.beatIntervalSeconds, 0.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(entry.beatGrid.beatTimestamps.last), 119.5, accuracy: 0.01)
        XCTAssertTrue(entry.confidence.isFinite && (0...1).contains(entry.confidence))
    }

    func testRejectsOutsideLibraryAndCorruptInput() throws {
        let fixture = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.deletingLastPathComponent().appendingPathComponent("outside.wav")
        try writeAudio(outside, duration: 1) { _ in 0 }
        XCTAssertThrowsError(try LocalTrackAnalyzer().analyze(url: outside, libraryRoot: fixture.root))

        let corrupt = fixture.root.appendingPathComponent("00_Test_Tracks_Dev/corrupt.wav")
        try Data("not audio".utf8).write(to: corrupt)
        XCTAssertThrowsError(try LocalTrackAnalyzer().analyze(url: corrupt, libraryRoot: fixture.root))
    }

    func testRejectsEmptyAudio() throws {
        let fixture = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let track = fixture.root.appendingPathComponent("00_Test_Tracks_Dev/empty.wav")
        try writeAudio(track, duration: 0) { _ in 0 }
        XCTAssertThrowsError(try LocalTrackAnalyzer().analyze(url: track, libraryRoot: fixture.root))
    }

    func testShortToneHasNoTempoEstimate() throws {
        let fixture = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let track = fixture.root.appendingPathComponent("00_Test_Tracks_Dev/short.wav")
        try writeAudio(track, duration: 1) { time in Float(sin(2 * .pi * 440 * time) * 0.3) }
        let entry = try LocalTrackAnalyzer().analyze(url: track, libraryRoot: fixture.root)
        XCTAssertEqual(entry.bpm, 0)
        XCTAssertEqual(entry.confidence, 0)
        XCTAssertTrue(entry.cueMarkers.isValid(forDuration: entry.duration))
    }

    func testCategoryParserUsesCrateConventionAndRejectsEscape() throws {
        let root = URL(fileURLWithPath: "/tmp/PulseDeck_Library", isDirectory: true)
        let track = root.appendingPathComponent("02_Drum_And_Bass/song.mp3")
        XCTAssertEqual(LibraryCategoryParser.category(for: track, libraryRoot: root), "Drum And Bass")
        XCTAssertNil(LibraryCategoryParser.category(for: URL(fileURLWithPath: "/tmp/outside/song.mp3"), libraryRoot: root))
    }

    func testServicePersistsValidatedCacheAndPreservesManualOverrides() async throws {
        let fixture = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let track = fixture.root.appendingPathComponent("00_Test_Tracks_Dev/tone.wav")
        try writeAudio(track, duration: 6) { time in Float(sin(2 * .pi * 440 * time) * 0.3) }
        let service = LibraryAnalysisService(libraryRoot: fixture.root)
        let first = try await service.analyzeTrack(at: track)
        var cache = try XCTUnwrap(CachePersistence.load(from: fixture.root.appendingPathComponent(PulseDeckCoreConfig.cacheFileName)))
        XCTAssertNoThrow(try cache.validate())
        cache.tracks[first.relativePath]?.cueMarkers = CueMarkers(startTrimCue: 0.2, vocalEntryCue: 1, mixOutCue: 4, endTrimCue: 5.8)
        cache.tracks[first.relativePath]?.bpm = 97
        cache.tracks[first.relativePath]?.manualOverrides = ManualOverrides(isManual: true, overriddenFields: ["cueMarkers", "bpm"])
        try CachePersistence.saveAtomic(cache: cache, to: fixture.root.appendingPathComponent(PulseDeckCoreConfig.cacheFileName))

        let second = try await service.analyzeTrack(at: track)
        XCTAssertEqual(second.bpm, 97)
        XCTAssertEqual(second.cueMarkers.startTrimCue, 0.2)
        XCTAssertTrue(second.manualOverrides.isManual)
        XCTAssertNoThrow(try XCTUnwrap(CachePersistence.load(from: fixture.root.appendingPathComponent(PulseDeckCoreConfig.cacheFileName))).validate())
    }

    func testServiceDoesNotOverwriteInvalidExistingCache() async throws {
        let fixture = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let track = fixture.root.appendingPathComponent("00_Test_Tracks_Dev/tone.wav")
        try writeAudio(track, duration: 1) { _ in 0 }
        let cacheURL = fixture.root.appendingPathComponent(PulseDeckCoreConfig.cacheFileName)
        let invalidData = Data("invalid cache".utf8)
        try invalidData.write(to: cacheURL)
        let service = LibraryAnalysisService(libraryRoot: fixture.root)

        do {
            _ = try await service.analyzeTrack(at: track)
            XCTFail("Expected invalid cache to fail")
        } catch let error as LibraryAnalysisServiceError {
            XCTAssertEqual(error, .invalidExistingCache)
        }
        XCTAssertEqual(try Data(contentsOf: cacheURL), invalidData)
    }

    private func makeLibrary() throws -> (root: URL, crate: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PulseDeckTests-\(UUID().uuidString)", isDirectory: true)
        let crate = root.appendingPathComponent("00_Test_Tracks_Dev", isDirectory: true)
        try FileManager.default.createDirectory(at: crate, withIntermediateDirectories: true)
        return (root, crate)
    }

    private func writeAudio(_ url: URL, duration: Double, sample: (Double) -> Float) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = Int(duration * sampleRate)
        guard frameCount > 0 else { return }
        var samples = [Float](repeating: 0, count: frameCount)
        for index in samples.indices { samples[index] = sample(Double(index) / sampleRate) }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: frameCount)
        }
        try file.write(from: buffer)
    }
}
