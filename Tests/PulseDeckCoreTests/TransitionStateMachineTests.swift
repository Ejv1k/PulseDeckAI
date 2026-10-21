import XCTest
@testable import PulseDeckCore

final class TransitionStateMachineTests: XCTestCase {

    private func makeFixturePlan() -> TransitionPlan {
        let events: [ScheduledTransitionEvent] = [
            // Co-timed events at t = 0.0 with different priorities
            ScheduledTransitionEvent(timeOffsetSeconds: 0.0, command: .setRate(deck: .deckB, rate: 1.05, keyLock: true), priority: .configuration),
            ScheduledTransitionEvent(timeOffsetSeconds: 0.0, command: .seek(deck: .deckB, positionSeconds: 15.0), priority: .transportPrep),
            ScheduledTransitionEvent(timeOffsetSeconds: 0.0, command: .setEQ(deck: .deckB, eq: EQ3BandParameters(lowGainDB: -24.0, midGainDB: 0.0, highGainDB: 0.0)), priority: .audioProcessing),
            ScheduledTransitionEvent(timeOffsetSeconds: 0.0, command: .play(deck: .deckB), priority: .transportStart),
            ScheduledTransitionEvent(timeOffsetSeconds: 0.0, command: .setVolume(deck: .deckB, volume: 1.0), priority: .volumeFader),

            // Midpoint event at t = 4.0
            ScheduledTransitionEvent(timeOffsetSeconds: 4.0, command: .setEQ(deck: .deckA, eq: EQ3BandParameters(lowGainDB: -24.0, midGainDB: 0.0, highGainDB: 0.0)), priority: .audioProcessing),
            ScheduledTransitionEvent(timeOffsetSeconds: 4.0, command: .setEQ(deck: .deckB, eq: EQ3BandParameters(lowGainDB: 0.0, midGainDB: 0.0, highGainDB: 0.0)), priority: .audioProcessing),

            // Completion events at t = 8.0
            ScheduledTransitionEvent(timeOffsetSeconds: 8.0, command: .setVolume(deck: .deckA, volume: 0.0), priority: .volumeFader),
            ScheduledTransitionEvent(timeOffsetSeconds: 8.0, command: .stop(deck: .deckA), priority: .transportStop)
        ]

        return TransitionPlan(
            style: .beatSyncedBassSwap(bars: 8),
            outgoingDeck: .deckA,
            incomingDeck: .deckB,
            startTimestampSeconds: 100.0,
            durationSeconds: 8.0,
            events: events,
            metadata: TransitionPlanMetadata()
        )
    }

    // MARK: - Linear & Skipped Advance Tests

    func testSequentialLinearClockAdvance() throws {
        let plan = makeFixturePlan()
        var machine = TransitionStateMachine(plan: plan)

        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.progress, 0.0)
        XCTAssertEqual(machine.executedEventCount, 0)
        XCTAssertEqual(machine.remainingEventCount, 9)
        XCTAssertFalse(machine.isFinished)

        // Advance before start point (t = 95s < 100s start)
        let earlyCommands = try machine.advance(to: 95.0)
        XCTAssertTrue(earlyCommands.isEmpty)
        XCTAssertEqual(machine.state, .idle)

        // Advance to start (t = 100.0s, offset = 0.0s)
        let startCommands = try machine.advance(to: 100.0)
        XCTAssertEqual(startCommands.count, 5)
        XCTAssertEqual(machine.executedEventCount, 5)
        XCTAssertEqual(machine.remainingEventCount, 4)
        if case .inProgress(let pos) = machine.state {
            XCTAssertEqual(pos, 100.0)
        } else {
            XCTFail("Expected inProgress state")
        }

        // Advance to midpoint (t = 104.0s, offset = 4.0s)
        let midCommands = try machine.advance(to: 104.0)
        XCTAssertEqual(midCommands.count, 2)
        XCTAssertEqual(machine.executedEventCount, 7)
        XCTAssertEqual(machine.remainingEventCount, 2)
        XCTAssertEqual(machine.progress, 0.5, accuracy: 0.001)

        // Advance to end (t = 108.0s, offset = 8.0s)
        let endCommands = try machine.advance(to: 108.0)
        XCTAssertEqual(endCommands.count, 2)
        XCTAssertEqual(machine.executedEventCount, 9)
        XCTAssertEqual(machine.remainingEventCount, 0)
        XCTAssertEqual(machine.state, .completed)
        XCTAssertEqual(machine.progress, 1.0)
        XCTAssertTrue(machine.isFinished)

