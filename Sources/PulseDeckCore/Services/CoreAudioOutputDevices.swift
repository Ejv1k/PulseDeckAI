import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

/// Stateless utility functions for CoreAudio output device enumeration, identification, and output node binding.
///
/// ## Architectural Constraints:
/// - Strictly output-only: queries only `kAudioDevicePropertyScopeOutput` for direction-sensitive properties.
/// - Never accesses `AVAudioEngine.inputNode` to prevent microphone TCC prompts and Bluetooth A2DP codec downgrades.
/// - Resolves stable UID strings to ephemeral numeric `AudioDeviceID` handles at bind time.
/// - Filters out zero-channel and input-only endpoints.
public enum CoreAudioOutputDevices {

    /// Enumerates all currently available physical output devices on the host system.
    ///
    /// - Parameter hal: The underlying HAL abstraction interface (defaults to `SystemAudioHardware.shared`).
    /// - Returns: An array of `AudioDeviceDescriptor` representing output-capable hardware endpoints.
    /// - Throws: `CoreAudioError` if the device-list query fails.
    ///   A device whose nominal sample rate query fails, or whose rate is non-finite or not positive, is omitted.
    ///   This method never substitutes a fabricated sample rate.
    public static func enumerate(using hal: AudioHardwareInterface = SystemAudioHardware.shared) throws -> [AudioDeviceDescriptor] {
        let deviceIDs = try hal.getDeviceIDs()
        var descriptors: [AudioDeviceDescriptor] = []
        let defaultOutputID = try? hal.getDefaultOutputDeviceID()

        for deviceID in deviceIDs {
            // Strictly query output channels in output scope; filter out input-only or zero-channel endpoints
            let channelCount: Int
            do {
                channelCount = try hal.getOutputChannelCount(deviceID: deviceID)
            } catch {
                // If a device fails channel count query (e.g. unplugged during iteration), skip safely
                continue
            }

            guard channelCount > 0 else {
                continue
            }

            // Stable UID query (required for persistent identity)
            guard let uid = try? hal.getDeviceUID(deviceID: deviceID), !uid.isEmpty else {
                continue
            }

            // Human-readable name with safe fallback
            let name = (try? hal.getDeviceName(deviceID: deviceID)) ?? "Audio Device (\(deviceID))"

            // Manufacturer with safe fallback
            let manufacturer = (try? hal.getDeviceManufacturer(deviceID: deviceID)) ?? "Generic"

            // Skip the endpoint when the device does not report a usable rate.
            // Never publish a stand-in such as 44.1 kHz.
            let sampleRate: Double
            do {
                sampleRate = try hal.getNominalSampleRate(deviceID: deviceID)
            } catch {
                continue
            }
            guard sampleRate.isFinite && sampleRate > 0.0 else {
                continue
            }

            // Transport type recognition (Bluetooth Classic A2DP or Bluetooth Low Energy)
            var isBluetooth = false
            if let transport = try? hal.getTransportType(deviceID: deviceID) {
                isBluetooth = (transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE)
            }

            let isDefault = (defaultOutputID != nil && defaultOutputID == deviceID)

            let descriptor = AudioDeviceDescriptor(
                id: uid,
                name: name,
                manufacturer: manufacturer,
                outputChannelCount: channelCount,
                sampleRate: sampleRate,
                isDefault: isDefault,
                isBluetooth: isBluetooth
            )
            descriptors.append(descriptor)
        }

        return descriptors
    }

    /// Queries the current system default output device ID.
    ///
    /// - Parameter hal: The underlying HAL abstraction interface (defaults to `SystemAudioHardware.shared`).
    /// - Returns: The active default `AudioDeviceID`, or `nil` if no usable default output is available.
    /// - Throws: `CoreAudioError` if HAL query fails.
    public static func defaultOutputDeviceID(using hal: AudioHardwareInterface = SystemAudioHardware.shared) throws -> AudioDeviceID? {
        guard let deviceID = try hal.getDefaultOutputDeviceID(), deviceID != 0 else {
            return nil
        }
        let channels = (try? hal.getOutputChannelCount(deviceID: deviceID)) ?? 0
        guard channels > 0 else {
            return nil
        }
        return deviceID
    }

