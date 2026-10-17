import XCTest
@testable import PulseDeckCore

final class TransitionPlannerTests: XCTestCase {

    // MARK: - Test Helpers

    private func makeBeatGrid(bpm: Double, duration: Double = 240.0, offset: Double = 0.0) -> BeatGrid {
        let interval = 60.0 / bpm
        let count = max(0, Int(floor((duration - offset) / interval)) + 1)
        var timestamps: [Double] = []
        for i in 0..<count {
            timestamps.append(offset + Double(i) * interval)
        }
        return BeatGrid(
            firstBeatOffsetSeconds: offset,
            beatIntervalSeconds: interval,
            beatTimestamps: timestamps
        )
    }

    private func makeTrack(
        deck: DeckIdentifier,
        duration: Double = 240.0,
        bpm: Double = 120.0,
        confidence: Double = 0.95,
        startTrim: Double = 10.0,
        vocalEntry: Double = 30.0,
        mixOut: Double = 200.0,
        endTrim: Double = 235.0,
        beatGrid: BeatGrid? = nil
    ) -> TrackTransitionDescriptor {
        let grid = beatGrid ?? makeBeatGrid(bpm: bpm > 0 ? bpm : 120.0, duration: duration.isFinite && duration > 0 ? duration : 240)
        let cues = CueMarkers(
            startTrimCue: startTrim,
            vocalEntryCue: vocalEntry,
            mixOutCue: mixOut,
            endTrimCue: endTrim
        )
        return TrackTransitionDescriptor(
            deck: deck,
            duration: duration,
            bpm: bpm,
            confidence: confidence,
            cueMarkers: cues,
            beatGrid: grid
        )
    }

    // MARK: - Beat-Synced Bass Swap Tests

    func testBeatSyncedBassSwapReal120And126Tempos() throws {
        let planner = TransitionPlanner()
        let outgoing = makeTrack(deck: .deckA, bpm: 120.0)
        let incoming = makeTrack(deck: .deckB, bpm: 126.0)

        // 126 vs 120 BPM: delta is |126 - 120| / 120 = 5.0%, within 6.0% limit
        let request = TransitionRequest(
            outgoingTrack: outgoing,
            incomingTrack: incoming,
            style: .beatSyncedBassSwap(bars: 16)
        )

        let plan = try planner.plan(request)

        XCTAssertEqual(plan.outgoingDeck, .deckA)
        XCTAssertEqual(plan.incomingDeck, .deckB)
        XCTAssertEqual(plan.startTimestampSeconds, 200.0) // defaults to mixOutCue

        // 16 bars of 4/4 at 120 BPM = 64 beats * 0.5s = 32.0s
        XCTAssertEqual(plan.durationSeconds, 32.0, accuracy: 0.001)

        // Metadata check
        XCTAssertEqual(plan.metadata.targetTempoBPM, 120.0)
        let expectedRate = Float(120.0 / 126.0)
        XCTAssertEqual(try XCTUnwrap(plan.metadata.tempoAdjustmentRate), expectedRate, accuracy: 0.001)
        XCTAssertEqual(plan.metadata.phraseBars, 16)
        XCTAssertEqual(try XCTUnwrap(plan.metadata.bassSwapOffsetSeconds), 16.0, accuracy: 0.001)
        XCTAssertFalse(plan.metadata.isFallback)

        // Initial setup events at t = 0
        let initialEvents = plan.events.filter { abs($0.timeOffsetSeconds) < 0.001 }
        XCTAssertFalse(initialEvents.isEmpty)

        // Verify incoming rate instruction
        let rateEvent = try XCTUnwrap(initialEvents.first {
            if case .setRate(let d, let r, let lock) = $0.command {
                return d == .deckB && abs(r - expectedRate) < 0.001 && lock
            }
            return false
        })
        XCTAssertEqual(rateEvent.priority, .configuration)

        // Verify incoming seek aligns to nearest incoming downbeat respecting startTrimCue
        let seekEvent = try XCTUnwrap(initialEvents.first {
            if case .seek(let d, let pos) = $0.command {
                return d == .deckB && abs(pos - 11.4286) < 0.01
            }
            return false
        })
        XCTAssertEqual(seekEvent.priority, .transportPrep)

        // Verify incoming initial low-shelf bass cut (-24 dB)
        XCTAssertTrue(initialEvents.contains {
            if case .setEQ(let d, let eq) = $0.command {
                return d == .deckB && eq.lowGainDB == -24.0
            }
            return false
        })

        // Verify incoming playback start
        XCTAssertTrue(initialEvents.contains {
            if case .play(let d) = $0.command { return d == .deckB }
            return false
        })

        // Verify Midpoint Downbeat Bass Swap at t = 16.0s (bar 8 downbeat)
        let midpointEvents = plan.events.filter { abs($0.timeOffsetSeconds - 16.0) < 0.001 }
        XCTAssertFalse(midpointEvents.isEmpty)

        // Outgoing bass cut to -24 dB
        XCTAssertTrue(midpointEvents.contains {
            if case .setEQ(let d, let eq) = $0.command {
                return d == .deckA && eq.lowGainDB == -24.0
            }
            return false
        })

        // Incoming bass restored to 0 dB
        XCTAssertTrue(midpointEvents.contains {
            if case .setEQ(let d, let eq) = $0.command {
                return d == .deckB && eq.lowGainDB == 0.0
            }
            return false
        })

        // Verify Completion at t = 32.0s
        let endEvents = plan.events.filter { abs($0.timeOffsetSeconds - 32.0) < 0.001 }
        XCTAssertTrue(endEvents.contains {
            if case .setVolume(let d, let vol) = $0.command {
                return d == .deckA && vol == 0.0
            }
            return false
        })
        XCTAssertTrue(endEvents.contains {
            if case .stop(let d) = $0.command { return d == .deckA }
            return false
        })
        XCTAssertTrue(endEvents.contains {
            if case .setVolume(let d, let vol) = $0.command {
                return d == .deckB && vol == 1.0
            }
            return false
        })

        // Bounded plan verification: must not create thousands of automation events
        XCTAssertLessThanOrEqual(plan.events.count, 60)
    }

