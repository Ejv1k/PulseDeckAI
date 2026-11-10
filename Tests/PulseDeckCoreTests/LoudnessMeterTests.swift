import XCTest
import AVFoundation
@testable import PulseDeckCore

final class LoudnessMeterTests: XCTestCase {
    private func writeSine(hz: Double, dBFS: Double, seconds: Double, rate: Double = 48_000, channels: AVAudioChannelCount = 2,
                           gapSeconds: Double = 0) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loudness-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let frames = AVAudioFrameCount((seconds + gapSeconds) * rate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let amplitude = pow(10, dBFS / 20)
        let data = try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            let v = t < seconds ? Float(amplitude * sin(2 * .pi * hz * t)) : 0
            for c in 0..<Int(channels) { data[c][i] = v }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    /// EBU Tech 3341 reference: a stereo 1 kHz sine at -23 dBFS reads -23 LUFS.
    func testEBUReferenceSineReadsMinus23LUFS() throws {
        let url = try writeSine(hz: 1000, dBFS: -23, seconds: 10); defer { try? FileManager.default.removeItem(at: url) }
        let m = try LoudnessMeter.measure(url: url)
        XCTAssertEqual(m.integratedLUFS, -23, accuracy: 0.1)
        XCTAssertEqual(Double(m.samplePeak), pow(10, -23.0 / 20), accuracy: 1e-3)
    }

    func testSampleRateIndependentAndSilenceIsGatedOut() throws {
        let url = try writeSine(hz: 1000, dBFS: -18, seconds: 6, rate: 44_100, gapSeconds: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try LoudnessMeter.measure(url: url).integratedLUFS, -18, accuracy: 0.15,
                       "Trailing silence must not drag the loudness down")
    }

    func testSilentFileIsReportedNotGuessed() throws {
        let url = try writeSine(hz: 1000, dBFS: -200, seconds: 3); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try LoudnessMeter.measure(url: url)) { XCTAssertEqual($0 as? LoudnessMeter.Failure, .silent) }
    }

    func testAutoGainTargetsRangeAndPeakCeiling() {
        let quiet = LoudnessMeter.Measurement(integratedLUFS: -20, samplePeak: 0.1)    // peak -20 dBFS
        XCTAssertEqual(LoudnessMeter.autoGainDB(for: quiet), 6, accuracy: 1e-9)
        let loud = LoudnessMeter.Measurement(integratedLUFS: -6, samplePeak: 1)
        XCTAssertEqual(LoudnessMeter.autoGainDB(for: loud), -8, accuracy: 1e-9)
        let peaky = LoudnessMeter.Measurement(integratedLUFS: -24, samplePeak: 0.5)   // peak -6 dBFS
        XCTAssertEqual(LoudnessMeter.autoGainDB(for: peaky), -1 + 20 * log10(2.0), accuracy: 1e-6, "Boost stops 1 dB under full scale")
        let whisper = LoudnessMeter.Measurement(integratedLUFS: -50, samplePeak: 0.001)
        XCTAssertEqual(LoudnessMeter.autoGainDB(for: whisper), 9, accuracy: 1e-9, "Boost is capped")
    }
}
