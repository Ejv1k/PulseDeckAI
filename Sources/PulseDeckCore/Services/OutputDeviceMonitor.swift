import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation

/// Thread-safe monitor for CoreAudio output-device additions, removals, and configuration changes.
///
/// ## Output-only boundary
/// Direction-sensitive HAL queries use `kAudioDevicePropertyScopeOutput`. Device-wide properties use the global scope.
/// This type never reads `AVAudioEngine.inputNode`.
///
/// ## Engine mutation ownership
/// For a registered engine, `AVAudioEngine.start()`, `pause()`, `stop()`, and output-device bind run only on
/// `com.pulsedeck.audio.control`. `AVAudioEngine` is not thread-safe. Clients must not mutate a registered engine
/// concurrently with this monitor. Recovery pauses a running engine before rebind so the scheduled graph is kept.
/// `AVAudioEngine.stop()` is not used. The engine restarts only when `intendedRunningState` is true.
///
/// ## Synchronization
/// Mutable monitor state is serialized on the control queue. The queue carries a specific key. Work already running
/// on that queue runs inline and never calls `sync` on it. `onChange` and `onError` run only after the control-queue
/// section has finished, and never on that queue. `deinit` uses the same rule, including when the last reference
/// drops on the control queue.
///
/// `@unchecked Sendable` is limited to that queue ownership. Listener blocks are `nonisolated` and hop onto the queue
/// before touching an engine.
public final class OutputDeviceMonitor: @unchecked Sendable {

    /// Registered engine record. Mutated only on the control queue.
    final class RegisteredEngine {
        weak var engine: AVAudioEngine?
        let role: AudioEngineRole
        var desiredDeviceUID: String?
        var boundDeviceID: AudioDeviceID?
        var boundDeviceUID: String?
        var intendedRunningState: Bool
        var observerToken: NSObjectProtocol?
        /// Candidate UID plus topology generation currently being retried.
        var recoveryEpoch: String = ""
        var recoveryAttempts: Int = 0
        var recoveryLimitEmitted: Bool = false

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
            self.observerToken = nil
        }

