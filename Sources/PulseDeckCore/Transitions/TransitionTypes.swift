import Foundation

// MARK: - Transition Style

/// Supported automated DJ transition styles.
public enum TransitionStyle: Sendable, Equatable {
    /// Beat-synced bass swap across 8, 16, or 32 bars.
    /// Requires effective tempo difference strictly below 6.0% and valid beat grids on both decks.
    /// On the midpoint downbeat, cuts outgoing low shelf to -24 dB and restores incoming low shelf to 0 dB.
    case beatSyncedBassSwap(bars: Int = 16, allowFallbackToFilter: Bool = false)

    /// High-pass filter sweep with echo wash and equal-power S-curve crossfade.
    /// Ideal for larger tempo differentials or tracks without beat grids.
    case filterEchoWash(durationSeconds: Double = 8.0, echoSend: Float = 0.5)

    /// Bar-quantized instantaneous hard cut on a downbeat / drop marker.
    case hardCutOnDrop(bars: Int = 1, allowFallbackToFilter: Bool = false)
}

// MARK: - Track Transition Descriptor

/// Immutable descriptor containing all track analysis, cue points, and beat grid
/// data necessary for transition calculation.
public struct TrackTransitionDescriptor: Sendable, Equatable {
    /// Assigned deck channel (Deck A or Deck B).
    public let deck: DeckIdentifier

    /// Total audio file duration in seconds.
    public let duration: Double

    /// Detected Beats Per Minute (0.0 if unknown).
    public let bpm: Double

    /// Detection confidence score (0.0 to 1.0).
    public let confidence: Double

    /// Ordered and bounded cue markers.
    public let cueMarkers: CueMarkers

    /// Detected beat grid timestamps and intervals.
    public let beatGrid: BeatGrid

    public init(
        deck: DeckIdentifier,
        duration: Double,
        bpm: Double,
        confidence: Double,
        cueMarkers: CueMarkers,
        beatGrid: BeatGrid
    ) {
        self.deck = deck
        self.duration = duration
        self.bpm = bpm
        self.confidence = confidence
        self.cueMarkers = cueMarkers
        self.beatGrid = beatGrid
    }

    /// Convenience initializer mapping from a cached library entry.
    public init(deck: DeckIdentifier, cacheEntry: TrackCacheEntry) {
        self.init(
            deck: deck,
            duration: cacheEntry.duration,
            bpm: cacheEntry.bpm,
            confidence: cacheEntry.confidence,
            cueMarkers: cacheEntry.cueMarkers,
            beatGrid: cacheEntry.beatGrid
        )
    }
}

// MARK: - Transition Request

/// Request specifying the outgoing track, incoming track, transition style,
/// and optional custom trigger position.
public struct TransitionRequest: Sendable, Equatable {
    /// Track currently playing on Master output.
    public let outgoingTrack: TrackTransitionDescriptor

    /// Track cued to take over Master output.
    public let incomingTrack: TrackTransitionDescriptor

    /// Transition algorithm style to calculate.
    public let style: TransitionStyle

    /// Optional explicit trigger position in seconds within outgoing track timeline.
    /// When nil, defaults to `outgoingTrack.cueMarkers.mixOutCue`.
    public let triggerPositionSeconds: Double?

    /// Current outgoing deck rate, including any rate retained from an earlier transition.
    /// Supply the live deck rate. Event offsets remain outgoing source-media seconds;
    /// elapsed playback time equals those offsets divided by this rate.
    public let outgoingPlaybackRate: Float

    public init(
        outgoingTrack: TrackTransitionDescriptor,
        incomingTrack: TrackTransitionDescriptor,
        style: TransitionStyle,
        triggerPositionSeconds: Double? = nil,
        outgoingPlaybackRate: Float = 1.0
    ) {
        self.outgoingTrack = outgoingTrack
        self.incomingTrack = incomingTrack
        self.style = style
        self.triggerPositionSeconds = triggerPositionSeconds
        self.outgoingPlaybackRate = outgoingPlaybackRate
    }
}

// MARK: - Transition Command & Priority

/// Discrete executable audio commands emitted by transition schedules.
///
/// Designed for execution by audio adapters without coupling to AVFoundation in the planner.
public enum TransitionCommand: Sendable, Equatable {
    /// Adjust deck linear volume level (0.0 to 1.0).
    case setVolume(deck: DeckIdentifier, volume: Float)

    /// Adjust deck 3-band equalizer parameters.
    case setEQ(deck: DeckIdentifier, eq: EQ3BandParameters)