    func testBeatSyncedBassSwapComplementaryGainProgressionAndContinuousFader() throws {
        let planner = TransitionPlanner()
        let outgoing = makeTrack(deck: .deckA, bpm: 120.0)
        let incoming = makeTrack(deck: .deckB, bpm: 126.0)

        let request = TransitionRequest(
            outgoingTrack: outgoing,
            incomingTrack: incoming,
            style: .beatSyncedBassSwap(bars: 16)
        )

        let plan = try planner.plan(request)
        let beatInterval = 60.0 / 120.0 // 0.5s

        // Test each bar boundary 1..<16
        for barIndex in 1..<16 {
            let offset = Double(barIndex * 4) * beatInterval
            let barEvents = plan.events.filter { abs($0.timeOffsetSeconds - offset) < 0.001 }
            let progress = Double(barIndex) / 16.0

            // 1. Outgoing volume fader must be continuous and monotonic: exactly (1.0 - progress)
            let outVolEvent = try XCTUnwrap(barEvents.first {
                if case .setVolume(let d, let v) = $0.command { return d == .deckA && abs(v - Float(1.0 - progress)) < 0.001 }
                return false
            })
            XCTAssertEqual(outVolEvent.priority, .volumeFader)

            // 2. Outgoing EQ mid/high ramps down: -24.0 * progress
            let expectedOutMidHigh = Float(-24.0 * progress)
            let expectedOutLow: Float = barIndex < 8 ? 0.0 : -24.0
            XCTAssertTrue(barEvents.contains {
                if case .setEQ(let d, let eq) = $0.command {
                    return d == .deckA && eq.lowGainDB == expectedOutLow
                        && abs(eq.midGainDB - expectedOutMidHigh) < 0.001
                        && abs(eq.highGainDB - expectedOutMidHigh) < 0.001
                }
                return false
            })

            // 3. Incoming EQ mid/high ramps up: -12.0 * (1.0 - progress)
            let expectedInMidHigh = Float(-12.0 * (1.0 - progress))
            let expectedInLow: Float = barIndex < 8 ? -24.0 : 0.0
            XCTAssertTrue(barEvents.contains {
                if case .setEQ(let d, let eq) = $0.command {
                    return d == .deckB && eq.lowGainDB == expectedInLow
                        && abs(eq.midGainDB - expectedInMidHigh) < 0.001
                        && abs(eq.highGainDB - expectedInMidHigh) < 0.001
                }
                return false
            })
        }
    }

