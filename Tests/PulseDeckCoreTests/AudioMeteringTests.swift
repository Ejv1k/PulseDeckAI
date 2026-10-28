import AVFoundation
import PulseDeckAtomics
import XCTest
@testable import PulseDeckCore

final class AudioMeteringTests: XCTestCase {
    private func ring() throws -> OpaquePointer {
        let ring = try XCTUnwrap(pd_meter_ring_create())
        XCTAssertTrue(pd_meter_ring_is_lock_free(ring))
        return ring
    }

    private func pop(_ ring: OpaquePointer) -> PDMeterSample? {
        var sample = PDMeterSample()
        return pd_meter_ring_pop(ring, &sample) ? sample : nil
    }

    private func bin(_ sample: PDMeterSample, _ index: Int) -> Float {
        withUnsafeBytes(of: sample.spectrum) { bytes in
            bytes.load(fromByteOffset: index * MemoryLayout<Float>.stride, as: Float.self)
        }
    }

    private func assertFullCallbackMetrics(frameCount: Int, sampleRate: Double,
                                           file: StaticString = #filePath, line: UInt = #line) throws {
        let ring = try ring()
        defer { pd_meter_ring_destroy(ring) }
        var left = [Float](repeating: 0.003, count: frameCount)
        var right = [Float](repeating: 0.004, count: frameCount)
        // A peak beyond the original 4096-frame limit also proves metrics include the tail.
        left[frameCount - 1] = 0.2
        right[frameCount - 1] = -0.3
        let pushed = left.withUnsafeBufferPointer { leftBuffer in
            right.withUnsafeBufferPointer { rightBuffer in
                pd_meter_ring_push_audio(ring, leftBuffer.baseAddress, rightBuffer.baseAddress,
                                         2, UInt32(frameCount), sampleRate, UInt64(frameCount))
            }
        }
        XCTAssertTrue(pushed, "Supported tap callback must not be dropped", file: file, line: line)
        guard pushed else { return }
        let sample = try XCTUnwrap(pop(ring), file: file, line: line)
        let energy = Double(frameCount - 1) * (0.003 * 0.003 + 0.004 * 0.004) + 0.2 * 0.2 + 0.3 * 0.3
        XCTAssertEqual(sample.rms, Float(sqrt(energy / Double(2 * frameCount))), accuracy: 0.000001,
                       file: file, line: line)
        XCTAssertEqual(sample.peak, 0.3, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(sample.frame_count, UInt32(frameCount), file: file, line: line)
        XCTAssertEqual(sample.sample_rate, sampleRate, file: file, line: line)
        XCTAssertEqual(sample.host_time, UInt64(frameCount), file: file, line: line)
        XCTAssertEqual(sample.fft_size, 1024, file: file, line: line)
        // The first 1024-frame stereo average stays 0.0035; the late peak must not resize the FFT.
        XCTAssertEqual(bin(sample, 0), 0.0035, accuracy: 0.00005, file: file, line: line)
        XCTAssertNil(pop(ring), file: file, line: line)
        XCTAssertEqual(pd_meter_ring_dropped_count(ring), 0, file: file, line: line)
    }

    func testNative4410FrameCallbackPreservesFullStereoPeakAndRMS() throws {
        try assertFullCallbackMetrics(frameCount: 4410, sampleRate: 44100)
    }

    func testNative4800FrameCallbackPreservesFullStereoPeakAndRMS() throws {
        try assertFullCallbackMetrics(frameCount: 4800, sampleRate: 48000)
    }

    func testExactCallbackCapacityAndBeyondCapacityRejection() throws {
        let capacity = Int(PD_METER_MAX_CALLBACK_FRAMES)
        XCTAssertEqual(capacity, 76800)
        try assertFullCallbackMetrics(frameCount: capacity, sampleRate: 192000)
        let ring = try ring()
        defer { pd_meter_ring_destroy(ring) }
        let values = [Float](repeating: 0.125, count: capacity + 1)
        let pushed = values.withUnsafeBufferPointer {
            pd_meter_ring_push_audio(ring, $0.baseAddress, $0.baseAddress,
                                     2, UInt32(values.count), 192000, 100)
        }
        XCTAssertFalse(pushed)
        XCTAssertNil(pop(ring))
        XCTAssertEqual(pd_meter_ring_dropped_count(ring), 1)
    }

    func testValidBuffersStillRejectUnsupportedChannelsAndRates() throws {
        let ring = try ring()
        defer { pd_meter_ring_destroy(ring) }
        let values = [Float](repeating: 0.125, count: 1024)
        values.withUnsafeBufferPointer { buffer in
            for channels in [UInt32(0), 3] {
                XCTAssertFalse(pd_meter_ring_push_audio(ring, buffer.baseAddress, buffer.baseAddress,
                                                        channels, 1024, 48000, 1))
            }
            for rate in [Double(7999), 192001, .nan, .infinity] {
                XCTAssertFalse(pd_meter_ring_push_audio(ring, buffer.baseAddress, buffer.baseAddress,
                                                        2, 1024, rate, 2))
            }
            XCTAssertFalse(pd_meter_ring_push_audio(ring, buffer.baseAddress, buffer.baseAddress,
                                                    2, 0, 48000, 3))
            XCTAssertTrue(pd_meter_ring_push_audio(ring, buffer.baseAddress, nil,
                                                   1, 1024, 8000, 4))
        }
        let sample = try XCTUnwrap(pop(ring))
        XCTAssertEqual(sample.rms, 0.125, accuracy: 0.000001)
        XCTAssertEqual(sample.peak, 0.125, accuracy: 0.000001)
        XCTAssertNil(pop(ring))
        XCTAssertEqual(pd_meter_ring_dropped_count(ring), 7)
    }

    func testSilenceDCAndToneMetricsAndFrequencyBins() throws {
        let ring = try ring()
        defer { pd_meter_ring_destroy(ring) }
        let silence = [Float](repeating: 0, count: 1024)
        let pushedSilence = silence.withUnsafeBufferPointer {
            pd_meter_ring_push_audio(ring, $0.baseAddress, nil, 1, 1024, 48000, 1)
        }
        XCTAssertTrue(pushedSilence)
        let silenceSample = try XCTUnwrap(pop(ring))
        XCTAssertEqual(silenceSample.rms, 0)
        XCTAssertEqual(silenceSample.peak, 0)
        XCTAssertEqual(silenceSample.sample_rate, 48000)
        XCTAssertEqual(silenceSample.frame_count, 1024)
        XCTAssertEqual(silenceSample.fft_size, 1024)
        XCTAssertEqual(bin(silenceSample, 0), 0)

        let dc = [Float](repeating: 0.25, count: 1024)
        let pushedDC = dc.withUnsafeBufferPointer {
            pd_meter_ring_push_audio(ring, $0.baseAddress, nil, 1, 1024, 48000, 2)
        }
        XCTAssertTrue(pushedDC)
        let dcSample = try XCTUnwrap(pop(ring))
        XCTAssertEqual(dcSample.rms, 0.25, accuracy: 0.0001)
        XCTAssertEqual(dcSample.peak, 0.25, accuracy: 0.0001)
        XCTAssertGreaterThan(bin(dcSample, 0), 0.1)

        let tone = (0..<1024).map { Float(0.5 * sin(2 * Double.pi * 32 * Double($0) / 1024)) }
        let pushedTone = tone.withUnsafeBufferPointer {
            pd_meter_ring_push_audio(ring, $0.baseAddress, nil, 1, 1024, 48000, 3)
        }
        XCTAssertTrue(pushedTone)
        let toneSample = try XCTUnwrap(pop(ring))
        XCTAssertEqual(toneSample.rms, 0.5 / sqrt(2), accuracy: 0.001)
        XCTAssertEqual(toneSample.peak, 0.5, accuracy: 0.001)
        XCTAssertEqual(Double(32) * toneSample.sample_rate / Double(toneSample.fft_size), 1500, accuracy: 0.001)
        XCTAssertGreaterThan(bin(toneSample, 32), 0.2)
        XCTAssertLessThan(bin(toneSample, 32), 0.3)
        XCTAssertEqual(toneSample.host_time, 3)

        let changedRate = tone.withUnsafeBufferPointer {
            pd_meter_ring_push_audio(ring, $0.baseAddress, nil, 1, 1024, 44100, 4)
        }
        XCTAssertTrue(changedRate)
        let changedRateSample = try XCTUnwrap(pop(ring))
        XCTAssertEqual(changedRateSample.sample_rate, 44100)
        XCTAssertEqual(Double(32) * changedRateSample.sample_rate / Double(changedRateSample.fft_size), 1378.125, accuracy: 0.001)
    }

    func testStereoRMSUsesBothChannelsAndMonoSpectrumUsesAverage() throws {
        let ring = try ring()
        defer { pd_meter_ring_destroy(ring) }
        let left = (0..<1024).map { Float(0.5 * sin(2 * Double.pi * 32 * Double($0) / 1024)) }
        let right = [Float](repeating: 0, count: 1024)
        let pushed = left.withUnsafeBufferPointer { leftBuffer in
            right.withUnsafeBufferPointer { rightBuffer in
                pd_meter_ring_push_audio(ring, leftBuffer.baseAddress, rightBuffer.baseAddress,
                                         2, 1024, 44100, 77)
            }
        }
        XCTAssertTrue(pushed)
        let sample = try XCTUnwrap(pop(ring))
        XCTAssertEqual(sample.rms, 0.25, accuracy: 0.001)
        XCTAssertEqual(sample.peak, 0.5, accuracy: 0.001)
        XCTAssertEqual(sample.sample_rate, 44100)
        XCTAssertEqual(Double(32) * sample.sample_rate / Double(sample.fft_size), 1378.125, accuracy: 0.001)
        XCTAssertGreaterThan(bin(sample, 32), 0.1)
        XCTAssertLessThan(bin(sample, 32), 0.2)
    }

    func testNonFiniteSamplesBecomeSilenceAndUnsupportedFormatsDrop() throws {
        let ring = try ring()
        defer { pd_meter_ring_destroy(ring) }
        var values = [Float](repeating: 0, count: 1024)
        values[0] = .nan
        values[1] = .infinity
        values[2] = -.infinity
        values[3] = 0.5
        let pushed = values.withUnsafeBufferPointer {
            pd_meter_ring_push_audio(ring, $0.baseAddress, nil, 1, 1024, 96000, 90)
        }
        XCTAssertTrue(pushed)
        let sample = try XCTUnwrap(pop(ring))
        XCTAssertTrue(sample.rms.isFinite)
        XCTAssertTrue(sample.peak.isFinite)
        XCTAssertEqual(sample.peak, 0.5, accuracy: 0.0001)
        XCTAssertEqual(sample.sample_rate, 96000)
        XCTAssertFalse(pd_meter_ring_push_audio(ring, nil, nil, 3, 1024, 48000, 91))
        XCTAssertFalse(pd_meter_ring_push_audio(ring, nil, nil, 1, 0, 48000, 92))
        XCTAssertFalse(pd_meter_ring_push_audio(ring, nil, nil, 1, 1024, .infinity, 93))
        XCTAssertEqual(pd_meter_ring_dropped_count(ring), 3)
    }

    func testBoundedDropNewestAndFIFOReadOrder() throws {
        let ring = try ring()
        defer { pd_meter_ring_destroy(ring) }
        let values = [Float](repeating: 0.125, count: 1024)
        for index in 0..<32 {
            let pushed = values.withUnsafeBufferPointer {
                pd_meter_ring_push_audio(ring, $0.baseAddress, nil, 1, 1024, 48000,
                                         UInt64(index))
            }
            XCTAssertTrue(pushed)
        }
        let overflowed = values.withUnsafeBufferPointer {
            pd_meter_ring_push_audio(ring, $0.baseAddress, nil, 1, 1024, 48000, 32)
        }
        XCTAssertFalse(overflowed)
        XCTAssertEqual(pd_meter_ring_dropped_count(ring), 1)
        for index in 0..<32 {
            XCTAssertEqual(try XCTUnwrap(pop(ring)).host_time, UInt64(index))
        }
        XCTAssertNil(pop(ring))
    }

    func testCueRingAllocationFailureDestroysMasterResourcesAndAllowsRetry() throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let allocationCount = TestBox(0)
        let destructionCount = TestBox(0)
        let service = AudioMeteringService(
            coordinator: coordinator,
            allocateRingForTesting: {
                allocationCount.value += 1
                guard allocationCount.value != 2 else { return nil }
                return pd_meter_ring_create()
            },
            destroyRingForTesting: { ring in
                destructionCount.value += 1
                pd_meter_ring_destroy(ring)
            }
        )

        XCTAssertThrowsError(try service.start()) { error in
            guard case AudioMeteringError.processingResourcesUnavailable = error else {
                return XCTFail("Unexpected allocation error: \(error)")
            }
        }
        XCTAssertEqual(destructionCount.value, 1, "Failed cue allocation must destroy the already-created master ring and FFT setup")

        try service.start()
        service.stop()
        XCTAssertEqual(destructionCount.value, 3, "Retry must install and then destroy both role rings")
    }

