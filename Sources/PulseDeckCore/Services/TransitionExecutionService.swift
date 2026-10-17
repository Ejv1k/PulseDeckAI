import Foundation
import AVFoundation

// MARK: - Transition Execution State

/// Observable lifecycle state of the transition execution service.
public enum TransitionExecutionState: Sendable, Equatable {
    /// Service is idle with no active transition and no armed AutoPilot.
    case idle

    /// Backend AutoPilot is armed with a validated pending request, awaiting the mixOutCue.
    case armed(request: TransitionRequest, triggerPosition: Double)

    /// A transition is actively rendering automation commands across the decks.
    case inProgress(style: TransitionStyle, progress: Double)

    /// The active transition completed all scheduled events and reached duration end.
    case completed

    /// The transition was aborted early with emergency recovery applied.
    case cancelled
}

// MARK: - Transition Execution Snapshot

/// Immutable telemetry snapshot of the transition execution subsystem.
public struct TransitionExecutionSnapshot: Sendable, Equatable {
    /// Current execution lifecycle state.
    public let state: TransitionExecutionState

    /// The active transition plan being executed, or nil if idle/armed.
    public let activePlan: TransitionPlan?

    /// Normalized progress of active transition from 0.0 to 1.0.
    public let progress: Double

    /// Outgoing deck identifier, if active or armed.
    public let outgoingDeck: DeckIdentifier?

    /// Incoming deck identifier, if active or armed.
    public let incomingDeck: DeckIdentifier?

    /// Current playhead position in seconds along the outgoing track timeline.
    public let currentPlayheadSeconds: Double?

    /// Count of discrete scheduled commands executed so far.
    public let executedEventCount: Int

    /// Count of discrete scheduled commands remaining in the active plan.
    public let remainingEventCount: Int

    /// True if backend AutoPilot is armed and awaiting mixOutCue trigger.
    public let isAutoPilotArmed: Bool

    /// Pending transition request held by armed AutoPilot.
    public let armedRequest: TransitionRequest?

    /// Current execution generation/epoch counter.
    public let generation: UInt64

    public init(
        state: TransitionExecutionState,
        activePlan: TransitionPlan? = nil,
        progress: Double = 0.0,
        outgoingDeck: DeckIdentifier? = nil,
        incomingDeck: DeckIdentifier? = nil,
        currentPlayheadSeconds: Double? = nil,
        executedEventCount: Int = 0,
        remainingEventCount: Int = 0,
        isAutoPilotArmed: Bool = false,
        armedRequest: TransitionRequest? = nil,
        generation: UInt64 = 0
    ) {
        self.state = state
        self.activePlan = activePlan
        self.progress = progress
        self.outgoingDeck = outgoingDeck
        self.incomingDeck = incomingDeck
        self.currentPlayheadSeconds = currentPlayheadSeconds
        self.executedEventCount = executedEventCount
        self.remainingEventCount = remainingEventCount
        self.isAutoPilotArmed = isAutoPilotArmed
        self.armedRequest = armedRequest
        self.generation = generation
    }
}

// MARK: - Transition Execution Service Errors

/// Domain-specific errors thrown by the transition execution service.
public enum TransitionExecutionServiceError: LocalizedError, Sendable, Equatable {
    case trackNotLoaded(DeckIdentifier)
    case trackMismatch(deck: DeckIdentifier, expectedDuration: Double, actualDuration: Double)
    case transitionAlreadyInProgress
    case noTransitionInProgress
    case invalidRequest(String)
    case deckPlaybackNotActive(DeckIdentifier)
    case rateMismatch(expected: Float, actual: Float)
    case playheadPastTrigger(current: Double, trigger: Double)
    case nonFinitePlayhead(Double)
    case incompatibleCrossfaderRouting(deck: DeckIdentifier, crossfaderPosition: Float)

