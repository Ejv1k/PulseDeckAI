import Foundation

/// Pure deterministic planner for automated multi-deck transitions.
///
/// Converts a high-level transition request into a bounded, discrete timeline schedule
/// of executable audio commands without timers, tasks, or audio framework dependencies.
public struct TransitionPlanner: Sendable {

    /// Maximum allowable tempo differential (6.0%) for beat-synced transitions.
    public static let maxTempoDifferential: Double = 0.06

    /// The tempo scaled by ½, 1 or 2, whichever sits nearest the reference, so a 70 BPM track mixes into
    /// 140 BPM as half-time (and analyzer octave errors stop reading as a tempo clash).
    public static func foldedTempo(_ tempo: Double, toward reference: Double) -> Double {
        [tempo, tempo * 2, tempo / 2].min { abs($0 - reference) < abs($1 - reference) } ?? tempo
    }

    /// True when the BPM label agrees with the grid interval within 1 %, at ×½, ×1 or ×2.
    static func bpm(_ bpm: Double, matchesInterval interval: Double) -> Bool {
        let gridBPM = 60 / interval
        return [bpm, bpm * 2, bpm / 2].contains { abs($0 - gridBPM) <= gridBPM * 0.01 }
    }

    /// Fewest keyframes for continuous curve transitions (e.g. Filter Echo Wash).
    public static let defaultWashKeyframes: Int = 16
    /// Keyframes per second for those curves: the engine applies each gain as a step, so 8 per second
    /// keeps every step small (a fixed 16 left 0.5 s steps in an 8 s wash).
    public static let washKeyframesPerSecond: Double = 8

    public init() {}

    /// Plans a complete transition schedule matching the given request.
    ///
    /// - Parameter request: Structural request defining outgoing/incoming tracks, style, and optional trigger position.
    /// - Returns: Deterministic, immutable `TransitionPlan`.
    /// - Throws: `TransitionPlanningError` if parameters violate domain constraints or beat grids are unavailable.
    public func plan(_ request: TransitionRequest) throws -> TransitionPlan {
        try validateRequest(request)

        let triggerPos = request.triggerPositionSeconds ?? request.outgoingTrack.cueMarkers.mixOutCue

        let result: TransitionPlan
        switch request.style {
        case .beatSyncedBassSwap(let bars, let allowFallback):
            result = try planBeatSyncedBassSwap(
                request: request,
                triggerPosition: triggerPos,
                bars: bars,
                allowFallback: allowFallback
            )

        case .filterEchoWash(let durationSeconds, let echoSend):
            result = try planFilterEchoWash(
                outgoing: request.outgoingTrack,
                incoming: request.incomingTrack,
                triggerPosition: triggerPos,
                durationSeconds: durationSeconds,
                echoSend: echoSend,
                style: request.style,
                isFallback: false
            )

        case .hardCutOnDrop(let bars, let allowFallback):
            result = try planHardCutOnDrop(
                request: request,
                triggerPosition: triggerPos,
                bars: bars,
                allowFallback: allowFallback
            )
        }
        try validatePlayableBounds(result, request: request)
        return result
    }

    // MARK: - Validation