    /// Binds an `AudioDeviceID` to the output node of an `AVAudioEngine` instance.
    ///
    /// - Parameters:
    ///   - deviceID: The numeric CoreAudio device identifier to bind.
    ///   - engine: The target `AVAudioEngine` instance.
    ///   - hal: The underlying HAL abstraction interface (defaults to `SystemAudioHardware.shared`).
    /// - Throws:
    ///   - `CoreAudioError.notAnOutputDevice` if the device has 0 output channels.
    ///   - `CoreAudioError.engineRunning` if the target engine is currently running.
    ///   - `CoreAudioError.missingAudioUnit` if the engine's outputNode does not expose an AudioUnit.
    ///   - `CoreAudioError.osStatus` if the underlying `AudioUnitSetProperty` call fails.
    public static func bind(
        _ deviceID: AudioDeviceID,
        to engine: AVAudioEngine,
        using hal: AudioHardwareInterface = SystemAudioHardware.shared
    ) throws {
        // Validate output channel capability
        let channels = try hal.getOutputChannelCount(deviceID: deviceID)
        guard channels > 0 else {
            throw CoreAudioError.notAnOutputDevice(deviceID)
        }

        // Validate stopped engine state
        guard !engine.isRunning else {
            throw CoreAudioError.engineRunning
        }

        // Validate AudioUnit availability on output node
        guard let audioUnit = engine.outputNode.audioUnit else {
            throw CoreAudioError.missingAudioUnit
        }

        // Apply device binding via AudioUnitSetProperty
        try hal.setOutputDevice(deviceID: deviceID, for: audioUnit)
    }

    /// Resolves a stable device UID string to an active numeric `AudioDeviceID`.
    ///
    /// - Parameters:
    ///   - uid: The persistent UID string (e.g. from `AudioDeviceDescriptor.id`).
    ///   - hal: The underlying HAL abstraction interface.
    /// - Returns: The matching `AudioDeviceID` if currently online, or `nil` if no device reports that UID.
    /// - Throws: The underlying HAL error when the device list or a device UID cannot be read.
    ///   A thrown error is not proof that the UID is absent.
    public static func deviceID(forUID uid: String, using hal: AudioHardwareInterface = SystemAudioHardware.shared) throws -> AudioDeviceID? {
        let deviceIDs = try hal.getDeviceIDs()
        for deviceID in deviceIDs {
            let deviceUID = try hal.getDeviceUID(deviceID: deviceID)
            if deviceUID == uid {
                return deviceID
            }
        }
        return nil
    }

    /// Generates an `AudioDeviceDescriptor` for a specific active numeric `AudioDeviceID`.
    ///
    /// - Parameters:
    ///   - deviceID: The numeric CoreAudio device identifier.
    ///   - hal: The underlying HAL abstraction interface.
    /// - Returns: An `AudioDeviceDescriptor` when the device has output channels.
    /// - Throws: The sample-rate error from the HAL, or `CoreAudioError.invalidSampleRate`
    ///   when the reported rate is non-finite or not positive. A missing device returns `nil`.
    public static func descriptor(for deviceID: AudioDeviceID, using hal: AudioHardwareInterface = SystemAudioHardware.shared) throws -> AudioDeviceDescriptor? {
        let channelCount: Int
        do {
            channelCount = try hal.getOutputChannelCount(deviceID: deviceID)
        } catch {
            return nil
        }
        guard channelCount > 0 else {
            return nil
        }

        let uid = try hal.getDeviceUID(deviceID: deviceID)
        let name = (try? hal.getDeviceName(deviceID: deviceID)) ?? "Audio Device (\(deviceID))"
        let manufacturer = (try? hal.getDeviceManufacturer(deviceID: deviceID)) ?? "Generic"
        let sampleRate = try hal.getNominalSampleRate(deviceID: deviceID)
        guard sampleRate.isFinite && sampleRate > 0.0 else {
            throw CoreAudioError.invalidSampleRate(sampleRate)
        }
        var isBluetooth = false
        if let transport = try? hal.getTransportType(deviceID: deviceID) {
            isBluetooth = (transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE)
        }
        let defaultID = try? hal.getDefaultOutputDeviceID()
        let isDefault = (defaultID != nil && defaultID == deviceID)

        return AudioDeviceDescriptor(
            id: uid,
            name: name,
            manufacturer: manufacturer,
            outputChannelCount: channelCount,
            sampleRate: sampleRate,
            isDefault: isDefault,
            isBluetooth: isBluetooth
        )
    }
}
