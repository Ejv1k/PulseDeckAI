import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

/// Strongly typed errors encountered during CoreAudio HAL operations, device binding, and monitoring.
public enum CoreAudioError: LocalizedError, Sendable, Equatable {
    case osStatus(OSStatus, operation: String)
    case missingAudioUnit
    case engineRunning
    case notAnOutputDevice(AudioDeviceID)
    case deviceNotFound(String)
    case noOutputDeviceAvailable
    case listenerRegistrationFailed(OSStatus, property: String)
    case listenerRemovalFailed(OSStatus, property: String)
    case invalidSampleRate(Double)
    case recoveryRetryLimitExceeded(AudioEngineRole)

    public var errorDescription: String? {
        switch self {
        case .osStatus(let status, let operation):
            return "CoreAudio HAL OSStatus error \(status) during operation '\(operation)'."
        case .missingAudioUnit:
            return "AVAudioEngine outputNode audioUnit is nil; output device cannot be bound."
        case .engineRunning:
            return "Cannot bind output device while AVAudioEngine is running. Stop the engine first."
        case .notAnOutputDevice(let id):
            return "Device ID \(id) has 0 output channels and cannot be used as an output device."
        case .deviceNotFound(let uid):
            return "CoreAudio output device with UID '\(uid)' was not found."
        case .noOutputDeviceAvailable:
            return "No usable physical CoreAudio output device is available on the system."
        case .listenerRegistrationFailed(let status, let property):
            return "Failed to register HAL property listener for '\(property)' (OSStatus: \(status))."
        case .listenerRemovalFailed(let status, let property):
            return "Failed to remove HAL property listener for '\(property)' (OSStatus: \(status))."
        case .invalidSampleRate(let rate):
            return "CoreAudio device reported an invalid or non-finite sample rate: \(rate)."
        case .recoveryRetryLimitExceeded(let role):
            return "Exceeded maximum retry limit attempting to recover output engine for role '\(role.rawValue)'."
        }
    }
}

/// Abstraction layer for CoreAudio HAL queries, listener registration, and device property modification.
///
/// Enables dependency injection and comprehensive unit testing without requiring physical hardware mutability.
public protocol AudioHardwareInterface: Sendable {
    /// Returns all active CoreAudio device IDs present on the system.
    func getDeviceIDs() throws -> [AudioDeviceID]

    /// Returns the system default output device ID, or nil if none is configured.
    func getDefaultOutputDeviceID() throws -> AudioDeviceID?

    /// Queries the stable UID string for a given device ID (`kAudioDevicePropertyDeviceUID`).
    func getDeviceUID(deviceID: AudioDeviceID) throws -> String

    /// Queries the localized human-readable name for a given device ID (`kAudioDevicePropertyDeviceNameCFString`).
    func getDeviceName(deviceID: AudioDeviceID) throws -> String

    /// Queries the manufacturer string for a given device ID (`kAudioDevicePropertyDeviceManufacturerCFString`).
    func getDeviceManufacturer(deviceID: AudioDeviceID) throws -> String

    /// Queries the total output channel count for a given device ID strictly in `kAudioDevicePropertyScopeOutput`.
    func getOutputChannelCount(deviceID: AudioDeviceID) throws -> Int

    /// Queries the nominal sample rate in Hz for a given device ID.
    func getNominalSampleRate(deviceID: AudioDeviceID) throws -> Double

    /// Queries the transport type for a given device ID (`kAudioDevicePropertyTransportType`).
    func getTransportType(deviceID: AudioDeviceID) throws -> UInt32

    /// Assigns the given CoreAudio device ID to an `AudioUnit` output node via `kAudioOutputUnitProperty_CurrentDevice`.
    func setOutputDevice(deviceID: AudioDeviceID, for audioUnit: AudioUnit) throws

    /// Registers a listener block on the specified queue for system device list changes (`kAudioHardwarePropertyDevices`).
    func addDevicesListener(on queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) throws

    /// Removes a previously registered device list listener block.
    func removeDevicesListener(on queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) throws

    /// Registers a listener block on the specified queue for default output device changes (`kAudioHardwarePropertyDefaultOutputDevice`).
    func addDefaultOutputDeviceListener(on queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) throws

    /// Removes a previously registered default output device listener block.
    func removeDefaultOutputDeviceListener(on queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) throws
}

/// Production implementation of `AudioHardwareInterface` interfacing directly with the macOS CoreAudio HAL C API.
public final class SystemAudioHardware: AudioHardwareInterface, @unchecked Sendable {
    public static let shared = SystemAudioHardware()

