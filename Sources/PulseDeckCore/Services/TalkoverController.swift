import Foundation
import AVFoundation

/// Talkover execution state.
public enum TalkoverState: Sendable, Equatable {
    case inactive
    case ducking(progress: Double)
    case active
    case restoring(progress: Double)

    /// True if talkover is engaged or ramping.
    public var isActive: Bool {
        switch self {
        case .inactive:
            return false
        case .ducking, .active, .restoring:
            return true
        }
    }

    /// Normalized progress from 0.0 (neutral unity) to 1.0 (fully ducked).
    public var progress: Double {
        switch self {
        case .inactive:
            return 0.0
        case .ducking(let p), .restoring(let p):
            return p
        case .active:
            return 1.0
        }
    }
}

/// Controller managing Master-only talkover attenuation and vocal pocket EQ.
///
/// ## Architectural Guarantees:
/// - Master-Only Isolation: Modulates Master deck audio graphs (`deckA` and `deckB`) only.
///   Cue engine, cue nodes, and preview playback remain strictly isolated and unaffected.
/// - Linear 800ms Ramp: Deterministically ramps volume multiplier to 0.15 and vocal-pocket EQ dip to -4.0 dB.
/// - Independent Composition: Multiplies independently with channel volumes and crossfader weights;
///   never captures or overwrites user fader or EQ intent.
/// - Smooth Reversal & Idempotence: Direction reversals mid-ramp proceed continuously from the current
///   progress without audio discontinuities or pops. Duplicate toggle/keyDown events are safely ignored.
/// - Lifecycle Cleanliness: Cancelling or tearing down the coordinator halts background ramp tasks immediately.
public final class TalkoverController: @unchecked Sendable {

    /// Standard ramp duration in seconds (800 ms).
    public static let rampDurationSeconds: Double = 0.8

    /// Attenuation multiplier when fully ducked (15% Master volume = 0.15 linear gain).
    public static let duckedVolumeMultiplier: Float = 0.15

    /// Vocal-pocket EQ dip in dB when fully ducked (-4.0 dB across 300 Hz–3 kHz).
    public static let duckedEQGainDB: Float = -4.0

    /// Center frequency in Hz of the broad vocal-pocket parametric EQ filter (geometric mean of 300 Hz and 3000 Hz).
    public static let vocalPocketCenterHz: Float = 948.683

    /// Bandwidth in octaves covering the decade from 300 Hz to 3000 Hz (log2(10) ≈ 3.32 octaves).
    public static let vocalPocketBandwidthOctaves: Float = 3.3219

    private let deckA: any DeckAudioGraphContract
    private let deckB: any DeckAudioGraphContract
    private weak var monitor: OutputDeviceMonitor?

    /// Installed before test operations; pauses a selected application before graph mutation.
    var beforeGraphApplicationForTesting: (@Sendable () -> Void)?

    private let fallbackQueue = DispatchQueue(label: "com.pulsedeck.talkover.control")
    private let fallbackQueueKey = DispatchSpecificKey<UInt8>()
    private static let fallbackQueueToken: UInt8 = 1
    private let stateLock = NSLock()
    private var _isTargetActive: Bool = false
    private var _currentProgress: Double = 0.0
    private var _rampGeneration: UInt64 = 0
    private var _rampTask: Task<Void, Never>?
    private var _lastTickTimestamp: Double?

    /// Callback invoked whenever talkover state or progress changes.
    public var onStateChanged: (@Sendable (TalkoverState) -> Void)?

    /// Initializes a new talkover controller attached to the two deck graphs.
    public init(
        deckA: any DeckAudioGraphContract,
        deckB: any DeckAudioGraphContract,
        monitor: OutputDeviceMonitor? = nil
    ) {
        self.deckA = deckA
        self.deckB = deckB
        self.monitor = monitor
        fallbackQueue.setSpecific(key: fallbackQueueKey, value: Self.fallbackQueueToken)
    }

    deinit {
        _rampTask?.cancel()
    }

    // MARK: - State Properties

