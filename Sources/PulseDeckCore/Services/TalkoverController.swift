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
        stateLock.lock()
        let newTarget = !_isTargetActive
        stateLock.unlock()
        setTalkover(active: newTarget)
    }

    /// Sets talkover ducking state (idempotent for redundant target calls).
    public func setTalkover(active: Bool) {
        stateLock.lock()
        if _isTargetActive == active {
            // Already at endpoint target: no-op
            if active && _currentProgress >= 1.0 {
                stateLock.unlock()
                return
            }
            if !active && _currentProgress <= 0.0 {
                stateLock.unlock()
                return
            }
        }

        _isTargetActive = active
        _rampGeneration &+= 1
        let generation = _rampGeneration
        _rampTask?.cancel()
        _rampTask = nil
        _lastTickTimestamp = nil
        stateLock.unlock()

        startRampTask(generation: generation)
    }

    /// Immediately halts any running ramp task and resets talkover to neutral unity.
    public func cancelTalkover() {
        stateLock.lock()
        _rampGeneration &+= 1
        _isTargetActive = false
        _currentProgress = 0.0
        _rampTask?.cancel()
        _rampTask = nil
        _lastTickTimestamp = nil
        stateLock.unlock()

        applyCurrentValuesToGraphs()
        notifyStateChanged()
    }

    // MARK: - Deterministic Stepping & Offline Testing APIs

    /// Explicitly steps the talkover progress to a fixed normalized value in [0.0, 1.0].
    @discardableResult
    public func stepProgress(to progress: Double) -> TalkoverState {
        let clamped = progress.isFinite ? min(max(progress, 0.0), 1.0) : 0.0
        stateLock.lock()
        _currentProgress = clamped
        if clamped >= 1.0 {
            _isTargetActive = true
        } else if clamped <= 0.0 {
            _isTargetActive = false
        }
        let st = currentStateLocked()
        stateLock.unlock()

        applyCurrentValuesToGraphs()
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
        stateLock.lock()
        let previous = _lastTickTimestamp
        _lastTickTimestamp = timestampSeconds
        stateLock.unlock()

        let elapsed: Double
        if let previous, timestampSeconds >= previous {
            elapsed = timestampSeconds - previous
        } else {
            elapsed = 0.0
        }
        return advanceTimeInternal(deltaSeconds: elapsed, expectedGeneration: nil)
    }

    // MARK: - Internal Ramp Implementation

    @discardableResult
    private func advanceTimeInternal(deltaSeconds: Double, expectedGeneration: UInt64?) -> Bool {
        guard deltaSeconds.isFinite, deltaSeconds >= 0.0 else { return false }

        stateLock.lock()
        if let expected = expectedGeneration, expected != _rampGeneration {
            stateLock.unlock()
            return true // Outdated generation: stop task
        }

        let target = _isTargetActive
        let rate = 1.0 / Self.rampDurationSeconds
        let deltaProgress = deltaSeconds * rate

        if target {
            _currentProgress = min(1.0, _currentProgress + deltaProgress)
        } else {
            _currentProgress = max(0.0, _currentProgress - deltaProgress)
        }

        let isDone: Bool
        if target {
            isDone = _currentProgress >= 1.0
        } else {
            isDone = _currentProgress <= 0.0
        }
        stateLock.unlock()

        applyCurrentValuesToGraphs()
        notifyStateChanged()
        return isDone
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

    private func applyCurrentValuesToGraphs() {
        let mult = currentVolumeMultiplier
        let eq = currentEQGainDB

        deckA.applyTalkover(volumeMultiplier: mult, eqGainDB: eq)
        deckB.applyTalkover(volumeMultiplier: mult, eqGainDB: eq)
    }

    private func notifyStateChanged() {
        let st = state
        onStateChanged?(st)
    }
}
