import XCTest
@testable import GymLogKit

/// 2026-09-07 M3: `WODTimerModel` -- the deadline-based (never per-second-
/// decrementing) WOD execution timer. `now` is injected throughout so these
/// tests never actually wait in real time, mirroring `RestTimerModel`'s own
/// test discipline.
@MainActor
final class WODTimerModelTests: XCTestCase {
    private final class Clock {
        var current: Date
        init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) { current = date }
        func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
        func now() -> Date { current }
    }

    // MARK: - Single-phase (AMRAP / For Time with cap)

    func testSinglePhaseCountsDownAndEnds() {
        let clock = Clock()
        let timer = WODTimerModel(phases: [WODTimerPhase(label: "AMRAP", durationSeconds: 600)], now: clock.now)
        timer.start()
        XCTAssertEqual(timer.remainingSecondsInPhase, 600)

        clock.advance(600)
        timer.sync()
        XCTAssertEqual(timer.state, .ended)
        XCTAssertEqual(timer.elapsedSeconds, 600)
    }

    func testSinglePhasePartwayThroughReportsCorrectRemaining() {
        let clock = Clock()
        let timer = WODTimerModel(phases: [WODTimerPhase(label: "For Time", durationSeconds: 720)], now: clock.now)
        timer.start()
        clock.advance(500)
        timer.sync()
        XCTAssertEqual(timer.remainingSecondsInPhase, 220)
        XCTAssertEqual(timer.elapsedSeconds, 500)
        XCTAssertEqual(timer.state, .running)
    }

    /// Regression (2026-09-15): the live ticker calls `sync()` every 200ms.
    /// Re-anchoring the deadline to `now + ceil(remaining)` on each call
    /// pushed it forward by the rounded-up fraction every tick, so an AMRAP
    /// sat at 12:00 forever. Whole-second clock steps never exposed it.
    func testSubSecondTicksStillCountDown() {
        let clock = Clock()
        let timer = WODTimerModel(phases: [WODTimerPhase(label: "AMRAP", durationSeconds: 720)], now: clock.now)
        timer.start()
        for _ in 0..<25 {
            clock.advance(0.2)
            timer.sync()
        }
        XCTAssertEqual(timer.remainingSecondsInPhase, 715)
        XCTAssertEqual(timer.elapsedSeconds, 5)
    }

    func testSubSecondTicksAcrossPhaseBoundaryKeepAccurateDeadline() {
        let clock = Clock()
        let phases = [WODTimerPhase(label: "1", durationSeconds: 60), WODTimerPhase(label: "2", durationSeconds: 60)]
        let timer = WODTimerModel(phases: phases, now: clock.now)
        timer.start()
        for _ in 0..<(65 * 5) {
            clock.advance(0.2)
            timer.sync()
        }
        XCTAssertEqual(timer.currentPhaseIndex, 1)
        XCTAssertEqual(timer.remainingSecondsInPhase, 55)
        XCTAssertEqual(timer.elapsedSeconds, 65)
    }

    /// The exact acceptance case from the review: a 12-minute cap, stopped
    /// early -- `end()` must report the elapsed-so-far, never the full cap
    /// duration as if it were a finish.
    func testEndingEarlyReportsActualElapsedNotTheCap() {
        let clock = Clock()
        let timer = WODTimerModel(phases: [WODTimerPhase(label: "For Time", durationSeconds: 720)], now: clock.now)
        timer.start()
        clock.advance(300)
        timer.end()
        XCTAssertEqual(timer.state, .ended)
        XCTAssertEqual(timer.elapsedSeconds, 300)
    }

    // MARK: - Multi-phase (EMOM / interval) with background catch-up

    func testMultiPhaseAdvancesOnBoundary() {
        let clock = Clock()
        let phases = [
            WODTimerPhase(label: "1", durationSeconds: 60), WODTimerPhase(label: "2", durationSeconds: 60),
            WODTimerPhase(label: "3", durationSeconds: 60),
        ]
        let timer = WODTimerModel(phases: phases, now: clock.now)
        var finishedIndices: [Int] = []
        timer.onPhaseFinish = { finishedIndices.append($0) }
        timer.start()

        clock.advance(60)
        timer.sync()
        XCTAssertEqual(timer.currentPhaseIndex, 1)
        XCTAssertEqual(timer.remainingSecondsInPhase, 60)
        XCTAssertEqual(finishedIndices, [0])
    }

    /// The exact scenario the review flags: the app is backgrounded through
    /// an ENTIRE EMOM interval (or more than one). A single `sync()` call
    /// (fired once when the app returns to foreground) must catch up
    /// through every boundary crossed, not just the first one, and must not
    /// lose or double-count seconds doing it.
    func testCatchesUpThroughMultipleFinishedPhasesInOneSync() {
        let clock = Clock()
        let phases = (0..<5).map { WODTimerPhase(label: "\($0)", durationSeconds: 60) }
        let timer = WODTimerModel(phases: phases, now: clock.now)
        var finishedIndices: [Int] = []
        timer.onPhaseFinish = { finishedIndices.append($0) }
        timer.start()

        // Backgrounded through phases 0, 1, 2 entirely, and 25s into phase 3.
        clock.advance(60 * 3 + 25)
        timer.sync()

        XCTAssertEqual(finishedIndices, [0, 1, 2], "must fire exactly once per boundary actually crossed, not one lump sum")
        XCTAssertEqual(timer.currentPhaseIndex, 3)
        XCTAssertEqual(timer.remainingSecondsInPhase, 35, "60 - 25 = 35s left in phase 3")
        XCTAssertEqual(timer.elapsedSeconds, 60 * 3 + 25)
        XCTAssertEqual(timer.state, .running)
    }

    func testCatchingUpPastTheLastPhaseEndsTheTimer() {
        let clock = Clock()
        let phases = (0..<3).map { WODTimerPhase(label: "\($0)", durationSeconds: 60) }
        let timer = WODTimerModel(phases: phases, now: clock.now)
        var allFinished = false
        timer.onAllPhasesFinished = { allFinished = true }
        timer.start()

        clock.advance(1000) // way past all 3 phases (180s total)
        timer.sync()

        XCTAssertTrue(allFinished)
        XCTAssertEqual(timer.state, .ended)
        XCTAssertEqual(timer.elapsedSeconds, 180, "elapsed caps at the prescribed total, not the background duration")
    }

    // MARK: - Manual advance (EMOM: clock still consumes the full nominal interval)

    func testManualAdvanceConsumesFullNominalPhaseLength() {
        let clock = Clock()
        let phases = [WODTimerPhase(label: "1", durationSeconds: 60), WODTimerPhase(label: "2", durationSeconds: 60)]
        let timer = WODTimerModel(phases: phases, now: clock.now)
        timer.start()
        clock.advance(10) // only 10s into a 60s interval
        timer.advanceToNextPhase()

        XCTAssertEqual(timer.currentPhaseIndex, 1)
        // EMOM's clock advances a full nominal minute regardless of when the
        // coach confirms the station -- elapsed must reflect 60s consumed
        // for phase 0, not the 10s that had actually passed.
        XCTAssertEqual(timer.elapsedSeconds, 60)
    }

    func testUndoLastAdvanceRevertsAFatFingeredConfirm() {
        let clock = Clock()
        let phases = [WODTimerPhase(label: "1", durationSeconds: 60), WODTimerPhase(label: "2", durationSeconds: 60)]
        let timer = WODTimerModel(phases: phases, now: clock.now)
        timer.start()
        clock.advance(10)
        XCTAssertFalse(timer.canUndoLastAdvance)
        timer.advanceToNextPhase()
        XCTAssertEqual(timer.currentPhaseIndex, 1)
        XCTAssertTrue(timer.canUndoLastAdvance)

        timer.undoLastAdvance()
        XCTAssertEqual(timer.currentPhaseIndex, 0)
        XCTAssertEqual(timer.remainingSecondsInPhase, 50, "must restore exactly the pre-advance remaining time, not just reset to the phase's full duration")
        XCTAssertFalse(timer.canUndoLastAdvance)
    }

    func testUndoCanReviveATimerThatJustEnded() {
        let clock = Clock()
        let phases = [WODTimerPhase(label: "1", durationSeconds: 60)]
        let timer = WODTimerModel(phases: phases, now: clock.now)
        timer.start()
        clock.advance(30)
        timer.advanceToNextPhase() // this was the last phase -- ends the timer
        XCTAssertEqual(timer.state, .ended)

        timer.undoLastAdvance()
        XCTAssertEqual(timer.state, .running, "undoing the advance that ended the timer must un-end it")
        XCTAssertEqual(timer.remainingSecondsInPhase, 30)
    }

    // MARK: - Pause / resume

    func testPauseFreezesRemainingAndResumePicksUpWhereItLeftOff() {
        let clock = Clock()
        let timer = WODTimerModel(phases: [WODTimerPhase(label: "AMRAP", durationSeconds: 600)], now: clock.now)
        timer.start()
        clock.advance(100)
        timer.pause()
        XCTAssertEqual(timer.state, .paused)
        XCTAssertEqual(timer.remainingSecondsInPhase, 500)

        // Time passes while paused -- must NOT count against the timer.
        clock.advance(9999)
        timer.start() // resume
        XCTAssertEqual(timer.state, .running)
        XCTAssertEqual(timer.remainingSecondsInPhase, 500, "time elapsed while paused must never be charged to the timer")

        clock.advance(50)
        timer.sync()
        XCTAssertEqual(timer.remainingSecondsInPhase, 450)
    }

    func testCountUpPauseAndResumePreservesElapsed() {
        let clock = Clock()
        let timer = WODTimerModel(countUp: clock.now)
        timer.start()
        clock.advance(45)
        timer.pause()
        XCTAssertEqual(timer.elapsedSeconds, 45)

        clock.advance(500) // paused -- must not count
        timer.start()
        clock.advance(15)
        timer.sync()
        XCTAssertEqual(timer.elapsedSeconds, 60)
    }

    // MARK: - Count-up (uncapped For Time)

    func testCountUpCountsIndefinitelyUntilEnded() {
        let clock = Clock()
        let timer = WODTimerModel(countUp: clock.now)
        timer.start()
        clock.advance(1234)
        timer.sync()
        XCTAssertEqual(timer.elapsedSeconds, 1234)
        XCTAssertEqual(timer.state, .running, "an uncapped timer never auto-ends")
        timer.end()
        XCTAssertEqual(timer.state, .ended)
        XCTAssertEqual(timer.elapsedSeconds, 1234)
    }

    // MARK: - Persistence / recovery across process death

    func testAnchorRoundTripsAndFlagsResumedState() {
        let clock = Clock()
        let phases = [WODTimerPhase(label: "1", durationSeconds: 60), WODTimerPhase(label: "2", durationSeconds: 60)]
        let timer = WODTimerModel(phases: phases, now: clock.now)
        timer.start()
        clock.advance(20)
        guard let anchor = timer.makeAnchor() else { return XCTFail("expected an anchor while running") }

        // Simulate the process being killed and relaunched: a brand new
        // model, restored from the persisted anchor.
        let revived = WODTimerModel(phases: phases, now: clock.now)
        XCTAssertFalse(revived.resumedFromPersistedState)
        revived.restore(from: anchor)
        XCTAssertTrue(revived.resumedFromPersistedState, "restoring from a persisted anchor must always flag for review, per the reboot/clock-change risk")
        XCTAssertEqual(revived.state, .running)
        XCTAssertEqual(revived.remainingSecondsInPhase, 40)
    }

    func testAnchorSurvivesAndCatchesUpEvenAcrossASimulatedRestart() {
        let clock = Clock()
        let phases = [WODTimerPhase(label: "1", durationSeconds: 60), WODTimerPhase(label: "2", durationSeconds: 60)]
        let timer = WODTimerModel(phases: phases, now: clock.now)
        timer.start()
        clock.advance(20)
        let anchor = timer.makeAnchor()!

        // The "process" was dead for 90 more seconds before relaunching.
        clock.advance(90)
        let revived = WODTimerModel(phases: phases, now: clock.now)
        revived.restore(from: anchor)

        XCTAssertEqual(revived.currentPhaseIndex, 1)
        XCTAssertEqual(revived.state, .running)
    }

    func testMakeAnchorReturnsNilWhenNotRunning() {
        let timer = WODTimerModel(phases: [WODTimerPhase(label: "1", durationSeconds: 60)])
        XCTAssertNil(timer.makeAnchor(), "idle timer has nothing to persist")
        timer.start()
        timer.pause()
        XCTAssertNil(timer.makeAnchor(), "a paused timer's remaining time is already captured in the draft's own fields, not re-persisted as a running anchor")
    }

    // MARK: - Defensive: empty phases must never crash

    func testEmptyPhasesEndsImmediatelyInsteadOfCrashing() {
        let clock = Clock()
        let timer = WODTimerModel(phases: [], now: clock.now)
        timer.start()
        timer.sync()
        XCTAssertEqual(timer.state, .ended)
    }

    // MARK: - forPrescription mapping

    func testForPrescriptionAMRAPIsSinglePhase() {
        let prescription = WODPrescription(id: "w1", revision: 1, format: .amrap, timeCapSeconds: 720, rounds: [], scoringRule: .roundsAndReps)
        let timer = WODTimerModel.forPrescription(prescription)
        XCTAssertEqual(timer.phases.count, 1)
        XCTAssertEqual(timer.phases[0].durationSeconds, 720)
        XCTAssertFalse(timer.isCountUp)
    }

    func testForPrescriptionForTimeWithNoCapIsCountUp() {
        let prescription = WODPrescription(id: "w2", revision: 1, format: .forTime, rounds: [], scoringRule: .completionTime)
        let timer = WODTimerModel.forPrescription(prescription)
        XCTAssertTrue(timer.isCountUp)
    }

    func testForPrescriptionEMOMProducesOnePhasePerInterval() {
        let prescription = WODPrescription(id: "w3", revision: 1, format: .emom, intervalSeconds: 60, intervalCount: 12, rounds: [], scoringRule: .manual)
        let timer = WODTimerModel.forPrescription(prescription)
        XCTAssertEqual(timer.phases.count, 12)
        XCTAssertTrue(timer.phases.allSatisfy { $0.durationSeconds == 60 })
    }

    func testForPrescriptionIntervalProducesAlternatingWorkRestPhases() {
        let prescription = WODPrescription(id: "w4", revision: 1, format: .interval, intervalSeconds: 20, restSeconds: 10, intervalCount: 8, rounds: [], scoringRule: .totalQuantity)
        let timer = WODTimerModel.forPrescription(prescription)
        XCTAssertEqual(timer.phases.count, 16, "8 work + 8 rest phases")
        XCTAssertEqual(timer.phases[0].durationSeconds, 20)
        XCTAssertTrue(timer.phases[0].isWork)
        XCTAssertEqual(timer.phases[1].durationSeconds, 10)
        XCTAssertFalse(timer.phases[1].isWork)
    }
}
