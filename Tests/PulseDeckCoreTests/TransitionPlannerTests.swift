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
        XCTAssertEqual(try XCTUnwrap(plan.metadata.bassSwapOffsetSeconds), 28.0, accuracy: 0.001)
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

        // Bass swap on the bar 14 downbeat (2 bars before the end) at t = 28.0s
        let midpointEvents = plan.events.filter { abs($0.timeOffsetSeconds - 28.0) < 0.001 }
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

        // Bounded plan verification: four steps per bar, never thousands of automation events
        XCTAssertLessThanOrEqual(plan.events.count, 160)
    }

    func testBassSwapHoldsOutgoingThenSwapsOnceAndLeavesFast() throws {
        let plan = try TransitionPlanner().plan(TransitionRequest(
            outgoingTrack: makeTrack(deck: .deckA, bpm: 120.0),
            incomingTrack: makeTrack(deck: .deckB, bpm: 126.0),
            style: .beatSyncedBassSwap(bars: 8)))
        let swap = try XCTUnwrap(plan.metadata.bassSwapOffsetSeconds)
        XCTAssertEqual(swap, 12.0, accuracy: 0.001, "Swap on the bar 6 downbeat of 8 (0.5 s beats)")

        func eqs(_ deck: DeckIdentifier) -> [(Double, EQ3BandParameters)] {
            plan.events.compactMap { if case .setEQ(deck, let eq) = $0.command { return ($0.timeOffsetSeconds, eq) }; return nil }
        }
        let outVolumes = plan.events.compactMap { event -> (Double, Float)? in
            if case .setVolume(.deckA, let volume) = event.command { return (event.timeOffsetSeconds, volume) }
            return nil
        }
        // Before the swap the outgoing fader, lows and mids hold; the incoming plays highs only.
        XCTAssertTrue(outVolumes.filter { $0.0 < swap - 1e-6 }.allSatisfy { $0.1 == 1 })
        XCTAssertTrue(eqs(.deckA).filter { $0.0 < swap - 1e-6 }.allSatisfy { $0.1.lowGainDB == 0 && $0.1.midGainDB == 0 })
        let incomingBefore = eqs(.deckB).filter { $0.0 < swap - 1e-6 }
        XCTAssertTrue(incomingBefore.allSatisfy { $0.1.lowGainDB == -24 && $0.1.midGainDB == -24 })
        let highs = incomingBefore.map(\.1.highGainDB)
        XCTAssertEqual(highs.first ?? 0, -24)
        XCTAssertTrue(zip(highs, highs.dropFirst()).allSatisfy { $1 >= $0 && $1 - $0 <= 1.5 }, "Highs rise in small steps")

        // One swap downbeat: lows and mids change hands together.
        XCTAssertTrue(eqs(.deckB).contains { abs($0.0 - swap) < 1e-6 && $0.1 == EQ3BandParameters(lowGainDB: 0, midGainDB: 0, highGainDB: 0) })
        XCTAssertTrue(eqs(.deckA).contains { abs($0.0 - swap) < 1e-6 && $0.1.lowGainDB == -24 && $0.1.midGainDB == -24 })

        // After it the outgoing fader only falls: -18 dB one bar later, -36 dB two beats before the end, then silence.
        let after = outVolumes.filter { $0.0 >= swap - 1e-6 }.sorted { $0.0 < $1.0 }.map(\.1)
        XCTAssertTrue(zip(after, after.dropFirst()).allSatisfy { $1 <= $0 })
        XCTAssertLessThanOrEqual(after[4], 0.13)
        XCTAssertLessThanOrEqual(after.dropLast(2).last ?? 1, 0.016)
        XCTAssertEqual(after.last, 0)
    }

    func testBassSwapBarsFollowThreeFourDownbeats() throws {
        let uniform = makeBeatGrid(bpm: 120.0)
        // 3/4: a bar line on every third beat.
        let waltz = BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 0.5, beatTimestamps: uniform.beatTimestamps,
                             downbeatTimestamps: stride(from: 0, to: uniform.beatTimestamps.count, by: 3).map { uniform.beatTimestamps[$0] })
        let plan = try TransitionPlanner().plan(TransitionRequest(
            outgoingTrack: makeTrack(deck: .deckA, beatGrid: waltz),
            incomingTrack: makeTrack(deck: .deckB),
            style: .beatSyncedBassSwap(bars: 8)))
        XCTAssertEqual(plan.startTimestampSeconds, 201.0, accuracy: 0.001, "First 3/4 bar line at or after the 200 s mix-out")
        XCTAssertEqual(plan.durationSeconds, 12.0, accuracy: 0.001, "8 bars x 3 beats x 0.5 s")
        XCTAssertEqual(plan.metadata.bassSwapOffsetSeconds ?? -1, 9.0, accuracy: 0.001, "Swap on the bar 6 line")
        let fades = plan.events.compactMap { event -> Double? in
            if case .setVolume(.deckA, let volume) = event.command, volume > 0, volume < 1 { return event.timeOffsetSeconds }
            return nil
        }
        XCTAssertEqual(fades.first ?? -1, 9.375, accuracy: 0.001, "Fade steps split the real 3/4 bar into quarters")
    }

    func testBarOffsetsFollowDriftingTempoAndRejectShortGrids() {
        let bars = [10.0, 12.0, 14.1, 16.3]
        let offsets = TransitionPlanner.barOffsets(bars: 3, from: 10.0, barTimestamps: bars, beatInterval: 0.5) ?? []
        XCTAssertEqual(offsets.count, 4)
        for (actual, expected) in zip(offsets, [0, 2.0, 4.1, 6.3]) { XCTAssertEqual(actual, expected, accuracy: 1e-9) }
        XCTAssertNil(TransitionPlanner.barOffsets(bars: 4, from: 10.0, barTimestamps: bars, beatInterval: 0.5), "Grid ends before the phrase")
        XCTAssertNil(TransitionPlanner.barOffsets(bars: 1, from: 11.0, barTimestamps: bars, beatInterval: 0.5), "Start must be a bar line")
        XCTAssertNil(TransitionPlanner.barOffsets(bars: 2, from: 10.0, barTimestamps: [10, 12, 18], beatInterval: 0.5),
                     "A missed downbeat (12-beat bar) falls back to uniform bars")
        XCTAssertNil(TransitionPlanner.barOffsets(bars: 2, from: 10.0, barTimestamps: [10, 10.5, 12.5], beatInterval: 0.5),
                     "A spurious downbeat (1-beat bar) falls back to uniform bars")
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

    func testHalfTimeIncomingBeatSyncsAtNativeSpeed() throws {
        let planner = TransitionPlanner()
        let request = TransitionRequest(
            outgoingTrack: makeTrack(deck: .deckA, bpm: 140.0),
            incomingTrack: makeTrack(deck: .deckB, bpm: 71.0),
            style: .beatSyncedBassSwap(bars: 8, allowFallbackToFilter: false)
        )
        let plan = try planner.plan(request)
        XCTAssertFalse(plan.metadata.isFallback)
        XCTAssertEqual(Double(try XCTUnwrap(plan.metadata.tempoAdjustmentRate)), 140.0 / 142.0, accuracy: 1e-4,
                       "71 BPM plays as half of 140, not stretched to 140")
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

        // Bass swap downbeat occurs at bar 14 = 56 beats * 0.5s = 28.0s offset
        XCTAssertEqual(try XCTUnwrap(plan.metadata.bassSwapOffsetSeconds), 28.0, accuracy: 0.0001)

        // Absolute outgoing playhead at bass swap: 200.25 + 28.0 = 228.25s
        let swapTime = plan.startTimestampSeconds + 28.0
        XCTAssertEqual(swapTime, 228.25, accuracy: 0.0001)

        // Verify 228.25 is an exact downbeat on outgoing grid: (228.25 - 0.25) / (4 * 0.5) = 114 bars
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
            .setEcho(deck: .deckA, enabled: true, feedback: 0.5, mix: 0),
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

    func testLocalBeatIntervalIgnoresFrameJitterAndMissedOrExtraBeats() throws {
        // 124.6 BPM read on 20 ms frames, with one beat missed and one spurious off-beat hit.
        let truth = 60.0 / 124.6
        var beats = (0..<64).map { (10 + Double($0) * truth) / 0.02 }.map { $0.rounded() * 0.02 }
        beats.remove(at: 20)
        beats.insert(beats[40] + truth * 0.45, at: 41)
        let interval = try XCTUnwrap(TransitionPlanner.localBeatInterval(beats, from: 10, through: 10 + 63 * truth))
        XCTAssertEqual(interval / truth, 1, accuracy: 0.0003)
        // 122 BPM: every gap reads 0.48 or 0.50 s, so the median is 2 % off the true 0.4918 s.
        let slow = 60.0 / 122
        let slowBeats = (0..<64).map { ((5 + Double($0) * slow) / 0.02).rounded() * 0.02 }
        let slowInterval = try XCTUnwrap(TransitionPlanner.localBeatInterval(slowBeats, from: 5, through: 5 + 63 * slow))
        XCTAssertEqual(slowInterval / slow, 1, accuracy: 0.0003)
        XCTAssertNil(TransitionPlanner.localBeatInterval(Array(beats.prefix(5)), from: 0, through: 100))
    }

    func testAcceptsMeasuredGridWithDriftAndRoundedBPM() throws {
        // Like a live band read by the beat model: tempo drifts ±2 % and the label is rounded to 0.1 BPM.
        var beats: [Double] = []
        var time = 0.31
        for index in 0..<440 {
            beats.append(time)
            time += 0.5 * (1 + 0.02 * sin(Double(index) / 30))
        }
        let interval = (beats.last! - beats.first!) / Double(beats.count - 1)
        let bpm = ((60 / interval) * 10).rounded() / 10
        let grid = BeatGrid(firstBeatOffsetSeconds: beats[0], beatIntervalSeconds: interval, beatTimestamps: beats)
        let incoming = makeTrack(deck: .deckB, bpm: bpm, beatGrid: grid)
        let planner = TransitionPlanner()
        XCTAssertTrue(planner.isUsableBeatGrid(descriptor: incoming))
        XCTAssertTrue(planner.isUsableBeatGrid(descriptor: makeTrack(deck: .deckB, bpm: bpm / 2, beatGrid: grid)))
        let plan = try planner.plan(TransitionRequest(outgoingTrack: makeTrack(deck: .deckA), incomingTrack: incoming, style: .beatSyncedBassSwap(bars: 8)))
        XCTAssertFalse(plan.metadata.isFallback)
    }

    func testRejectsMalformedGridsAndDoesNotUseIncomingSentinelForHardCut() throws {
        let planner = TransitionPlanner()
        let outgoing = makeTrack(deck: .deckA)
        let malformed: [BeatGrid] = [
            BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 0.5, beatTimestamps: [0, .nan]),
            BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 0.5, beatTimestamps: [0, 0]),
            BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 0.5, beatTimestamps: [0, 1]),
            BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 0.5, beatTimestamps: [0.1, 0.6]),
            BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 0.75, beatTimestamps: [0, 0.75]),
            BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 1.5, beatTimestamps: [0, 1.5]),
            BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 0.5, beatTimestamps: [0, 0.5, 1.1, 1.7]),
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
            .setEcho(deck: .deckA, enabled: true, feedback: 0.5, mix: 0),
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


    func testFilterEchoWashRampsEchoAndStepsFinely() throws {
        let plan = try TransitionPlanner().plan(TransitionRequest(
            outgoingTrack: makeTrack(deck: .deckA), incomingTrack: makeTrack(deck: .deckB),
            style: .filterEchoWash(durationSeconds: 8.0, echoSend: 0.6)))
        let echoMixes = plan.events.compactMap { event -> Float? in
            if case .setEcho(.deckA, true, _, let mix) = event.command { return mix }
            return nil
        }
        XCTAssertEqual(echoMixes.first, 0, "Starts dry")
        XCTAssertEqual(echoMixes.last ?? 0, 0.6, accuracy: 1e-6, "Full send after the first quarter")
        XCTAssertTrue(zip(echoMixes, echoMixes.dropFirst()).allSatisfy { $1 >= $0 && $1 - $0 <= 0.04 }, "Echo rises in small steps")
        // About 8 gain steps per second: no outgoing volume step longer than 0.13 s.
        let fades = plan.events.compactMap { event -> Double? in
            if case .setVolume(.deckA, _) = event.command { return event.timeOffsetSeconds }
            return nil
        }
        XCTAssertLessThanOrEqual(zip(fades, fades.dropFirst()).map { $1 - $0 }.max() ?? 1, 0.13)

        // A duration that does not split into quarters evenly still reaches the full send.
        let odd = try TransitionPlanner().plan(TransitionRequest(
            outgoingTrack: makeTrack(deck: .deckA), incomingTrack: makeTrack(deck: .deckB),
            style: .filterEchoWash(durationSeconds: 6.1, echoSend: 0.6)))
        let oddLast = odd.events.compactMap { event -> Float? in
            if case .setEcho(.deckA, true, _, let mix) = event.command { return mix }
            return nil
        }.last
        XCTAssertEqual(oddLast ?? 0, 0.6, accuracy: 1e-6)
    }

    func testHardCutLandsWhereTheBeatComesInAfterAQuietIntro() throws {
        // 240 s at 120 BPM: bars every 2 s. Bass is quiet for the first 32 s, then full.
        let bins = 4_800 // 20 per second
        let quietIntro = (0..<bins).map { Float($0 < 640 ? 0.05 : 0.5) }
        let bars = stride(from: 0.0, to: 240, by: 2.0).map { $0 }
        XCTAssertEqual(TransitionPlanner.dropDownbeat(bars: bars, lowBand: quietIntro, duration: 240, from: 10, before: 235), 42,
                       "First phrase start (8 bars from the 10 s downbeat) with full bass")
        let loudFromStart = [Float](repeating: 0.5, count: bins)
        XCTAssertNil(TransitionPlanner.dropDownbeat(bars: bars, lowBand: loudFromStart, duration: 240, from: 10, before: 235))
        let slowBuild = (0..<bins).map { Float($0 < 1_400 ? 0.05 : 0.5) } // beat only after 70 s
        XCTAssertNil(TransitionPlanner.dropDownbeat(bars: bars, lowBand: slowBuild, duration: 240, from: 10, before: 235))
        XCTAssertNil(TransitionPlanner.dropDownbeat(bars: bars, lowBand: [], duration: 240, from: 10, before: 235))

        let incoming = makeTrack(deck: .deckB)
        let withBass = TrackTransitionDescriptor(deck: .deckB, duration: incoming.duration, bpm: incoming.bpm, confidence: incoming.confidence,
                                                 cueMarkers: incoming.cueMarkers, beatGrid: incoming.beatGrid, lowBandPeaks: quietIntro)
        let plan = try TransitionPlanner().plan(TransitionRequest(outgoingTrack: makeTrack(deck: .deckA), incomingTrack: withBass, style: .hardCutOnDrop()))
        XCTAssertTrue(plan.events.contains { $0.command == .seek(deck: .deckB, positionSeconds: 42) })
    }
}
