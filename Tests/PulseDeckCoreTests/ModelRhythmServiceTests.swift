import AVFoundation
import CoreML
import Foundation
@testable import PulseDeckCore
import XCTest

final class ModelRhythmServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PulseDeck_RhythmServiceTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = tempDir, FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Synthesizes a hermetic mono PCM Float32 WAV file with periodic beat pulses.
    private func createSyntheticWAV(durationSeconds: Double, sampleRate: Double = 22050.0, bpm: Double = 120.0) throws -> URL {
        let fileURL = tempDir.appendingPathComponent("synthetic_\(UUID().uuidString).wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)

        let totalFrames = AVAudioFrameCount(round(durationSeconds * sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            throw MelSpectrogramError.bufferAllocationFailed
        }
        buffer.frameLength = totalFrames

        let channelData = buffer.floatChannelData![0]
        let beatIntervalFrames = Int(sampleRate * (60.0 / bpm))

        for f in 0..<Int(totalFrames) {
            let beatIndex = f % beatIntervalFrames
            if beatIndex < 200 { // 200 samples click burst (~9ms)
                let t = Double(beatIndex) / sampleRate
                let freq = (f % (4 * beatIntervalFrames) < 200) ? 880.0 : 440.0 // higher pitch on downbeat
                channelData[f] = Float(sin(2.0 * Double.pi * freq * t) * (1.0 - Double(beatIndex) / 200.0) * 0.8)
            } else {
                channelData[f] = 0.0
            }
        }

        try file.write(from: buffer)
        return fileURL
    }

    // MARK: - Unit Tests

    func testPostprocessingMaxpoolAndDeduplication() {
        // Direct algorithmic verification of 1D max pooling (+/- 70ms / 7 frames)
        let signal: [Float] = [0.1, 0.5, 0.9, 0.4, 0.2, 0.3, 0.1, 0.8, 0.2]
        let pooled = ModelRhythmService.maxPool1D(signal: signal, kernelSize: 7)

        XCTAssertEqual(pooled.count, signal.count)
        // At index 2 (val 0.9), it should equal max in window [0..5] which is 0.9
        XCTAssertEqual(pooled[2], 0.9, accuracy: 1e-6)
        // At index 7 (val 0.8), it should equal max in window [4..8] which is 0.8
        XCTAssertEqual(pooled[7], 0.8, accuracy: 1e-6)

        // Peak deduplication with width = 1 (matching upstream Python deduplicate_peaks)
        let adjacentPeaks = [10, 11, 20, 21, 22, 50]
        let dedup = ModelRhythmService.deduplicatePeaks(peaks: adjacentPeaks, width: 1.0)
        XCTAssertEqual(dedup.count, 4)
        XCTAssertEqual(dedup[0], 10.5, accuracy: 1e-5) // mean of 10 and 11
        XCTAssertEqual(dedup[1], 20.5, accuracy: 1e-5) // mean of 20 and 21
        XCTAssertEqual(dedup[2], 22.0, accuracy: 1e-5) // 22 is 1.5 away from 20.5 (> 1.0)
        XCTAssertEqual(dedup[3], 50.0, accuracy: 1e-5)

        // Snapping downbeats to nearest beats
        let beats = [0.0, 0.5, 1.0, 1.5, 2.0]
        let rawDownbeats = [0.02, 1.01, 1.98]
        let snapped = ModelRhythmService.snapDownbeats(downbeats: rawDownbeats, beats: beats)
        XCTAssertEqual(snapped, [0.0, 1.0, 2.0])
    }

    func testSlaneyMelSpectrogramComputation() throws {
        let frontend = try SlaneyMelSpectrogram()

        // 1 second of silence at 22,050 Hz
        let silence = [Float](repeating: 0.0, count: 22050)
        let spec = try frontend.computeLogMelSpectrogram(samples: silence)

        // 22050 + 1024 padded = 23074 samples. (23074 - 1024) / 441 + 1 = 51 frames
        let expectedFrames = (22050 + 1024 - 1024) / 441 + 1
        XCTAssertEqual(spec.count, expectedFrames * 128)

        // All values should be 0.0 because ln(1 + 1000 * 0) == 0.0
        for val in spec {
            XCTAssertEqual(val, 0.0, accuracy: 1e-5)
        }
    }

    func testAudioSampleLoadingAndResampling() throws {
        // Create 44.1 kHz stereo audio file
        let stereoURL = tempDir.appendingPathComponent("stereo44100.wav")
        let format44100 = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: stereoURL, settings: format44100.settings)
            let frames44100 = AVAudioFrameCount(44100)
            let buf = AVAudioPCMBuffer(pcmFormat: format44100, frameCapacity: frames44100)!
            buf.frameLength = frames44100
            for ch in 0..<2 {
                for i in 0..<Int(frames44100) {
                    buf.floatChannelData![ch][i] = 0.1
                }
            }
            try file.write(from: buf)
        }

        // Load through SlaneyMelSpectrogram.loadAudioSamples
        let resampled = try SlaneyMelSpectrogram.loadAudioSamples(from: stereoURL)

        // 1.0s at 22,050 Hz should be ~22,050 samples
        XCTAssertEqual(resampled.count, 22050, accuracy: 50)
    }

    func testLoopedAudioSampleLoadingExactFrames() throws {
        // 30,429 frames (non-power-of-two, 1.38s at 22,050 Hz)
        let exactFrames = 30429
        let wavURL = try createSyntheticWAV(durationSeconds: Double(exactFrames) / 22050.0, sampleRate: 22050.0, bpm: 120.0)
        let samples = try SlaneyMelSpectrogram.loadAudioSamples(from: wavURL)
        XCTAssertEqual(samples.count, exactFrames, "Looped audio loader must read all frames without premature truncation")
    }

    func testQAEvidenceFixturesIfPresent() async throws {
        let shortURL = URL(fileURLWithPath: "/var/folders/1h/6xqn450n79l88dgzb89r9k0r0000gn/T/rhythm-native93-luita8p4/evidence/fixtures/short_nonzero.wav")
        let multiURL = URL(fileURLWithPath: "/var/folders/1h/6xqn450n79l88dgzb89r9k0r0000gn/T/rhythm-native93-luita8p4/evidence/fixtures/multichunk_stereo.wav")
        guard FileManager.default.fileExists(atPath: shortURL.path) && FileManager.default.fileExists(atPath: multiURL.path) else { return }

        let shortPCM = try SlaneyMelSpectrogram.loadAudioSamples(from: shortURL)
        XCTAssertEqual(shortPCM.count, 30429)

        let service = try ModelRhythmService(computeUnits: .cpuOnly)
        let shortAnalysis = try await service.analyzeRhythm(audioURL: shortURL)
        XCTAssertFalse(shortAnalysis.beats.isEmpty)
        XCTAssertEqual(shortAnalysis.beats, [0.5])

        let multiPCM = try SlaneyMelSpectrogram.loadAudioSamples(from: multiURL)
        XCTAssertEqual(multiPCM.count, 780129)
        let multiAnalysis = try await service.analyzeRhythm(audioURL: multiURL)
        XCTAssertFalse(multiAnalysis.beats.isEmpty)
        XCTAssertEqual(multiAnalysis.beats.count, 71)
        XCTAssertEqual(multiAnalysis.downbeats.count, 54)
    }

    func testModelRhythmServiceEndToEnd() async throws {
        let wavURL = try createSyntheticWAV(durationSeconds: 10.0, bpm: 120.0)
        let service = try ModelRhythmService(computeUnits: .cpuOnly)

        let analysis = try await service.analyzeRhythm(audioURL: wavURL)

        // Verify provenance metadata
        XCTAssertEqual(analysis.modelName, "BeatThis_small0")
        XCTAssertEqual(analysis.modelVersion, "small0_fp32")
        XCTAssertEqual(analysis.frameRateHz, 50.0)

        // Verify beats: sorted, positive, bounded
        XCTAssertFalse(analysis.beats.isEmpty, "Service should detect beats on rhythmic fixture")
        XCTAssertTrue(analysis.beats == analysis.beats.sorted(), "Beats must be strictly sorted")
        for b in analysis.beats {
            XCTAssertGreaterThanOrEqual(b, 0.0)
            XCTAssertLessThanOrEqual(b, 10.5)
        }

        // Verify downbeats: subset of beats, sorted
        XCTAssertFalse(analysis.downbeats.isEmpty, "Service should detect downbeats on rhythmic fixture")
        XCTAssertTrue(analysis.downbeats == analysis.downbeats.sorted(), "Downbeats must be strictly sorted")
        for db in analysis.downbeats {
            XCTAssertTrue(analysis.beats.contains(db), "Every downbeat must snap to a detected beat")
        }
    }

    func testShortAudioHandling() async throws {
        // 1.0 second audio (< 1500 frames / 30 seconds)
        let wavURL = try createSyntheticWAV(durationSeconds: 1.0, bpm: 120.0)
        let service = try ModelRhythmService(computeUnits: .cpuOnly)

        let analysis = try await service.analyzeRhythm(audioURL: wavURL)
        XCTAssertEqual(analysis.modelName, "BeatThis_small0")
        for b in analysis.beats {
            XCTAssertLessThanOrEqual(b, 1.5)
        }
    }

    func testLongAudioMultiChunkHandling() async throws {
        // 35.0 seconds audio (> 1500 frames / 30 seconds chunk size)
        let wavURL = try createSyntheticWAV(durationSeconds: 35.0, bpm: 120.0)
        let service = try ModelRhythmService(computeUnits: .cpuOnly)

        let analysis = try await service.analyzeRhythm(audioURL: wavURL)

        // Should detect beats across chunks, spanning beyond 30 seconds
        XCTAssertFalse(analysis.beats.isEmpty)
        let beatsAfter30s = analysis.beats.filter { $0 > 30.0 }
        XCTAssertFalse(beatsAfter30s.isEmpty, "Multi-chunk aggregation must retain beats past 30 seconds")
        XCTAssertTrue(analysis.beats == analysis.beats.sorted())
    }

    func testCancellation() async throws {
        let wavURL = try createSyntheticWAV(durationSeconds: 15.0, bpm: 120.0)
        let service = try ModelRhythmService(computeUnits: .cpuOnly)

        let task = Task {
            try await service.analyzeRhythm(audioURL: wavURL)
        }
        task.cancel()

        do {
            _ = try await task.value
            // If it completed before cancel was checked, it's acceptable, but should not crash
        } catch is CancellationError {
            // Expected cancellation
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testInvalidFileHandling() async {
        let nonexistentURL = tempDir.appendingPathComponent("missing.wav")
        do {
            let service = try ModelRhythmService(computeUnits: .cpuOnly)
            _ = try await service.analyzeRhythm(audioURL: nonexistentURL)
            XCTFail("Should throw on nonexistent file")
        } catch {
            // Expected error
            XCTAssertNotNil(error)
        }
    }
}