    public var errorDescription: String? {
        switch self {
        case .trackNotLoaded(let deck):
            return "No track is loaded on \(deck.rawValue) to execute transition."
        case .trackMismatch(let deck, let expected, let actual):
            return "Track duration mismatch on \(deck.rawValue): expected \(expected)s, actual \(actual)s."
        case .transitionAlreadyInProgress:
            return "A transition is already in progress. Cancel it before starting a new transition."
        case .noTransitionInProgress:
            return "No transition is currently in progress."
        case .invalidRequest(let reason):
            return "Invalid transition request: \(reason)"
        case .deckPlaybackNotActive(let deck):
            return "Playback on \(deck.rawValue) is not active."
        case .rateMismatch(let expected, let actual):
            return "Playback rate mismatch: expected \(expected)x, live deck rate is \(actual)x."
        case .playheadPastTrigger(let current, let trigger):
            return "Current playhead \(current)s is already past trigger position \(trigger)s."
        case .nonFinitePlayhead(let val):
            return "Playhead position must be finite, got: \(val)"
        case .incompatibleCrossfaderRouting(let deck, let crossfaderPosition):
            return "Incompatible crossfader routing: outgoing deck \(deck.rawValue) is muted at crossfader position \(crossfaderPosition)."
        }
    }
}

// MARK: - AutoPilot One-Shot Identity Key

private struct AutoPilotFiredKey: Hashable, Sendable {
    let deck: DeckIdentifier
    let generation: UInt64
}

// MARK: - Transition Execution Service