    /// Adjust deck resonant filter parameters.
    case setFilter(deck: DeckIdentifier, filter: ResonantFilterParameters)

    /// Adjust playback rate multiplier and key-lock state.
    case setRate(deck: DeckIdentifier, rate: Float, keyLock: Bool)

    /// Adjust echo effect parameters (enabled, feedback [0.0..1.0], wet/dry mix [0.0..1.0]).
    case setEcho(deck: DeckIdentifier, enabled: Bool, feedback: Float, mix: Float)

    /// Seek playback playhead to timestamp in seconds.
    case seek(deck: DeckIdentifier, positionSeconds: Double)

    /// Start playback rendering.
    case play(deck: DeckIdentifier)

    /// Pause playback rendering.
    case pause(deck: DeckIdentifier)

    /// Stop playback rendering and reset buffers.
    case stop(deck: DeckIdentifier)
}

/// Execution priority used to guarantee deterministic ordering for events scheduled at the exact same timestamp.
public enum TransitionCommandPriority: Int, Sendable, Equatable, Comparable {
    /// Playback rate multiplier, key-lock, and pre-configuration.
    case configuration = 10

    /// Playhead seeking and pre-buffering.
    case transportPrep = 20

    /// Equalizer, resonant filter, and echo DSP settings.
    case audioProcessing = 30

    /// Playback start commands.
    case transportStart = 40

    /// Volume fader ramps.
    case volumeFader = 50

    /// Playback stop or pause commands.
    case transportStop = 60

