import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

/// Thread-safe monitor for CoreAudio hardware device additions, removals, and configuration changes.
///
/// ## Synchronization & Concurrency Model:
/// - Internal mutable state is strictly serialized on a private control queue (`com.pulsedeck.audio.control`).
/// - `@unchecked Sendable` is justified because all mutations of registered engines, listener tokens,
///   coalesced work items, and recovery states are locked behind this serial queue.
/// - Conforms strictly to synchronous Phase 0 protocols; avoids actor reentrancy during HAL notifications.
/// - CoreAudio callbacks are `nonisolated` and `@Sendable`, immediately dispatching coalesced events
///   to the serial queue without mutating `AVAudioEngine` or graphs on the HAL callback thread.
public final class OutputDeviceMonitor: @unchecked Sendable {

    /// Registered audio engine record tracking fallback state, intended lifecycle state, and NotificationCenter tokens.
    final class RegisteredEngine {
        weak var engine: AVAudioEngine?
        let role: AudioEngineRole
        var desiredDeviceUID: String?
        var boundDeviceID: AudioDeviceID?
        var boundDeviceUID: String?
        var intendedRunningState: Bool
        var retryCount: Int
        var observerToken: NSObjectProtocol?

        init(
            engine: AVAudioEngine,
            role: AudioEngineRole,
            desiredDeviceUID: String? = nil,
            boundDeviceID: AudioDeviceID? = nil,
            boundDeviceUID: String? = nil,
            intendedRunningState: Bool = false
        ) {
            self.engine = engine
            self.role = role
            self.desiredDeviceUID = desiredDeviceUID
            self.boundDeviceID = boundDeviceID
            self.boundDeviceUID = boundDeviceUID
            self.intendedRunningState = intendedRunningState
            self.retryCount = 0
            self.observerToken = nil
        }
    }

    private let hal: AudioHardwareInterface
    private let controlQueue: DispatchQueue
    private let coalescingDelayMs: Int
    private let onChange: (@Sendable () -> Void)?
    private let onError: (@Sendable (CoreAudioError) -> Void)?

    private var isMonitoring: Bool = false
    private var isShuttingDown: Bool = false
    private var devicesListenerRegistered: Bool = false
    private var defaultListenerRegistered: Bool = false
    private var coalesceWorkItem: DispatchWorkItem?
    private var registeredEngines: [RegisteredEngine] = []

    // Retained exact listener block references required by CoreAudio HAL for listener removal
    private var devicesListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultListenerBlock: AudioObjectPropertyListenerBlock?

    /// Initializes a new `OutputDeviceMonitor`.
    ///
    /// - Parameters:
    ///   - hal: Injected audio hardware abstraction layer.
    ///   - coalescingDelayMs: Delay in milliseconds to coalesce rapid successive HAL events (defaults to 50ms).
    ///   - onChange: Callback invoked on device topology or active endpoint changes.
    ///   - onError: Callback invoked when a recoverable HAL or recovery error occurs.
    public init(
        hal: AudioHardwareInterface = SystemAudioHardware.shared,
        coalescingDelayMs: Int = 50,
        onChange: (@Sendable () -> Void)? = nil,
        onError: (@Sendable (CoreAudioError) -> Void)? = nil
    ) {
        self.hal = hal
        self.controlQueue = DispatchQueue(label: "com.pulsedeck.audio.control", qos: .userInitiated)
        self.coalescingDelayMs = coalescingDelayMs
        self.onChange = onChange
        self.onError = onError
    }

    /// Convenience initializer matching required Phase 1A signature.
    ///
    /// - Parameter onChange: Closure invoked whenever output device topology changes.
    public convenience init(onChange: @escaping @Sendable () -> Void) {
        self.init(hal: SystemAudioHardware.shared, coalescingDelayMs: 50, onChange: onChange, onError: nil)
    }

    deinit {
        stop()
    }

    /// Starts monitoring CoreAudio hardware device events and configuration changes.
    ///
    /// - Throws: `CoreAudioError` if listener registration fails (rolls back any partial registrations).
    public func start() throws {
        try controlQueue.sync {
            guard !isMonitoring else { return }

            isShuttingDown = false

            // Define exact listener closures
            let devBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.handleHALEvent()
            }
            let defBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.handleHALEvent()
            }

            self.devicesListenerBlock = devBlock
            self.defaultListenerBlock = defBlock

            // Register kAudioHardwarePropertyDevices listener
            do {
                try hal.addDevicesListener(on: controlQueue, block: devBlock)
                devicesListenerRegistered = true
            } catch {
                cleanupInternalListeners()
                throw error
            }

            // Register kAudioHardwarePropertyDefaultOutputDevice listener with rollback on failure
            do {
                try hal.addDefaultOutputDeviceListener(on: controlQueue, block: defBlock)
                defaultListenerRegistered = true
            } catch {
                cleanupInternalListeners()
                throw error
            }