    private func validateRequest(_ request: TransitionRequest) throws {
        // Deck identity invariant: outgoing and incoming must differ
        guard request.outgoingTrack.deck != request.incomingTrack.deck else {
            throw TransitionPlanningError.sameDeck(request.outgoingTrack.deck)
        }

        guard request.outgoingPlaybackRate.isFinite, (0.05...32.0).contains(request.outgoingPlaybackRate) else {
            throw TransitionPlanningError.invalidPlaybackRate(request.outgoingPlaybackRate)
        }

        // Duration validation
        guard request.outgoingTrack.duration.isFinite && request.outgoingTrack.duration > 0 else {
            throw TransitionPlanningError.invalidDuration(
                deck: request.outgoingTrack.deck,
                duration: request.outgoingTrack.duration
            )
        }
        guard request.incomingTrack.duration.isFinite && request.incomingTrack.duration > 0 else {
            throw TransitionPlanningError.invalidDuration(
                deck: request.incomingTrack.deck,
                duration: request.incomingTrack.duration
            )
        }

        // Cue markers validation
        guard request.outgoingTrack.cueMarkers.isValid(forDuration: request.outgoingTrack.duration) else {
            throw TransitionPlanningError.invalidCueMarkers(
                deck: request.outgoingTrack.deck,
                reason: "Markers fail ordering or bounds for duration \(request.outgoingTrack.duration)s"
            )
        }
        guard request.incomingTrack.cueMarkers.isValid(forDuration: request.incomingTrack.duration) else {
            throw TransitionPlanningError.invalidCueMarkers(
                deck: request.incomingTrack.deck,
                reason: "Markers fail ordering or bounds for duration \(request.incomingTrack.duration)s"
            )
        }

        // Trigger position validation
        let triggerPos = request.triggerPositionSeconds ?? request.outgoingTrack.cueMarkers.mixOutCue
        guard triggerPos.isFinite && triggerPos >= request.outgoingTrack.cueMarkers.startTrimCue && triggerPos <= request.outgoingTrack.cueMarkers.endTrimCue else {
            throw TransitionPlanningError.triggerPositionOutOfBounds(
                position: triggerPos,
                mixOutCue: request.outgoingTrack.cueMarkers.mixOutCue,
                duration: request.outgoingTrack.duration
            )
        }

        // Style parameter validation
        switch request.style {
        case .beatSyncedBassSwap(let bars, _):
            guard [8, 16, 32].contains(bars) else {
                throw TransitionPlanningError.nonFiniteParameter("Beat-synced phrase must contain 8, 16, or 32 bars, got: \(bars)")
            }
        case .filterEchoWash(let durationSeconds, let echoSend):
            guard durationSeconds.isFinite && durationSeconds > 0 else {
                throw TransitionPlanningError.nonFiniteParameter("Filter wash duration must be positive and finite: \(durationSeconds)")
            }
            guard echoSend.isFinite && echoSend >= 0.0 && echoSend <= 1.0 else {
                throw TransitionPlanningError.nonFiniteParameter("Filter wash echoSend must be in range [0.0, 1.0], got: \(echoSend)")
            }
        case .hardCutOnDrop(let bars, _):
            guard (1...32).contains(bars) else {
                throw TransitionPlanningError.nonFiniteParameter("Hard cut bars count must be within 1...32, got: \(bars)")
            }
        }
    }

    /// Rejects schedules whose final commands cannot be reached on the outgoing playhead,
    /// or whose incoming playback would consume content outside its manual trim interval.
    private func validatePlayableBounds(_ plan: TransitionPlan, request: TransitionRequest) throws {
        let outgoing = request.outgoingTrack
        let incoming = request.incomingTrack
        guard plan.startTimestampSeconds.isFinite, plan.durationSeconds.isFinite,
              plan.durationSeconds >= 0,
              plan.startTimestampSeconds >= outgoing.cueMarkers.startTrimCue,
              plan.endTimestampSeconds.isFinite,
              plan.endTimestampSeconds <= outgoing.cueMarkers.endTrimCue else {
            throw TransitionPlanningError.insufficientPlayableContent(deck: outgoing.deck)
        }
        let seek = plan.events.compactMap { event -> Double? in
            if case .seek(let deck, let position) = event.command, deck == incoming.deck { return position }
            return nil
        }.first
        let rate = plan.events.compactMap { event -> Float? in
            if case .setRate(let deck, let rate, _) = event.command, deck == incoming.deck { return rate }
            return nil
        }.first
        let playOffset = plan.events.first { $0.command == .play(deck: incoming.deck) }?.timeOffsetSeconds
        guard let seek, let rate, let playOffset,
              seek.isFinite, seek >= incoming.cueMarkers.startTrimCue,
              seek < incoming.cueMarkers.endTrimCue,
              rate.isFinite, rate > 0,
              playOffset.isFinite, playOffset >= 0, playOffset <= plan.durationSeconds else {
            throw TransitionPlanningError.insufficientPlayableContent(deck: incoming.deck)
        }
        let consumed = (plan.durationSeconds - playOffset) / Double(request.outgoingPlaybackRate) * Double(rate)
        guard consumed.isFinite, consumed <= incoming.cueMarkers.endTrimCue - seek else {
            throw TransitionPlanningError.insufficientPlayableContent(deck: incoming.deck)
        }
    }