    /// True if talkover is target-active or currently ducked/ramping.
    public var isTalkoverActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isTargetActive || _currentProgress > 0.0
    }

    /// Target active intent (true if toggle is ON).
    public var isTargetActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isTargetActive
    }

    /// True if talkover has reached full 800ms ducking.
    public var isFullyDucked: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentProgress >= 1.0
    }

    /// Current normalized progress between 0.0 (neutral) and 1.0 (fully ducked).
    public var currentProgress: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentProgress
    }

    /// Current Master volume attenuation multiplier (1.0 = unity, 0.15 = ducked).
    public var currentVolumeMultiplier: Float {
        let p = currentProgress
        return Float(1.0 - (1.0 - Double(Self.duckedVolumeMultiplier)) * p)
    }

    /// Current vocal pocket EQ gain dip in dB (0.0 dB = neutral, -4.0 dB = ducked).
    public var currentEQGainDB: Float {
        let p = currentProgress
        return Float(Double(Self.duckedEQGainDB) * p)
    }

    /// Current high-level talkover state.
    public var state: TalkoverState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentStateLocked()
    }

    private func currentStateLocked() -> TalkoverState {
        if _currentProgress <= 0.0 && !_isTargetActive {
            return .inactive
        } else if _currentProgress >= 1.0 && _isTargetActive {
            return .active
        } else if _isTargetActive {
            return .ducking(progress: _currentProgress)
        } else {
            return .restoring(progress: _currentProgress)
        }
    }

    // MARK: - Public Control Interface

    /// Toggles talkover ducking state.
    public func toggleTalkover() {
        executeOnControlQueue {
            self.setTalkover(active: !self.isTargetActive)
        }
    }

    /// Sets talkover ducking state (idempotent for redundant target calls).
    public func setTalkover(active: Bool) {
        executeOnControlQueue {
            self.stateLock.lock()
            if self._isTargetActive == active {
                // Already at endpoint target: no-op
                if active && self._currentProgress >= 1.0 {
                    self.stateLock.unlock()
                    return
                }
                if !active && self._currentProgress <= 0.0 {
                    self.stateLock.unlock()
                    return
                }
            }

            self._isTargetActive = active
            self._rampGeneration &+= 1
            let generation = self._rampGeneration
            self._rampTask?.cancel()
            self._rampTask = nil
            self._lastTickTimestamp = nil
            self.stateLock.unlock()

            // Publish the replacement task before another control operation can cancel it.
            self.startRampTask(generation: generation)
        }
    }

    /// Immediately halts any running ramp task and resets talkover to neutral unity.
    public func cancelTalkover() {
        executeOnControlQueue {
            self.stateLock.lock()
            self._rampGeneration &+= 1
            self._isTargetActive = false
            self._currentProgress = 0.0
            self._rampTask?.cancel()
            self._rampTask = nil
            self._lastTickTimestamp = nil
            self.stateLock.unlock()

            self.applyCurrentValuesToGraphs()
        }
        notifyStateChanged()
    }

    // MARK: - Deterministic Stepping & Offline Testing APIs

    /// Explicitly steps the talkover progress to a fixed normalized value in [0.0, 1.0].
    @discardableResult
    public func stepProgress(to progress: Double) -> TalkoverState {
        let clamped = progress.isFinite ? min(max(progress, 0.0), 1.0) : 0.0
        let st = executeOnControlQueue {
            self.stateLock.lock()
            self._currentProgress = clamped
            if clamped >= 1.0 {
                self._isTargetActive = true
            } else if clamped <= 0.0 {
                self._isTargetActive = false
            }
            let st = self.currentStateLocked()
            self.stateLock.unlock()

            self.applyCurrentValuesToGraphs()
            return st
        }
        notifyStateChanged()
        return st
    }

    /// Advances the talkover ramp by the given time delta in seconds (deterministic offline testing).
    ///
    /// - Parameter deltaSeconds: Time step in seconds.
    /// - Returns: True if the target endpoint has been reached.
    @discardableResult
    public func advanceTime(deltaSeconds: Double) -> Bool {
        advanceTimeInternal(deltaSeconds: deltaSeconds, expectedGeneration: nil)
    }

    /// Ticks the talkover ramp at a specific monotonic timestamp in seconds.
    ///
    /// - Parameter timestampSeconds: Monotonic time in seconds.
    /// - Returns: True if the target endpoint has been reached.
    @discardableResult
    public func tick(at timestampSeconds: Double) -> Bool {
        guard timestampSeconds.isFinite else { return false }
        let (elapsed, generation) = executeOnControlQueue {
            self.stateLock.lock()
            let previous = self._lastTickTimestamp
            self._lastTickTimestamp = timestampSeconds
            let generation = self._rampGeneration
            self.stateLock.unlock()
            let elapsed = previous.map { max(0.0, timestampSeconds - $0) } ?? 0.0
            return (elapsed, generation)
        }
        return advanceTimeInternal(deltaSeconds: elapsed, expectedGeneration: generation)
    }

    // MARK: - Internal Ramp Implementation

    @discardableResult
    private func advanceTimeInternal(deltaSeconds: Double, expectedGeneration: UInt64?) -> Bool {
        guard deltaSeconds.isFinite, deltaSeconds >= 0.0 else { return false }
        stateLock.lock()
        let generation = expectedGeneration ?? _rampGeneration
        stateLock.unlock()
        // A paused/cancelled tick must still validate its generation inside the
        // same serialized operation that writes both graphs.
        beforeGraphApplicationForTesting?()
        let result = executeOnControlQueue { () -> (done: Bool, applied: Bool) in
            self.stateLock.lock()
            guard generation == self._rampGeneration else {
                self.stateLock.unlock()
                return (true, false) // Outdated generation: stop task
            }
            let target = self._isTargetActive
            let deltaProgress = deltaSeconds / Self.rampDurationSeconds
            if target {
                self._currentProgress = min(1.0, self._currentProgress + deltaProgress)
            } else {
                self._currentProgress = max(0.0, self._currentProgress - deltaProgress)
            }
            let isDone = target ? self._currentProgress >= 1.0 : self._currentProgress <= 0.0
            self.stateLock.unlock()

            self.applyCurrentValuesToGraphs()
            return (isDone, true)
        }
        if result.applied {
            notifyStateChanged()
        }
        return result.done
    }

    private func startRampTask(generation: UInt64) {
        _rampTask = Task { [weak self] in
            let clock = ContinuousClock()
            var lastInstant = clock.now

            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 20_000_000) // 20ms steps
                } catch {
                    return
                }

                guard !Task.isCancelled, let self else { return }

                let currentInstant = clock.now
                let duration = currentInstant - lastInstant
                lastInstant = currentInstant

                let elapsedSeconds = Double(duration.components.seconds) +
                    Double(duration.components.attoseconds) / 1e18

                let isDone = self.advanceTimeInternal(
                    deltaSeconds: elapsedSeconds,
                    expectedGeneration: generation
                )

                if isDone {
                    break
                }
            }
        }
    }

    /// Called only inside the controller's serialized control operation.
    private func applyCurrentValuesToGraphs() {
        let progress = currentProgress
        let mult = Float(1.0 - (1.0 - Double(Self.duckedVolumeMultiplier)) * progress)
        let eq = Float(Double(Self.duckedEQGainDB) * progress)
        deckA.applyTalkover(volumeMultiplier: mult, eqGainDB: eq)
        deckB.applyTalkover(volumeMultiplier: mult, eqGainDB: eq)
    }

    private func executeOnControlQueue<T: Sendable>(_ body: () throws -> T) rethrows -> T {
        if let monitor {
            return try monitor.performOnControlQueue(body)
        }
        if DispatchQueue.getSpecific(key: fallbackQueueKey) == Self.fallbackQueueToken {
            return try body()
        }
        return try fallbackQueue.sync(execute: body)
    }

    private func notifyStateChanged() {
        let st = state
        onStateChanged?(st)
    }
}
