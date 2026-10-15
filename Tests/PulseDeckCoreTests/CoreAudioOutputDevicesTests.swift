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
        let block: OutputPropertyListenerBlock
    }

    private let lock = NSLock()
    var devices: [DeviceRecord] = []
    var defaultOutputDeviceID: AudioDeviceID?
    var boundUnits: [AudioUnit: AudioDeviceID] = [:]
    var simulatedOSStatus: OSStatus?
    var failOnOperation: String?
    var defaultOutputError: CoreAudioError?
    var setOutputDeviceError: CoreAudioError?
    var sampleRateErrors: [AudioDeviceID: CoreAudioError] = [:]
    /// Throws on the next `getDeviceUID` for that device, then clears so a later read can succeed.
    var oneShotUIDErrors: [AudioDeviceID: CoreAudioError] = [:]
    /// Throws once when `getDeviceUID` for that device reaches this 1-based call count.
    var uidThrowOnCall: [AudioDeviceID: Int] = [:]
    /// Throws once when `getOutputChannelCount` for that device reaches this 1-based call count.
    var channelCountThrowOnCall: [AudioDeviceID: Int] = [:]
    private var uidReadCounts: [AudioDeviceID: Int] = [:]
    private var channelCountReads: [AudioDeviceID: Int] = [:]
    /// When set, the first N `getDeviceIDs` calls succeed and the next call throws.
    var remainingSuccessfulDeviceIDQueries: Int?
    private var setOutputDeviceAttempts: Int = 0

    var devicesListeners: [ListenerRecord] = []
    var defaultListeners: [ListenerRecord] = []

    func outputDeviceAttemptCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return setOutputDeviceAttempts
    }

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
            let box = SendableListenerBlock(listener.block)
            listener.queue.async {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDevices,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                withUnsafePointer(to: &address) { addrPtr in
                    box.block(1, addrPtr)
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
            let box = SendableListenerBlock(listener.block)
            listener.queue.async {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                withUnsafePointer(to: &address) { addrPtr in
                    box.block(1, addrPtr)
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
        if var remaining = remainingSuccessfulDeviceIDQueries {
            if remaining <= 0 {
                throw CoreAudioError.osStatus(-50, operation: "getDeviceIDs")
            }
            remaining -= 1
            remainingSuccessfulDeviceIDQueries = remaining
        }
        return devices.map { $0.id }
    }

    func getDefaultOutputDeviceID() throws -> AudioDeviceID? {
        lock.lock()
        defer { lock.unlock() }
        if let defaultOutputError {
            throw defaultOutputError
        }
        if let err = simulatedOSStatus {
            throw CoreAudioError.osStatus(err, operation: "getDefaultOutputDeviceID")
        }
        return defaultOutputDeviceID
    }

    func getDeviceUID(deviceID: AudioDeviceID) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let uidReads = (uidReadCounts[deviceID] ?? 0) + 1
        uidReadCounts[deviceID] = uidReads
        if let error = oneShotUIDErrors.removeValue(forKey: deviceID) {
            throw error
        }
        if uidThrowOnCall[deviceID] == uidReads {
            uidThrowOnCall[deviceID] = nil
            throw CoreAudioError.osStatus(-50, operation: "getDeviceUID")
        }
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
        let reads = (channelCountReads[deviceID] ?? 0) + 1
        channelCountReads[deviceID] = reads
        if channelCountThrowOnCall[deviceID] == reads {
            channelCountThrowOnCall[deviceID] = nil
            throw CoreAudioError.osStatus(-50, operation: "getOutputChannelCount")
        }
        guard let dev = devices.first(where: { $0.id == deviceID }) else {
            throw CoreAudioError.osStatus(-50, operation: "getOutputChannelCount")
        }
        return dev.outputChannels
    }

    func getNominalSampleRate(deviceID: AudioDeviceID) throws -> Double {
        lock.lock()
        defer { lock.unlock() }
        if let error = sampleRateErrors[deviceID] {
            throw error
        }
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
        setOutputDeviceAttempts += 1
        if let setOutputDeviceError {
            throw setOutputDeviceError
        }
        if let err = simulatedOSStatus {
            throw CoreAudioError.osStatus(err, operation: "setOutputDevice")
        }
        boundUnits[audioUnit] = deviceID
    }

    func addDevicesListener(on queue: DispatchQueue, block: @escaping OutputPropertyListenerBlock) throws {
        lock.lock()
        defer { lock.unlock() }
        if failOnOperation == "addDevicesListener" {
            throw CoreAudioError.listenerRegistrationFailed(-50, property: "kAudioHardwarePropertyDevices")
        }
        devicesListeners.append(ListenerRecord(queue: queue, block: block))
    }

    func removeDevicesListener(on queue: DispatchQueue, block: @escaping OutputPropertyListenerBlock) throws {
        lock.lock()
        defer { lock.unlock() }
        if failOnOperation == "removeDevicesListener" {
            throw CoreAudioError.listenerRemovalFailed(-50, property: "kAudioHardwarePropertyDevices")
        }
        guard let index = devicesListeners.firstIndex(where: {
            $0.queue === queue && listenerBlocksAreIdentical($0.block, block)
        }) else {
            throw CoreAudioError.listenerRemovalFailed(-50, property: "kAudioHardwarePropertyDevices")
        }
        devicesListeners.remove(at: index)
    }

    func addDefaultOutputDeviceListener(on queue: DispatchQueue, block: @escaping OutputPropertyListenerBlock) throws {
        lock.lock()
        defer { lock.unlock() }
        if failOnOperation == "addDefaultOutputDeviceListener" {
            throw CoreAudioError.listenerRegistrationFailed(-50, property: "kAudioHardwarePropertyDefaultOutputDevice")
        }
        defaultListeners.append(ListenerRecord(queue: queue, block: block))
    }

    func removeDefaultOutputDeviceListener(on queue: DispatchQueue, block: @escaping OutputPropertyListenerBlock) throws {
        lock.lock()
        defer { lock.unlock() }
        if failOnOperation == "removeDefaultOutputDeviceListener" {
            throw CoreAudioError.listenerRemovalFailed(-50, property: "kAudioHardwarePropertyDefaultOutputDevice")
        }
        guard let index = defaultListeners.firstIndex(where: {
            $0.queue === queue && listenerBlocksAreIdentical($0.block, block)
        }) else {
            throw CoreAudioError.listenerRemovalFailed(-50, property: "kAudioHardwarePropertyDefaultOutputDevice")
        }
        defaultListeners.remove(at: index)
    }
}

/// Holds one listener block so a queue hop does not capture a non-Sendable block value.
private final class SendableListenerBlock: @unchecked Sendable {
    let block: OutputPropertyListenerBlock
    init(_ block: @escaping OutputPropertyListenerBlock) {
        self.block = block
    }
}

/// `AudioObjectRemovePropertyListenerBlock` matches the Objective-C block object, not a Swift function value.
private func listenerBlocksAreIdentical(
    _ lhs: @escaping OutputPropertyListenerBlock,
    _ rhs: @escaping OutputPropertyListenerBlock
) -> Bool {
    unsafeBitCast(lhs, to: AnyObject.self) === unsafeBitCast(rhs, to: AnyObject.self)
}

/// Engine double whose running state and start failures are scripted. Production recovery must not call `stop()`.
private final class ScriptedAudioEngine: AVAudioEngine, @unchecked Sendable {
    private let stateLock = NSLock()
    private var scriptedRunning = false
    private var startFailure: Error?
    private var recordedStartCount = 0
    private var recordedPauseCount = 0
    private var recordedStopCount = 0

    override var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return scriptedRunning
    }

    var startCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recordedStartCount
    }

    var pauseCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recordedPauseCount
    }

    var stopCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recordedStopCount
    }

    func setRunning(_ value: Bool) {
        stateLock.lock()
        scriptedRunning = value
        stateLock.unlock()
    }

    func failNextStarts(with error: Error?) {
        stateLock.lock()
        startFailure = error
        stateLock.unlock()
    }

    override func start() throws {
        stateLock.lock()
        recordedStartCount += 1
        let failure = startFailure
        stateLock.unlock()
        if let failure {
            throw failure
        }
        stateLock.lock()
        scriptedRunning = true
        stateLock.unlock()
    }

    override func pause() {
        stateLock.lock()
        recordedPauseCount += 1
        scriptedRunning = false
        stateLock.unlock()
    }

    override func stop() {
        stateLock.lock()
        recordedStopCount += 1
        scriptedRunning = false
        stateLock.unlock()
    }
}

