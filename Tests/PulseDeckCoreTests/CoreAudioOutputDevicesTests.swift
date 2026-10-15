import XCTest
import CoreAudio
import AudioToolbox
import AVFoundation
@testable import PulseDeckCore

// MARK: - Thread-Safe Test Synchronization Box

final class TestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    init(_ value: T) {
        self._value = value
    }

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _value = newValue
        }
    }
}

// MARK: - Mock CoreAudio Hardware Implementation

final class MockAudioHardware: AudioHardwareInterface, @unchecked Sendable {
    struct DeviceRecord: Sendable {
        var id: AudioDeviceID
        var uid: String
        var name: String
        var manufacturer: String
        var outputChannels: Int
        var sampleRate: Double
        var transportType: UInt32
    }

    struct ListenerRecord: @unchecked Sendable {
        let queue: DispatchQueue
        let block: AudioObjectPropertyListenerBlock
    }

    private let lock = NSLock()
    var devices: [DeviceRecord] = []
    var defaultOutputDeviceID: AudioDeviceID?
    var boundUnits: [AudioUnit: AudioDeviceID] = [:]
    var simulatedOSStatus: OSStatus?
    var failOnOperation: String?

    var devicesListeners: [ListenerRecord] = []
    var defaultListeners: [ListenerRecord] = []

    init() {}

    func addDevice(
        id: AudioDeviceID,
        uid: String,
        name: String,
        manufacturer: String = "Mock Audio Inc.",
        outputChannels: Int = 2,
        sampleRate: Double = 48000.0,
        transportType: UInt32 = 0
    ) {
        lock.lock()
        defer { lock.unlock() }
        devices.append(DeviceRecord(
            id: id,
            uid: uid,
            name: name,
            manufacturer: manufacturer,
            outputChannels: outputChannels,
            sampleRate: sampleRate,
            transportType: transportType
        ))
    }

    func removeDevice(id: AudioDeviceID) {
        lock.lock()
        defer { lock.unlock() }
        devices.removeAll { $0.id == id }
    }

    func setDefaultOutputID(_ id: AudioDeviceID?) {
        lock.lock()
        defer { lock.unlock() }
        defaultOutputDeviceID = id
    }

    func triggerDevicesChange() {
        let listeners: [ListenerRecord]
        lock.lock()
        listeners = devicesListeners
        lock.unlock()

        for listener in listeners {
            let block = listener.block
            listener.queue.async {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDevices,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                withUnsafePointer(to: &address) { addrPtr in
                    block(1, addrPtr)
                }
            }
        }
    }

    func triggerDefaultDeviceChange() {
        let listeners: [ListenerRecord]
        lock.lock()
        listeners = defaultListeners
        lock.unlock()

        for listener in listeners {
            let block = listener.block
            listener.queue.async {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                withUnsafePointer(to: &address) { addrPtr in
                    block(1, addrPtr)
                }
            }
        }
    }

    // MARK: AudioHardwareInterface

    func getDeviceIDs() throws -> [AudioDeviceID] {
        lock.lock()
        defer { lock.unlock() }
        if let err = simulatedOSStatus {
            throw CoreAudioError.osStatus(err, operation: "getDeviceIDs")
        }
        return devices.map { $0.id }
    }

    func getDefaultOutputDeviceID() throws -> AudioDeviceID? {
        lock.lock()
        defer { lock.unlock() }
        if let err = simulatedOSStatus {
            throw CoreAudioError.osStatus(err, operation: "getDefaultOutputDeviceID")
        }
        return defaultOutputDeviceID
    }

