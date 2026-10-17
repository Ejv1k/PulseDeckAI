import Foundation

/// Pure deterministic planner for automated multi-deck transitions.
///
/// Converts a high-level transition request into a bounded, discrete timeline schedule
/// of executable audio commands without timers, tasks, or audio framework dependencies.
public struct TransitionPlanner: Sendable {

    /// Maximum allowable tempo differential (6.0%) for beat-synced transitions.
    public static let maxTempoDifferential: Double = 0.06

    /// Discrete keyframe resolution for continuous curve transitions (e.g. Filter Echo Wash).
    public static let defaultWashKeyframes: Int = 16

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

    /// Validates the complete regular grid, including its phase, interval, tempo and bounds.
    /// Positive schema sentinels never establish a usable tempo without genuine timestamps.
    public func isUsableBeatGrid(descriptor: TrackTransitionDescriptor) -> Bool {
        let grid = descriptor.beatGrid
        guard descriptor.duration.isFinite, descriptor.duration > 0,
              descriptor.bpm.isFinite, descriptor.bpm > 0,
              descriptor.confidence.isFinite, (0...1).contains(descriptor.confidence), descriptor.confidence > 0,
              grid.firstBeatOffsetSeconds.isFinite, grid.firstBeatOffsetSeconds >= 0,
              grid.beatIntervalSeconds.isFinite, grid.beatIntervalSeconds > 0,
              grid.beatTimestamps.count >= 2 else { return false }
        let tolerance = max(1e-7, grid.beatIntervalSeconds * 1e-6)
        guard abs(grid.beatIntervalSeconds - 60 / descriptor.bpm) <= tolerance else { return false }
        var previous = -Double.infinity
        for (index, timestamp) in grid.beatTimestamps.enumerated() {
            let expected = grid.firstBeatOffsetSeconds + Double(index) * grid.beatIntervalSeconds
            guard timestamp.isFinite, timestamp >= 0, timestamp <= descriptor.duration,
                  timestamp > previous, expected.isFinite, abs(timestamp - expected) <= tolerance else { return false }
            previous = timestamp
        }
        return true
    }

    /// Finds the first existing downbeat (beat 0 of a 4-beat bar) on or after the requested position.
    public func findQuantizedOutgoingDownbeat(timestamps: [Double], onOrAfter targetPosition: Double) -> Double? {
        guard targetPosition.isFinite else { return nil }
        for index in stride(from: 0, to: timestamps.count, by: 4) {
            let timestamp = timestamps[index]
            if timestamp.isFinite && timestamp >= targetPosition { return timestamp }
        }
        return nil
    }