    /// Validates a measured grid: ordered in-bounds beats whose phase, median spacing and BPM match the stored interval.
    /// Positive schema sentinels never establish a usable tempo without genuine timestamps.
    public func isUsableBeatGrid(descriptor: TrackTransitionDescriptor) -> Bool {
        let grid = descriptor.beatGrid
        guard descriptor.duration.isFinite, descriptor.duration > 0,
              descriptor.bpm.isFinite, descriptor.bpm > 0,
              descriptor.confidence.isFinite, (0...1).contains(descriptor.confidence), descriptor.confidence > 0,
              grid.firstBeatOffsetSeconds.isFinite, grid.firstBeatOffsetSeconds >= 0,
              grid.beatIntervalSeconds.isFinite, grid.beatIntervalSeconds > 0,
              grid.beatTimestamps.count >= 2 else { return false }
        // The planner reads real beat/bar positions, so measured grids may drift (live bands, rubato);
        // only the stored interval must describe them. ×½/×2 covers a hand-corrected BPM label.
        guard Self.bpm(descriptor.bpm, matchesInterval: grid.beatIntervalSeconds),
              abs(grid.beatTimestamps[0] - grid.firstBeatOffsetSeconds) <= 0.02 else { return false }
        var previous = -Double.infinity
        var gaps: [Double] = []
        for timestamp in grid.beatTimestamps {
            guard timestamp.isFinite, timestamp >= 0, timestamp <= descriptor.duration, timestamp > previous else { return false }
            if previous.isFinite { gaps.append(timestamp - previous) }
            previous = timestamp
        }
        let medianGap = gaps.sorted()[gaps.count / 2]
        return abs(medianGap - grid.beatIntervalSeconds) <= grid.beatIntervalSeconds * 0.1
    }

    /// Finds the first existing downbeat (beat 0 of a 4-beat bar) on or after the requested position.
    /// `step` 4 walks raw beats; pass `BeatGrid.barTimestamps` with `step: 1`.
    public func findQuantizedOutgoingDownbeat(timestamps: [Double], onOrAfter targetPosition: Double, step: Int = 4) -> Double? {
        guard targetPosition.isFinite, step > 0 else { return nil }
        for index in stride(from: 0, to: timestamps.count, by: step) {
            let timestamp = timestamps[index]
            if timestamp.isFinite && timestamp >= targetPosition { return timestamp }
        }
        return nil
    }

    /// Finds an existing incoming downbeat at or after the trim cue and strictly before the playable end.
    /// Returns nil instead of seeking backwards or fabricating a downbeat when none fits.
    public func findAlignedIncomingDownbeat(timestamps: [Double], near targetTrimCue: Double, duration: Double, step: Int = 4) -> Double? {
        guard targetTrimCue.isFinite, targetTrimCue >= 0, duration.isFinite, step > 0 else { return nil }
        for index in stride(from: 0, to: timestamps.count, by: step) {
            let timestamp = timestamps[index]
            if timestamp.isFinite && timestamp >= targetTrimCue && timestamp < duration { return timestamp }
        }
        return nil
    }

    // MARK: - Beat-Synced Bass Swap Planning