    func testTempoDifferenceThreshold6Percent() throws {
        let planner = TransitionPlanner()
        let outgoing = makeTrack(deck: .deckA, bpm: 120.0)

        // 127.08 BPM: |127.08 - 120| / 120 = 5.9% (< 6.0%) -> must succeed
        let incomingUnder6 = makeTrack(deck: .deckB, bpm: 127.08)
        let requestUnder6 = TransitionRequest(
            outgoingTrack: outgoing,
            incomingTrack: incomingUnder6,
            style: .beatSyncedBassSwap(bars: 8)
        )
        XCTAssertNoThrow(try planner.plan(requestUnder6))

        // 127.2 BPM: |127.2 - 120| / 120 = 0.060 (exactly 6.0%, NOT strictly < 6.0%) -> must throw or fallback
        let incoming6Percent = makeTrack(deck: .deckB, bpm: 127.2)
        let request6NoFallback = TransitionRequest(
            outgoingTrack: outgoing,
            incomingTrack: incoming6Percent,
            style: .beatSyncedBassSwap(bars: 8, allowFallbackToFilter: false)
        )
        XCTAssertThrowsError(try planner.plan(request6NoFallback)) { error in
            guard case TransitionPlanningError.tempoDifferenceExceedsThreshold(let outBPM, let inBPM, _) = error else {
                XCTFail("Expected tempoDifferenceExceedsThreshold, got: \(error)")
                return
            }
            XCTAssertEqual(outBPM, 120.0)
            XCTAssertEqual(inBPM, 127.2)
        }

        // 128.0 BPM: |128 - 120| / 120 = 6.67% > 6.0% -> must throw or fallback
        let incomingOver = makeTrack(deck: .deckB, bpm: 128.0)
        let requestNoFallback = TransitionRequest(
            outgoingTrack: outgoing,
            incomingTrack: incomingOver,
            style: .beatSyncedBassSwap(bars: 8, allowFallbackToFilter: false)
        )
        XCTAssertThrowsError(try planner.plan(requestNoFallback))

        // With fallback enabled -> successfully produces safe Filter Echo Wash plan
        let requestWithFallback = TransitionRequest(
            outgoingTrack: outgoing,
            incomingTrack: incomingOver,
            style: .beatSyncedBassSwap(bars: 8, allowFallbackToFilter: true)
        )
        let fallbackPlan = try planner.plan(requestWithFallback)
        XCTAssertTrue(fallbackPlan.metadata.isFallback)
        XCTAssertEqual(fallbackPlan.durationSeconds, 8.0)
    }

    func testBeatSyncedBassSwapWithNonzeroOffsetsAndOffGridTrigger() throws {
        let planner = TransitionPlanner()
        // Outgoing track: 120 BPM, offset 0.25s, beats at 0.25, 0.75, 1.25 ...
        // Downbeats (every 4 beats) at: 0.25, 2.25, 4.25, ..., 200.25, 202.25 ...
        let outgoingGrid = makeBeatGrid(bpm: 120.0, duration: 240.0, offset: 0.25)
        let outgoing = makeTrack(deck: .deckA, bpm: 120.0, mixOut: 200.0, beatGrid: outgoingGrid)

        // Incoming track: 126 BPM, offset 0.15s, interval = 60/126 = 0.476190s
        // Incoming downbeats: 0.15 + k * 4 * 0.47619s
        // For k = 6: 0.15 + 11.4286 = 11.5786s (first downbeat after 10.0s trim cue)
        let incomingGrid = makeBeatGrid(bpm: 126.0, duration: 240.0, offset: 0.15)
        let incoming = makeTrack(deck: .deckB, bpm: 126.0, startTrim: 10.0, beatGrid: incomingGrid)

        // Off-grid trigger at 200.0s (between beats 199.75 and 200.25)
        let request = TransitionRequest(
            outgoingTrack: outgoing,
            incomingTrack: incoming,
            style: .beatSyncedBassSwap(bars: 16),
            triggerPositionSeconds: 200.0
        )

        let plan = try planner.plan(request)

        // Schedule must quantize start to the next outgoing downbeat: 200.25s
        XCTAssertEqual(plan.startTimestampSeconds, 200.25, accuracy: 0.0001)

        // Bass swap downbeat occurs at bar 8 = 32 beats * 0.5s = 16.0s offset
        XCTAssertEqual(try XCTUnwrap(plan.metadata.bassSwapOffsetSeconds), 16.0, accuracy: 0.0001)

        // Absolute outgoing playhead at bass swap: 200.25 + 16.0 = 216.25s
        let swapTime = plan.startTimestampSeconds + 16.0
        XCTAssertEqual(swapTime, 216.25, accuracy: 0.0001)

        // Verify 216.25 is an exact downbeat on outgoing grid: (216.25 - 0.25) / (4 * 0.5) = 216.0 / 2.0 = 108 bars
        let outgoingBars = (swapTime - outgoingGrid.firstBeatOffsetSeconds) / (4.0 * outgoingGrid.beatIntervalSeconds)
        XCTAssertEqual(outgoingBars.rounded(), outgoingBars, accuracy: 0.0001)

        // Verify incoming deck seeks to aligned incoming downbeat (11.5786s) rather than raw 10.0s
        let t0Events = plan.events.filter { abs($0.timeOffsetSeconds) < 0.001 }
        let seekEvent = try XCTUnwrap(t0Events.first {
            if case .seek(let d, let pos) = $0.command {
                return d == .deckB && abs(pos - 11.5786) < 0.01
            }
            return false
        })
        if case .seek(_, let pos) = seekEvent.command {
            XCTAssertEqual(pos, 11.5786, accuracy: 0.005)
            XCTAssertGreaterThanOrEqual(pos, incoming.cueMarkers.startTrimCue)
            // Verify pos is an exact downbeat on incoming grid
            let incomingBars = (pos - incomingGrid.firstBeatOffsetSeconds) / (4.0 * incomingGrid.beatIntervalSeconds)
            XCTAssertEqual(incomingBars.rounded(), incomingBars, accuracy: 0.0001)
        }
    }