/// Production Swift 6 actor coordinating real-time automated DJ transitions and backend AutoPilot.
///
/// ## Architectural Guarantees:
/// - Actor Isolation: All mutable state machine, plan, driver task, and armed AutoPilot data are isolated within this actor.
/// - Deterministic Command Order: Executes discrete audio commands mapped deterministically via `TransitionStateMachine`.
/// - Exhaustive Command Mapping: Maps all commands (`setVolume`, `setEQ`, `setFilter`, `setRate`, `setEcho`, `seek`, `play`, `pause`, `stop`).
/// - Real Beat & Engine Time: Drives execution using outgoing player playhead derived from `AVAudioPlayerNode.playerTime`.
/// - Generation / Epoch Invalidation: Invalidates active plans or pending AutoPilot when outgoing rate, track, or transport changes.
/// - One-Shot AutoPilot: Fires exactly once per track generation when playhead reaches `mixOutCue`; no retry loops.
/// - Safe Recovery: Cancellation restores full unity volume and neutral DSP to outgoing deck while muting and stopping incoming deck.
public actor TransitionExecutionService {

    private let coordinator: AudioEngineCoordinatorContract
    private let planner: TransitionPlanner

    private var state: TransitionExecutionState = .idle
    private var stateMachine: TransitionStateMachine?
    private var activePlan: TransitionPlan?

    private var armedRequest: TransitionRequest?
    private var armedTriggerPosition: Double?

    private var executionGeneration: UInt64 = 0
    private var initialOutgoingRate: Float = 1.0
    private var lastObservedDeckGeneration: [DeckIdentifier: UInt64] = [:]
    private var autoPilotFiredHistory: Set<AutoPilotFiredKey> = []
    private var initialCrossfaderPosition: Float?

    private var driverTask: Task<Void, Never>?
    private var lastTickedPosition: Double?

    /// Initializes a new `TransitionExecutionService`.
    ///
    /// - Parameters:
    ///   - coordinator: Audio engine coordinator governing dual engines and deck audio graphs.
    ///   - planner: Deterministic transition planner instance.
    public init(
        coordinator: AudioEngineCoordinatorContract,
        planner: TransitionPlanner = TransitionPlanner()
    ) {
        self.coordinator = coordinator
        self.planner = planner
    }

    deinit {
        driverTask?.cancel()
    }

    // MARK: - Public Observables

    /// Telemetry snapshot of the transition execution service.
    public var snapshot: TransitionExecutionSnapshot {
        currentSnapshot()
    }

    /// Fetches the current telemetry snapshot.
    public func currentSnapshot() -> TransitionExecutionSnapshot {
        let outDeck = activePlan?.outgoingDeck ?? armedRequest?.outgoingTrack.deck
        let inDeck = activePlan?.incomingDeck ?? armedRequest?.incomingTrack.deck
        let playhead = outDeck.map { currentPlayhead(for: $0) }
        let progress = stateMachine?.progress ?? 0.0
        let executed = stateMachine?.executedEventCount ?? 0
        let remaining = stateMachine?.remainingEventCount ?? 0
        let isArmed: Bool
        if case .armed = state {
            isArmed = true
        } else {
            isArmed = false
        }

        return TransitionExecutionSnapshot(
            state: state,
            activePlan: activePlan,
            progress: progress,
            outgoingDeck: outDeck,
            incomingDeck: inDeck,
            currentPlayheadSeconds: playhead,
            executedEventCount: executed,
            remainingEventCount: remaining,
            isAutoPilotArmed: isArmed,
            armedRequest: armedRequest,
            generation: executionGeneration
        )
    }

    // MARK: - Core Execution Controls

    /// Starts an automated transition matching the given request immediately against active deck audio graphs.
    ///
    /// - Parameter request: Validated transition request specifying tracks, style, and parameters.
    /// - Returns: Deterministic, immutable `TransitionPlan` being executed.
    /// - Throws: `TransitionExecutionServiceError` or `TransitionPlanningError` if preconditions are violated.
    @discardableResult
    public func startTransition(request: TransitionRequest) throws -> TransitionPlan {
        _ = try startTransitionInternal(request: request)
        guard let plan = activePlan else {
            throw TransitionExecutionServiceError.invalidRequest("Failed to calculate transition plan")
        }
        return plan
    }

    @discardableResult
    private func startTransitionInternal(request: TransitionRequest) throws -> [TransitionCommand] {
        if case .inProgress = state {
            throw TransitionExecutionServiceError.transitionAlreadyInProgress
        }

        try validateLoadedTracks(for: request)

        // Validate crossfader routing: outgoing deck must be audible on master
        let outDeck = request.outgoingTrack.deck
        let outWeight = (outDeck == .deckA) ? coordinator.deckA.crossfaderWeight : coordinator.deckB.crossfaderWeight
        guard outWeight > 1e-3 else {
            throw TransitionExecutionServiceError.incompatibleCrossfaderRouting(
                deck: outDeck,
                crossfaderPosition: currentCrossfaderPosition()
            )
        }

        let plan = try planner.plan(request)

        executionGeneration &+= 1
        initialOutgoingRate = request.outgoingPlaybackRate
        armedRequest = nil
        armedTriggerPosition = nil
        lastTickedPosition = nil

        recordDeckGenerations()

        // Capture initial crossfader position before opening crossfader weights
        initialCrossfaderPosition = currentCrossfaderPosition()

        // Open crossfader weights for both decks during transition so transition volume envelopes
        // are unattenuated without double attenuation or endpoint muting
        coordinator.deckA.crossfaderWeight = 1.0
        coordinator.deckB.crossfaderWeight = 1.0

        var sm = TransitionStateMachine(plan: plan)
        activePlan = plan
        state = .inProgress(style: plan.style, progress: 0.0)

        // Determine actual starting playhead
        let currentPos = currentPlayhead(for: request.outgoingTrack.deck)
        let startPosition: Double
        if let explicitTrigger = request.triggerPositionSeconds {
            if currentPos > explicitTrigger {
                startPosition = currentPos
            } else {
                startPosition = explicitTrigger
            }
        } else {
            startPosition = currentPos
        }

        // Advance from actual playhead: emits commands ONLY if startPosition >= plan.startTimestampSeconds
        let initialCommands = try sm.advance(to: startPosition)
        self.stateMachine = sm
        lastTickedPosition = startPosition

        executeCommands(initialCommands)

        if sm.isFinished {
            state = .completed
            stopDriver()
            let targetPos: Float = (plan.incomingDeck == .deckB) ? 1.0 : 0.0
            applyCrossfader(position: targetPos)
            initialCrossfaderPosition = nil
        } else {
            startDriver()
        }

        return initialCommands
    }

    /// Aborts an active transition immediately, restoring unity volume and clean DSP to outgoing deck
    /// and safely muting and stopping incoming deck.
    ///
    /// - Returns: Array of emergency recovery commands executed across the decks.
    @discardableResult
    public func cancelTransition() -> [TransitionCommand] {
        executionGeneration &+= 1
        stopDriver()

        if case .armed = state {
            armedRequest = nil
            armedTriggerPosition = nil
            state = .idle
            return []
        }

        guard var sm = stateMachine else {
            state = .idle
            return []
        }

        let recoveryCommands = sm.cancel()
        stateMachine = sm
        state = .cancelled

        let plan = activePlan
        activePlan = nil

        executeCommands(recoveryCommands)

        // Restore crossfader to initial pre-transition position
        if let initialPos = initialCrossfaderPosition {
            applyCrossfader(position: initialPos)
            initialCrossfaderPosition = nil
        } else if let plan {
            let fallbackPos: Float = (plan.outgoingDeck == .deckA) ? 0.0 : 1.0
            applyCrossfader(position: fallbackPos)
        }

        return recoveryCommands
    }

    // MARK: - AutoPilot Backend

    /// Arms backend AutoPilot to fire an automated transition automatically at outgoing track's mixOutCue.
    ///
    /// - Parameter request: Validated transition request.
    /// - Returns: Pre-calculated `TransitionPlan` that will execute once playhead reaches trigger position.
    /// - Throws: `TransitionExecutionServiceError` if tracks are invalid or playhead is already past trigger point.
    @discardableResult
    public func armAutoPilot(request: TransitionRequest) throws -> TransitionPlan {
        if case .inProgress = state {
            throw TransitionExecutionServiceError.transitionAlreadyInProgress
        }

        try validateLoadedTracks(for: request)

        let plan = try planner.plan(request)
        let trigger = request.triggerPositionSeconds ?? request.outgoingTrack.cueMarkers.mixOutCue

        let currentPos = currentPlayhead(for: request.outgoingTrack.deck)
        guard currentPos < (trigger - 1e-4) else {
            throw TransitionExecutionServiceError.playheadPastTrigger(current: currentPos, trigger: trigger)
        }

        executionGeneration &+= 1
        initialOutgoingRate = request.outgoingPlaybackRate
        armedRequest = request
        armedTriggerPosition = trigger
        state = .armed(request: request, triggerPosition: trigger)

        recordDeckGenerations()
        startDriver()

        return plan
    }

    /// Disarms backend AutoPilot without affecting active playback.
    public func disableAutoPilot() {
        if case .armed = state {
            executionGeneration &+= 1
            armedRequest = nil
            armedTriggerPosition = nil
            state = .idle
            stopDriver()
        }
    }

    // MARK: - Timeline Advancement & Deterministic Clock Driving

    /// Advances the transition execution timeline.
    ///
    /// - Parameter playheadSeconds: Optional explicit playhead timestamp along outgoing track timeline.
    ///   When omitted, queries real engine playhead from `DeckAudioGraph.currentMasterPlayheadSeconds()`.
    /// - Returns: Commands that became due and were executed during this tick.
    /// - Throws: `TransitionExecutionError` or `TransitionExecutionServiceError` on invalid clock progression.
    @discardableResult
    public func tick(playheadSeconds: Double? = nil) throws -> [TransitionCommand] {
        switch state {
        case .idle, .completed, .cancelled:
            return []

        case .armed(let request, let triggerPosition):
            if isDeckInvalidated(deck: request.outgoingTrack.deck) {
                disableAutoPilot()
                return []
            }

            let pos = playheadSeconds ?? currentPlayhead(for: request.outgoingTrack.deck)
            guard pos.isFinite && !pos.isNaN else {
                throw TransitionExecutionServiceError.nonFinitePlayhead(pos)
            }

            let playing = isPlaying(for: request.outgoingTrack.deck)
            guard playing else {
                // Outgoing deck is paused: wait safely, do not fire or restart accidentally
                return []
            }

            if pos >= (triggerPosition - 1e-4) {
                let deck = request.outgoingTrack.deck
                let deckGen = deckGeneration(for: deck)
                let key = AutoPilotFiredKey(deck: deck, generation: deckGen)
                guard !autoPilotFiredHistory.contains(key) else {
                    return []
                }
                autoPilotFiredHistory.insert(key)

                // One-shot AutoPilot fire!
                disableAutoPilot()
                return try startTransitionInternal(request: request)
            }
            return []

        case .inProgress(let style, _):
            guard var sm = stateMachine, let plan = activePlan else {
                return []
            }

            // Invalidation check: rate change or track change aborts stale transition safely
            if isRateInvalidated(deck: plan.outgoingDeck) || isDeckInvalidated(deck: plan.outgoingDeck) {
                return cancelTransition()
            }

            let playing = isPlaying(for: plan.outgoingDeck)
            guard playing || playheadSeconds != nil else {
                // Outgoing deck is paused: pause timeline progression without advancing or restarting
                return []
            }

            let pos = playheadSeconds ?? currentPlayhead(for: plan.outgoingDeck)
            guard pos.isFinite && !pos.isNaN else {
                throw TransitionExecutionServiceError.nonFinitePlayhead(pos)
            }

            // In live unforced ticks, if playhead has not advanced past last ticked position, wait for next render buffer
            if playheadSeconds == nil, let last = lastTickedPosition, pos <= last {
                return []
            }

            let dueCommands = try sm.advance(to: pos)
            self.stateMachine = sm
            lastTickedPosition = pos

            executeCommands(dueCommands)

            if sm.isFinished {
                state = .completed
                stopDriver()
                let targetPos: Float = (plan.incomingDeck == .deckB) ? 1.0 : 0.0
                applyCrossfader(position: targetPos)
                initialCrossfaderPosition = nil
            } else {
                state = .inProgress(style: style, progress: sm.progress)
            }

            return dueCommands
        }
    }

    /// Convenience forwarder for deterministic tests to step the clock directly to a specific timestamp.
    @discardableResult
    public func advance(to playheadSeconds: Double) throws -> [TransitionCommand] {
        try tick(playheadSeconds: playheadSeconds)
    }

    // MARK: - Command Dispatch

    private func executeCommands(_ commands: [TransitionCommand]) {
        for command in commands {
            executeCommand(command)
        }
    }

    private func executeCommand(_ command: TransitionCommand) {
        switch command {
        case .setVolume(let deck, let volume):
            deckGraph(for: deck).volume = volume

        case .setEQ(let deck, let eq):
            deckGraph(for: deck).eqParameters = eq

        case .setFilter(let deck, let filter):
            deckGraph(for: deck).filterParameters = filter

        case .setRate(let deck, let rate, let keyLock):
            let currentPitch = deckGraph(for: deck).timePitchParameters.pitchCents
            deckGraph(for: deck).timePitchParameters = TimePitchParameters(
                rate: rate,
                pitchCents: currentPitch,
                keyLockEnabled: keyLock
            )

        case .setEcho(let deck, let enabled, let feedback, let mix):
            if let concrete = concreteDeckGraph(for: deck) {
                concrete.setEcho(enabled: enabled, feedback: feedback, mix: mix)
            }

        case .seek(let deck, let positionSeconds):
            deckGraph(for: deck).seek(to: positionSeconds)

        case .play(let deck):
            deckGraph(for: deck).play()

        case .pause(let deck):
            deckGraph(for: deck).pause()

        case .stop(let deck):
            if let concrete = concreteDeckGraph(for: deck) {
                concrete.stop()
            } else {
                deckGraph(for: deck).pause()
                deckGraph(for: deck).seek(to: 0.0)
            }
        }
    }

    // MARK: - Validation & Helpers

    private func validateLoadedTracks(for request: TransitionRequest) throws {
        let outgoing = request.outgoingTrack
        let incoming = request.incomingTrack

        guard outgoing.deck != incoming.deck else {
            throw TransitionPlanningError.sameDeck(outgoing.deck)
        }

        let outDuration = trackDuration(for: outgoing.deck)
        guard outDuration > 0.0 && outDuration.isFinite else {
            throw TransitionExecutionServiceError.trackNotLoaded(outgoing.deck)
        }
        guard abs(outDuration - outgoing.duration) < 0.1 else {
            throw TransitionExecutionServiceError.trackMismatch(
                deck: outgoing.deck,
                expectedDuration: outgoing.duration,
                actualDuration: outDuration
            )
        }

        let inDuration = trackDuration(for: incoming.deck)
        guard inDuration > 0.0 && inDuration.isFinite else {
            throw TransitionExecutionServiceError.trackNotLoaded(incoming.deck)
        }
        guard abs(inDuration - incoming.duration) < 0.1 else {
            throw TransitionExecutionServiceError.trackMismatch(
                deck: incoming.deck,
                expectedDuration: incoming.duration,
                actualDuration: inDuration
            )
        }

        let liveOutRate = deckGraph(for: outgoing.deck).timePitchParameters.rate
        guard abs(liveOutRate - request.outgoingPlaybackRate) < 0.01 else {
            throw TransitionExecutionServiceError.rateMismatch(
                expected: request.outgoingPlaybackRate,
                actual: liveOutRate
            )
        }
    }

    private func deckGraph(for deck: DeckIdentifier) -> DeckAudioGraphContract {
        switch deck {
        case .deckA:
            return coordinator.deckA
        case .deckB:
            return coordinator.deckB
        }
    }

    private func concreteDeckGraph(for deck: DeckIdentifier) -> DeckAudioGraph? {
        deckGraph(for: deck) as? DeckAudioGraph
    }

    private func currentPlayhead(for deck: DeckIdentifier) -> Double {
        if let concrete = concreteDeckGraph(for: deck) {
            return concrete.currentMasterPlayheadSeconds()
        }
        return 0.0
    }

    private func trackDuration(for deck: DeckIdentifier) -> Double {
        if let concrete = concreteDeckGraph(for: deck) {
            return concrete.trackDurationSeconds
        }
        return Double.infinity
    }

    private func isPlaying(for deck: DeckIdentifier) -> Bool {
        if let concrete = concreteDeckGraph(for: deck) {
            return concrete.isMasterPlaying
        }
        return true
    }

    private func deckGeneration(for deck: DeckIdentifier) -> UInt64 {
        if let concrete = concreteDeckGraph(for: deck) {
            return concrete.scheduleGeneration
        }
        return 0
    }

    private func recordDeckGenerations() {
        lastObservedDeckGeneration[.deckA] = deckGeneration(for: .deckA)
        lastObservedDeckGeneration[.deckB] = deckGeneration(for: .deckB)
    }

    private func isDeckInvalidated(deck: DeckIdentifier) -> Bool {
        guard let recorded = lastObservedDeckGeneration[deck] else { return false }
        return deckGeneration(for: deck) != recorded
    }

    private func isRateInvalidated(deck: DeckIdentifier) -> Bool {
        let liveRate = deckGraph(for: deck).timePitchParameters.rate
        return abs(liveRate - initialOutgoingRate) > 0.01
    }

    // MARK: - Crossfader Helpers

    private func currentCrossfaderPosition() -> Float {
        if let concrete = coordinator as? AudioEngineCoordinator {
            return concrete.crossfaderPosition
        }
        let weightA = coordinator.deckA.crossfaderWeight
        let weightB = coordinator.deckB.crossfaderWeight
        if weightA > 0.99 && weightB < 0.01 {
            return 0.0
        } else if weightB > 0.99 && weightA < 0.01 {
            return 1.0
        }
        return 0.5
    }

    private func applyCrossfader(position: Float) {
        if let concrete = coordinator as? AudioEngineCoordinator {
            concrete.setCrossfader(position: position)
        } else {
            let safePos = position.isFinite ? min(max(position, 0.0), 1.0) : 0.5
            let weightA: Float = safePos <= 0.5 ? 1.0 : (1.0 - safePos) * 2.0
            let weightB: Float = safePos >= 0.5 ? 1.0 : safePos * 2.0
            coordinator.deckA.crossfaderWeight = weightA
            coordinator.deckB.crossfaderWeight = weightB
        }
    }

    private func isMasterEngineRunning() -> Bool {
        if let concrete = coordinator as? AudioEngineCoordinator {
            return concrete.masterAudioEngine.isRunning
        }
        return true
    }

    // MARK: - Driver Loop

    private func startDriver() {
        stopDriver()
        guard isMasterEngineRunning() else { return }
        driverTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000) // 20ms poll interval
                guard let self else { break }
                do {
                    _ = try await self.tick()
                } catch {
                    await self.handleDriverError(error)
                    break
                }
            }
        }
    }

    private func handleDriverError(_ error: Error) {
        switch state {
        case .inProgress:
            _ = cancelTransition()
        case .armed:
            disableAutoPilot()
        case .idle, .completed, .cancelled:
            break
        }
    }

    private func stopDriver() {
        driverTask?.cancel()
        driverTask = nil
    }
}