    public init() {}

    public func getDeviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        )
        guard sizeStatus == noErr else {
            throw CoreAudioError.osStatus(sizeStatus, operation: "kAudioHardwarePropertyDevices.size")
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceIDs
        )
        guard status == noErr else {
            throw CoreAudioError.osStatus(status, operation: "kAudioHardwarePropertyDevices.data")
        }
        let actualCount = Int(size) / MemoryLayout<AudioDeviceID>.size
        return Array(deviceIDs.prefix(actualCount))
    }

    public func getDefaultOutputDeviceID() throws -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr else {
            throw CoreAudioError.osStatus(status, operation: "kAudioHardwarePropertyDefaultOutputDevice")
        }
        guard deviceID != 0 && deviceID != kAudioDeviceUnknown else {
            return nil
        }
        return deviceID
    }

    public func getDeviceUID(deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedString: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &unmanagedString
        )
        guard status == noErr, let unmanaged = unmanagedString else {
            throw CoreAudioError.osStatus(status, operation: "kAudioDevicePropertyDeviceUID(\(deviceID))")
        }
        return unmanaged.takeRetainedValue() as String
    }

    public func getDeviceName(deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedString: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &unmanagedString
        )
        guard status == noErr, let unmanaged = unmanagedString else {
            throw CoreAudioError.osStatus(status, operation: "kAudioDevicePropertyDeviceNameCFString(\(deviceID))")
        }
        return unmanaged.takeRetainedValue() as String
    }

    public func getDeviceManufacturer(deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceManufacturerCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedString: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &unmanagedString
        )
        guard status == noErr, let unmanaged = unmanagedString else {
            throw CoreAudioError.osStatus(status, operation: "kAudioDevicePropertyDeviceManufacturerCFString(\(deviceID))")
        }
        return unmanaged.takeRetainedValue() as String
    }

    public func getOutputChannelCount(deviceID: AudioDeviceID) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &size
        )
        guard sizeStatus == noErr else {
            throw CoreAudioError.osStatus(sizeStatus, operation: "kAudioDevicePropertyStreamConfiguration.size(\(deviceID))")
        }
        guard size > 0 else { return 0 }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBuffer.deallocate() }

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            rawBuffer
        )
        guard status == noErr else {
            throw CoreAudioError.osStatus(status, operation: "kAudioDevicePropertyStreamConfiguration.data(\(deviceID))")
        }

        let bufferListPtr = rawBuffer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferListPtr)
        var totalChannels = 0
        for buf in buffers {
            totalChannels += Int(buf.mNumberChannels)
        }
        return totalChannels
    }

    public func getNominalSampleRate(deviceID: AudioDeviceID) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &sampleRate
        )
        guard status == noErr else {
            throw CoreAudioError.osStatus(status, operation: "kAudioDevicePropertyNominalSampleRate(\(deviceID))")
        }
        let rate = Double(sampleRate)
        guard rate.isFinite && rate > 0.0 else {
            throw CoreAudioError.invalidSampleRate(rate)
        }
        return rate
    }

    public func getTransportType(deviceID: AudioDeviceID) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &transport
        )
        guard status == noErr else {
            throw CoreAudioError.osStatus(status, operation: "kAudioDevicePropertyTransportType(\(deviceID))")
        }
        return transport
    }

    public func setOutputDevice(deviceID: AudioDeviceID, for audioUnit: AudioUnit) throws {
        var devID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw CoreAudioError.osStatus(status, operation: "kAudioOutputUnitProperty_CurrentDevice(\(deviceID))")
        }
    }

    public func addDevicesListener(on queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )
        guard status == noErr else {
            throw CoreAudioError.listenerRegistrationFailed(status, property: "kAudioHardwarePropertyDevices")
        }
    }

    public func removeDevicesListener(on queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )
        guard status == noErr else {
            throw CoreAudioError.listenerRemovalFailed(status, property: "kAudioHardwarePropertyDevices")
        }
    }

    public func addDefaultOutputDeviceListener(on queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )
        guard status == noErr else {
            throw CoreAudioError.listenerRegistrationFailed(status, property: "kAudioHardwarePropertyDefaultOutputDevice")
        }
    }

    public func removeDefaultOutputDeviceListener(on queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            block
        )
        guard status == noErr else {
            throw CoreAudioError.listenerRemovalFailed(status, property: "kAudioHardwarePropertyDefaultOutputDevice")
        }
    }
}