    // MARK: - Beat Grid & Sentinel Handling

    func testRejectsUnknownTempoAndSentinelBeatGrid() throws {
        let planner = TransitionPlanner()
        let outgoing = makeTrack(deck: .deckA, bpm: 120.0)

        // Sentinel schema representation: bpm = 0, confidence = 0, empty timestamps, positive 1.0s sentinel
        let sentinelGrid = BeatGrid(
            firstBeatOffsetSeconds: 0.0,
            beatIntervalSeconds: 1.0,
            beatTimestamps: []
        )
        let incomingUnknown = makeTrack(
            deck: .deckB,
            bpm: 0.0,
            confidence: 0.0,
            beatGrid: sentinelGrid
        )

        // Strict beat-synced mode MUST reject sentinel and not fabricate a fake grid
        let strictRequest = TransitionRequest(
            outgoingTrack: outgoing,
            incomingTrack: incomingUnknown,
            style: .beatSyncedBassSwap(bars: 16, allowFallbackToFilter: false)
        )
        XCTAssertThrowsError(try planner.plan(strictRequest)) { error in
            guard case TransitionPlanningError.missingBeatGrid(let deck, _) = error else {
                XCTFail("Expected missingBeatGrid error, got: \(error)")
                return
            }
            XCTAssertEqual(deck, .deckB)
        }

        // Safe fallback must divert to Filter Echo Wash without using sentinel
        let fallbackRequest = TransitionRequest(
            outgoingTrack: outgoing,
            incomingTrack: incomingUnknown,
            style: .beatSyncedBassSwap(bars: 16, allowFallbackToFilter: true)
        )
        let plan = try planner.plan(fallbackRequest)
        XCTAssertTrue(plan.metadata.isFallback)
    }

    // MARK: - Filter Echo Wash Equal-Power Tests

    func testFilterEchoWashEqualPowerSCurveAndDSP() throws {
        let planner = TransitionPlanner()
        let outgoing = makeTrack(deck: .deckA, bpm: 120.0)
        let incoming = makeTrack(deck: .deckB, bpm: 140.0) // high BPM delta

        let request = TransitionRequest(
            outgoingTrack: outgoing,
            incomingTrack: incoming,
            style: .filterEchoWash(durationSeconds: 8.0, echoSend: 0.6)
        )

        let plan = try planner.plan(request)
        XCTAssertEqual(plan.durationSeconds, 8.0)

        // Verify exact whole ordered start-command batch at t = 0 (initial mute precedes transport start)
        let t0Events = plan.events.filter { $0.timeOffsetSeconds == 0.0 }
        let expectedStartBatch: [TransitionCommand] = [
            .setRate(deck: .deckB, rate: 1.0, keyLock: true),
            .seek(deck: .deckB, positionSeconds: incoming.cueMarkers.startTrimCue),
            .setEQ(deck: .deckB, eq: EQ3BandParameters(lowGainDB: 0.0, midGainDB: 0.0, highGainDB: 0.0)),
            .setFilter(deck: .deckB, filter: ResonantFilterParameters(sweep: 0.0, resonance: 1.0)),
            .setEcho(deck: .deckA, enabled: true, feedback: 0.5, mix: 0.6),
            .setFilter(deck: .deckA, filter: ResonantFilterParameters(sweep: 0.0, resonance: 1.0)),
            .setVolume(deck: .deckB, volume: 0.0),
            .play(deck: .deckB),
            .setVolume(deck: .deckA, volume: 1.0)
        ]
        XCTAssertEqual(t0Events.map(\.command), expectedStartBatch)

        // Verify equal-power sum: gainOut^2 + gainIn^2 ≈ 1.0 at every intermediate step
        let intermediateOffsets = Set(plan.events.map { $0.timeOffsetSeconds }).filter { $0 > 0.0 && $0 < 8.0 }
        XCTAssertFalse(intermediateOffsets.isEmpty)

        for offset in intermediateOffsets {
            let eventsAtOffset = plan.events.filter { abs($0.timeOffsetSeconds - offset) < 0.0001 }
            var outGain: Float? = nil
            var inGain: Float? = nil

            for event in eventsAtOffset {
                if case .setVolume(let deck, let vol) = event.command {
                    if deck == .deckA { outGain = vol }
                    if deck == .deckB { inGain = vol }
                }
            }

            if let og = outGain, let ig = inGain {
                let powerSum = (og * og) + (ig * ig)
                XCTAssertEqual(powerSum, 1.0, accuracy: 0.05, "Equal power violation at offset \(offset)")
            }
        }

        // Verify termination: echo bypassed, outgoing stopped
        let finalEvents = plan.events.filter { abs($0.timeOffsetSeconds - 8.0) < 0.0001 }
        XCTAssertTrue(finalEvents.contains {
            if case .setEcho(let d, let enabled, _, _) = $0.command {
                return d == .deckA && !enabled
            }
            return false
        })
        XCTAssertTrue(finalEvents.contains {
            if case .stop(let d) = $0.command { return d == .deckA }
            return false
        })
    }