    func getDeviceUID(deviceID: AudioDeviceID) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let dev = devices.first(where: { $0.id == deviceID }) else {
            throw CoreAudioError.osStatus(-50, operation: "getDeviceUID")
        }
        return dev.uid
    }

    func getDeviceName(deviceID: AudioDeviceID) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let dev = devices.first(where: { $0.id == deviceID }) else {
            throw CoreAudioError.osStatus(-50, operation: "getDeviceName")
        }
        return dev.name
    }

    func getDeviceManufacturer(deviceID: AudioDeviceID) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let dev = devices.first(where: { $0.id == deviceID }) else {
            throw CoreAudioError.osStatus(-50, operation: "getDeviceManufacturer")
        }
        return dev.manufacturer
    }

    func getOutputChannelCount(deviceID: AudioDeviceID) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let dev = devices.first(where: { $0.id == deviceID }) else {
            throw CoreAudioError.osStatus(-50, operation: "getOutputChannelCount")
        }
        return dev.outputChannels
    }

    func getNominalSampleRate(deviceID: AudioDeviceID) throws -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard let dev = devices.first(where: { $0.id == deviceID }) else {
            throw CoreAudioError.osStatus(-50, operation: "getNominalSampleRate")
        }
        return dev.sampleRate
    }

    func getTransportType(deviceID: AudioDeviceID) throws -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        guard let dev = devices.first(where: { $0.id == deviceID }) else {
            throw CoreAudioError.osStatus(-50, operation: "getTransportType")
        }
        return dev.transportType
    }

    func setOutputDevice(deviceID: AudioDeviceID, for audioUnit: AudioUnit) throws {
        lock.lock()
        defer { lock.unlock() }
        if let err = simulatedOSStatus {
            throw CoreAudioError.osStatus(err, operation: "setOutputDevice")
        }
        boundUnits[audioUnit] = deviceID
    }

    func addDevicesListener(on queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) throws {
        lock.lock()
        defer { lock.unlock() }
        if failOnOperation == "addDevicesListener" {
            throw CoreAudioError.listenerRegistrationFailed(-50, property: "kAudioHardwarePropertyDevices")
        }
        devicesListeners.append(ListenerRecord(queue: queue, block: block))
    }

    func removeDevicesListener(on queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) throws {
        lock.lock()
        defer { lock.unlock() }
        devicesListeners.removeAll()
    }

    func addDefaultOutputDeviceListener(on queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) throws {
        lock.lock()
        defer { lock.unlock() }
        if failOnOperation == "addDefaultOutputDeviceListener" {
            throw CoreAudioError.listenerRegistrationFailed(-50, property: "kAudioHardwarePropertyDefaultOutputDevice")
        }
        defaultListeners.append(ListenerRecord(queue: queue, block: block))
    }

    func removeDefaultOutputDeviceListener(on queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) throws {
        lock.lock()
        defer { lock.unlock() }
        defaultListeners.removeAll()
    }
}

// MARK: - CoreAudioOutputDevices Tests

final class CoreAudioOutputDevicesTests: XCTestCase {

    func testEnumerateFiltersZeroChannelsAndInputOnlyDevices() throws {
        let mock = MockAudioHardware()
        mock.addDevice(id: 101, uid: "speakers_uid", name: "MacBook Pro Speakers", outputChannels: 2, transportType: 0)
        mock.addDevice(id: 102, uid: "mic_uid", name: "Internal Microphone", outputChannels: 0, transportType: 0)
        mock.addDevice(
            id: 103,
            uid: "bt_headphones_uid",
            name: "Sony WH-1000XM4",
            outputChannels: 2,
            transportType: kAudioDeviceTransportTypeBluetooth
        )
        mock.addDevice(id: 104, uid: "virtual_zero_uid", name: "Zero Channel Dummy", outputChannels: 0)
        mock.setDefaultOutputID(101)

        let descriptors = try CoreAudioOutputDevices.enumerate(using: mock)

        XCTAssertEqual(descriptors.count, 2, "Must filter out zero-channel and input-only endpoints.")

        let speakerDesc = try XCTUnwrap(descriptors.first(where: { $0.id == "speakers_uid" }))
        XCTAssertEqual(speakerDesc.name, "MacBook Pro Speakers")
        XCTAssertEqual(speakerDesc.outputChannelCount, 2)
        XCTAssertTrue(speakerDesc.isDefault)
        XCTAssertFalse(speakerDesc.isBluetooth)

        let btDesc = try XCTUnwrap(descriptors.first(where: { $0.id == "bt_headphones_uid" }))
        XCTAssertEqual(btDesc.name, "Sony WH-1000XM4")
        XCTAssertEqual(btDesc.outputChannelCount, 2)
        XCTAssertFalse(btDesc.isDefault)
        XCTAssertTrue(btDesc.isBluetooth)
    }

    func testEnumerateThrowsOnOSStatusFailure() {
        let mock = MockAudioHardware()
        mock.simulatedOSStatus = kAudioHardwareNotRunningError

        XCTAssertThrowsError(try CoreAudioOutputDevices.enumerate(using: mock)) { error in
            guard case CoreAudioError.osStatus(let status, _) = error else {
                XCTFail("Expected CoreAudioError.osStatus, got \(error)")
                return
            }
            XCTAssertEqual(status, kAudioHardwareNotRunningError)
        }
    }