            isMonitoring = true
        }
    }

    /// Stops monitoring and unregisters all HAL property listeners and NotificationCenter observers.
    public func stop() {
        controlQueue.sync {
            guard isMonitoring || devicesListenerRegistered || defaultListenerRegistered else { return }

            isShuttingDown = true
            isMonitoring = false

            coalesceWorkItem?.cancel()
            coalesceWorkItem = nil

            cleanupInternalListeners()

            // Remove engine observers
            for registration in registeredEngines {
                if let token = registration.observerToken {
                    NotificationCenter.default.removeObserver(token)
                    registration.observerToken = nil
                }
            }
            registeredEngines.removeAll()

            isShuttingDown = false
        }
    }

    /// Registers an `AVAudioEngine` for automatic device recovery and configuration change observation.
    ///
    /// - Parameters:
    ///   - engine: The audio engine instance to register (held via weak reference).
    ///   - role: The architectural role of the engine (Master or Cue).
    ///   - desiredDeviceUID: Optional preferred device UID string.
    ///   - boundDeviceID: Optional initial bound `AudioDeviceID`.
    ///   - boundDeviceUID: Optional initial bound device UID string.
    public func registerEngine(
        _ engine: AVAudioEngine,
        role: AudioEngineRole,
        desiredDeviceUID: String? = nil,
        boundDeviceID: AudioDeviceID? = nil,
        boundDeviceUID: String? = nil
    ) {
        controlQueue.sync {
            // Prune dead references
            registeredEngines.removeAll { $0.engine == nil }

            let resolvedBoundUID: String?
            if let explicitUID = boundDeviceUID {
                resolvedBoundUID = explicitUID
            } else if let id = boundDeviceID {
                resolvedBoundUID = try? hal.getDeviceUID(deviceID: id)
            } else {
                resolvedBoundUID = nil
            }

            // Check if already registered
            if let existing = registeredEngines.first(where: { $0.engine === engine }) {
                existing.desiredDeviceUID = desiredDeviceUID
                existing.boundDeviceID = boundDeviceID
                existing.boundDeviceUID = resolvedBoundUID
                existing.intendedRunningState = engine.isRunning
                return
            }

            let registration = RegisteredEngine(
                engine: engine,
                role: role,
                desiredDeviceUID: desiredDeviceUID,
                boundDeviceID: boundDeviceID,
                boundDeviceUID: resolvedBoundUID,
                intendedRunningState: engine.isRunning
            )

            // Listen for engine configuration change notifications
            let token = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                self?.handleHALEvent()
            }
            registration.observerToken = token
            registeredEngines.append(registration)
        }
    }

    /// Unregisters an `AVAudioEngine` from device monitoring and recovery.
    ///
    /// - Parameter engine: The engine to remove.
    public func unregisterEngine(_ engine: AVAudioEngine) {
        controlQueue.sync {
            if let index = registeredEngines.firstIndex(where: { $0.engine === engine }) {
                let registration = registeredEngines.remove(at: index)
                if let token = registration.observerToken {
                    NotificationCenter.default.removeObserver(token)
                }
            }
        }
    }

    /// Updates the intended running state for a registered engine.
    ///
    /// When recovery or rebind occurs, the engine will only restart if intended running state is true.
    public func setIntendedRunningState(for engine: AVAudioEngine, running: Bool) {
        controlQueue.sync {
            if let registration = registeredEngines.first(where: { $0.engine === engine }) {
                registration.intendedRunningState = running
            }
        }
    }

    /// Updates the active bound device identifier and persists its UID for a registered engine.
    public func setBoundDeviceID(for engine: AVAudioEngine, deviceID: AudioDeviceID?, desiredUID: String? = nil) {
        controlQueue.sync {
            if let registration = registeredEngines.first(where: { $0.engine === engine }) {
                registration.boundDeviceID = deviceID
                registration.boundDeviceUID = deviceID.flatMap { try? hal.getDeviceUID(deviceID: $0) }
                if let uid = desiredUID {
                    registration.desiredDeviceUID = uid
                }
            }
        }
    }

    /// Explicitly updates both the bound device ID and its persistent UID.
    public func setBoundDevice(
        for engine: AVAudioEngine,
        deviceID: AudioDeviceID?,
        uid: String?,
        desiredUID: String? = nil
    ) {
        controlQueue.sync {
            if let registration = registeredEngines.first(where: { $0.engine === engine }) {
                registration.boundDeviceID = deviceID
                registration.boundDeviceUID = uid ?? deviceID.flatMap { try? hal.getDeviceUID(deviceID: $0) }
                if let desired = desiredUID {
                    registration.desiredDeviceUID = desired
                }
            }
        }
    }

    /// Synchronously executes device reconciliation (primarily for test verification and immediate state sync).
    public func reconcileImmediately() {
        controlQueue.sync {
            performReconciliation()
        }
    }

    // MARK: - Private Serialized Control-Plane Logic

    private func handleHALEvent() {
        controlQueue.async { [weak self] in
            guard let self = self, self.isMonitoring, !self.isShuttingDown else { return }

            self.coalesceWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.performReconciliation()
            }
            self.coalesceWorkItem = item
            if self.coalescingDelayMs <= 0 {
                self.controlQueue.async(execute: item)
            } else {
                self.controlQueue.asyncAfter(
                    deadline: .now() + .milliseconds(self.coalescingDelayMs),
                    execute: item
                )
            }
        }
    }

    private func performReconciliation() {
        guard isMonitoring, !isShuttingDown else { return }

        // Prune deallocated engines
        registeredEngines.removeAll { $0.engine == nil }

        let availableDevices = (try? CoreAudioOutputDevices.enumerate(using: hal)) ?? []
        let defaultDeviceID = try? CoreAudioOutputDevices.defaultOutputDeviceID(using: hal)

        for registration in registeredEngines {
            guard let engine = registration.engine else { continue }

            // Presence verification: binding is valid ONLY when deviceID(forUID:) returns
            // an active output endpoint matching the persisted bound UID and numeric ID.
            // CoreAudio recycles ephemeral numeric IDs, so checking numeric ID alone is insufficient.
            if let boundUID = registration.boundDeviceUID,
               let boundID = registration.boundDeviceID,
               let resolvedID = try? CoreAudioOutputDevices.deviceID(forUID: boundUID, using: hal),
               resolvedID == boundID,
               availableDevices.contains(where: { $0.id == boundUID }) {
                // Device is present, numeric ID is unchanged, and endpoint is an active output
                registration.retryCount = 0

                // If running was intended but engine stopped during HAL change, restart it
                if registration.intendedRunningState && !engine.isRunning {
                    do {
                        try engine.start()
                    } catch {
                        onError?(.osStatus(OSStatus(-1), operation: "engineRestartAfterConfigChange"))
                    }
                }
                continue
            }

            // Active binding is lost or invalidated.
            // Pick target in priority order:
            // 1. Preferred UID (desiredDeviceUID) if online
            // 2. System default output device
            // 3. First enumerated output endpoint with channels
            var targetCandidate: (id: AudioDeviceID, uid: String)? = nil

            // 1. Preferred UID
            if let preferredUID = registration.desiredDeviceUID,
               let preferredDesc = availableDevices.first(where: { $0.id == preferredUID }),
               let preferredID = try? CoreAudioOutputDevices.deviceID(forUID: preferredUID, using: hal) {
                targetCandidate = (preferredID, preferredDesc.id)
            }

            // 2. System default output
            if targetCandidate == nil,
               let defID = defaultDeviceID,
               let defUID = try? hal.getDeviceUID(deviceID: defID),
               availableDevices.contains(where: { $0.id == defUID }) {
                targetCandidate = (defID, defUID)
            }

            // 3. First enumerated output with channels
            if targetCandidate == nil,
               let firstDesc = availableDevices.first(where: { $0.outputChannelCount > 0 }),
               let firstID = try? CoreAudioOutputDevices.deviceID(forUID: firstDesc.id, using: hal) {
                targetCandidate = (firstID, firstDesc.id)
            }

            // Report noOutputDeviceAvailable ONLY when no candidate output is found
            guard let target = targetCandidate else {
                if engine.isRunning {
                    engine.stop()
                }
                registration.boundDeviceID = nil
                registration.boundDeviceUID = nil
                onError?(.noOutputDeviceAvailable)
                continue
            }

            // Enforce bounded retries to prevent restart loops
            guard registration.retryCount < 3 else {
                onError?(.recoveryRetryLimitExceeded(registration.role))
                continue
            }
            registration.retryCount += 1

            // Rebind target device preserving intended running/stopped state
            let shouldBeRunning = registration.intendedRunningState || engine.isRunning
            if engine.isRunning {
                engine.stop()
            }

            do {
                try CoreAudioOutputDevices.bind(target.id, to: engine, using: hal)
                // Persist the bound UID and numeric ID after every successful bind
                registration.boundDeviceID = target.id
                registration.boundDeviceUID = target.uid
                if shouldBeRunning {
                    try engine.start()
                }
                registration.retryCount = 0
            } catch let error as CoreAudioError {
                onError?(error)
            } catch {
                onError?(.osStatus(OSStatus(-1), operation: "rebindTargetDevice: \(error.localizedDescription)"))
            }
        }

        // Notify client listener of configuration/topology changes
        onChange?()
    }

    private func cleanupInternalListeners() {
        if defaultListenerRegistered, let block = defaultListenerBlock {
            try? hal.removeDefaultOutputDeviceListener(on: controlQueue, block: block)
            defaultListenerRegistered = false
        }
        if devicesListenerRegistered, let block = devicesListenerBlock {
            try? hal.removeDevicesListener(on: controlQueue, block: block)
            devicesListenerRegistered = false
        }
        devicesListenerBlock = nil
        defaultListenerBlock = nil
    }
}