    // MARK: - Hard Cut on Drop Tests

    func testHardCutOnDropBarQuantization() throws {
        let planner = TransitionPlanner()
        // Outgoing track at 120 BPM: beats every 0.5s; downbeats at 0.0, 2.0, 4.0, 6.0, ...
        let outgoing = makeTrack(deck: .deckA, bpm: 120.0, mixOut: 200.0)
        let incoming = makeTrack(deck: .deckB, bpm: 120.0)

        // Trigger position at 200.7s: next bar downbeat is at 202.0s (offset 1.3s)
        let request = TransitionRequest(
            outgoingTrack: outgoing,
            incomingTrack: incoming,
            style: .hardCutOnDrop(bars: 1),
            triggerPositionSeconds: 200.7
        )

        let plan = try planner.plan(request)
        XCTAssertEqual(plan.durationSeconds, 1.3, accuracy: 0.001)

        // Check pre-cue at t = 0
        let t0Events = plan.events.filter { abs($0.timeOffsetSeconds) < 0.001 }
        XCTAssertTrue(t0Events.contains {
            if case .seek(let d, _) = $0.command {
                return d == .deckB
            }
            return false
        })

        // Check instant hard cut at t = 1.3s
        let cutEvents = plan.events.filter { abs($0.timeOffsetSeconds - 1.3) < 0.001 }
        XCTAssertTrue(cutEvents.contains {
            if case .setVolume(let d, let vol) = $0.command { return d == .deckA && vol == 0.0 }
            return false
        })
        XCTAssertTrue(cutEvents.contains {
            if case .stop(let d) = $0.command { return d == .deckA }
            return false
        })
        XCTAssertTrue(cutEvents.contains {
            if case .setVolume(let d, let vol) = $0.command { return d == .deckB && vol == 1.0 }
            return false
        })
        XCTAssertTrue(cutEvents.contains {
            if case .play(let d) = $0.command { return d == .deckB }
            return false
        })
    }

    // MARK: - Validation & Invariant Tests

    func testRejectsIdenticalDecks() {
        let planner = TransitionPlanner()
        let trackA1 = makeTrack(deck: .deckA)
        let trackA2 = makeTrack(deck: .deckA)

        let request = TransitionRequest(
            outgoingTrack: trackA1,
            incomingTrack: trackA2,
            style: .beatSyncedBassSwap(bars: 8)
        )
        XCTAssertThrowsError(try planner.plan(request)) { error in
            guard case TransitionPlanningError.sameDeck(let d) = error else {
                XCTFail("Expected sameDeck error, got: \(error)")
                return
            }
            XCTAssertEqual(d, .deckA)
        }
    }

    func testRejectsNonFiniteDurations() {
        let planner = TransitionPlanner()
        let invalidOutgoing = makeTrack(deck: .deckA, duration: Double.nan)
        let incoming = makeTrack(deck: .deckB)

        let request = TransitionRequest(
            outgoingTrack: invalidOutgoing,
            incomingTrack: incoming,
            style: .filterEchoWash(durationSeconds: 8.0)
        )
        XCTAssertThrowsError(try planner.plan(request))
    }

    func testRejectsInvalidCueMarkers() {
        let planner = TransitionPlanner()
        // Outgoing track where mixOutCue > endTrimCue
        let badCues = CueMarkers(startTrimCue: 10.0, vocalEntryCue: 20.0, mixOutCue: 100.0, endTrimCue: 50.0)
        let outgoing = TrackTransitionDescriptor(
            deck: .deckA,
            duration: 200.0,
            bpm: 120.0,
            confidence: 0.9,
            cueMarkers: badCues,
            beatGrid: makeBeatGrid(bpm: 120.0)
        )
        let incoming = makeTrack(deck: .deckB)

        let request = TransitionRequest(
            outgoingTrack: outgoing,
            incomingTrack: incoming,
            style: .filterEchoWash()
        )
        XCTAssertThrowsError(try planner.plan(request))
    }

