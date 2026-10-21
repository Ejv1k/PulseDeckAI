import Foundation

/// Pure deterministic state machine driving real-time transition playback execution.
///
/// Converts continuous playback playhead timestamps into discrete scheduled audio commands.
/// Guarantees:
/// - Exact-once command emission
/// - Deterministic same-time event priority ordering
/// - Safe monotonic clock regression checks
/// - Idempotent, safe cancellation
/// - Pure Sendable control-time state with zero audio runtime dependencies
public struct TransitionStateMachine: Sendable {

    /// The active transition schedule being executed.
    public private(set) var plan: TransitionPlan

    /// Current lifecycle state of the state machine.
    public private(set) var state: TransitionState

    /// Most recent clock position in seconds fed into `advance(to:)`.
    public private(set) var lastPositionSeconds: Double?

    /// Set of unique event IDs that have already been emitted.
    private var executedEventIds: Set<UUID>

    public init(plan: TransitionPlan) {
        self.plan = plan
        self.state = .idle
        self.lastPositionSeconds = nil
        self.executedEventIds = []
    }

    // MARK: - Snapshot Observables

    /// True if the transition has reached its scheduled end or was cancelled.
    public var isFinished: Bool {
        switch state {
        case .completed, .cancelled:
            return true
        case .idle, .inProgress:
            return false
        }
    }

    /// Number of scheduled discrete events already emitted.
    public var executedEventCount: Int {
        executedEventIds.count
    }

    /// Number of scheduled discrete events remaining in the plan.
    public var remainingEventCount: Int {
        max(0, plan.events.count - executedEventIds.count)
    }

    /// Normalized transition execution progress from 0.0 to 1.0.
    public var progress: Double {
        switch state {
        case .idle:
            return 0.0
        case .completed:
            return 1.0
        case .cancelled:
            guard let last = lastPositionSeconds, plan.durationSeconds > 0 else { return 0.0 }
            let rel = last - plan.startTimestampSeconds
            return min(1.0, max(0.0, rel / plan.durationSeconds))
        case .inProgress(let currentPosition):
            guard plan.durationSeconds > 0 else { return 1.0 }
            let rel = currentPosition - plan.startTimestampSeconds
            return min(1.0, max(0.0, rel / plan.durationSeconds))
        }
    }

    // MARK: - Execution

    /// Advances the transition clock to a given playhead position in seconds.
    ///
    /// - Parameter positionSeconds: Playhead position along the outgoing deck's timeline.
    /// - Returns: Array of discrete `TransitionCommand`s that became due at or before this timestamp,
    ///   ordered deterministically by timestamp then command priority.
    /// - Throws: `TransitionExecutionError.nonFiniteTime` if timestamp is NaN or infinite;
    ///   `TransitionExecutionError.timeRegressed` if timestamp moves backward before previous advance.
    public mutating func advance(to positionSeconds: Double) throws -> [TransitionCommand] {
        guard positionSeconds.isFinite && !positionSeconds.isNaN else {
            throw TransitionExecutionError.nonFiniteTime(positionSeconds)
        }

        if let last = lastPositionSeconds {
            guard positionSeconds >= (last - 1e-9) else {
                throw TransitionExecutionError.timeRegressed(current: last, attempted: positionSeconds)
            }
        }

        // Terminal states emit nothing further
        if state == .completed || state == .cancelled {
            lastPositionSeconds = positionSeconds
            return []
        }

        let relativeTime = positionSeconds - plan.startTimestampSeconds
        if relativeTime < 0.0 {
            // Before transition start point
            lastPositionSeconds = positionSeconds
            return []
        }

        let isAtEnd = relativeTime >= (plan.durationSeconds - 1e-9)
        if isAtEnd {
            state = .completed
        } else {
            state = .inProgress(currentPosition: positionSeconds)
        }
        lastPositionSeconds = positionSeconds

        // Filter events due for execution that have not yet run
        let dueEvents: [ScheduledTransitionEvent]
        if isAtEnd {
            dueEvents = plan.events.filter { !executedEventIds.contains($0.id) }
        } else {
            dueEvents = plan.events.filter {
                !executedEventIds.contains($0.id) && $0.timeOffsetSeconds <= (relativeTime + 1e-9)
            }
        }

        guard !dueEvents.isEmpty else {
            return []
        }

        // Deterministic sort: ascending timestamp, then priority order
        let sortedEvents = dueEvents.sorted {
            if $0.timeOffsetSeconds != $1.timeOffsetSeconds {
                return $0.timeOffsetSeconds < $1.timeOffsetSeconds
            }
            return $0.priority < $1.priority
        }

        for event in sortedEvents {
            executedEventIds.insert(event.id)
        }

        return sortedEvents.map { $0.command }
    }

    /// Aborts the transition immediately, restoring the outgoing deck to full volume
    /// and resetting the incoming deck safely to zero volume and stopped state.
    ///
    /// - Returns: Immediate emergency recovery commands. Idempotent: returns empty array if already cancelled or completed.
    public mutating func cancel() -> [TransitionCommand] {
        if state == .cancelled || state == .completed {
            return []
        }

        state = .cancelled

        var recoveryCommands: [TransitionCommand] = []

        // Outgoing deck: restore safe unity gain, neutral EQ, neutral filter, bypass echo
        recoveryCommands.append(.setEQ(
            deck: plan.outgoingDeck,
            eq: EQ3BandParameters(lowGainDB: 0.0, midGainDB: 0.0, highGainDB: 0.0)
        ))
        recoveryCommands.append(.setFilter(
            deck: plan.outgoingDeck,
            filter: ResonantFilterParameters(sweep: 0.0, resonance: 1.0)
        ))
        recoveryCommands.append(.setEcho(
            deck: plan.outgoingDeck,
            enabled: false,
            feedback: 0.0,
            mix: 0.0
        ))
        recoveryCommands.append(.setVolume(
            deck: plan.outgoingDeck,
            volume: 1.0
        ))

        // Incoming deck: safe mute, stop, neutral EQ, neutral filter, bypass echo
        recoveryCommands.append(.setVolume(
            deck: plan.incomingDeck,
            volume: 0.0
        ))
        recoveryCommands.append(.stop(
            deck: plan.incomingDeck
        ))
        recoveryCommands.append(.setEQ(
            deck: plan.incomingDeck,
            eq: EQ3BandParameters(lowGainDB: 0.0, midGainDB: 0.0, highGainDB: 0.0)
        ))
        recoveryCommands.append(.setFilter(
            deck: plan.incomingDeck,
            filter: ResonantFilterParameters(sweep: 0.0, resonance: 1.0)
        ))
        recoveryCommands.append(.setEcho(
            deck: plan.incomingDeck,
            enabled: false,
            feedback: 0.0,
            mix: 0.0
        ))

        return recoveryCommands
    }
}
