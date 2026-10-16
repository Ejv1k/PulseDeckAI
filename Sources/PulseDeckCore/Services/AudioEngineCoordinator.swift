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

    public let monitor: OutputDeviceMonitor
    private let hal: AudioHardwareInterface
    private let stateLock = NSLock()

    private var _latencyCompensation: LatencyCompensation = LatencyCompensation(offsetMs: 0.0)

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

    // MARK: - Lifecycle Controls

    /// Starts both audio engines and activates hardware monitoring.
    public func start() throws {
        var monitorStarted = false
        var masterStarted = false
        do {
            try monitor.start()
            monitorStarted = true

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

    /// Pauses audio output rendering on both engines without resetting graphs.
    public func pause() {
        masterAudioEngine.pause()
        cueAudioEngine.pause()
    }

    /// Stops audio rendering, resets player positions and filters, and halts monitoring.
    public func stop() {
        deckAGraph.pause()
        deckBGraph.pause()
        cuePreview.stop()

        masterAudioEngine.stop()
        cueAudioEngine.stop()
        monitor.stop()
    }

    // MARK: - Crossfader Macro Routing

    /// Updates crossfader weighting across Deck A and Deck B.
    ///
    /// - Parameter position: Bipolar crossfader position from 0.0 (full Deck A) to 1.0 (full Deck B).
    ///   Center position (0.5) delivers full unity gain on both decks.
    public func setCrossfader(position: Float) {
        let safePos = position.isFinite ? min(max(position, 0.0), 1.0) : 0.5
        let weightA: Float = safePos <= 0.5 ? 1.0 : (1.0 - safePos) * 2.0
        let weightB: Float = safePos >= 0.5 ? 1.0 : safePos * 2.0

        deckAGraph.crossfaderWeight = weightA
        deckBGraph.crossfaderWeight = weightB
    }
}
