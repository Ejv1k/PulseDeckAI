import Foundation
import AVFoundation
import CoreAudio

/// Production implementation of an output-only audio engine conforming to `AudioEngineContract`.
///
/// ## Safety Invariants:
/// - Strictly Output-Only: Absolutely NEVER calls or accesses `rawEngine.inputNode`.
/// - Independent Audio Graph: Owns its internal `AVAudioEngine`, `AVAudioMixerNode`, and `AVAudioUnitDelay`.
///   Never shares any `AVAudioNode` instance across engine boundaries.
/// - Serialized Control Plane: Starts, pauses, stops, and hardware device bindings are serialized on
///   the `OutputDeviceMonitor` control queue (`com.pulsedeck.audio.control`).
/// - Latency Delay Injection: Real positive path delay is injected via an `AVAudioUnitDelay` node
///   configured with 100% wet mix, 0% feedback, and neutral 20kHz lowpass filter cutoff.
public final class OutputAudioEngine: AudioEngineContract, @unchecked Sendable {

    public let role: AudioEngineRole
    public let rawEngine: AVAudioEngine
    public let subMixer: AVAudioMixerNode
    public let delayNode: AVAudioUnitDelay

    private let hal: AudioHardwareInterface
    private weak var monitor: OutputDeviceMonitor?
    private let stateLock = NSLock()

    private var _currentDevice: AudioDeviceDescriptor?
    private var _currentPathDelayMs: Double = 0.0
    private var _lastReportedHardwareLatencyMs: Double = 0.0

    /// Presentation latency query closure used by tests to simulate non-zero output node latency.
    public var presentationLatencyProviderForTesting: (@Sendable () throws -> Double)?

    /// Hook for simulating engine start failure during unit testing.
    public var startErrorForTesting: (any Error)?

    /// Initializes a new output-only audio engine with an isolated audio graph.
    ///
    /// - Parameters:
    ///   - role: Architectural role (`.master` or `.cue`).
    ///   - monitor: Optional device monitor used for serialized control synchronization.
    ///   - hal: Injected CoreAudio HAL abstraction (defaults to `SystemAudioHardware.shared`).
    public init(
        role: AudioEngineRole,
        monitor: OutputDeviceMonitor? = nil,
        hal: AudioHardwareInterface = SystemAudioHardware.shared
    ) {
        self.role = role
        self.monitor = monitor
        self.hal = hal
        self.rawEngine = AVAudioEngine()
        self.subMixer = AVAudioMixerNode()
        self.delayNode = AVAudioUnitDelay()

        setupGraph()
    }

    private func setupGraph() {
        // Output-only: attach nodes exclusively to the output tree.
        rawEngine.attach(subMixer)
        rawEngine.attach(delayNode)

        // Initialize delay node with neutral bypassed settings.
        delayNode.bypass = true
        delayNode.wetDryMix = 0.0
        delayNode.delayTime = 0.0
        delayNode.feedback = 0.0
        delayNode.lowPassCutoff = 20000.0

        // Connect subMixer -> delayNode -> mainMixerNode.
        rawEngine.connect(subMixer, to: delayNode, format: nil)
        rawEngine.connect(delayNode, to: rawEngine.mainMixerNode, format: nil)
    }

    // MARK: - AudioEngineContract Properties