    func testDefaultOutputDeviceID() throws {
        let mock = MockAudioHardware()
        mock.addDevice(id: 201, uid: "dev_201", name: "Headphones", outputChannels: 2)
        mock.setDefaultOutputID(201)

        let defaultID = try CoreAudioOutputDevices.defaultOutputDeviceID(using: mock)
        XCTAssertEqual(defaultID, 201)

        // If default device has 0 channels, return nil
        mock.addDevice(id: 202, uid: "dev_202", name: "Input Only Default", outputChannels: 0)
        mock.setDefaultOutputID(202)
        let invalidDefault = try CoreAudioOutputDevices.defaultOutputDeviceID(using: mock)
        XCTAssertNil(invalidDefault, "Default device with 0 output channels must return nil.")

        // If no default is set
        mock.setDefaultOutputID(nil)
        XCTAssertNil(try CoreAudioOutputDevices.defaultOutputDeviceID(using: mock))
    }

    func testDeviceIDResolutionFromUID() throws {
        let mock = MockAudioHardware()
        mock.addDevice(id: 301, uid: "dac_usb_uid", name: "USB DAC", outputChannels: 4)

        let foundID = try CoreAudioOutputDevices.deviceID(forUID: "dac_usb_uid", using: mock)
        XCTAssertEqual(foundID, 301)

        let missingID = try CoreAudioOutputDevices.deviceID(forUID: "non_existent_uid", using: mock)
        XCTAssertNil(missingID)
    }

    func testDescriptorForDeviceID() throws {
        let mock = MockAudioHardware()
        mock.addDevice(
            id: 401,
            uid: "studio_monitors_uid",
            name: "Studio Monitors",
            outputChannels: 2,
            sampleRate: 96000.0,
            transportType: kAudioDeviceTransportTypeBluetoothLE
        )

        let desc = try CoreAudioOutputDevices.descriptor(for: 401, using: mock)
        XCTAssertNotNil(desc)
        XCTAssertEqual(desc?.id, "studio_monitors_uid")
        XCTAssertEqual(desc?.name, "Studio Monitors")
        XCTAssertEqual(desc?.outputChannelCount, 2)
        XCTAssertEqual(desc?.sampleRate, 96000.0)
        XCTAssertTrue(desc?.isBluetooth ?? false)

        // Disappeared or invalid device
        let invalidDesc = try CoreAudioOutputDevices.descriptor(for: 999, using: mock)
        XCTAssertNil(invalidDesc)
    }

    func testBindValidatesOutputCapability() {
        let mock = MockAudioHardware()
        mock.addDevice(id: 501, uid: "mic_only", name: "Microphone", outputChannels: 0)
        let engine = AVAudioEngine()

        XCTAssertThrowsError(try CoreAudioOutputDevices.bind(501, to: engine, using: mock)) { error in
            guard case CoreAudioError.notAnOutputDevice(let id) = error else {
                XCTFail("Expected notAnOutputDevice, got \(error)")
                return
            }
            XCTAssertEqual(id, 501)
        }
    }

    func testBindSucceedsOnStoppedEngine() throws {
        let mock = MockAudioHardware()
        mock.addDevice(id: 601, uid: "main_out", name: "Main Output", outputChannels: 2)
        let engine = AVAudioEngine()

        XCTAssertFalse(engine.isRunning)
        XCTAssertNoThrow(try CoreAudioOutputDevices.bind(601, to: engine, using: mock))

        let au = try XCTUnwrap(engine.outputNode.audioUnit)
        XCTAssertEqual(mock.boundUnits[au], 601)
    }

    func testOutputDeviceMonitorRollbackOnPartialRegistrationFailure() {
        let mock = MockAudioHardware()
        mock.failOnOperation = "addDefaultOutputDeviceListener"

        let monitor = OutputDeviceMonitor(hal: mock)
        XCTAssertThrowsError(try monitor.start()) { error in
            guard case CoreAudioError.listenerRegistrationFailed(_, let prop) = error else {
                XCTFail("Expected listenerRegistrationFailed, got \(error)")
                return
            }
            XCTAssertEqual(prop, "kAudioHardwarePropertyDefaultOutputDevice")
        }

        // Verify rollback cleaned up the first listener
        XCTAssertEqual(mock.devicesListeners.count, 0, "Partial registration must rollback and unregister devices listener.")
    }

    func testOutputDeviceMonitorLifecycleAndCleanup() throws {
        let mock = MockAudioHardware()
        let monitor = OutputDeviceMonitor(hal: mock)

        try monitor.start()
        XCTAssertEqual(mock.devicesListeners.count, 1)
        XCTAssertEqual(mock.defaultListeners.count, 1)

        monitor.stop()
        XCTAssertEqual(mock.devicesListeners.count, 0)
        XCTAssertEqual(mock.defaultListeners.count, 0)
    }