    public static func < (lhs: TransitionCommandPriority, rhs: TransitionCommandPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Scheduled Transition Event

/// An immutable discrete command scheduled at a relative time offset from transition start.
public struct ScheduledTransitionEvent: Sendable, Equatable, Identifiable {
    /// Unique identifier for deduplication and tracking.
    public let id: UUID

    /// Offset in outgoing source-media seconds from transition start (always >= 0.0).
    public let timeOffsetSeconds: Double

    /// Command to execute.
    public let command: TransitionCommand

    /// Deterministic execution priority for co-timed events.
    public let priority: TransitionCommandPriority

    public init(
        id: UUID = UUID(),
        timeOffsetSeconds: Double,
        command: TransitionCommand,
        priority: TransitionCommandPriority = .volumeFader
    ) {
        self.id = id
        self.timeOffsetSeconds = timeOffsetSeconds
        self.command = command
        self.priority = priority
    }
}

// MARK: - Transition Plan Metadata

/// Analytical metadata regarding calculated transition parameters.
public struct TransitionPlanMetadata: Sendable, Equatable {
    /// Target tempo in BPM for beat-matched transitions.
    public let targetTempoBPM: Double?

    /// Calculated time-stretch playback rate applied to incoming track.
    public let tempoAdjustmentRate: Float?

    /// Total phrase length in musical bars.
    public let phraseBars: Int?

    /// Time offset in seconds where the bass swap downbeat occurs.
    public let bassSwapOffsetSeconds: Double?

    /// True if the plan fell back from beat-synced mode to filter echo wash due to BPM delta or grid limits.
    public let isFallback: Bool

    public init(
        targetTempoBPM: Double? = nil,
        tempoAdjustmentRate: Float? = nil,
        phraseBars: Int? = nil,
        bassSwapOffsetSeconds: Double? = nil,
        isFallback: Bool = false
    ) {
        self.targetTempoBPM = targetTempoBPM
        self.tempoAdjustmentRate = tempoAdjustmentRate
        self.phraseBars = phraseBars
        self.bassSwapOffsetSeconds = bassSwapOffsetSeconds
        self.isFallback = isFallback
    }
}

// MARK: - Transition Plan

/// Immutable, deterministic transition schedule comprising bounded discrete audio commands.
public struct TransitionPlan: Sendable, Equatable, Identifiable {
    /// Unique identifier for this transition plan instance.
    public let id: UUID

    /// Selected transition style.
    public let style: TransitionStyle

    /// Outgoing master deck identifier.
    public let outgoingDeck: DeckIdentifier

    /// Incoming cue deck identifier.
    public let incomingDeck: DeckIdentifier

    /// Timeline position in seconds on outgoing track where transition begins.
    public let startTimestampSeconds: Double

    /// Total transition duration in outgoing source-media seconds. An immediate cut has duration zero.
    public let durationSeconds: Double

    /// Strictly ordered bounded events.
    public let events: [ScheduledTransitionEvent]

    /// Informational metadata for transition telemetry and UI display.
    public let metadata: TransitionPlanMetadata

    public init(
        id: UUID = UUID(),
        style: TransitionStyle,
        outgoingDeck: DeckIdentifier,
        incomingDeck: DeckIdentifier,
        startTimestampSeconds: Double,
        durationSeconds: Double,
        events: [ScheduledTransitionEvent],
        metadata: TransitionPlanMetadata = TransitionPlanMetadata()
    ) {
        self.id = id
        self.style = style
        self.outgoingDeck = outgoingDeck
        self.incomingDeck = incomingDeck
        self.startTimestampSeconds = startTimestampSeconds
        self.durationSeconds = durationSeconds
        self.events = events
        self.metadata = metadata
    }

    /// Absolute timeline position in seconds when transition ends.
    public var endTimestampSeconds: Double {
        startTimestampSeconds + durationSeconds
    }

    /// Total count of discrete scheduled commands.
    public var totalEventCount: Int {
        events.count
    }
}

// MARK: - Transition State

/// Lifecycle state of a deterministic transition execution.
public enum TransitionState: Sendable, Equatable {
    /// Transition initialized, awaiting first clock advance.
    case idle

    /// Transition executing; `currentPosition` is the latest clock position in seconds.
    case inProgress(currentPosition: Double)

    /// Transition finished all scheduled events and reached duration end.
    case completed

    /// Transition cancelled early with emergency safety fallbacks applied.
    case cancelled
}

// MARK: - Errors

/// Domain-specific errors thrown during transition plan calculation.
public enum TransitionPlanningError: LocalizedError, Sendable, Equatable {
    case sameDeck(DeckIdentifier)
    case invalidDuration(deck: DeckIdentifier, duration: Double)
    case invalidBPM(deck: DeckIdentifier, bpm: Double)
    case tempoDifferenceExceedsThreshold(outgoingBPM: Double, incomingBPM: Double, deltaPercent: Double)
    case missingBeatGrid(deck: DeckIdentifier, reason: String)
    case invalidCueMarkers(deck: DeckIdentifier, reason: String)
    case triggerPositionOutOfBounds(position: Double, mixOutCue: Double, duration: Double)
    case nonFiniteParameter(String)
    case invalidPlaybackRate(Float)
    case insufficientPlayableContent(deck: DeckIdentifier)

    public var errorDescription: String? {
        switch self {
        case .sameDeck(let deck):
            return "Outgoing and incoming tracks cannot share the same deck: \(deck.rawValue)"
        case .invalidDuration(let deck, let duration):
            return "Track on \(deck.rawValue) has invalid duration: \(duration)s (must be positive and finite)"
        case .invalidBPM(let deck, let bpm):
            return "Track on \(deck.rawValue) has invalid BPM: \(bpm) (must be positive and finite)"
        case .tempoDifferenceExceedsThreshold(let outBPM, let inBPM, let delta):
            return String(format: "BPM difference %.2f%% between %.1f and %.1f must be below 6.0%% for a beat-synced transition", delta, outBPM, inBPM)
        case .missingBeatGrid(let deck, let reason):
            return "Track on \(deck.rawValue) missing valid beat grid: \(reason)"
        case .invalidCueMarkers(let deck, let reason):
            return "Track on \(deck.rawValue) has invalid cue markers: \(reason)"
        case .triggerPositionOutOfBounds(let pos, let mixOut, let dur):
            return "Trigger position \(pos)s is out of valid bounds [0.0, \(dur)s] (mixOutCue: \(mixOut)s)"
        case .nonFiniteParameter(let detail):
            return "Transition planning rejected non-finite parameter: \(detail)"
        case .invalidPlaybackRate(let rate):
            return "Transition playback rate must be finite and within the supported range: \(rate)"
        case .insufficientPlayableContent(let deck):
            return "The complete transition does not fit the playable cue interval on \(deck.rawValue)"
        }
    }
}

/// Domain-specific errors thrown during state machine clock advancement.
public enum TransitionExecutionError: LocalizedError, Sendable, Equatable {
    case timeRegressed(current: Double, attempted: Double)
    case nonFiniteTime(Double)

    public var errorDescription: String? {
        switch self {
        case .timeRegressed(let current, let attempted):
            return "Timeline clock regressed backwards from \(current)s to \(attempted)s"
        case .nonFiniteTime(let val):
            return "Clock advancement timestamp must be finite, got: \(val)"
        }
    }
}