private struct SentinelStartError: Error, CustomStringConvertible {
    var description: String { "sentinel-start-failure" }
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

    func testPreferredUIDRebindsUnderNewDeviceIDOverDefault() throws {
        let mock = MockAudioHardware()
        mock.addDevice(id: 1001, uid: "pref_dac", name: "Preferred DAC", outputChannels: 2)
        mock.addDevice(id: 1002, uid: "default_speakers", name: "Default Speakers", outputChannels: 2)
        mock.setDefaultOutputID(1002)

        let engine = AVAudioEngine()
        try CoreAudioOutputDevices.bind(1001, to: engine, using: mock)

        let monitor = OutputDeviceMonitor(hal: mock, coalescingDelayMs: 0)
        try monitor.start()
        monitor.registerEngine(engine, role: .master, desiredDeviceUID: "pref_dac", boundDeviceID: 1001)

        // Device 1001 disconnects and reconnects under new numeric ID 1005
        mock.removeDevice(id: 1001)
        mock.addDevice(id: 1005, uid: "pref_dac", name: "Preferred DAC", outputChannels: 2)

        monitor.reconcileImmediately()

        let au = try XCTUnwrap(engine.outputNode.audioUnit)
        XCTAssertEqual(
            mock.boundUnits[au],
            1005,
            "Preferred UID must be chosen over default output when returning under a new numeric ID."
        )

        monitor.stop()
    }