    func testRejectsTriggerPositionOutOfBounds() {
        let planner = TransitionPlanner()
        let outgoing = makeTrack(deck: .deckA, duration: 200.0)
        let incoming = makeTrack(deck: .deckB)

        let request = TransitionRequest(
            outgoingTrack: outgoing,
            incomingTrack: incoming,
            style: .filterEchoWash(),
            triggerPositionSeconds: 250.0 // beyond 200s duration
        )
        XCTAssertThrowsError(try planner.plan(request))
    }
    func testAlignedSeeksNeverPrecedeManualTrimAcrossBothQuantizedStyles() throws {
        let planner = TransitionPlanner()
        let outgoing = makeTrack(deck: .deckA, beatGrid: makeBeatGrid(bpm: 120, offset: 0.25))
        for trim in [0.0, 0.15, 10.0, 11.6] {
            let incoming = makeTrack(deck: .deckB, bpm: 126, startTrim: trim, beatGrid: makeBeatGrid(bpm: 126, offset: 0.15))
            for style in [TransitionStyle.beatSyncedBassSwap(bars: 8), .hardCutOnDrop()] {
                let plan = try planner.plan(TransitionRequest(outgoingTrack: outgoing, incomingTrack: incoming, style: style))
                let position = try XCTUnwrap(plan.events.compactMap { event -> Double? in
                    if case .seek(.deckB, let position) = event.command { return position }
                    return nil
                }.first)
                XCTAssertGreaterThanOrEqual(position, trim)
                XCTAssertLessThan(position, incoming.cueMarkers.endTrimCue)
                let bars = (position - incoming.beatGrid.firstBeatOffsetSeconds) / (incoming.beatGrid.beatIntervalSeconds * 4)
                XCTAssertEqual(bars, bars.rounded(), accuracy: 1e-8)
            }
        }
    }

    func testRejectsCompletePlansBeyondPlayableTrackIntervals() throws {
        let planner = TransitionPlanner()
        let incoming = makeTrack(deck: .deckB)
        let short = makeTrack(deck: .deckA, duration: 60, startTrim: 0, vocalEntry: 1, mixOut: 58, endTrim: 60)
        XCTAssertThrowsError(try planner.plan(TransitionRequest(outgoingTrack: short, incomingTrack: incoming, style: .filterEchoWash(durationSeconds: 8)))) {
            XCTAssertEqual($0 as? TransitionPlanningError, .insufficientPlayableContent(deck: .deckA))
        }
        let exact = try planner.plan(TransitionRequest(outgoingTrack: short, incomingTrack: incoming, style: .filterEchoWash(durationSeconds: 2)))
        XCTAssertEqual(exact.endTimestampSeconds, 60)
        let trimmed = makeTrack(deck: .deckA, duration: 60, startTrim: 0, vocalEntry: 1, mixOut: 58, endTrim: 59)
        XCTAssertThrowsError(try planner.plan(TransitionRequest(outgoingTrack: trimmed, incomingTrack: incoming, style: .filterEchoWash(durationSeconds: 2))))

        // The raw trigger plus 16 seconds fits, but quantization to 44.25 makes the complete plan too long.
        let quantized = makeTrack(deck: .deckA, duration: 60, startTrim: 0, vocalEntry: 1, mixOut: 43.9, endTrim: 60,
                                  beatGrid: makeBeatGrid(bpm: 120, duration: 60, offset: 0.25))
        XCTAssertThrowsError(try planner.plan(TransitionRequest(outgoingTrack: quantized, incomingTrack: incoming, style: .beatSyncedBassSwap(bars: 8)))) {
            XCTAssertEqual($0 as? TransitionPlanningError, .insufficientPlayableContent(deck: .deckA))
        }
        let shortIncoming = makeTrack(deck: .deckB, duration: 20, startTrim: 10, vocalEntry: 10, mixOut: 11, endTrim: 11)
        XCTAssertThrowsError(try planner.plan(TransitionRequest(outgoingTrack: short, incomingTrack: shortIncoming, style: .filterEchoWash(durationSeconds: 2)))) {
            XCTAssertEqual($0 as? TransitionPlanningError, .insufficientPlayableContent(deck: .deckB))
        }
        let lateCut = makeTrack(deck: .deckA, duration: 70, startTrim: 0, vocalEntry: 1, mixOut: 58.5, endTrim: 59,
                               beatGrid: makeBeatGrid(bpm: 120, duration: 70, offset: 0.25))
        XCTAssertThrowsError(try planner.plan(TransitionRequest(outgoingTrack: lateCut, incomingTrack: incoming, style: .hardCutOnDrop()))) {
            XCTAssertEqual($0 as? TransitionPlanningError, .insufficientPlayableContent(deck: .deckA))
        }
    }