        deinit {
            if let token = observerToken {
                NotificationCenter.default.removeObserver(token)
                observerToken = nil
            }
        }
    }

    private enum MonitorEvent: Sendable {
        case failure(CoreAudioError)
        case topologyChanged
    }

    /// Planned against a successful topology snapshot, then applied. Lookup failures produce no steps.
    private enum RecoveryStep {
        case maintain(RegisteredEngine, AVAudioEngine, candidateUID: String)
        case attach(RegisteredEngine, AVAudioEngine, deviceID: AudioDeviceID, uid: String)
        case clearMissing(RegisteredEngine, AVAudioEngine)
    }

    private static let maxRecoveryAttempts = 3
    private static let controlQueueToken: UInt8 = 1

    private let hal: AudioHardwareInterface
    private let controlQueue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let controlQueueKey = DispatchSpecificKey<UInt8>()
    private let coalescingDelayMs: Int
    private let onChange: (@Sendable () -> Void)?
    private let onError: (@Sendable (CoreAudioError) -> Void)?

    private var isMonitoring: Bool = false
    private var isShuttingDown: Bool = false
    private var devicesListenerRegistered: Bool = false
    private var defaultListenerRegistered: Bool = false
    private var coalesceWorkItem: DispatchWorkItem?
    private var registeredEngines: [RegisteredEngine] = []

    // Exact Objective-C blocks passed to the HAL. Removal must pass these same objects.
    private var devicesListenerBlock: OutputPropertyListenerBlock?
    private var defaultListenerBlock: OutputPropertyListenerBlock?

    /// Initializes a new `OutputDeviceMonitor`.
    ///
    /// - Parameters:
    ///   - hal: Injected audio hardware abstraction layer.
    ///   - coalescingDelayMs: Delay in milliseconds to coalesce rapid successive HAL events (defaults to 50ms).
    ///   - onChange: Callback invoked after a successful topology pass. Not invoked when a HAL query fails.
    ///   - onError: Callback invoked when a HAL, bind, or start error occurs.
    public init(
        hal: AudioHardwareInterface = SystemAudioHardware.shared,
        coalescingDelayMs: Int = 50,
        onChange: (@Sendable () -> Void)? = nil,
        onError: (@Sendable (CoreAudioError) -> Void)? = nil
    ) {
        self.hal = hal
        self.controlQueue = DispatchQueue(label: "com.pulsedeck.audio.control", qos: .userInitiated)
        self.callbackQueue = DispatchQueue(label: "com.pulsedeck.audio.control.callbacks", qos: .userInitiated)
        self.controlQueue.setSpecific(key: controlQueueKey, value: Self.controlQueueToken)
        self.coalescingDelayMs = coalescingDelayMs
        self.onChange = onChange
        self.onError = onError
    }

    /// Convenience initializer matching the Phase 1A signature.
    ///
    /// - Parameter onChange: Closure invoked whenever an output-device topology pass succeeds.
    public convenience init(onChange: @escaping @Sendable () -> Void) {
        self.init(hal: SystemAudioHardware.shared, coalescingDelayMs: 50, onChange: onChange, onError: nil)
    }

    deinit {
        // `stop()` takes the queue. `sync` from this queue deadlocks, so a release on the queue cleans up inline.
        if isOnControlQueue {
            _ = stopLocked()
        } else {
            controlQueue.sync {
                _ = self.stopLocked()
            }
        }
    }

    /// Starts monitoring CoreAudio hardware device events and configuration changes.
    ///
    /// - Throws: `CoreAudioError` if listener registration fails. Listeners added during this attempt are removed.
    ///   A listener that is still installed from an earlier failed removal is kept and is not registered twice.
    public func start() throws {
        let result: (events: [MonitorEvent], error: CoreAudioError?) = syncControl {
            self.beginMonitoring()
        }
        deliver(result.events)
        if let error = result.error {
            throw error
        }
    }

    /// Stops monitoring and unregisters HAL property listeners and configuration observers.
    ///
    /// A failed `AudioObjectRemovePropertyListenerBlock` reports `listenerRemovalFailed` and keeps that block.
    /// The next `start()` does not add a second listener for a block that is still installed.
    public func stop() {
        let events = syncControl { self.stopLocked() }
        deliver(events)
    }

    /// Registers an `AVAudioEngine` for automatic device recovery and configuration observation.
    ///
    /// The configuration observer does not retain `engine`. After registration, this monitor is the exclusive
    /// mutator of that engine's running state and output device. Pass `intendedRunningState` changes through
    /// `setIntendedRunningState`. The flag is copied from `engine.isRunning` at registration.
    ///
    /// - Parameters:
    ///   - engine: The audio engine instance to register (held via weak reference).
    ///   - role: The architectural role of the engine (Master or Cue).
    ///   - desiredDeviceUID: Optional preferred device UID string.
    ///   - boundDeviceID: Optional initial bound `AudioDeviceID`.
    ///   - boundDeviceUID: Optional initial bound device UID string. When omitted, the UID is read from `boundDeviceID`.
    ///     A thrown read on an engine that is already registered leaves the previous ID and UID unchanged and
    ///     reports the error. The new ID is stored only together with a resolved UID. Both are cleared only
    ///     when the caller passes nil for both. A first registration still stores the numeric ID with a nil UID.
    public func registerEngine(
        _ engine: AVAudioEngine,
        role: AudioEngineRole,
        desiredDeviceUID: String? = nil,
        boundDeviceID: AudioDeviceID? = nil,
        boundDeviceUID: String? = nil
    ) {
        let events = syncControl { () -> [MonitorEvent] in
            self.registeredEngines.removeAll { $0.engine == nil }

            let resolvedBoundUID = self.resolveInitialUID(
                explicitUID: boundDeviceUID,
                deviceID: boundDeviceID
            )

            if let existing = self.registeredEngines.first(where: { $0.engine === engine }) {
                existing.desiredDeviceUID = desiredDeviceUID
                existing.intendedRunningState = engine.isRunning
                // A thrown UID read must not pair the new numeric ID with the previous UID.
                // Apply the new ID only together with the resolved UID. Clear both only when
                // the caller passes nil for both. Otherwise keep the binding recovery already has.
                if boundDeviceUID == nil && boundDeviceID == nil {
                    existing.boundDeviceID = nil
                    existing.boundDeviceUID = nil
                } else if let uid = resolvedBoundUID.uid {
                    existing.boundDeviceID = boundDeviceID
                    existing.boundDeviceUID = uid
                }
                return resolvedBoundUID.events
            }

            let registration = RegisteredEngine(
                engine: engine,
                role: role,
                desiredDeviceUID: desiredDeviceUID,
                boundDeviceID: boundDeviceID,
                boundDeviceUID: resolvedBoundUID.uid,
                intendedRunningState: engine.isRunning
            )

            // `object: nil` so NotificationCenter does not retain the engine for the lifetime of the token.
            // The block stores `ObjectIdentifier` instead of the engine, so the closure stays sendable and
            // does not keep the engine alive.
            let engineID = ObjectIdentifier(engine)
            let token = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                self?.noteConfigurationObserverFireForTesting()
                guard let posted = notification.object as? AVAudioEngine else { return }
                guard ObjectIdentifier(posted) == engineID else { return }
                self?.handleHALEvent()
            }
            registration.observerToken = token
            self.registeredEngines.append(registration)
            return resolvedBoundUID.events
        }
        deliver(events)
    }

    /// Unregisters an `AVAudioEngine` from device monitoring and recovery.
    ///
    /// - Parameter engine: The engine to remove.
    public func unregisterEngine(_ engine: AVAudioEngine) {
        syncControl {
            if let index = self.registeredEngines.firstIndex(where: { $0.engine === engine }) {
                let registration = self.registeredEngines.remove(at: index)
                if let token = registration.observerToken {
                    NotificationCenter.default.removeObserver(token)
                    registration.observerToken = nil
                }
            }
        }
    }

    /// Updates the intended running state for a registered engine.
    ///
    /// Recovery restarts the engine only when this value is true. A still-running engine does not override `false`.
    public func setIntendedRunningState(for engine: AVAudioEngine, running: Bool) {
        syncControl {
            if let registration = self.registeredEngines.first(where: { $0.engine === engine }) {
                registration.intendedRunningState = running
            }
        }
    }

    /// Updates the active bound device identifier and persists its UID for a registered engine.
    ///
    /// A failed UID lookup leaves the previous UID in place and is reported through `onError`.
    public func setBoundDeviceID(for engine: AVAudioEngine, deviceID: AudioDeviceID?, desiredUID: String? = nil) {
        let events = syncControl { () -> [MonitorEvent] in
            guard let registration = self.registeredEngines.first(where: { $0.engine === engine }) else {
                return []
            }
            if let desiredUID {
                registration.desiredDeviceUID = desiredUID
            }
            guard let deviceID else {
                registration.boundDeviceID = nil
                registration.boundDeviceUID = nil
                return []
            }
            do {
                let uid = try self.hal.getDeviceUID(deviceID: deviceID)
                registration.boundDeviceID = deviceID
                registration.boundDeviceUID = uid
                return []
            } catch {
                return [.failure(Self.coreAudioError(error, operation: "getDeviceUID"))]
            }
        }
        deliver(events)
    }

    /// Explicitly updates both the bound device ID and its persistent UID.
    ///
    /// When `uid` is nil, the UID is read from `deviceID`. A failed read keeps the previous binding and reports the error.
    public func setBoundDevice(
        for engine: AVAudioEngine,
        deviceID: AudioDeviceID?,
        uid: String?,
        desiredUID: String? = nil
    ) {
        let events = syncControl { () -> [MonitorEvent] in
            guard let registration = self.registeredEngines.first(where: { $0.engine === engine }) else {
                return []
            }
            if let desiredUID {
                registration.desiredDeviceUID = desiredUID
            }
            if let uid {
                registration.boundDeviceID = deviceID
                registration.boundDeviceUID = uid
                return []
            }
            guard let deviceID else {
                registration.boundDeviceID = nil
                registration.boundDeviceUID = nil
                return []
            }
            do {
                let resolved = try self.hal.getDeviceUID(deviceID: deviceID)
                registration.boundDeviceID = deviceID
                registration.boundDeviceUID = resolved
                return []
            } catch {
                return [.failure(Self.coreAudioError(error, operation: "getDeviceUID"))]
            }
        }
        deliver(events)
    }

    /// Synchronously executes device reconciliation for tests and immediate state sync.
    ///
    /// Callbacks run on the caller after the control queue is released, so they may re-enter the monitor.
    public func reconcileImmediately() {
        let events = syncControl { self.performReconciliation() }
        deliver(events)
    }

    /// Schedules `body` on the monitor control queue.
    ///
    /// Tests use this to drop the last monitor reference from that queue and prove `deinit` does not deadlock.
    func scheduleOnControlQueueForTesting(_ body: @escaping @Sendable () -> Void) {
        controlQueue.async(execute: body)
    }

    private let configurationObserverFireLock = NSLock()
    private var configurationObserverFireCount = 0

    private func noteConfigurationObserverFireForTesting() {
        configurationObserverFireLock.lock()
        configurationObserverFireCount += 1
        configurationObserverFireLock.unlock()
    }

    /// How many times the configuration-change block has been entered.
    func configurationObserverFireCountForTesting() -> Int {
        configurationObserverFireLock.lock()
        defer { configurationObserverFireLock.unlock() }
        return configurationObserverFireCount
    }

    /// Returns the UID stored for `engine`, or `nil` when that engine is not registered.
    func boundDeviceUIDForTesting(of engine: AVAudioEngine) -> String? {
        syncControl {
            self.registeredEngines.first { $0.engine === engine }?.boundDeviceUID
        }
    }

    /// Returns the numeric ID stored for `engine`, or `nil` when that engine is not registered or unbound.
    func boundDeviceIDForTesting(of engine: AVAudioEngine) -> AudioDeviceID? {
        syncControl {
            self.registeredEngines.first { $0.engine === engine }?.boundDeviceID
        }
    }

    // MARK: - Queue ownership

    private var isOnControlQueue: Bool {
        DispatchQueue.getSpecific(key: controlQueueKey) == Self.controlQueueToken
    }

    /// Executes a synchronous operation on the monitor's private serialized control queue.
    ///
    /// If the calling context is already executing on the control queue, `body` is invoked directly inline.
    public func performOnControlQueue<T: Sendable>(_ body: () throws -> T) rethrows -> T {
        try syncControl(body)
    }

    private func syncControl<T: Sendable>(_ body: () throws -> T) rethrows -> T {
        if isOnControlQueue {
            return try body()
        }
        return try controlQueue.sync(execute: body)
    }

    private func deliver(_ events: [MonitorEvent]) {
        guard !events.isEmpty else { return }
        // Callbacks that re-enter `stop` or `registerEngine` must not run inside the control-queue section.
        if isOnControlQueue {
            let copied = events
            callbackQueue.async { [weak self] in
                self?.emit(copied)
            }
            return
        }
        emit(events)
    }

    private func emit(_ events: [MonitorEvent]) {
        for event in events {
            switch event {
            case .failure(let error):
                onError?(error)
            case .topologyChanged:
                onChange?()
            }
        }
    }

    // MARK: - Listener lifecycle

    private func beginMonitoring() -> (events: [MonitorEvent], error: CoreAudioError?) {
        guard !isMonitoring else { return ([], nil) }
        isShuttingDown = false

        do {
            try installListenersIfNeeded()
            isMonitoring = true
            return ([], nil)
        } catch let error as CoreAudioError {
            let events = removeInstalledListeners()
            return (events, error)
        } catch {
            let events = removeInstalledListeners()
            return (events, Self.coreAudioError(error, operation: "startMonitoring"))
        }
    }

    private func installListenersIfNeeded() throws {
        if !devicesListenerRegistered {
            let block: OutputPropertyListenerBlock = { [weak self] _, _ in
                self?.handleHALEvent()
            }
            try hal.addDevicesListener(on: controlQueue, block: block)
            devicesListenerBlock = block
            devicesListenerRegistered = true
        }

        if !defaultListenerRegistered {
            let block: OutputPropertyListenerBlock = { [weak self] _, _ in
                self?.handleHALEvent()
            }
            do {
                try hal.addDefaultOutputDeviceListener(on: controlQueue, block: block)
            } catch {
                throw Self.coreAudioError(error, operation: "addDefaultOutputDeviceListener")
            }
            defaultListenerBlock = block
            defaultListenerRegistered = true
        }
    }

    private func stopLocked() -> [MonitorEvent] {
        let hasListener = devicesListenerRegistered || defaultListenerRegistered
        let hasEngineState = !registeredEngines.isEmpty || coalesceWorkItem != nil
        guard isMonitoring || hasListener || hasEngineState else { return [] }

        isShuttingDown = true
        isMonitoring = false
        coalesceWorkItem?.cancel()
        coalesceWorkItem = nil

        let events = removeInstalledListeners()
        for registration in registeredEngines {
            if let token = registration.observerToken {
                NotificationCenter.default.removeObserver(token)
                registration.observerToken = nil
            }
        }
        registeredEngines.removeAll()
        isShuttingDown = false
        return events
    }

    /// Removes installed listeners. A removal failure keeps that block and registration flag.
    private func removeInstalledListeners() -> [MonitorEvent] {
        var events: [MonitorEvent] = []

        if defaultListenerRegistered, let block = defaultListenerBlock {
            do {
                try hal.removeDefaultOutputDeviceListener(on: controlQueue, block: block)
                defaultListenerRegistered = false
                defaultListenerBlock = nil
            } catch {
                events.append(.failure(Self.coreAudioError(error, operation: "removeDefaultOutputDeviceListener")))
            }
        }

        if devicesListenerRegistered, let block = devicesListenerBlock {
            do {
                try hal.removeDevicesListener(on: controlQueue, block: block)
                devicesListenerRegistered = false
                devicesListenerBlock = nil
            } catch {
                events.append(.failure(Self.coreAudioError(error, operation: "removeDevicesListener")))
            }
        }

        return events
    }

    private func handleHALEvent() {
        let schedule: @Sendable () -> Void = { [weak self] in
            guard let self, self.isMonitoring, !self.isShuttingDown else { return }
            self.coalesceWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let events = self.performReconciliation()
                self.deliver(events)
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

        if isOnControlQueue {
            schedule()
        } else {
            controlQueue.async(execute: schedule)
        }
    }

    // MARK: - Reconciliation

    private func performReconciliation() -> [MonitorEvent] {
        guard isMonitoring, !isShuttingDown else { return [] }
        registeredEngines.removeAll { $0.engine == nil }

        let devices: [AudioDeviceDescriptor]
        let defaultDeviceID: AudioDeviceID?
        do {
            devices = try CoreAudioOutputDevices.enumerate(using: hal)
            defaultDeviceID = try CoreAudioOutputDevices.defaultOutputDeviceID(using: hal)
        } catch {
            return [.failure(Self.coreAudioError(error, operation: "outputTopology"))]
        }

        let topology = devices.map(\.id).sorted().joined(separator: "\u{1e}")
        let snapshot = registeredEngines

        let steps: [RecoveryStep]
        do {
            steps = try planRecovery(snapshot: snapshot, devices: devices, defaultDeviceID: defaultDeviceID)
        } catch {
            // A thrown UID or device-list read is not an empty topology. Leave every binding untouched.
            return [.failure(Self.coreAudioError(error, operation: "outputTopology"))]
        }

        var events: [MonitorEvent] = []
        for step in steps {
            apply(step, topology: topology, events: &events)
        }
        events.append(.topologyChanged)
        return events
    }

    private func planRecovery(
        snapshot: [RegisteredEngine],
        devices: [AudioDeviceDescriptor],
        defaultDeviceID: AudioDeviceID?
    ) throws -> [RecoveryStep] {
        var steps: [RecoveryStep] = []
        for registration in snapshot {
            guard let engine = registration.engine else { continue }

            if registration.boundDeviceUID == nil, let boundID = registration.boundDeviceID {
                // A failed UID read at registration stores the numeric ID and leaves the UID nil.
                // Nil here means "not known yet", not "unbound". Resolve that ID before any fallback.
                let listedIDs = try hal.getDeviceIDs()
                if listedIDs.contains(boundID) {
                    let uid = try hal.getDeviceUID(deviceID: boundID)
                    if !uid.isEmpty, devices.contains(where: { $0.id == uid }) {
                        steps.append(.maintain(registration, engine, candidateUID: uid))
                        continue
                    }
                }
            }

            if let boundUID = registration.boundDeviceUID,
               devices.contains(where: { $0.id == boundUID }) {
                // Throws stay failures. `nil` means this successful read did not find the UID.
                if let resolvedID = try CoreAudioOutputDevices.deviceID(forUID: boundUID, using: hal) {
                    if registration.boundDeviceID == resolvedID {
                        steps.append(.maintain(registration, engine, candidateUID: boundUID))
                    } else {
                        // Same UID, new numeric ID. Stay on this device. Do not accept another UID at the old ID.
                        steps.append(.attach(registration, engine, deviceID: resolvedID, uid: boundUID))
                    }
                    continue
                }
            }

            if let target = try selectFallback(
                for: registration,
                devices: devices,
                defaultDeviceID: defaultDeviceID
            ) {
                steps.append(.attach(registration, engine, deviceID: target.id, uid: target.uid))
            } else {
                steps.append(.clearMissing(registration, engine))
            }
        }
        return steps
    }

    private func selectFallback(
        for registration: RegisteredEngine,
        devices: [AudioDeviceDescriptor],
        defaultDeviceID: AudioDeviceID?
    ) throws -> (id: AudioDeviceID, uid: String)? {
        if let preferredUID = registration.desiredDeviceUID,
           devices.contains(where: { $0.id == preferredUID }) {
            if let preferredID = try CoreAudioOutputDevices.deviceID(forUID: preferredUID, using: hal) {
                return (preferredID, preferredUID)
            }
        }

        if let defaultDeviceID {
            let defaultUID = try hal.getDeviceUID(deviceID: defaultDeviceID)
            if devices.contains(where: { $0.id == defaultUID }) {
                return (defaultDeviceID, defaultUID)
            }
        }

        if let first = devices.first(where: { $0.outputChannelCount > 0 }) {
            if let firstID = try CoreAudioOutputDevices.deviceID(forUID: first.id, using: hal) {
                return (firstID, first.id)
            }
        }

        return nil
    }

    private func apply(_ step: RecoveryStep, topology: String, events: inout [MonitorEvent]) {
        switch step {
        case .maintain(let registration, let engine, let candidateUID):
            maintain(registration, engine: engine, candidateUID: candidateUID, topology: topology, events: &events)
        case .attach(let registration, let engine, let deviceID, let uid):
            attach(registration, engine: engine, deviceID: deviceID, uid: uid, topology: topology, events: &events)
        case .clearMissing(let registration, let engine):
            if engine.isRunning {
                engine.pause()
            }
            registration.boundDeviceID = nil
            registration.boundDeviceUID = nil
            events.append(.failure(.noOutputDeviceAvailable))
        }
    }

    private func maintain(
        _ registration: RegisteredEngine,
        engine: AVAudioEngine,
        candidateUID: String,
        topology: String,
        events: inout [MonitorEvent]
    ) {
        registration.boundDeviceUID = candidateUID
        guard registration.intendedRunningState else {
            // The caller asked the engine to stay stopped. Do not restart it because it is still running,
            // and do not reset the cap in front of a start that this pass is about to attempt.
            return
        }
        if engine.isRunning {
            noteRecoverySuccess(registration)
            return
        }
        attemptStart(registration, engine: engine, candidateUID: candidateUID, topology: topology, events: &events)
    }

    private func attach(
        _ registration: RegisteredEngine,
        engine: AVAudioEngine,
        deviceID: AudioDeviceID,
        uid: String,
        topology: String,
        events: inout [MonitorEvent]
    ) {
        guard beginRecoveryAttempt(registration, candidateUID: uid, topology: topology, events: &events) else {
            return
        }

        if engine.isRunning {
            engine.pause()
        }

        do {
            try CoreAudioOutputDevices.bind(deviceID, to: engine, using: hal)
        } catch {
            noteRecoveryFailure(registration, error: error, operation: "bindOutputDevice", events: &events)
            return
        }

        registration.boundDeviceID = deviceID
        registration.boundDeviceUID = uid

        guard registration.intendedRunningState else {
            noteRecoverySuccess(registration)
            return
        }

        do {
            try engine.start()
            noteRecoverySuccess(registration)
        } catch {
            // Bind succeeded, so the stored ID now matches. Further attempts use the start-on-present path
            // and keep this epoch's counter. The cap is not cleared before this start failure.
            noteRecoveryFailure(registration, error: error, operation: "AVAudioEngine.start", events: &events)
        }
    }

    private func attemptStart(
        _ registration: RegisteredEngine,
        engine: AVAudioEngine,
        candidateUID: String,
        topology: String,
        events: inout [MonitorEvent]
    ) {
        guard beginRecoveryAttempt(registration, candidateUID: candidateUID, topology: topology, events: &events) else {
            return
        }
        do {
            try engine.start()
            noteRecoverySuccess(registration)
        } catch {
            noteRecoveryFailure(registration, error: error, operation: "AVAudioEngine.start", events: &events)
        }
    }

    private func beginRecoveryAttempt(
        _ registration: RegisteredEngine,
        candidateUID: String,
        topology: String,
        events: inout [MonitorEvent]
    ) -> Bool {
        let epoch = recoveryEpoch(candidateUID: candidateUID, topology: topology)
        if registration.recoveryEpoch != epoch {
            registration.recoveryEpoch = epoch
            registration.recoveryAttempts = 0
            registration.recoveryLimitEmitted = false
        }
        guard registration.recoveryAttempts < Self.maxRecoveryAttempts else {
            if !registration.recoveryLimitEmitted {
                registration.recoveryLimitEmitted = true
                events.append(.failure(.recoveryRetryLimitExceeded(registration.role)))
            }
            return false
        }
        return true
    }

    private func noteRecoverySuccess(_ registration: RegisteredEngine) {
        registration.recoveryAttempts = 0
        registration.recoveryLimitEmitted = false
    }

    private func noteRecoveryFailure(
        _ registration: RegisteredEngine,
        error: Error,
        operation: String,
        events: inout [MonitorEvent]
    ) {
        events.append(.failure(Self.coreAudioError(error, operation: operation)))
        registration.recoveryAttempts += 1
        if registration.recoveryAttempts >= Self.maxRecoveryAttempts && !registration.recoveryLimitEmitted {
            registration.recoveryLimitEmitted = true
            events.append(.failure(.recoveryRetryLimitExceeded(registration.role)))
        }
    }

    private func recoveryEpoch(candidateUID: String, topology: String) -> String {
        "\(topology.utf8.count):\(topology)|\(candidateUID.utf8.count):\(candidateUID)"
    }

    private func resolveInitialUID(
        explicitUID: String?,
        deviceID: AudioDeviceID?
    ) -> (uid: String?, events: [MonitorEvent]) {
        if let explicitUID {
            return (explicitUID, [])
        }
        guard let deviceID else {
            return (nil, [])
        }
        do {
            return (try hal.getDeviceUID(deviceID: deviceID), [])
        } catch {
            return (nil, [.failure(Self.coreAudioError(error, operation: "getDeviceUID"))])
        }
    }

    private static func coreAudioError(_ error: Error, operation: String) -> CoreAudioError {
        if let coreAudioError = error as? CoreAudioError {
            return coreAudioError
        }
        return .engineOperationFailed(operation: operation, message: String(describing: error))
    }
}