    func testRecycledNumericIDDoesNotCountAsOriginalDevice() throws {
        let mock = MockAudioHardware()
        mock.addDevice(id: 2001, uid: "original_dac", name: "Original DAC", outputChannels: 2)
        mock.addDevice(id: 2002, uid: "default_speakers", name: "Default Speakers", outputChannels: 2)
        mock.setDefaultOutputID(2002)

        let engine = AVAudioEngine()
        try CoreAudioOutputDevices.bind(2001, to: engine, using: mock)

        let monitor = OutputDeviceMonitor(hal: mock, coalescingDelayMs: 0)
        try monitor.start()
        monitor.registerEngine(engine, role: .master, boundDeviceID: 2001)

        // Simulate disconnect of original_dac, then OS recycles numeric ID 2001 for a different device
        mock.removeDevice(id: 2001)
        mock.addDevice(id: 2001, uid: "recycled_headset", name: "Recycled Headset", outputChannels: 2)

        monitor.reconcileImmediately()

        let au = try XCTUnwrap(engine.outputNode.audioUnit)
        XCTAssertEqual(
            mock.boundUnits[au],
            2002,
            "Recycled numeric ID with different UID must not count as original device; must fallback to default."
        )

        monitor.stop()
    }

    func testFallbackToFirstEnumeratedOutputWhenDefaultIsNil() throws {
        let mock = MockAudioHardware()
        mock.addDevice(id: 3001, uid: "active_device", name: "Active Device", outputChannels: 2)
        mock.addDevice(id: 3002, uid: "other_device", name: "Other Device", outputChannels: 2)
        mock.setDefaultOutputID(nil) // Default is nil

        let engine = AVAudioEngine()
        try CoreAudioOutputDevices.bind(3001, to: engine, using: mock)

        let monitor = OutputDeviceMonitor(hal: mock, coalescingDelayMs: 0)
        try monitor.start()
        monitor.registerEngine(engine, role: .master, boundDeviceID: 3001)

        // Disconnect 3001
        mock.removeDevice(id: 3001)
        monitor.reconcileImmediately()

        let au = try XCTUnwrap(engine.outputNode.audioUnit)
        XCTAssertEqual(
            mock.boundUnits[au],
            3002,
            "When default output is nil, monitor must fallback to the first enumerated output with channels."
        )

        monitor.stop()
    }

    func testLiveSystemCoreAudioEnumeration() throws {
        // Hardware-free hosts have no default output. Skip instead of failing the suite.
        let defaultID: AudioDeviceID?
        do {
            defaultID = try CoreAudioOutputDevices.defaultOutputDeviceID()
        } catch {
            throw XCTSkip("Skipping live CoreAudio enumeration. Default output query failed: \(error.localizedDescription)")
        }
        guard defaultID != nil else {
            throw XCTSkip("Skipping live CoreAudio enumeration. Host has no default output device.")
        }

        let descriptors = try CoreAudioOutputDevices.enumerate()
        XCTAssertFalse(descriptors.isEmpty, "A host with a default output should enumerate at least one output device.")

        for desc in descriptors {
            XCTAssertFalse(desc.id.isEmpty, "Device UID must not be empty.")
            XCTAssertFalse(desc.name.isEmpty, "Device name must not be empty.")
            XCTAssertGreaterThan(desc.outputChannelCount, 0, "Output channels must be > 0.")
            XCTAssertTrue(desc.sampleRate.isFinite && desc.sampleRate > 0.0, "Sample rate must be finite and positive.")
        }
    }

    func testEnumerateThrowsWhenUIDReadFailsAndSkipsEmptyUID() throws {
        let mock = MockAudioHardware()
        mock.addDevice(id: 1, uid: "dac", name: "DAC", outputChannels: 2)
        mock.addDevice(id: 2, uid: "", name: "Blank", outputChannels: 2)
        mock.addDevice(id: 3, uid: "speakers", name: "Speakers", outputChannels: 2)
        let uidError = CoreAudioError.osStatus(-50, operation: "getDeviceUID")
        mock.oneShotUIDErrors[1] = uidError

        XCTAssertThrowsError(try CoreAudioOutputDevices.enumerate(using: mock)) { error in
            XCTAssertEqual(error as? CoreAudioError, uidError)
        }

        let descriptors = try CoreAudioOutputDevices.enumerate(using: mock)
        XCTAssertEqual(descriptors.map(\.id), ["dac", "speakers"])
    }