    func testIncomingContentBoundsIncludeActualPlaybackRates() throws {
        let planner = TransitionPlanner()
        let outgoing = makeTrack(deck: .deckA)
        let incoming = makeTrack(deck: .deckB, duration: 30, startTrim: 0, vocalEntry: 1, mixOut: 5, endTrim: 10)
        XCTAssertThrowsError(try planner.plan(TransitionRequest(outgoingTrack: outgoing, incomingTrack: incoming,
                                                               style: .filterEchoWash(durationSeconds: 8), outgoingPlaybackRate: 0.5))) {
            XCTAssertEqual($0 as? TransitionPlanningError, .insufficientPlayableContent(deck: .deckB))
        }
        let fastOutgoing = try planner.plan(TransitionRequest(outgoingTrack: outgoing, incomingTrack: incoming,
                                                             style: .filterEchoWash(durationSeconds: 8), outgoingPlaybackRate: 2))
        XCTAssertTrue(fastOutgoing.events.contains { $0.command == .setRate(deck: .deckB, rate: 1, keyLock: true) })

        // Incoming 114 BPM plays faster than unity to meet 120 BPM; 16 media seconds are insufficient.
        let accelerated = makeTrack(deck: .deckB, duration: 30, bpm: 114, startTrim: 0, vocalEntry: 1, mixOut: 10, endTrim: 16.5)
        XCTAssertThrowsError(try planner.plan(TransitionRequest(outgoingTrack: outgoing, incomingTrack: accelerated, style: .beatSyncedBassSwap(bars: 8)))) {
            XCTAssertEqual($0 as? TransitionPlanningError, .insufficientPlayableContent(deck: .deckB))
        }
        let slowed = makeTrack(deck: .deckB, duration: 30, bpm: 126, startTrim: 0, vocalEntry: 1, mixOut: 10, endTrim: 16)
        XCTAssertNoThrow(try planner.plan(TransitionRequest(outgoingTrack: outgoing, incomingTrack: slowed, style: .beatSyncedBassSwap(bars: 8))))
    }

    func testChainedTransitionsMatchOutgoingEffectiveTempoAndPhase() throws {
        let planner = TransitionPlanner()
        let first = try planner.plan(TransitionRequest(outgoingTrack: makeTrack(deck: .deckA, bpm: 120),
                                                     incomingTrack: makeTrack(deck: .deckB, bpm: 126), style: .beatSyncedBassSwap(bars: 8)))
        let retainedRate = try XCTUnwrap(first.metadata.tempoAdjustmentRate)
        let outgoing = makeTrack(deck: .deckB, bpm: 126)
        let incoming = makeTrack(deck: .deckA, bpm: 126)
        let second = try planner.plan(TransitionRequest(outgoingTrack: outgoing, incomingTrack: incoming,
                                                      style: .beatSyncedBassSwap(bars: 8), outgoingPlaybackRate: retainedRate))
        XCTAssertEqual(try XCTUnwrap(second.metadata.targetTempoBPM), 126 * Double(retainedRate), accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(second.metadata.tempoAdjustmentRate), retainedRate, accuracy: 1e-7)
        XCTAssertEqual(second.durationSeconds / Double(retainedRate), 16, accuracy: 1e-5)
        XCTAssertTrue(second.events.contains { $0.command == .setRate(deck: .deckA, rate: retainedRate, keyLock: true) })
        let seek = try XCTUnwrap(second.events.compactMap { event -> Double? in
            if case .seek(.deckA, let position) = event.command { return position }
            return nil
        }.first)
        let swapOffset = try XCTUnwrap(second.metadata.bassSwapOffsetSeconds)
        let incomingAtSwap = seek + swapOffset / Double(retainedRate) * Double(retainedRate)
        let incomingBars = (incomingAtSwap - incoming.beatGrid.firstBeatOffsetSeconds) / (incoming.beatGrid.beatIntervalSeconds * 4)
        XCTAssertEqual(incomingBars, incomingBars.rounded(), accuracy: 1e-7)
    }