    func testServiceOfflineLifecycleRestartAndIndependentOutputQueues() throws {
        let coordinator = AudioEngineCoordinator(hal: MockAudioHardware())
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        for engine in [coordinator.masterAudioEngine.rawEngine, coordinator.cueAudioEngine.rawEngine] {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
            let source = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for buffer in buffers {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    data.initialize(repeating: 0, count: Int(frameCount))
                }
                return noErr
            }
            engine.attach(source)
            engine.connect(source, to: engine === coordinator.masterAudioEngine.rawEngine
                           ? coordinator.masterAudioEngine.subMixer
                           : coordinator.cueAudioEngine.subMixer, format: format)
        }
        let service = AudioMeteringService(coordinator: coordinator)
        try service.start()
        try coordinator.masterAudioEngine.rawEngine.start()
        coordinator.masterAudioEngine.rawEngine.pause()
        try coordinator.masterAudioEngine.rawEngine.start()
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        for _ in 0..<4 {
            XCTAssertEqual(try coordinator.masterAudioEngine.rawEngine.renderOffline(1024, to: buffer), .success)
        }
        let renderedChannels = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<1024 {
                XCTAssertEqual(renderedChannels[channel][frame], 0, accuracy: 0.0001)
            }
        }
        // Manual offline rendering validates the graph lifecycle. AVAudioEngine does not
        // consistently dispatch mixer taps during offline rendering across supported hosts.
        _ = service.drainLatest(for: .master)
        XCTAssertNil(service.drainLatest(for: .cue))
        XCTAssertFalse(coordinator.cueAudioEngine.rawEngine.isRunning)

        service.stop()
        XCTAssertTrue(coordinator.masterAudioEngine.rawEngine.isRunning)
        XCTAssertFalse(coordinator.cueAudioEngine.rawEngine.isRunning)
        coordinator.masterAudioEngine.subMixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { _, _ in }
        coordinator.masterAudioEngine.subMixer.removeTap(onBus: 0)
        try service.start()
        service.stop()
        XCTAssertTrue(coordinator.masterAudioEngine.rawEngine.isRunning)
        coordinator.masterAudioEngine.subMixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { _, _ in }
        coordinator.masterAudioEngine.subMixer.removeTap(onBus: 0)
        coordinator.masterAudioEngine.rawEngine.stop()
    }
}
