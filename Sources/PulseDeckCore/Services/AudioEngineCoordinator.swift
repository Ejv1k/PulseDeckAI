import Foundation
import AVFoundation
import CoreAudio

/// Master coordinator managing dual independent output engines, deck audio graphs, and CoreAudio hardware binding.
///
/// Conforms to `AudioEngineCoordinatorContract`.
///
/// ## Architectural Guarantees:
/// - True Dual Output: Manages decoupled `masterEngine` (FOH sound) and `cueEngine` (headphones preview).
/// - Complete Node Isolation: Absolutely no `AVAudioNode` instance is shared between engines.
/// - Output-Only Boundary: Absolutely no access to `engine.inputNode`.
/// - Serialized Control Plane: Engine starts, pauses, stops, and hardware rebinds are serialized on
///   the `OutputDeviceMonitor` control queue (`com.pulsedeck.audio.control`).
/// - Real Positive Latency Compensation: Automatically routes positive delay to whichever output path is ahead
///   within the strictly bounded `[-300ms, +300ms]` range.
public final class AudioEngineCoordinator: AudioEngineCoordinatorContract, @unchecked Sendable {

    public let masterAudioEngine: OutputAudioEngine
    public let cueAudioEngine: OutputAudioEngine

    public let deckAGraph: DeckAudioGraph
    public let deckBGraph: DeckAudioGraph
    public let cuePreview: CuePreviewPlayer
    public let talkoverController: TalkoverController
    public let soundboardController: SoundboardController

    public let monitor: OutputDeviceMonitor
    private let hal: AudioHardwareInterface
    private let stateLock = NSLock()

    private var _latencyCompensation: LatencyCompensation = LatencyCompensation(offsetMs: 0.0)
    private var _crossfaderPosition: Float = 0.5
    private var _transitionExecutionService: TransitionExecutionService?

    /// Lazily initialized transition execution service governing automated transitions.
    public var transitionExecutionService: TransitionExecutionService {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let existing = _transitionExecutionService {
            return existing
        }
        let created = TransitionExecutionService(coordinator: self)
        _transitionExecutionService = created
        return created
    }

    /// Initializes the dual-engine coordinator with full CoreAudio HAL and monitor integration.
    ///
    /// - Parameters:
    ///   - hal: CoreAudio HAL interface (defaults to `SystemAudioHardware.shared`).
    ///   - coalescingDelayMs: Coalescing delay in milliseconds for rapid CoreAudio hardware notifications.
    public init(
        hal: AudioHardwareInterface = SystemAudioHardware.shared,
        coalescingDelayMs: Int = 50
    ) {
        self.hal = hal

        // Initialize device monitor with serialized control queue
        let monitorInstance = OutputDeviceMonitor(
            hal: hal,
            coalescingDelayMs: coalescingDelayMs
        )
        self.monitor = monitorInstance

        // Initialize Master and Cue output engines
        let master = OutputAudioEngine(role: .master, monitor: monitorInstance, hal: hal)
        let cue = OutputAudioEngine(role: .cue, monitor: monitorInstance, hal: hal)
        self.masterAudioEngine = master
        self.cueAudioEngine = cue

        // Register engines with the monitor for automatic hotplug recovery
        monitorInstance.registerEngine(master.rawEngine, role: .master)
        monitorInstance.registerEngine(cue.rawEngine, role: .cue)

        // Initialize Deck Graphs
        self.deckAGraph = DeckAudioGraph(
            deckId: .deckA,
            masterEngine: master,
            cueEngine: cue,
            monitor: monitorInstance
        )
        self.deckBGraph = DeckAudioGraph(
            deckId: .deckB,
            masterEngine: master,
            cueEngine: cue,
            monitor: monitorInstance
        )

        // Initialize independent Cue Preview Player
        self.cuePreview = CuePreviewPlayer(cueEngine: cue, monitor: monitorInstance)

        // Initialize Master-only Talkover Controller
        self.talkoverController = TalkoverController(
            deckA: self.deckAGraph,
            deckB: self.deckBGraph,
            monitor: monitorInstance
        )

        // Initialize Master-only Soundboard Controller
        self.soundboardController = SoundboardController(
            masterEngine: master,
            monitor: monitorInstance
        )
    }

    // MARK: - AudioEngineCoordinatorContract Conformance

    public var masterEngine: AudioEngineContract {
        masterAudioEngine
    }

    public var cueEngine: AudioEngineContract {
        cueAudioEngine
    }

    public var deckA: DeckAudioGraphContract {
        deckAGraph
    }

    public var deckB: DeckAudioGraphContract {
        deckBGraph
    }

    public var isTalkoverActive: Bool {
        talkoverController.isTalkoverActive
    }

    public func toggleTalkover() {
        talkoverController.toggleTalkover()
    }

    public func setTalkover(active: Bool) {
        talkoverController.setTalkover(active: active)
    }

