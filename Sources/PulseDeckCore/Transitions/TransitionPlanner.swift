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

        switch request.style {
        case .beatSyncedBassSwap(let bars, let allowFallback):
            return try planBeatSyncedBassSwap(
                request: request,
                triggerPosition: triggerPos,
                bars: bars,
                allowFallback: allowFallback
            )

        case .filterEchoWash(let durationSeconds, let echoSend):
            return try planFilterEchoWash(
                outgoing: request.outgoingTrack,
                incoming: request.incomingTrack,
                triggerPosition: triggerPos,
                durationSeconds: durationSeconds,
                echoSend: echoSend,
                style: request.style,
                isFallback: false
            )

        case .hardCutOnDrop(let bars, let allowFallback):
            return try planHardCutOnDrop(
                request: request,
                triggerPosition: triggerPos,
                bars: bars,
                allowFallback: allowFallback
            )
        }
    }

    // MARK: - Validation

    private func validateRequest(_ request: TransitionRequest) throws {
        // Deck identity invariant: outgoing and incoming must differ
        guard request.outgoingTrack.deck != request.incomingTrack.deck else {
            throw TransitionPlanningError.sameDeck(request.outgoingTrack.deck)
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
        guard triggerPos.isFinite && triggerPos >= 0.0 && triggerPos <= request.outgoingTrack.duration else {
            throw TransitionPlanningError.triggerPositionOutOfBounds(
                position: triggerPos,
                mixOutCue: request.outgoingTrack.cueMarkers.mixOutCue,
                duration: request.outgoingTrack.duration
            )
        }

        // Style parameter validation
        switch request.style {
        case .beatSyncedBassSwap(let bars, _):
            guard bars > 0 else {
                throw TransitionPlanningError.nonFiniteParameter("Beat-synced bars count must be > 0, got: \(bars)")
            }
        case .filterEchoWash(let durationSeconds, let echoSend):
            guard durationSeconds.isFinite && durationSeconds > 0 else {
                throw TransitionPlanningError.nonFiniteParameter("Filter wash duration must be positive and finite: \(durationSeconds)")
            }
            guard echoSend.isFinite && echoSend >= 0.0 && echoSend <= 1.0 else {
                throw TransitionPlanningError.nonFiniteParameter("Filter wash echoSend must be in range [0.0, 1.0], got: \(echoSend)")
            }
        case .hardCutOnDrop(let bars, _):
            guard bars > 0 else {
                throw TransitionPlanningError.nonFiniteParameter("Hard cut bars count must be > 0, got: \(bars)")
            }
        }
    }

    /// Validates whether a track descriptor has an authentic, usable beat grid.
    /// Rejects sentinel schema fallbacks (bpm <= 0, confidence <= 0, empty timestamps).
    public func isUsableBeatGrid(descriptor: TrackTransitionDescriptor) -> Bool {
        guard descriptor.bpm.isFinite && descriptor.bpm > 0 else { return false }
        guard descriptor.confidence.isFinite && descriptor.confidence > 0 else { return false }
        guard !descriptor.beatGrid.beatTimestamps.isEmpty else { return false }
        guard descriptor.beatGrid.beatIntervalSeconds.isFinite && descriptor.beatGrid.beatIntervalSeconds > 0 else { return false }
        guard descriptor.beatGrid.beatTimestamps.count >= 2 else { return false }
        return true
    }

    /// Finds the first downbeat (beat 0 of a 4-beat bar) in timestamps on or after targetPosition.
    public func findQuantizedOutgoingDownbeat(timestamps: [Double], onOrAfter targetPosition: Double) -> Double? {
        guard !timestamps.isEmpty else { return nil }
        for i in stride(from: 0, to: timestamps.count, by: 4) {
            let t = timestamps[i]
            if t >= targetPosition - 0.0001 {
                return t
            }
        }
        return nil
    }

    /// Finds the downbeat (beat 0 of a 4-beat bar) in incoming timestamps closest to targetTrimCue,
    /// clamped within track duration.
    public func findAlignedIncomingDownbeat(timestamps: [Double], near targetTrimCue: Double, duration: Double) -> Double {
        guard !timestamps.isEmpty else { return min(max(0.0, targetTrimCue), duration) }
        var bestDownbeat = timestamps[0]
        var minDiff = abs(timestamps[0] - targetTrimCue)
        for i in stride(from: 0, to: timestamps.count, by: 4) {
            let t = timestamps[i]
            let diff = abs(t - targetTrimCue)
            if diff < minDiff {
                minDiff = diff
                bestDownbeat = t
            }
        }
        return min(max(0.0, bestDownbeat), duration)
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
        let bpmDelta = abs(incoming.bpm - outgoing.bpm) / outgoing.bpm
        if bpmDelta >= (Self.maxTempoDifferential - 1e-9) {
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
                outgoingBPM: outgoing.bpm,
                incomingBPM: incoming.bpm,
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

        // 4. Align incoming seek position to nearest incoming downbeat respecting startTrimCue
        let incomingSeekPos = findAlignedIncomingDownbeat(
            timestamps: incoming.beatGrid.beatTimestamps,
            near: incoming.cueMarkers.startTrimCue,
            duration: incoming.duration
        )

        // 5. Compute pitch-locked tempo adjustment rate for incoming deck
        let rate = Float(outgoing.bpm / incoming.bpm)
        guard rate.isFinite && rate >= 0.5 && rate <= 2.0 else {
            throw TransitionPlanningError.nonFiniteParameter("Calculated rate out of legal bounds: \(rate)")
        }

        // Outgoing beat duration in seconds
        let beatInterval = 60.0 / outgoing.bpm
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
            if abs($0.timeOffsetSeconds - $1.timeOffsetSeconds) > 0.0001 {
                return $0.timeOffsetSeconds < $1.timeOffsetSeconds
            }
            return $0.priority < $1.priority
        }

        let metadata = TransitionPlanMetadata(
            targetTempoBPM: outgoing.bpm,
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
            command: .setVolume(deck: incoming.deck, volume: 0.0),
            priority: .volumeFader
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: 0.0,
            command: .play(deck: incoming.deck),
            priority: .transportStart
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
            if abs($0.timeOffsetSeconds - $1.timeOffsetSeconds) > 0.0001 {
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

        let incomingSeekPos = findAlignedIncomingDownbeat(
            timestamps: incoming.beatGrid.beatTimestamps,
            near: incoming.cueMarkers.startTrimCue,
            duration: incoming.duration
        )

        let cutOffsetSeconds = max(0.0, cutTime - triggerPosition)
        let totalDuration = max(0.01, cutOffsetSeconds)

        var events: [ScheduledTransitionEvent] = []

        // MARK: t = 0.0 Pre-Cue Incoming Deck
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: 0.0,
            command: .seek(deck: incoming.deck, positionSeconds: incomingSeekPos),
            priority: .transportPrep
        ))
        events.append(ScheduledTransitionEvent(
            timeOffsetSeconds: 0.0,
            command: .setVolume(deck: incoming.deck, volume: 0.0),
            priority: .volumeFader
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
            if abs($0.timeOffsetSeconds - $1.timeOffsetSeconds) > 0.0001 {
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