    func testEnumerateSkipsFailedOrNonFiniteSampleRate() throws {
        let mock = MockAudioHardware()
        mock.addDevice(id: 410, uid: "good_speakers", name: "Good Speakers", outputChannels: 2, sampleRate: 48000.0)
        mock.addDevice(id: 411, uid: "throws_rate", name: "Throws Rate", outputChannels: 2, sampleRate: 48000.0)
        mock.addDevice(id: 412, uid: "nan_rate", name: "NaN Rate", outputChannels: 2, sampleRate: .nan)
        mock.addDevice(id: 413, uid: "infinite_rate", name: "Infinite Rate", outputChannels: 2, sampleRate: .infinity)
        mock.sampleRateErrors[411] = CoreAudioError.invalidSampleRate(.signalingNaN)

        let descriptors = try CoreAudioOutputDevices.enumerate(using: mock)
        XCTAssertEqual(descriptors.map(\.id), ["good_speakers"])
        XCTAssertEqual(descriptors.first?.sampleRate, 48000.0)
        XCTAssertFalse(descriptors.contains(where: { $0.sampleRate == 44100.0 }))

        XCTAssertThrowsError(try CoreAudioOutputDevices.descriptor(for: 411, using: mock)) { error in
            guard case CoreAudioError.invalidSampleRate = error else {
                XCTFail("Expected invalidSampleRate, got \(error)")
                return
            }
        }

        XCTAssertThrowsError(try CoreAudioOutputDevices.descriptor(for: 412, using: mock)) { error in
            guard case CoreAudioError.invalidSampleRate(let rate) = error else {
                XCTFail("Expected invalidSampleRate, got \(error)")
                return
            }
            XCTAssertTrue(rate.isNaN)
        }
    }

    func testBoundUIDStaysSelectedUnderNewNumericIDWithoutDesiredUID() throws {
        let mock = MockAudioHardware()
        mock.addDevice(id: 11, uid: "dac", name: "DAC", outputChannels: 2)
        mock.addDevice(id: 22, uid: "speakers", name: "Speakers", outputChannels: 2)
        mock.setDefaultOutputID(22)

        let engine = AVAudioEngine()
        try CoreAudioOutputDevices.bind(11, to: engine, using: mock)

        let monitor = OutputDeviceMonitor(hal: mock, coalescingDelayMs: 0)
        try monitor.start()
        monitor.registerEngine(engine, role: .master, desiredDeviceUID: nil, boundDeviceID: 11)

        mock.removeDevice(id: 11)
        mock.addDevice(id: 12, uid: "dac", name: "DAC", outputChannels: 2)
        monitor.reconcileImmediately()

        let audioUnit = try XCTUnwrap(engine.outputNode.audioUnit)
        XCTAssertEqual(mock.boundUnits[audioUnit], 12, "Same bound UID under a new numeric ID stays selected when no preferred UID is set.")
        monitor.stop()
    }

    func testBoundDeviceUIDReadFailurePreservesBindingUntilReadSucceeds() throws {
        let mock = MockAudioHardware()
        mock.addDevice(id: 31, uid: "dac", name: "DAC", outputChannels: 2)
        mock.addDevice(id: 32, uid: "speakers", name: "Speakers", outputChannels: 2)
        mock.setDefaultOutputID(32)

        let engine = ScriptedAudioEngine()
        try CoreAudioOutputDevices.bind(31, to: engine, using: mock)
        engine.setRunning(true)

        let errors = TestBox<[CoreAudioError]>([])
        let changes = TestBox(0)
        let monitor = OutputDeviceMonitor(
            hal: mock,
            coalescingDelayMs: 0,
            onChange: { changes.value += 1 },
            onError: { error in
                var current = errors.value
                current.append(error)
                errors.value = current
            }
        )
        try monitor.start()
        monitor.registerEngine(engine, role: .master, boundDeviceID: 31)
        XCTAssertEqual(monitor.boundDeviceUIDForTesting(of: engine), "dac")

        let uidError = CoreAudioError.osStatus(-50, operation: "getDeviceUID")
        mock.oneShotUIDErrors[31] = uidError
        monitor.reconcileImmediately()

        let audioUnit = try XCTUnwrap(engine.outputNode.audioUnit)
        XCTAssertEqual(errors.value, [uidError])
        XCTAssertEqual(changes.value, 0, "A failed UID read must not report onChange.")
        XCTAssertEqual(monitor.boundDeviceUIDForTesting(of: engine), "dac")
        XCTAssertEqual(mock.boundUnits[audioUnit], 31)
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.pauseCount, 0)
        XCTAssertEqual(engine.stopCount, 0)