    /// Finds an existing incoming downbeat at or after the trim cue and strictly before the playable end.
    /// Returns nil instead of seeking backwards or fabricating a downbeat when none fits.
    public func findAlignedIncomingDownbeat(timestamps: [Double], near targetTrimCue: Double, duration: Double) -> Double? {
        guard targetTrimCue.isFinite, targetTrimCue >= 0, duration.isFinite else { return nil }
        for index in stride(from: 0, to: timestamps.count, by: 4) {
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

        // 2. Validate BPM tempo differential (must be strictly < 6.0%)
        let effectiveTempo = 60.0 / outgoing.beatGrid.beatIntervalSeconds * Double(request.outgoingPlaybackRate)
        let incomingTempo = 60.0 / incoming.beatGrid.beatIntervalSeconds
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
        guard let quantizedStart = findQuantizedOutgoingDownbeat(timestamps: outgoing.beatGrid.beatTimestamps, onOrAfter: triggerPosition) else {
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
            timestamps: incoming.beatGrid.beatTimestamps,
            near: incoming.cueMarkers.startTrimCue,
            duration: incoming.cueMarkers.endTrimCue
        ) else {
            if allowFallback {
                return try planFilterEchoWash(
                    outgoing: outgoing, incoming: incoming, triggerPosition: triggerPosition,
                    durationSeconds: 8, echoSend: 0.5, style: request.style, isFallback: true
                )
            }
            throw TransitionPlanningError.missingBeatGrid(deck: incoming.deck, reason: "No downbeat fits the incoming trim interval")
        }

        // 5. Compute pitch-locked tempo adjustment rate for incoming deck
        let rate = Float(effectiveTempo / incomingTempo)
        guard rate.isFinite && rate >= 0.5 && rate <= 2.0 else {
            throw TransitionPlanningError.nonFiniteParameter("Calculated rate out of legal bounds: \(rate)")
        }

        // Outgoing beat duration in seconds
        let beatInterval = outgoing.beatGrid.beatIntervalSeconds
        let totalBeats = bars * 4
        let totalDuration = Double(totalBeats) * beatInterval

        // Midpoint downbeat calculation: half of phrase bars (e.g. bar 8 downbeat for a 16-bar transition)
        let midpointBars = max(1, bars / 2)
        let bassSwapOffsetSeconds = Double(midpointBars * 4) * beatInterval

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
            command: .setEQ(deck: incoming.deck, eq: EQ3BandParameters(lowGainDB: -24.0, midGainDB: -12.0, highGainDB: -12.0)),
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

        // MARK: Intermediate Bar-Quantized Progressions
        for barIndex in 1..<bars {
            let offset = Double(barIndex * 4) * beatInterval
            let progress = Double(barIndex) / Double(bars)

            // Continuous monotonic outgoing fader fade from 1.0 down towards 0.0
            let outVol = Float(max(0.0, 1.0 - progress))
            events.append(ScheduledTransitionEvent(
                timeOffsetSeconds: offset,
                command: .setVolume(deck: outgoing.deck, volume: outVol),
                priority: .volumeFader
            ))

            // Complementary mid and high frequency EQ crossfade
            let outMidHigh = Float(-24.0 * progress)
            let inMidHigh = Float(-12.0 * (1.0 - progress))

            if barIndex < midpointBars {
                // Pre-swap: outgoing low shelf remains unity (0 dB), incoming low shelf cut (-24 dB)
                events.append(ScheduledTransitionEvent(
                    timeOffsetSeconds: offset,
                    command: .setEQ(deck: outgoing.deck, eq: EQ3BandParameters(lowGainDB: 0.0, midGainDB: outMidHigh, highGainDB: outMidHigh)),
                    priority: .audioProcessing
                ))
                events.append(ScheduledTransitionEvent(
                    timeOffsetSeconds: offset,
                    command: .setEQ(deck: incoming.deck, eq: EQ3BandParameters(lowGainDB: -24.0, midGainDB: inMidHigh, highGainDB: inMidHigh)),
                    priority: .audioProcessing
                ))
            } else {
                // At and post-midpoint downbeat: INSTANT BASS SWAP (outgoing low = -24 dB, incoming low = 0 dB)
                events.append(ScheduledTransitionEvent(
                    timeOffsetSeconds: offset,
                    command: .setEQ(deck: outgoing.deck, eq: EQ3BandParameters(lowGainDB: -24.0, midGainDB: outMidHigh, highGainDB: outMidHigh)),
                    priority: .audioProcessing
                ))
                events.append(ScheduledTransitionEvent(
                    timeOffsetSeconds: offset,
                    command: .setEQ(deck: incoming.deck, eq: EQ3BandParameters(lowGainDB: 0.0, midGainDB: inMidHigh, highGainDB: inMidHigh)),
                    priority: .audioProcessing
                ))
            }
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
        let keyframeCount = Self.defaultWashKeyframes
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
            command: .setEcho(deck: outgoing.deck, enabled: true, feedback: 0.5, mix: echoSend),
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
        guard let cutTime = findQuantizedOutgoingDownbeat(timestamps: outgoing.beatGrid.beatTimestamps, onOrAfter: triggerPosition) else {
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
                timestamps: incoming.beatGrid.beatTimestamps,
                near: incoming.cueMarkers.startTrimCue,
                duration: incoming.cueMarkers.endTrimCue
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