        // Subsequent advance past end emits nothing
        let postEndCommands = try machine.advance(to: 110.0)
        XCTAssertTrue(postEndCommands.isEmpty)
    }

    func testSkippedAndIrregularClockAdvances() throws {
        let plan = makeFixturePlan()
        var machine = TransitionStateMachine(plan: plan)

        // Jump directly from idle to midpoint: must emit all events from 0.0 through 4.0
        let batch = try machine.advance(to: 104.0)
        XCTAssertEqual(batch.count, 7) // 5 at t=0 + 2 at t=4
        XCTAssertEqual(machine.executedEventCount, 7)

        // Jump directly beyond end
        let endBatch = try machine.advance(to: 120.0)
        XCTAssertEqual(endBatch.count, 2) // remaining 2 at t=8
        XCTAssertEqual(machine.state, .completed)
        XCTAssertEqual(machine.executedEventCount, 9)
    }

    // MARK: - Same-Time Priority Ordering

    func testDeterministicSameTimeEventOrdering() throws {
        let plan = makeFixturePlan()
        var machine = TransitionStateMachine(plan: plan)

        let commands = try machine.advance(to: 100.0)
        XCTAssertEqual(commands.count, 5)

        // Expected strict priority sequence:
        // 1. configuration: setRate
        // 2. transportPrep: seek
        // 3. audioProcessing: setEQ
        // 4. transportStart: play
        // 5. volumeFader: setVolume
        guard case .setRate = commands[0] else { XCTFail("Command 0 must be setRate"); return }
        guard case .seek = commands[1] else { XCTFail("Command 1 must be seek"); return }
        guard case .setEQ = commands[2] else { XCTFail("Command 2 must be setEQ"); return }
        guard case .play = commands[3] else { XCTFail("Command 3 must be play"); return }
        guard case .setVolume = commands[4] else { XCTFail("Command 4 must be setVolume"); return }
    }

    // MARK: - Exact-Once Emission & Repetition

    func testRepeatedSamePositionAdvanceReturnsEmpty() throws {
        let plan = makeFixturePlan()
        var machine = TransitionStateMachine(plan: plan)

        let first = try machine.advance(to: 100.0)
        XCTAssertEqual(first.count, 5)

        let second = try machine.advance(to: 100.0)
        XCTAssertTrue(second.isEmpty, "Calling advance with the same timestamp must emit no duplicates")
    }

    // MARK: - Regression & Non-Finite Time Error Handling

    func testTimeRegressionThrowsAndPreservesState() throws {
        let plan = makeFixturePlan()
        var machine = TransitionStateMachine(plan: plan)

        _ = try machine.advance(to: 104.0)
        XCTAssertEqual(machine.executedEventCount, 7)

        // Monotonic violation: moving backwards from 104.0 to 102.0
        XCTAssertThrowsError(try machine.advance(to: 102.0)) { error in
            guard case TransitionExecutionError.timeRegressed(let curr, let att) = error else {
                XCTFail("Expected timeRegressed error, got: \(error)")
                return
            }
            XCTAssertEqual(curr, 104.0)
            XCTAssertEqual(att, 102.0)
        }

        // State remains healthy: subsequent forward advance to 108.0 succeeds
        let remaining = try machine.advance(to: 108.0)
        XCTAssertEqual(remaining.count, 2)
        XCTAssertEqual(machine.state, .completed)
    }

    func testNonFiniteTimestampsRejected() {
        let plan = makeFixturePlan()
        var machine = TransitionStateMachine(plan: plan)

        XCTAssertThrowsError(try machine.advance(to: Double.nan))
        XCTAssertThrowsError(try machine.advance(to: Double.infinity))
        XCTAssertThrowsError(try machine.advance(to: -Double.infinity))
    }

    // MARK: - Idempotent Cancellation

    func testIdempotentCancellation() throws {
        let plan = makeFixturePlan()
        var machine = TransitionStateMachine(plan: plan)

        _ = try machine.advance(to: 102.0)
        XCTAssertFalse(machine.isFinished)

        // Cancel mid-flight
        let recoveryCommands = machine.cancel()
        XCTAssertFalse(recoveryCommands.isEmpty)
        XCTAssertEqual(machine.state, .cancelled)
        XCTAssertTrue(machine.isFinished)

        // Verify safe recovery: outgoing deck restored to 1.0, incoming muted and stopped
        XCTAssertTrue(recoveryCommands.contains(.setVolume(deck: .deckA, volume: 1.0)))
        XCTAssertTrue(recoveryCommands.contains(.setVolume(deck: .deckB, volume: 0.0)))
        XCTAssertTrue(recoveryCommands.contains(.stop(deck: .deckB)))

        // Idempotency: second cancel returns empty array
        let secondCancel = machine.cancel()
        XCTAssertTrue(secondCancel.isEmpty)

        // Subsequent advance returns empty array
        let postCancelAdvance = try machine.advance(to: 108.0)
        XCTAssertTrue(postCancelAdvance.isEmpty)
    }
    func testImmediateDownbeatHardCutCompletesBeforeOutgoingClockStops() throws {
        let grid = BeatGrid(firstBeatOffsetSeconds: 0, beatIntervalSeconds: 0.5,
                            beatTimestamps: stride(from: 0.0, through: 240.0, by: 0.5).map { $0 })
        let cues = CueMarkers(startTrimCue: 10, vocalEntryCue: 30, mixOutCue: 200, endTrimCue: 235)
        let outgoing = TrackTransitionDescriptor(deck: .deckA, duration: 240, bpm: 120, confidence: 1, cueMarkers: cues, beatGrid: grid)
        let incoming = TrackTransitionDescriptor(deck: .deckB, duration: 240, bpm: 120, confidence: 1, cueMarkers: cues, beatGrid: grid)
        let plan = try TransitionPlanner().plan(TransitionRequest(outgoingTrack: outgoing, incomingTrack: incoming, style: .hardCutOnDrop()))
        XCTAssertEqual(plan.durationSeconds, 0)
        var machine = TransitionStateMachine(plan: plan)
        let commands = try machine.advance(to: plan.startTimestampSeconds)
        XCTAssertTrue(commands.contains(.stop(deck: .deckA)))
        XCTAssertTrue(commands.contains(.play(deck: .deckB)))
        XCTAssertEqual(machine.executedEventCount, plan.events.count)
        XCTAssertEqual(machine.state, .completed)
        XCTAssertTrue(machine.isFinished)
        XCTAssertEqual(machine.progress, 1)
        XCTAssertTrue(machine.cancel().isEmpty, "A completed cut must never stop the new outgoing deck")
        XCTAssertTrue(try machine.advance(to: plan.startTimestampSeconds).isEmpty)
        let incomingVolumes = commands.compactMap { command -> Float? in
            if case .setVolume(.deckB, let volume) = command { return volume }
            return nil
        }
        XCTAssertEqual(incomingVolumes.last, 1)
    }

    func testClusteredSubToleranceOffsetsEmitStrictlyChronologicallyInSkippedBatch() throws {
        let events = [
            ScheduledTransitionEvent(
                timeOffsetSeconds: 0.0,
                command: .setVolume(deck: .deckA, volume: 0.5),
                priority: .volumeFader
            ),
            ScheduledTransitionEvent(
                timeOffsetSeconds: 0.000075,
                command: .play(deck: .deckB),
                priority: .transportStart
            ),
            ScheduledTransitionEvent(
                timeOffsetSeconds: 0.00015,
                command: .setEQ(deck: .deckB, eq: EQ3BandParameters(lowGainDB: 0, midGainDB: 0, highGainDB: 0)),
                priority: .audioProcessing
            )
        ]
        let plan = TransitionPlan(
            style: .filterEchoWash(durationSeconds: 1.0),
            outgoingDeck: .deckA,
            incomingDeck: .deckB,
            startTimestampSeconds: 100.0,
            durationSeconds: 1.0,
            events: events,
            metadata: TransitionPlanMetadata()
        )
        var machine = TransitionStateMachine(plan: plan)
        let emitted = try machine.advance(to: 100.0002)
        XCTAssertEqual(emitted.count, 3)
        XCTAssertEqual(emitted[0], .setVolume(deck: .deckA, volume: 0.5))
        XCTAssertEqual(emitted[1], .play(deck: .deckB))
        XCTAssertEqual(emitted[2], .setEQ(deck: .deckB, eq: EQ3BandParameters(lowGainDB: 0, midGainDB: 0, highGainDB: 0)))
    }

}