        monitor.reconcileImmediately()
        XCTAssertEqual(monitor.boundDeviceUIDForTesting(of: engine), "dac")
        XCTAssertEqual(mock.boundUnits[audioUnit], 31, "A later healthy read must stay on the bound device, not the default.")
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.pauseCount, 0)
        XCTAssertEqual(engine.stopCount, 0)
        monitor.stop()
    }

    func testDefaultChannelCountFailureDoesNotReplaceBoundDevice() throws {
        let mock = MockAudioHardware()
        mock.addDevice(id: 71, uid: "dac", name: "DAC", outputChannels: 2)
        mock.addDevice(id: 72, uid: "booth", name: "Booth", outputChannels: 2)
        mock.addDevice(id: 73, uid: "speakers", name: "Speakers", outputChannels: 2)
        mock.setDefaultOutputID(73)

        let engine = ScriptedAudioEngine()
        try CoreAudioOutputDevices.bind(71, to: engine, using: mock)
        engine.setRunning(true)

        let errors = TestBox<[CoreAudioError]>([])
        let changes = TestBox(0)
        let monitor = OutputDeviceMonitor(
            hal: mock,
            coalescingDelayMs: 0,
            onChange: { changes.value += 1 },
            onError: { error in
                var current = errors.value
                current.append(error)
                errors.value = current
            }
        )
        try monitor.start()
        monitor.registerEngine(engine, role: .master, boundDeviceID: 71)
        mock.removeDevice(id: 71)
        // enumerate reads the default's channel count once. The default-output query is the second read.
        mock.channelCountThrowOnCall[73] = 2

        let channelError = CoreAudioError.osStatus(-50, operation: "getOutputChannelCount")
        monitor.reconcileImmediately()

        let audioUnit = try XCTUnwrap(engine.outputNode.audioUnit)
        XCTAssertEqual(errors.value, [channelError])
        XCTAssertEqual(changes.value, 0)
        XCTAssertEqual(monitor.boundDeviceUIDForTesting(of: engine), "dac")
        XCTAssertEqual(mock.boundUnits[audioUnit], 71)
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.pauseCount, 0)

        monitor.reconcileImmediately()
        XCTAssertEqual(mock.boundUnits[audioUnit], 73, "The healthy pass must bind the default, not the output chosen while the read was failing.")
        XCTAssertEqual(monitor.boundDeviceUIDForTesting(of: engine), "speakers")
        XCTAssertTrue(engine.isRunning)
        monitor.stop()
    }

    func testRegisterEngineUIDFailureKeepsNumericBinding() throws {
        let mock = MockAudioHardware()
        mock.addDevice(id: 81, uid: "dac", name: "DAC", outputChannels: 2)
        mock.addDevice(id: 82, uid: "speakers", name: "Speakers", outputChannels: 2)
        mock.setDefaultOutputID(82)

        let engine = ScriptedAudioEngine()
        try CoreAudioOutputDevices.bind(81, to: engine, using: mock)
        engine.setRunning(true)

        let errors = TestBox<[CoreAudioError]>([])
        let changes = TestBox(0)
        let monitor = OutputDeviceMonitor(
            hal: mock,
            coalescingDelayMs: 0,
            onChange: { changes.value += 1 },
            onError: { error in
                var current = errors.value
                current.append(error)
                errors.value = current
            }
        )
        try monitor.start()
        // Call 1 is registration. Call 2 is enumerate. Call 3 is the unresolved-ID lookup.
        mock.uidThrowOnCall[81] = 1
        monitor.registerEngine(engine, role: .master, boundDeviceID: 81)
        XCTAssertNil(monitor.boundDeviceUIDForTesting(of: engine))
        let audioUnit = try XCTUnwrap(engine.outputNode.audioUnit)
        XCTAssertEqual(mock.boundUnits[audioUnit], 81)
        XCTAssertEqual(errors.value, [CoreAudioError.osStatus(-50, operation: "getDeviceUID")])

        mock.uidThrowOnCall[81] = 3
        changes.value = 0
        errors.value = []
        monitor.reconcileImmediately()
        XCTAssertEqual(errors.value, [CoreAudioError.osStatus(-50, operation: "getDeviceUID")])
        XCTAssertEqual(changes.value, 0)
        XCTAssertNil(monitor.boundDeviceUIDForTesting(of: engine))
        XCTAssertEqual(mock.boundUnits[audioUnit], 81)
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.pauseCount, 0)

        monitor.reconcileImmediately()
        XCTAssertEqual(monitor.boundDeviceUIDForTesting(of: engine), "dac")
        XCTAssertEqual(mock.boundUnits[audioUnit], 81, "The original device must remain the bound output.")
        XCTAssertNotEqual(mock.boundUnits[audioUnit], 82)
        XCTAssertTrue(engine.isRunning)
        monitor.stop()
    }

    func testTopologyQueryFailurePreservesRunningEngineAndBinding() throws {
        let mock = MockAudioHardware()
        mock.addDevice(id: 31, uid: "dac", name: "DAC", outputChannels: 2)
        mock.addDevice(id: 32, uid: "speakers", name: "Speakers", outputChannels: 2)
        mock.setDefaultOutputID(32)

        let engine = ScriptedAudioEngine()
        try CoreAudioOutputDevices.bind(31, to: engine, using: mock)
        engine.setRunning(true)

        let errors = TestBox<[CoreAudioError]>([])
        let changes = TestBox(0)
        let monitor = OutputDeviceMonitor(
            hal: mock,
            coalescingDelayMs: 0,
            onChange: { changes.value += 1 },
            onError: { error in
                var current = errors.value
                current.append(error)
                errors.value = current
            }
        )
        try monitor.start()
        monitor.registerEngine(engine, role: .master, boundDeviceID: 31)

        mock.simulatedOSStatus = 50
        monitor.reconcileImmediately()

        XCTAssertEqual(errors.value, [CoreAudioError.osStatus(50, operation: "getDeviceIDs")])
        XCTAssertEqual(changes.value, 0, "A failed topology pass must not report onChange.")
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.pauseCount, 0)
        XCTAssertEqual(engine.stopCount, 0)
        let audioUnit = try XCTUnwrap(engine.outputNode.audioUnit)
        XCTAssertEqual(mock.boundUnits[audioUnit], 31)

        mock.simulatedOSStatus = nil
        monitor.reconcileImmediately()
        XCTAssertEqual(mock.boundUnits[audioUnit], 31, "The preserved UID must still beat the default after the query succeeds.")
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.stopCount, 0)
        monitor.stop()
    }

    func testDefaultAndUIDLookupFailuresDoNotClearBinding() throws {
        let mock = MockAudioHardware()
        mock.addDevice(id: 41, uid: "dac", name: "DAC", outputChannels: 2)
        mock.addDevice(id: 42, uid: "speakers", name: "Speakers", outputChannels: 2)
        mock.setDefaultOutputID(42)

        let engine = ScriptedAudioEngine()
        try CoreAudioOutputDevices.bind(41, to: engine, using: mock)
        engine.setRunning(true)

        let errors = TestBox<[CoreAudioError]>([])
        let changes = TestBox(0)
        let monitor = OutputDeviceMonitor(
            hal: mock,
            coalescingDelayMs: 0,
            onChange: { changes.value += 1 },
            onError: { error in
                var current = errors.value
                current.append(error)
                errors.value = current
            }
        )
        try monitor.start()
        monitor.registerEngine(engine, role: .master, boundDeviceID: 41)
        let audioUnit = try XCTUnwrap(engine.outputNode.audioUnit)

        mock.defaultOutputError = CoreAudioError.osStatus(51, operation: "getDefaultOutputDeviceID")
        monitor.reconcileImmediately()
        XCTAssertEqual(errors.value, [CoreAudioError.osStatus(51, operation: "getDefaultOutputDeviceID")])
        XCTAssertEqual(changes.value, 0)
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.pauseCount, 0)
        XCTAssertEqual(mock.boundUnits[audioUnit], 41)

        mock.defaultOutputError = nil
        errors.value = []
        // enumerate consumes the one successful device-list read. The bound-UID lookup then throws.
        mock.remainingSuccessfulDeviceIDQueries = 1
        monitor.reconcileImmediately()
        XCTAssertEqual(errors.value, [CoreAudioError.osStatus(-50, operation: "getDeviceIDs")])
        XCTAssertEqual(changes.value, 0)
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.pauseCount, 0)
        XCTAssertEqual(mock.boundUnits[audioUnit], 41)

        mock.remainingSuccessfulDeviceIDQueries = nil
        monitor.reconcileImmediately()
        XCTAssertEqual(mock.boundUnits[audioUnit], 41)
        XCTAssertTrue(engine.isRunning)
        monitor.stop()
    }

    func testFalseIntentDisconnectStaysStoppedAndTrueIntentRecovers() throws {
        let mock = MockAudioHardware()
        mock.addDevice(id: 51, uid: "dac", name: "DAC", outputChannels: 2)
        mock.addDevice(id: 52, uid: "speakers", name: "Speakers", outputChannels: 2)
        mock.setDefaultOutputID(52)

        let engine = ScriptedAudioEngine()
        try CoreAudioOutputDevices.bind(51, to: engine, using: mock)
        engine.setRunning(true)

        let monitor = OutputDeviceMonitor(hal: mock, coalescingDelayMs: 0)
        try monitor.start()
        monitor.registerEngine(engine, role: .master, boundDeviceID: 51)
        monitor.setIntendedRunningState(for: engine, running: false)

        mock.removeDevice(id: 51)
        monitor.reconcileImmediately()

        let audioUnit = try XCTUnwrap(engine.outputNode.audioUnit)
        XCTAssertEqual(mock.boundUnits[audioUnit], 52)
        XCTAssertEqual(engine.pauseCount, 1)
        XCTAssertEqual(engine.stopCount, 0, "Rebind must pause. stop() drops the scheduled graph.")
        XCTAssertEqual(engine.startCount, 0)
        XCTAssertFalse(engine.isRunning)

        monitor.setIntendedRunningState(for: engine, running: true)
        monitor.reconcileImmediately()
        XCTAssertEqual(engine.startCount, 1)
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(mock.boundUnits[audioUnit], 52)
        XCTAssertEqual(engine.stopCount, 0)
        monitor.stop()
    }

    func testBindRetriesResetWhenCandidateSetChangesAndKeepTheRealError() throws {
        let mock = MockAudioHardware()
        mock.addDevice(id: 61, uid: "dac", name: "DAC", outputChannels: 2)
        mock.addDevice(id: 62, uid: "speakers", name: "Speakers", outputChannels: 2)
        mock.setDefaultOutputID(62)

        let engine = ScriptedAudioEngine()
        try CoreAudioOutputDevices.bind(61, to: engine, using: mock)
        let bindError = CoreAudioError.osStatus(99, operation: "AudioUnitSetProperty")
        mock.setOutputDeviceError = bindError

        let errors = TestBox<[CoreAudioError]>([])
        let monitor = OutputDeviceMonitor(
            hal: mock,
            coalescingDelayMs: 0,
            onError: { error in
                var current = errors.value
                current.append(error)
                errors.value = current
            }
        )
        try monitor.start()
        monitor.registerEngine(engine, role: .master, boundDeviceID: 61)
        mock.removeDevice(id: 61)
        let attemptsBeforeRecovery = mock.outputDeviceAttemptCount()

        monitor.reconcileImmediately()
        monitor.reconcileImmediately()
        monitor.reconcileImmediately()

        XCTAssertEqual(mock.outputDeviceAttemptCount(), attemptsBeforeRecovery + 3)
        XCTAssertEqual(
            errors.value.filter { $0 == bindError }.count,
            3,
            "Each failed bind must report the HAL error that was thrown."
        )
        XCTAssertEqual(errors.value.filter(isRetryLimit).count, 1)
        XCTAssertFalse(errors.value.contains(where: isSyntheticStatus))

        let attemptsAtCap = mock.outputDeviceAttemptCount()
        let errorsAtCap = errors.value.count
        monitor.reconcileImmediately()
        XCTAssertEqual(mock.outputDeviceAttemptCount(), attemptsAtCap, "The fourth pass must not bind again.")
        XCTAssertEqual(errors.value.count, errorsAtCap, "The retry-limit error is emitted once per exhausted epoch.")

        mock.addDevice(id: 63, uid: "headphones", name: "Headphones", outputChannels: 2)
        mock.setOutputDeviceError = nil
        monitor.reconcileImmediately()

        XCTAssertEqual(mock.outputDeviceAttemptCount(), attemptsAtCap + 1)
        let audioUnit = try XCTUnwrap(engine.outputNode.audioUnit)
        XCTAssertEqual(mock.boundUnits[audioUnit], 62, "A changed candidate set must allow recovery onto the default output.")
        XCTAssertEqual(engine.stopCount, 0)
        monitor.stop()
    }

    func testStartRetriesCapUntilTopologyChangesAndKeepTheThrownError() throws {
        let mock = MockAudioHardware()
        mock.addDevice(id: 71, uid: "dac", name: "DAC", outputChannels: 2)
        mock.setDefaultOutputID(71)

        let engine = ScriptedAudioEngine()
        try CoreAudioOutputDevices.bind(71, to: engine, using: mock)
        engine.failNextStarts(with: SentinelStartError())

        let errors = TestBox<[CoreAudioError]>([])
        let monitor = OutputDeviceMonitor(
            hal: mock,
            coalescingDelayMs: 0,
            onError: { error in
                var current = errors.value
                current.append(error)
                errors.value = current
            }
        )
        try monitor.start()
        monitor.registerEngine(engine, role: .master, boundDeviceID: 71)
        monitor.setIntendedRunningState(for: engine, running: true)

        monitor.reconcileImmediately()
        monitor.reconcileImmediately()
        monitor.reconcileImmediately()

        let expected = CoreAudioError.engineOperationFailed(
            operation: "AVAudioEngine.start",
            message: "sentinel-start-failure"
        )
        XCTAssertEqual(engine.startCount, 3)
        XCTAssertEqual(errors.value.filter { $0 == expected }.count, 3)
        XCTAssertEqual(errors.value.filter(isRetryLimit).count, 1)
        XCTAssertFalse(errors.value.contains(where: isSyntheticStatus))
        XCTAssertFalse(engine.isRunning)

        let errorsAtCap = errors.value.count
        monitor.reconcileImmediately()
        XCTAssertEqual(engine.startCount, 3)
        XCTAssertEqual(errors.value.count, errorsAtCap)

        mock.addDevice(id: 72, uid: "speakers", name: "Speakers", outputChannels: 2)
        engine.failNextStarts(with: nil)
        monitor.reconcileImmediately()
        XCTAssertEqual(engine.startCount, 4, "A topology change resets the start cap.")
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.stopCount, 0)
        monitor.stop()
    }

    func testCallbackReentryStopAndRegisterCompleteWithinTimeout() throws {
        let mock = MockAudioHardware()
        let finished = expectation(description: "callback reentry finished")
        let reentered = TestBox(false)
        let holder = TestBox<OutputDeviceMonitor?>(nil)

        holder.value = OutputDeviceMonitor(
            hal: mock,
            coalescingDelayMs: 0,
            onChange: {
                reentered.value = true
                let engine = AVAudioEngine()
                holder.value?.stop()
                holder.value?.registerEngine(engine, role: .cue)
                holder.value?.unregisterEngine(engine)
                finished.fulfill()
            }
        )
        try holder.value?.start()

        DispatchQueue.global(qos: .userInitiated).async {
            holder.value?.reconcileImmediately()
        }

        wait(for: [finished], timeout: 2.0)
        XCTAssertTrue(reentered.value)
        holder.value = nil
    }

    func testDeinitOnControlQueueCompletesWithinTimeout() throws {
        let mock = MockAudioHardware()
        let finished = expectation(description: "deinit on control queue finished")
        let holder = TestBox<OutputDeviceMonitor?>(nil)
        holder.value = OutputDeviceMonitor(hal: mock, coalescingDelayMs: 0)
        try holder.value?.start()

        holder.value?.scheduleOnControlQueueForTesting {
            holder.value = nil
            finished.fulfill()
        }

        wait(for: [finished], timeout: 2.0)
        XCTAssertNil(holder.value)
    }

    func testListenerRemovalUsesBlockIdentityAndKeepsBlockWhenRemovalFails() throws {
        let mock = MockAudioHardware()
        let errors = TestBox<[CoreAudioError]>([])
        let monitor = OutputDeviceMonitor(
            hal: mock,
            coalescingDelayMs: 0,
            onError: { error in
                var current = errors.value
                current.append(error)
                errors.value = current
            }
        )
        try monitor.start()
        XCTAssertEqual(mock.devicesListeners.count, 1)
        XCTAssertEqual(mock.defaultListeners.count, 1)

        let unrelated: OutputPropertyListenerBlock = { _, _ in }
        XCTAssertThrowsError(
            try mock.removeDevicesListener(on: mock.devicesListeners[0].queue, block: unrelated)
        )
        XCTAssertEqual(mock.devicesListeners.count, 1, "A different listener block must not remove the registered one.")

        mock.failOnOperation = "removeDevicesListener"
        monitor.stop()
        XCTAssertEqual(mock.devicesListeners.count, 1, "Failed removal must keep the installed devices listener.")
        XCTAssertEqual(mock.defaultListeners.count, 0)
        XCTAssertTrue(errors.value.contains { error in
            if case CoreAudioError.listenerRemovalFailed(_, let property) = error {
                return property == "kAudioHardwarePropertyDevices" || property == "removeDevicesListener"
            }
            return false
        })

        mock.failOnOperation = nil
        try monitor.start()
        XCTAssertEqual(mock.devicesListeners.count, 1, "start() must not install a second devices listener.")
        XCTAssertEqual(mock.defaultListeners.count, 1)

        monitor.stop()
        XCTAssertEqual(mock.devicesListeners.count, 0)
        XCTAssertEqual(mock.defaultListeners.count, 0)
    }

    func testConfigurationObserverDoesNotRetainEngine() throws {
        let mock = MockAudioHardware()
        let monitor = OutputDeviceMonitor(hal: mock, coalescingDelayMs: 0)
        try monitor.start()

        weak var weakEngine: AVAudioEngine?
        autoreleasepool {
            let engine = AVAudioEngine()
            weakEngine = engine
            monitor.registerEngine(engine, role: .master)
        }

        XCTAssertNil(weakEngine, "The configuration observer must not keep the engine alive.")
        monitor.stop()
    }

    func testPrunedRegistrationRemovesConfigurationObserver() throws {
        let mock = MockAudioHardware()
        let monitor = OutputDeviceMonitor(hal: mock, coalescingDelayMs: 0)
        try monitor.start()

        var engine: AVAudioEngine? = AVAudioEngine()
        monitor.registerEngine(engine!, role: .master)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        XCTAssertEqual(monitor.configurationObserverFireCountForTesting(), 1)

        engine = nil
        monitor.reconcileImmediately()
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: AVAudioEngine()
        )
        XCTAssertEqual(
            monitor.configurationObserverFireCountForTesting(),
            1,
            "Dropping a registration must remove its configuration observer."
        )
        monitor.stop()
    }
}

private func isRetryLimit(_ error: CoreAudioError) -> Bool {
    if case CoreAudioError.recoveryRetryLimitExceeded = error {
        return true
    }
    return false
}

private func isSyntheticStatus(_ error: CoreAudioError) -> Bool {
    if case CoreAudioError.osStatus(let status, _) = error {
        return status == OSStatus(-1)
    }
    return false
}