    private func planBeatSyncedBassSwap(
        request: TransitionRequest,
        triggerPosition: Double,
        bars: Int,
        allowFallback: Bool
    ) throws -> TransitionPlan {
        let outgoing = request.outgoingTrack
        let incoming = request.incomingTrack

        // 1. Verify beat grid authenticity (guard against sentinel 1.0s or empty grids)
        let outGridValid = isUsableBeatGrid(descriptor: outgoing)
        let inGridValid = isUsableBeatGrid(descriptor: incoming)

        if !outGridValid || !inGridValid {
            if allowFallback {
                return try planFilterEchoWash(
                    outgoing: outgoing,
                    incoming: incoming,
                    triggerPosition: triggerPosition,
                    durationSeconds: 8.0,
                    echoSend: 0.5,
                    style: request.style,
                    isFallback: true
                )
            }
            let failingDeck = !outGridValid ? outgoing.deck : incoming.deck
            throw TransitionPlanningError.missingBeatGrid(
                deck: failingDeck,
                reason: "Requires genuine beat grid with non-zero BPM and confidence (sentinel grids forbidden)"
            )
        }

        // A 6-beat bar never lines up with a 4-beat bar over a long blend.
        if outgoing.beatGrid.isCompoundMeter != incoming.beatGrid.isCompoundMeter {
            if allowFallback {
                return try planFilterEchoWash(
                    outgoing: outgoing, incoming: incoming, triggerPosition: triggerPosition,
                    durationSeconds: 8, echoSend: 0.5, style: request.style, isFallback: true
                )
            }
            throw TransitionPlanningError.meterMismatch
        }

        // 2. Validate BPM tempo differential (must be strictly < 6.0%)
        let effectiveTempo = 60.0 / outgoing.beatGrid.beatIntervalSeconds * Double(request.outgoingPlaybackRate)
        let incomingTempo = Self.foldedTempo(60.0 / incoming.beatGrid.beatIntervalSeconds, toward: effectiveTempo)
        let bpmDelta = abs(incomingTempo - effectiveTempo) / effectiveTempo
        if bpmDelta >= Self.maxTempoDifferential {
            if allowFallback {
                return try planFilterEchoWash(
                    outgoing: outgoing,
                    incoming: incoming,
                    triggerPosition: triggerPosition,
                    durationSeconds: 8.0,
                    echoSend: 0.5,
                    style: request.style,
                    isFallback: true
                )
            }
            throw TransitionPlanningError.tempoDifferenceExceedsThreshold(
                outgoingBPM: effectiveTempo,
                incomingBPM: incomingTempo,
                deltaPercent: bpmDelta * 100.0
            )
        }

        // 3. Quantize transition start to outgoing downbeat (beat 0 of a 4-beat bar)
        guard let quantizedStart = findQuantizedOutgoingDownbeat(timestamps: outgoing.beatGrid.barTimestamps, onOrAfter: triggerPosition, step: 1) else {
            if allowFallback {
                return try planFilterEchoWash(
                    outgoing: outgoing,
                    incoming: incoming,
                    triggerPosition: triggerPosition,
                    durationSeconds: 8.0,
                    echoSend: 0.5,
                    style: request.style,
                    isFallback: true
                )
            }
            throw TransitionPlanningError.missingBeatGrid(
                deck: outgoing.deck,
                reason: "No quantized outgoing downbeat found on or after trigger position \(triggerPosition)s"
            )
        }

        // 4. Choose an actual incoming downbeat without replaying manually trimmed audio.
        guard let incomingSeekPos = findAlignedIncomingDownbeat(
            timestamps: incoming.beatGrid.barTimestamps,
            near: incoming.cueMarkers.startTrimCue,
            duration: incoming.cueMarkers.endTrimCue,
            step: 1
        ) else {
            if allowFallback {
                return try planFilterEchoWash(
                    outgoing: outgoing, incoming: incoming, triggerPosition: triggerPosition,
                    durationSeconds: 8, echoSend: 0.5, style: request.style, isFallback: true
                )
            }
            throw TransitionPlanningError.missingBeatGrid(deck: incoming.deck, reason: "No downbeat fits the incoming trim interval")
        }


        // Outgoing beat duration in seconds
        let beatInterval = outgoing.beatGrid.beatIntervalSeconds
        // Offset of each bar line (0...bars) from the start. Real bar lines follow 3/4 downbeats and
        // drifting tempo; a grid that ends before the phrase does falls back to uniform 4/4 bars.
        let barOffsets = Self.barOffsets(bars: bars, from: quantizedStart, barTimestamps: outgoing.beatGrid.barTimestamps,
                                          beatInterval: beatInterval)
            ?? (0...bars).map { Double($0 * 4) * beatInterval }
        let totalDuration = barOffsets[bars]

        // 5. Pitch-locked incoming rate from the tempo both decks hold inside the mix window, so a
        // track whose tempo wanders still meets the other on the beat; whole-track tempo is the fallback.
        let averageRate = effectiveTempo / incomingTempo
        let foldFactor = incomingTempo * incoming.beatGrid.beatIntervalSeconds / 60.0
        let localRate = Self.localBeatInterval(outgoing.beatGrid.beatTimestamps, from: quantizedStart, through: quantizedStart + totalDuration)
            .flatMap { outInterval in
                Self.localBeatInterval(incoming.beatGrid.beatTimestamps, from: incomingSeekPos,
                                       through: incomingSeekPos + totalDuration * averageRate / Double(request.outgoingPlaybackRate))
                    .map { $0 * Double(request.outgoingPlaybackRate) / (outInterval * foldFactor) }
            }
            .flatMap { abs($0 / averageRate - 1) < 0.01 ? $0 : nil }
        let rate = Float(localRate ?? averageRate)
        guard rate.isFinite && rate >= 0.5 && rate <= 2.0 else {
            throw TransitionPlanningError.nonFiniteParameter("Calculated rate out of legal bounds: \(rate)")
        }

        // The swap sits 2 bars before the end so the outgoing track owns the mix until a clear, single
        // switch on a downbeat, then leaves fast (a slow mutual fade blurs both tops into a flam).
        let swapBar = bars - 2 // validateRequest allows 8, 16 or 32 bars
        let bassSwapOffsetSeconds = barOffsets[swapBar]
        // Four gain steps per bar (on the beat in 4/4): the engine applies them as steps, so per-bar steps would zipper.
        func beatOffset(bar: Int, beat: Int) -> Double {
            barOffsets[bar] + (barOffsets[bar + 1] - barOffsets[bar]) * Double(beat) / 4
        }

        var events: [ScheduledTransitionEvent] = []

        // MARK: t = 0.0 Initial Setup Events
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: 0.0,
            command: .setRate(deck: incoming.deck, rate: rate, keyLock: true),
            priority: .configuration
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: 0.0,
            command: .seek(deck: incoming.deck, positionSeconds: incomingSeekPos),
            priority: .transportPrep
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: 0.0,
            command: .setEQ(deck: incoming.deck, eq: EQ3BandParameters(lowGainDB: -24.0, midGainDB: -24.0, highGainDB: -24.0)),
            priority: .audioProcessing
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: 0.0,
            command: .setFilter(deck: incoming.deck, filter: ResonantFilterParameters(sweep: 0.0, resonance: 1.0)),
            priority: .audioProcessing
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: 0.0,
            command: .setVolume(deck: incoming.deck, volume: 1.0),
            priority: .volumeFader
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: 0.0,
            command: .play(deck: incoming.deck),
            priority: .transportStart
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: 0.0,
            command: .setVolume(deck: outgoing.deck, volume: 1.0),
            priority: .volumeFader
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: 0.0,
            command: .setEQ(deck: outgoing.deck, eq: EQ3BandParameters(lowGainDB: 0.0, midGainDB: 0.0, highGainDB: 0.0)),
            priority: .audioProcessing
        ))

        // MARK: Before the swap: incoming highs rise, outgoing highs make room, everything else holds.
        let preSwapBeats = swapBar * 4
        for step in 1..<max(1, preSwapBeats) {
            let progress = Double(step) / Double(preSwapBeats)
            let offset = beatOffset(bar: step / 4, beat: step % 4)
            events.append(ScheduledTransitionEvent(
                timeOffsetSeconds: offset,
                command: .setEQ(deck: incoming.deck, eq: EQ3BandParameters(lowGainDB: -24.0, midGainDB: -24.0, highGainDB: Float(-24.0 * (1 - progress)))),
                priority: .audioProcessing
            ))
            events.append(ScheduledTransitionEvent(
                timeOffsetSeconds: offset,
                command: .setEQ(deck: outgoing.deck, eq: EQ3BandParameters(lowGainDB: 0.0, midGainDB: 0.0, highGainDB: Float(-12.0 * progress))),
                priority: .audioProcessing
            ))
        }

        // MARK: Swap downbeat: lows and mids change hands at once.
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: bassSwapOffsetSeconds,
            command: .setEQ(deck: incoming.deck, eq: EQ3BandParameters(lowGainDB: 0.0, midGainDB: 0.0, highGainDB: 0.0)),
            priority: .audioProcessing
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: bassSwapOffsetSeconds,
            command: .setEQ(deck: outgoing.deck, eq: EQ3BandParameters(lowGainDB: -24.0, midGainDB: -24.0, highGainDB: -24.0)),
            priority: .audioProcessing
        ))

        // MARK: After the swap: the outgoing fader falls to silence by the end (cubed, so it drops early).
        let postSwapBeats = (bars - swapBar) * 4
        for step in 0..<postSwapBeats {
            let remaining = 1 - Double(step) / Double(postSwapBeats)
            let absolute = swapBar * 4 + step
            events.append(ScheduledTransitionEvent(
                timeOffsetSeconds: beatOffset(bar: absolute / 4, beat: absolute % 4),
                command: .setVolume(deck: outgoing.deck, volume: Float(remaining * remaining * remaining)),
                priority: .volumeFader
            ))
        }

        // MARK: t = totalDuration Completion Events
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: totalDuration,
            command: .setVolume(deck: outgoing.deck, volume: 0.0),
            priority: .volumeFader
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: totalDuration,
            command: .stop(deck: outgoing.deck),
            priority: .transportStop
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: totalDuration,
            command: .setEQ(deck: outgoing.deck, eq: EQ3BandParameters(lowGainDB: 0.0, midGainDB: 0.0, highGainDB: 0.0)),
            priority: .audioProcessing
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: totalDuration,
            command: .setVolume(deck: incoming.deck, volume: 1.0),
            priority: .volumeFader
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: totalDuration,
            command: .setEQ(deck: incoming.deck, eq: EQ3BandParameters(lowGainDB: 0.0, midGainDB: 0.0, highGainDB: 0.0)),
            priority: .audioProcessing
        ))

        // Deterministic sort: ascending timeOffset, then priority order
        events.sort {
            if $0.timeOffsetSeconds != $1.timeOffsetSeconds {
                return $0.timeOffsetSeconds < $1.timeOffsetSeconds
            }
            return $0.priority < $1.priority
        }

        let metadata = TransitionPlanMetadata(
            targetTempoBPM: effectiveTempo,
            tempoAdjustmentRate: rate,
            phraseBars: bars,
            bassSwapOffsetSeconds: bassSwapOffsetSeconds,
            isFallback: false
        )

        return TransitionPlan(
            style: request.style,
            outgoingDeck: outgoing.deck,
            incomingDeck: incoming.deck,
            startTimestampSeconds: quantizedStart,
            durationSeconds: totalDuration,
            events: events,
            metadata: metadata
        )
    }

    /// Beat spacing between two times: least-squares slope of beat time against beat number. Each beat is
    /// numbered from the last kept beat, so a median off by a frame never accumulates; hits far from a
    /// whole beat (spurious analyzer beats) drop out, and the 20 ms frame jitter averages out over the window.
    /// Nil with fewer than 8 kept beats.
    static func localBeatInterval(_ beats: [Double], from start: Double, through end: Double) -> Double? {
        let window = beats.filter { $0 >= start - 0.02 && $0 <= end + 0.02 }
        guard window.count >= 8, var last = window.first else { return nil }
        let gaps = zip(window, window.dropFirst()).map { $1 - $0 }.sorted()
        let pitch = gaps[gaps.count / 2]
        guard pitch.isFinite, pitch > 0 else { return nil }
        var number = 0.0
        var points = [(0.0, last)]
        for time in window.dropFirst() {
            let steps = ((time - last) / pitch).rounded()
            guard steps >= 1, abs(time - last - steps * pitch) <= 0.25 * pitch else { continue }
            number += steps
            points.append((number, time))
            last = time
        }
        guard points.count >= 8 else { return nil }
        let meanX = points.map(\.0).reduce(0, +) / Double(points.count)
        let meanY = points.map(\.1).reduce(0, +) / Double(points.count)
        let sxx = points.reduce(0) { $0 + ($1.0 - meanX) * ($1.0 - meanX) }
        let sxy = points.reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        return sxx > 0 ? sxy / sxx : nil
    }

    /// Bar-line offsets from `start` taken from the grid, or nil when the grid lacks `bars` further bars
    /// or a bar is implausibly short or long (a missed or spurious downbeat).
    static func barOffsets(bars: Int, from start: Double, barTimestamps: [Double], beatInterval: Double) -> [Double]? {
        let tolerance = 1e-6
        guard let first = barTimestamps.firstIndex(where: { abs($0 - start) <= tolerance }),
              first + bars < barTimestamps.count else { return nil }
        let offsets = barTimestamps[first...(first + bars)].map { $0 - start }
        let plausibleBar = (1.5 * beatInterval)...(8.5 * beatInterval)
        guard zip(offsets, offsets.dropFirst()).allSatisfy({ $1.isFinite && plausibleBar.contains($1 - $0) }) else { return nil }
        return offsets
    }

    // MARK: - Filter Echo Wash Planning

    private func planFilterEchoWash(
        outgoing: TrackTransitionDescriptor,
        incoming: TrackTransitionDescriptor,
        triggerPosition: Double,
        durationSeconds: Double,
        echoSend: Float,
        style: TransitionStyle,
        isFallback: Bool
    ) throws -> TransitionPlan {
        let keyframeCount = max(Self.defaultWashKeyframes, Int((durationSeconds * Self.washKeyframesPerSecond).rounded(.up)))
        var events: [ScheduledTransitionEvent] = []

        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: 0,
            command: .setRate(deck: incoming.deck, rate: 1, keyLock: true),
            priority: .configuration
        ))

        // MARK: t = 0.0 Initial Setup Events
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: 0.0,
            command: .seek(deck: incoming.deck, positionSeconds: incoming.cueMarkers.startTrimCue),
            priority: .transportPrep
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: 0.0,
            command: .setEQ(deck: incoming.deck, eq: EQ3BandParameters(lowGainDB: 0.0, midGainDB: 0.0, highGainDB: 0.0)),
            priority: .audioProcessing
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: 0.0,
            command: .setFilter(deck: incoming.deck, filter: ResonantFilterParameters(sweep: 0.0, resonance: 1.0)),
            priority: .audioProcessing
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: 0.0,
            // Starts dry: switching straight to the full wet mix drops the dry signal at once.
            command: .setEcho(deck: outgoing.deck, enabled: true, feedback: 0.5, mix: 0),
            priority: .audioProcessing
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: 0.0,
            command: .setFilter(deck: outgoing.deck, filter: ResonantFilterParameters(sweep: 0.0, resonance: 1.0)),
            priority: .audioProcessing
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: 0.0,
            command: .setVolume(deck: incoming.deck, volume: 0.0),
            priority: .gainPreparation
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: 0.0,
            command: .play(deck: incoming.deck),
            priority: .transportStart
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: 0.0,
            command: .setVolume(deck: outgoing.deck, volume: 1.0),
            priority: .volumeFader
        ))

        // MARK: Equal-Power S-Curve Discrete Automation Steps
        // Equal power formula: outGain^2 + inGain^2 = 1.0
        // s(p) = 3p^2 - 2p^3 (smoothstep S-curve mapping)
        // outGain = cos(s(p) * pi / 2)
        // inGain = sin(s(p) * pi / 2)
        for i in 1..<keyframeCount {
            let p = Double(i) / Double(keyframeCount)
            let offset = p * durationSeconds
            let sCurveP = (3.0 * p * p) - (2.0 * p * p * p)

            let outGain = Float(cos(sCurveP * .pi / 2.0))
            let inGain = Float(sin(sCurveP * .pi / 2.0))
            let filterSweep = Float(sCurveP * 0.85) // Sweep resonant high-pass filter upwards

            events.append(ScheduledTransitionEvent(
                timeOffsetSeconds: offset,
                command: .setFilter(deck: outgoing.deck, filter: ResonantFilterParameters(sweep: filterSweep, resonance: 1.4)),
                priority: .audioProcessing
            ))
            events.append(ScheduledTransitionEvent(
                timeOffsetSeconds: offset,
                command: .setVolume(deck: outgoing.deck, volume: outGain),
                priority: .volumeFader
            ))
            // The echo fades in over the first quarter of the wash.
            if p <= 0.25 + 1e-9 {
                events.append(ScheduledTransitionEvent(
                    timeOffsetSeconds: offset,
                    command: .setEcho(deck: outgoing.deck, enabled: true, feedback: 0.5, mix: echoSend * Float(min(1, p / 0.25))),
                    priority: .audioProcessing
                ))
            }
            events.append(ScheduledTransitionEvent(
                timeOffsetSeconds: offset,
                command: .setVolume(deck: incoming.deck, volume: inGain),
                priority: .volumeFader
            ))
        }

        // MARK: t = duration Completion Events
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: durationSeconds,
            command: .setVolume(deck: outgoing.deck, volume: 0.0),
            priority: .volumeFader
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: durationSeconds,
            command: .setEcho(deck: outgoing.deck, enabled: false, feedback: 0.0, mix: 0.0),
            priority: .audioProcessing
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: durationSeconds,
            command: .setFilter(deck: outgoing.deck, filter: ResonantFilterParameters(sweep: 0.0, resonance: 1.0)),
            priority: .audioProcessing
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: durationSeconds,
            command: .stop(deck: outgoing.deck),
            priority: .transportStop
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: durationSeconds,
            command: .setVolume(deck: incoming.deck, volume: 1.0),
            priority: .volumeFader
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: durationSeconds,
            command: .setFilter(deck: incoming.deck, filter: ResonantFilterParameters(sweep: 0.0, resonance: 1.0)),
            priority: .audioProcessing
        ))

        events.sort {
            if $0.timeOffsetSeconds != $1.timeOffsetSeconds {
                return $0.timeOffsetSeconds < $1.timeOffsetSeconds
            }
            return $0.priority < $1.priority
        }

        let metadata = TransitionPlanMetadata(
            isFallback: isFallback
        )

        return TransitionPlan(
            style: style,
            outgoingDeck: outgoing.deck,
            incomingDeck: incoming.deck,
            startTimestampSeconds: triggerPosition,
            durationSeconds: durationSeconds,
            events: events,
            metadata: metadata
        )
    }

    // MARK: - Hard Cut on Drop Planning

    private func planHardCutOnDrop(
        request: TransitionRequest,
        triggerPosition: Double,
        bars: Int,
        allowFallback: Bool
    ) throws -> TransitionPlan {
        let outgoing = request.outgoingTrack
        let incoming = request.incomingTrack

        // Verify outgoing track beat grid availability
        guard isUsableBeatGrid(descriptor: outgoing) else {
            if allowFallback {
                return try planFilterEchoWash(
                    outgoing: outgoing,
                    incoming: incoming,
                    triggerPosition: triggerPosition,
                    durationSeconds: 8.0,
                    echoSend: 0.5,
                    style: request.style,
                    isFallback: true
                )
            }
            throw TransitionPlanningError.missingBeatGrid(
                deck: outgoing.deck,
                reason: "Hard cut bar quantization requires valid beat grid"
            )
        }

        // Find the quantized downbeat (beat 0 of a 4-beat bar) at or after trigger position
        guard let cutTime = findQuantizedOutgoingDownbeat(timestamps: outgoing.beatGrid.barTimestamps, onOrAfter: triggerPosition, step: 1) else {
            if allowFallback {
                return try planFilterEchoWash(
                    outgoing: outgoing,
                    incoming: incoming,
                    triggerPosition: triggerPosition,
                    durationSeconds: 8.0,
                    echoSend: 0.5,
                    style: request.style,
                    isFallback: true
                )
            }
            throw TransitionPlanningError.missingBeatGrid(
                deck: outgoing.deck,
                reason: "No quantized bar downbeat found at or after trigger position \(triggerPosition)s"
            )
        }

        let incomingSeekPos: Double
        if isUsableBeatGrid(descriptor: incoming) {
            guard let downbeat = findAlignedIncomingDownbeat(
                timestamps: incoming.beatGrid.barTimestamps,
                near: incoming.cueMarkers.startTrimCue,
                duration: incoming.cueMarkers.endTrimCue,
                step: 1
            ) else {
                if allowFallback {
                    return try planFilterEchoWash(
                        outgoing: outgoing, incoming: incoming, triggerPosition: triggerPosition,
                        durationSeconds: 8, echoSend: 0.5, style: request.style, isFallback: true
                    )
                }
                throw TransitionPlanningError.missingBeatGrid(deck: incoming.deck, reason: "No downbeat fits the incoming trim interval")
            }
            incomingSeekPos = downbeat
        } else {
            // A hard cut needs only the outgoing grid. Preserve the incoming trim cue for unknown tempo.
            incomingSeekPos = incoming.cueMarkers.startTrimCue
        }

        let cutOffsetSeconds = max(0.0, cutTime - triggerPosition)
        let totalDuration = cutOffsetSeconds

        var events: [ScheduledTransitionEvent] = [ScheduledTransitionEvent(
            timeOffsetSeconds: 0,
            command: .setRate(deck: incoming.deck, rate: 1, keyLock: true),
            priority: .configuration
        )]

        // MARK: t = 0.0 Pre-Cue Incoming Deck
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: 0.0,
            command: .seek(deck: incoming.deck, positionSeconds: incomingSeekPos),
            priority: .transportPrep
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: 0.0,
            command: .setVolume(deck: incoming.deck, volume: 0.0),
            priority: .gainPreparation
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: 0.0,
            command: .setEQ(deck: incoming.deck, eq: EQ3BandParameters(lowGainDB: 0.0, midGainDB: 0.0, highGainDB: 0.0)),
            priority: .audioProcessing
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: 0.0,
            command: .setFilter(deck: incoming.deck, filter: ResonantFilterParameters(sweep: 0.0, resonance: 1.0)),
            priority: .audioProcessing
        ))

        // MARK: t = cutOffsetSeconds Instant Hard Cut
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: cutOffsetSeconds,
            command: .setVolume(deck: outgoing.deck, volume: 0.0),
            priority: .volumeFader
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: cutOffsetSeconds,
            command: .stop(deck: outgoing.deck),
            priority: .transportStop
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: cutOffsetSeconds,
            command: .setVolume(deck: incoming.deck, volume: 1.0),
            priority: .volumeFader
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: cutOffsetSeconds,
            command: .play(deck: incoming.deck),
            priority: .transportStart
        ))

        events.sort {
            if $0.timeOffsetSeconds != $1.timeOffsetSeconds {
                return $0.timeOffsetSeconds < $1.timeOffsetSeconds
            }
            return $0.priority < $1.priority
        }

        let metadata = TransitionPlanMetadata(
            phraseBars: bars,
            bassSwapOffsetSeconds: cutOffsetSeconds,
            isFallback: false
        )

        return TransitionPlan(
            style: request.style,
            outgoingDeck: outgoing.deck,
            incomingDeck: incoming.deck,
            startTimestampSeconds: triggerPosition,
            durationSeconds: totalDuration,
            events: events,
            metadata: metadata
        )
    }
}