    public var latencyCompensation: LatencyCompensation {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _latencyCompensation
        }
        set {
            let safe = LatencyCompensation(offsetMs: newValue.offsetMs)
            stateLock.lock()
            _latencyCompensation = safe
            stateLock.unlock()

            // Apply calculated positive path delays
            masterAudioEngine.setPathDelay(delayMs: safe.masterDelayMs)
            cueAudioEngine.setPathDelay(delayMs: safe.cueDelayMs)
        }
    }

    public func enumerateOutputDevices() -> [AudioDeviceDescriptor] {
        (try? CoreAudioOutputDevices.enumerate(using: hal)) ?? []
    }

    public func handleDeviceConfigurationChange() {
        monitor.reconcileImmediately()
    }

    /// Observes output device topology changes on the monitor callback queue.
    public var onDevicesChanged: (@Sendable () -> Void)? {
        get { monitor.onTopologyChange }
        set { monitor.onTopologyChange = newValue }
    }

    /// Observes monitor/hardware errors on the monitor callback queue.
    public var onDeviceError: (@Sendable (CoreAudioError) -> Void)? {
        get { monitor.onMonitorError }
        set { monitor.onMonitorError = newValue }
    }

    /// Resolves the currently bound output device descriptor for an engine role, or nil if missing/unbound.
    public func boundDevice(for role: AudioEngineRole) -> AudioDeviceDescriptor? {
        let engine = (role == .master) ? masterAudioEngine : cueAudioEngine
        guard let boundUID = monitor.boundDeviceUID(for: role) else {
            return nil
        }
        if let current = engine.currentDevice, current.id == boundUID {
            return current
        }
        let devices = enumerateOutputDevices()
        return devices.first(where: { $0.id == boundUID })
    }

    /// True if the engine for this role is currently routed to a fallback device rather than its desired target.
    public func isFallbackActive(for role: AudioEngineRole) -> Bool {
        guard let desired = monitor.desiredDeviceUID(for: role) else {
            return false
        }
        guard let bound = monitor.boundDeviceUID(for: role) else {
            return true
        }
        return desired != bound
    }

    /// Routes the specified engine role to a physical output device by UID.
    public func setOutputDevice(role: AudioEngineRole, uid: String) throws {
        switch role {
        case .master:
            try masterAudioEngine.setOutputDevice(id: uid)
        case .cue:
            try cueAudioEngine.setOutputDevice(id: uid)
        }
    }

    // MARK: - Lifecycle Controls

    /// Starts both audio engines and activates hardware monitoring.
    public func start() throws {
        try monitor.performOnControlQueue {
            // Rollback and normal shutdown remove registrations. Restore them before reconciliation;
            // currentDevice records the last explicit preference, not a recovered fallback binding.
            monitor.ensureEngineRegistration(masterAudioEngine.rawEngine, role: .master,
                                             desiredDeviceUID: masterAudioEngine.currentDevice?.id)
            monitor.ensureEngineRegistration(cueAudioEngine.rawEngine, role: .cue,
                                             desiredDeviceUID: cueAudioEngine.currentDevice?.id)
            var monitorStarted = false
            var masterStarted = false
            do {
                try monitor.start()
                monitorStarted = true

                monitor.reconcileImmediately()

                try masterAudioEngine.start()
                masterStarted = true

                try cueAudioEngine.start()
            } catch {
                if masterStarted {
                    masterAudioEngine.stop()
                }
                cueAudioEngine.stop()
                if monitorStarted {
                    monitor.stop()
                }
                throw error
            }
        }
    }

    /// Pauses audio output rendering on both engines without resetting graphs.
    public func pause() {
        masterAudioEngine.pause()
        cueAudioEngine.pause()
    }

    /// Stops audio rendering, resets player positions and filters, and halts monitoring.
    public func stop() {
        talkoverController.cancelTalkover()
        soundboardController.stopAllPads()

        deckAGraph.pause()
        deckBGraph.pause()
        cuePreview.stop()

        masterAudioEngine.stop()
        cueAudioEngine.stop()
        monitor.stop()
    }

    // MARK: - Crossfader Macro Routing

    /// Current crossfader position from 0.0 (full Deck A) to 1.0 (full Deck B).
    public var crossfaderPosition: Float {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _crossfaderPosition
        }
        set {
            setCrossfader(position: newValue)
        }
    }

    /// Updates crossfader weighting across Deck A and Deck B.
    ///
    /// - Parameter position: Bipolar crossfader position from 0.0 (full Deck A) to 1.0 (full Deck B).
    ///   Center position (0.5) delivers full unity gain on both decks.
    public func setCrossfader(position: Float) {
        let safePos = position.isFinite ? min(max(position, 0.0), 1.0) : 0.5
        stateLock.lock()
        _crossfaderPosition = safePos
        stateLock.unlock()

        let weightA: Float = safePos <= 0.5 ? 1.0 : (1.0 - safePos) * 2.0
        let weightB: Float = safePos >= 0.5 ? 1.0 : safePos * 2.0

        deckAGraph.crossfaderWeight = weightA
        deckBGraph.crossfaderWeight = weightB
    }
}
