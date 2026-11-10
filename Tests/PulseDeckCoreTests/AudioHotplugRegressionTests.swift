import XCTest
import CoreAudio
import AVFoundation
@testable import PulseDeckCore

final class AudioHotplugRegressionTests: XCTestCase {

    private func createTestWavFile(durationSeconds: Double = 1.0) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("test_track_\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 2)!
        let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        let frameCount = AVAudioFrameCount(44100.0 * durationSeconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        try file.write(from: buffer)
        return fileURL
    }

    // MARK: - Regression Tests

    func testMasterReturnsToChosenDeviceWhenItReappears() throws {
        let mock = MockAudioHardware()
        let deviceX_ID: AudioDeviceID = 101
        let deviceX_UID = "device_x_uid"
        let deviceY_ID: AudioDeviceID = 102
        let deviceY_UID = "device_y_uid"

        mock.addDevice(id: deviceX_ID, uid: deviceX_UID, name: "Device X", outputChannels: 2)
        mock.addDevice(id: deviceY_ID, uid: deviceY_UID, name: "Device Y", outputChannels: 2)
        mock.setDefaultOutputID(deviceY_ID)

        let engine = AVAudioEngine()
        try CoreAudioOutputDevices.bind(deviceX_ID, to: engine, using: mock)

        let monitor = OutputDeviceMonitor(hal: mock, coalescingDelayMs: 0)
        try monitor.start()
        defer { monitor.stop() }

        monitor.registerEngine(
            engine,
            role: .master,
            desiredDeviceUID: deviceX_UID,
            boundDeviceID: deviceX_ID
        )

        XCTAssertEqual(monitor.boundDeviceUID(for: .master), deviceX_UID)

        // X disappears -> master falls back to Y (assert bound Y)
        mock.removeDevice(id: deviceX_ID)
        monitor.reconcileImmediately()

        XCTAssertEqual(monitor.boundDeviceUID(for: .master), deviceY_UID)
        let au = try XCTUnwrap(engine.outputNode.audioUnit)
        XCTAssertEqual(mock.boundUnits[au], deviceY_ID)

        // X reappears -> after the monitor processes the device-list change, master bound UID == X
        mock.addDevice(id: deviceX_ID, uid: deviceX_UID, name: "Device X", outputChannels: 2)
        monitor.reconcileImmediately()

        XCTAssertEqual(monitor.boundDeviceUID(for: .master), deviceX_UID)
        XCTAssertEqual(mock.boundUnits[au], deviceX_ID)
    }

    func testCueDoesNotFallBackOntoMasterDevice() throws {
        let mock = MockAudioHardware()
        let masterID: AudioDeviceID = 201
        let masterUID = "master_m_uid"
        let cueID: AudioDeviceID = 202
        let cueUID = "cue_c_uid"

        mock.addDevice(id: masterID, uid: masterUID, name: "Master M", outputChannels: 2)
        mock.addDevice(id: cueID, uid: cueUID, name: "Cue C", outputChannels: 2)
        mock.setDefaultOutputID(masterID)

        let masterEngine = AVAudioEngine()
        let cueEngine = AVAudioEngine()

        try CoreAudioOutputDevices.bind(masterID, to: masterEngine, using: mock)
        try CoreAudioOutputDevices.bind(cueID, to: cueEngine, using: mock)

        let monitor = OutputDeviceMonitor(hal: mock, coalescingDelayMs: 0)
        try monitor.start()
        defer { monitor.stop() }

        monitor.registerEngine(masterEngine, role: .master, boundDeviceID: masterID)
        monitor.registerEngine(cueEngine, role: .cue, boundDeviceID: cueID)

        XCTAssertEqual(monitor.boundDeviceUID(for: .master), masterUID)
        XCTAssertEqual(monitor.boundDeviceUID(for: .cue), cueUID)

        // C disappears
        mock.removeDevice(id: cueID)
        monitor.reconcileImmediately()

        // Cue bound UID must NOT be M (expect nil / cleared), master still M
        XCTAssertNil(monitor.boundDeviceUID(for: .cue), "Cue must not fall back to master device; should be cleared to nil")
        XCTAssertNotEqual(monitor.boundDeviceUID(for: .cue), masterUID)
        XCTAssertEqual(monitor.boundDeviceUID(for: .master), masterUID, "Master must remain bound to M")
    }

    func testUnboundCueAtLaunchStillUsesDefault() throws {
        let mock = MockAudioHardware()
        let masterID: AudioDeviceID = 301
        let masterUID = "master_default_m"

        mock.addDevice(id: masterID, uid: masterUID, name: "Master M", outputChannels: 2)
        mock.setDefaultOutputID(masterID)

        let masterEngine = AVAudioEngine()
        let cueEngine = AVAudioEngine()

        let monitor = OutputDeviceMonitor(hal: mock, coalescingDelayMs: 0)
        try monitor.start()
        defer { monitor.stop() }

        try CoreAudioOutputDevices.bind(masterID, to: masterEngine, using: mock)
        monitor.registerEngine(masterEngine, role: .master, boundDeviceID: masterID)

        // Cue registered with no desired device and unbound at launch
        monitor.registerEngine(cueEngine, role: .cue)

        XCTAssertNil(monitor.boundDeviceUID(for: .cue))

        monitor.reconcileImmediately()

        // Unbound cue at launch binds to default device M
        XCTAssertEqual(monitor.boundDeviceUID(for: .cue), masterUID)
        XCTAssertEqual(monitor.boundDeviceUID(for: .master), masterUID)
        let au = try XCTUnwrap(cueEngine.outputNode.audioUnit)
        XCTAssertEqual(mock.boundUnits[au], masterID)
    }
}