    public var currentDevice: AudioDeviceDescriptor? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentDevice
    }

    /// True if the underlying audio engine is currently running.
    public var isRunning: Bool {
        rawEngine.isRunning
    }

    public var hardwareLatencyMs: Double {
        stateLock.lock()
        defer { stateLock.unlock() }

        // Return 0 only when no device is bound.
        guard _currentDevice != nil else {
            return 0.0
        }

        if let provider = presentationLatencyProviderForTesting {
            do {
                let seconds = try provider()
                let ms = seconds * 1000.0
                _lastReportedHardwareLatencyMs = ms
                return ms
            } catch {
                // If query fails after a device is bound, keep the last reported value and surface the error.
                if let coreError = error as? CoreAudioError {
                    monitor?.reportError(coreError)
                } else {
                    monitor?.reportError(CoreAudioError.osStatus(OSStatus(-1), operation: "presentationLatency"))
                }
                return _lastReportedHardwareLatencyMs
            }
        }

        let latencySeconds = rawEngine.outputNode.presentationLatency
        if latencySeconds.isFinite && latencySeconds >= 0.0 {
            let ms = latencySeconds * 1000.0
            _lastReportedHardwareLatencyMs = ms
            return ms
        } else {
            return _lastReportedHardwareLatencyMs
        }
    }

    /// Current real positive path delay in milliseconds injected into this engine graph.
    public var currentPathDelayMs: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentPathDelayMs
    }

    // MARK: - Path Latency Compensation

    /// Sets the positive real path delay in milliseconds on the internal delay node.
    ///
    /// - Parameter delayMs: Delay duration in milliseconds (clamped between 0.0 ms and 300.0 ms).
    public func setPathDelay(delayMs: Double) {
        let safeDelayMs: Double
        if delayMs.isFinite {
            safeDelayMs = min(max(delayMs, 0.0), 300.0)
        } else {
            safeDelayMs = 0.0
        }

        executeOnControlQueue {
            self.stateLock.lock()
            self._currentPathDelayMs = safeDelayMs
            self.stateLock.unlock()

            if safeDelayMs > 0.0 {
                self.delayNode.bypass = false
                self.delayNode.wetDryMix = 100.0
                self.delayNode.feedback = 0.0
                self.delayNode.lowPassCutoff = 20000.0
                self.delayNode.delayTime = safeDelayMs / 1000.0
            } else {
                self.delayNode.bypass = true
                self.delayNode.wetDryMix = 0.0
                self.delayNode.delayTime = 0.0
            }
        }
    }

    // MARK: - AudioEngineContract Methods

    public func start() throws {
        try executeOnControlQueue {
            if let error = self.startErrorForTesting {
                throw error
            }
            guard !self.rawEngine.isRunning else { return }
            try self.rawEngine.start()
            self.monitor?.setIntendedRunningState(for: self.rawEngine, running: true)
        }
    }

    public func pause() {
        executeOnControlQueue {
            self.monitor?.setIntendedRunningState(for: self.rawEngine, running: false)
            guard self.rawEngine.isRunning else { return }
            self.rawEngine.pause()
        }
    }

    public func stop() {
        executeOnControlQueue {
            self.rawEngine.stop()
            self.delayNode.reset()
            self.subMixer.reset()
            self.monitor?.setIntendedRunningState(for: self.rawEngine, running: false)
        }
    }

    public func setOutputDevice(id: String) throws {
        try executeOnControlQueue {
            guard let targetID = try CoreAudioOutputDevices.deviceID(forUID: id, using: self.hal) else {
                throw CoreAudioError.deviceNotFound(id)
            }

            guard let descriptor = try CoreAudioOutputDevices.descriptor(for: targetID, using: self.hal) else {
                throw CoreAudioError.notAnOutputDevice(targetID)
            }

            let wasRunning = self.rawEngine.isRunning
            if wasRunning {
                self.rawEngine.pause()
            }

            do {
                try CoreAudioOutputDevices.bind(targetID, to: self.rawEngine, using: self.hal)

                self.stateLock.lock()
                self._currentDevice = descriptor
                self.stateLock.unlock()

                if let monitor = self.monitor {
                    monitor.setBoundDevice(for: self.rawEngine, deviceID: targetID, uid: descriptor.id, desiredUID: descriptor.id)
                }

                if wasRunning {
                    try self.rawEngine.start()
                }
            } catch {
                if wasRunning {
                    do {
                        try self.rawEngine.start()
                    } catch {
                        self.monitor?.setIntendedRunningState(for: self.rawEngine, running: false)
                    }
                }
                throw error
            }
        }
    }

    // MARK: - Control Queue Dispatch

    private func executeOnControlQueue<T: Sendable>(_ block: @Sendable () throws -> T) rethrows -> T {
        if let monitor = self.monitor {
            return try monitor.performOnControlQueue(block)
        } else {
            return try block()
        }
    }
}