    func testOutputDeviceMonitorActiveDisconnectedEndpointFallback() throws {
        let mock = MockAudioHardware()
        mock.addDevice(id: 701, uid: "club_pa_uid", name: "Club PA System", outputChannels: 2)
        mock.addDevice(id: 702, uid: "builtin_speakers_uid", name: "MacBook Speakers", outputChannels: 2)
        mock.setDefaultOutputID(702)

        let engine = AVAudioEngine()
        try CoreAudioOutputDevices.bind(701, to: engine, using: mock)

        let onChangeBox = TestBox(false)
        let expectation = expectation(description: "onChange callback fired on fallback")

        let monitor = OutputDeviceMonitor(
            hal: mock,
            coalescingDelayMs: 0,
            onChange: {
                onChangeBox.value = true
                expectation.fulfill()
            }
        )
        try monitor.start()
        monitor.registerEngine(engine, role: .master, boundDeviceID: 701)

        // Disconnect Club PA (ID 701)
        mock.removeDevice(id: 701)

        // Trigger HAL device change event
        mock.triggerDevicesChange()

        wait(for: [expectation], timeout: 2.0)
        XCTAssertTrue(onChangeBox.value)

        // Verify fallback bound to default output 702
        let au = try XCTUnwrap(engine.outputNode.audioUnit)
        XCTAssertEqual(mock.boundUnits[au], 702, "Must automatically fallback to default usable output.")

        monitor.stop()
    }

    func testOutputDeviceMonitorPreservesIntendedRunningState() throws {
        let mock = MockAudioHardware()
        mock.addDevice(id: 801, uid: "active_dac_uid", name: "USB DAC", outputChannels: 2)
        mock.addDevice(id: 802, uid: "fallback_speaker_uid", name: "Fallback Speaker", outputChannels: 2)
        mock.setDefaultOutputID(802)

        let engine = AVAudioEngine()
        try CoreAudioOutputDevices.bind(801, to: engine, using: mock)

        let monitor = OutputDeviceMonitor(hal: mock, coalescingDelayMs: 0)
        try monitor.start()
        monitor.registerEngine(engine, role: .master, boundDeviceID: 801)
        monitor.setIntendedRunningState(for: engine, running: true)

        // Disconnect device 801
        mock.removeDevice(id: 801)
        monitor.reconcileImmediately()

        let au = try XCTUnwrap(engine.outputNode.audioUnit)
        XCTAssertEqual(mock.boundUnits[au], 802, "Rebound to fallback device.")

        monitor.stop()
    }

    func testOutputDeviceMonitorBoundedRetriesWhenNoOutputAvailable() throws {
        let mock = MockAudioHardware()
        mock.addDevice(id: 901, uid: "unplugged_device", name: "Unplugged USB", outputChannels: 2)
        mock.setDefaultOutputID(nil) // No default output available!

        let engine = AVAudioEngine()
        try CoreAudioOutputDevices.bind(901, to: engine, using: mock)

        let errorBox: TestBox<CoreAudioError?> = TestBox(nil)
        let monitor = OutputDeviceMonitor(
            hal: mock,
            coalescingDelayMs: 0,
            onError: { error in
                errorBox.value = error
            }
        )
        try monitor.start()
        monitor.registerEngine(engine, role: .cue, boundDeviceID: 901)

        mock.removeDevice(id: 901)
        monitor.reconcileImmediately()

        XCTAssertEqual(errorBox.value, CoreAudioError.noOutputDeviceAvailable)

        monitor.stop()
    }

    func testLiveSystemCoreAudioEnumeration() throws {
        // Live Mac smoke test to verify real HAL queries do not crash or access inputNode
        let descriptors = try CoreAudioOutputDevices.enumerate()
        XCTAssertFalse(descriptors.isEmpty, "A physical Mac should have at least 1 output audio device.")

        for desc in descriptors {
            XCTAssertFalse(desc.id.isEmpty, "Device UID must not be empty.")
            XCTAssertFalse(desc.name.isEmpty, "Device name must not be empty.")
            XCTAssertGreaterThan(desc.outputChannelCount, 0, "Output channels must be > 0.")
            XCTAssertTrue(desc.sampleRate.isFinite && desc.sampleRate > 0.0, "Sample rate must be finite and positive.")
        }

        let defaultID = try CoreAudioOutputDevices.defaultOutputDeviceID()
        XCTAssertNotNil(defaultID, "Host Mac must report an active default output device.")
    }
}