    func testRejectsMalformedGridsAndDoesNotUseIncomingSentinelForHardCut() throws {
        let planner = TransitionPlanner()
        let outgoing = makeTrack(deck: .deckA)
        let malformed: [BeatGrid] = [
            BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 0.5, beatTimestamps: [0, .nan]),
            BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 0.5, beatTimestamps: [0, 0]),
            BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 0.5, beatTimestamps: [0, 1]),
            BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 0.5, beatTimestamps: [0.1, 0.6]),
            BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 1, beatTimestamps: [0, 1]),
            BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 0.5, beatTimestamps: [0, 241])
        ]
        for grid in malformed {
            let incoming = makeTrack(deck: .deckB, beatGrid: grid)
            XCTAssertFalse(planner.isUsableBeatGrid(descriptor: incoming))
            XCTAssertThrowsError(try planner.plan(TransitionRequest(outgoingTrack: outgoing, incomingTrack: incoming, style: .beatSyncedBassSwap(bars: 8))))
        }
        let sentinel = BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 1, beatTimestamps: [])
        let incoming = makeTrack(deck: .deckB, bpm: 0, confidence: 0, startTrim: 10.3, beatGrid: sentinel)
        let cut = try planner.plan(TransitionRequest(outgoingTrack: outgoing, incomingTrack: incoming, style: .hardCutOnDrop()))
        XCTAssertTrue(cut.events.contains { $0.command == .seek(deck: .deckB, positionSeconds: 10.3) })
    }

    func testMissingDownbeatInsideTrimIntervalAndExtremeParametersFailSafely() throws {
        let planner = TransitionPlanner()
        let outgoing = makeTrack(deck: .deckA)
        let incoming = makeTrack(deck: .deckB, duration: 20, startTrim: 10.1, vocalEntry: 10.1, mixOut: 11, endTrim: 11)
        for style in [TransitionStyle.beatSyncedBassSwap(bars: 8), .hardCutOnDrop()] {
            XCTAssertThrowsError(try planner.plan(TransitionRequest(outgoingTrack: outgoing, incomingTrack: incoming, style: style)))
        }
        let partialGrid = BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 0.5, beatTimestamps: [0, 0.5])
        let partialIncoming = makeTrack(deck: .deckB, beatGrid: partialGrid)
        for style in [TransitionStyle.beatSyncedBassSwap(bars: 8, allowFallbackToFilter: true), .hardCutOnDrop(allowFallbackToFilter: true)] {
            let fallback = try planner.plan(TransitionRequest(outgoingTrack: outgoing, incomingTrack: partialIncoming, style: style))
            XCTAssertTrue(fallback.metadata.isFallback)
            XCTAssertTrue(fallback.events.contains { $0.command == .seek(deck: .deckB, positionSeconds: 10) })
        }
        for rate: Float in [0, -1, .nan, .infinity, 33] {
            XCTAssertThrowsError(try planner.plan(TransitionRequest(outgoingTrack: outgoing, incomingTrack: makeTrack(deck: .deckB),
                                                                   style: .filterEchoWash(), outgoingPlaybackRate: rate)))
        }
        for bars in [0, -1, Int.max] {
            XCTAssertThrowsError(try planner.plan(TransitionRequest(outgoingTrack: outgoing, incomingTrack: makeTrack(deck: .deckB),
                                                                   style: .beatSyncedBassSwap(bars: bars))))
        }
    }

    func testFilterEchoWashMutePrecedesPlayInOrderedStartBatch() throws {
        let planner = TransitionPlanner()
        let outgoing = makeTrack(deck: .deckA, bpm: 120.0)
        let incoming = makeTrack(deck: .deckB, bpm: 140.0)
        let request = TransitionRequest(
            outgoingTrack: outgoing,
            incomingTrack: incoming,
            style: .filterEchoWash(durationSeconds: 8.0, echoSend: 0.6)
        )
        let plan = try planner.plan(request)
        var machine = TransitionStateMachine(plan: plan)
        let startBatch = try machine.advance(to: plan.startTimestampSeconds)

        let muteIndex = try XCTUnwrap(startBatch.firstIndex(where: {
            if case .setVolume(let deck, let vol) = $0 {
                return deck == .deckB && vol == 0.0
            }
            return false
        }))
        let playIndex = try XCTUnwrap(startBatch.firstIndex(where: {
            if case .play(let deck) = $0 {
                return deck == .deckB
            }
            return false
        }))

        XCTAssertLessThan(muteIndex, playIndex, "Incoming deck mute must occur strictly before transport start")

        let expectedStartBatch: [TransitionCommand] = [
            .setRate(deck: .deckB, rate: 1.0, keyLock: true),
            .seek(deck: .deckB, positionSeconds: incoming.cueMarkers.startTrimCue),
            .setEQ(deck: .deckB, eq: EQ3BandParameters(lowGainDB: 0.0, midGainDB: 0.0, highGainDB: 0.0)),
            .setFilter(deck: .deckB, filter: ResonantFilterParameters(sweep: 0.0, resonance: 1.0)),
            .setEcho(deck: .deckA, enabled: true, feedback: 0.5, mix: 0.6),
            .setFilter(deck: .deckA, filter: ResonantFilterParameters(sweep: 0.0, resonance: 1.0)),
            .setVolume(deck: .deckB, volume: 0.0),
            .play(deck: .deckB),
            .setVolume(deck: .deckA, volume: 1.0)
        ]
        XCTAssertEqual(startBatch, expectedStartBatch)
    }

    func testFilterEchoWashShortDurationMonotonicEventOffsets() throws {
        let planner = TransitionPlanner()
        let outgoing = makeTrack(deck: .deckA, bpm: 120.0)
        let incoming = makeTrack(deck: .deckB, bpm: 120.0)
        let request = TransitionRequest(
            outgoingTrack: outgoing,
            incomingTrack: incoming,
            style: .filterEchoWash(durationSeconds: 0.0008, echoSend: 0.5)
        )
        let plan = try planner.plan(request)

        for i in 1..<plan.events.count {
            let prev = plan.events[i - 1]
            let curr = plan.events[i]
            XCTAssertLessThanOrEqual(
                prev.timeOffsetSeconds,
                curr.timeOffsetSeconds,
                "Event \(i) at \(curr.timeOffsetSeconds) was placed before event \(i-1) at \(prev.timeOffsetSeconds)"
            )
        }
    }

}

