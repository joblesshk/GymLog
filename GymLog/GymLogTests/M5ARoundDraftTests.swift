import XCTest
import SwiftData
@testable import GymLogKit

/// CONTRACT-M5.md §3.3 -- the Round table, the core of this milestone.
/// Covers the four things the task brief calls out as the real risk:
/// Round -> SetLog expansion (gapless setIndex numbering, in Round order),
/// `plannedSets` as the sum of every Round's setsCount, the 4-Round cap,
/// and the 1-Round floor. Also covers the quantity-conversion rule
/// (`RepTargetToRoundQuantity`, extended by CONTRACT-M8.md to be
/// metric-aware) in isolation, since prefill / copy-last-session /
/// template-consumption all route through it and it must behave identically
/// for all three.
@MainActor
final class M5ARoundDraftTests: XCTestCase {

    private func makeExercise(recordingMetric: RecordingMetric = .reps) -> Exercise {
        Exercise(id: "ex-bench", canonicalName: "Bench press", aliases: [], movementPattern: .push, equipment: .barbell, loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 50, needsReview: false, reviewReason: nil, recordingMetric: recordingMetric)
    }

    // MARK: - Round -> SetLog expansion (setIndex numbering, save-path shape)

    /// Recreates the coach's own example verbatim (CONTRACT-M5.md §3.3.1):
    /// bench press, Round 1 = 2 sets @ 30kg, Round 2 = 3 sets @ 45kg,
    /// Round 3 = 2 sets @ 40kg. Proves `resolvedSets()` -- the array
    /// `TodayView.save()` enumerates to assign `setIndex` -- expands each
    /// Round's sets in order, so Round 1 lands at indices 0-1, Round 2 at
    /// 2-4, Round 3 at 5-6: gapless, and grouped by Round, not interleaved.
    func testMultiRoundExpansionProducesGaplessSetIndexOrderedByRound() {
        let draft = EntryDraft(
            exercise: makeExercise(),
            rounds: [
                RoundDraft(setsCount: 2, load: .absolute(kg: 30, raw: "30"), targetQuantity: 10, actualQuantity: 10),
                RoundDraft(setsCount: 3, load: .absolute(kg: 45, raw: "45"), targetQuantity: 6, actualQuantity: 6),
                RoundDraft(setsCount: 2, load: .absolute(kg: 40, raw: "40"), targetQuantity: 8, actualQuantity: 8),
            ]
        )

        let sets = draft.resolvedSets()
        XCTAssertEqual(sets.count, 7, "2 + 3 + 2 sets across the three Rounds")

        // setIndex is assigned by the caller via .enumerated() over exactly
        // this array, so its order IS the setIndex order -- verify the
        // Round boundaries land where the contract specifies (Round 1:
        // 0..<2, Round 2: 2..<5, Round 3: 5..<7).
        func kg(_ i: Int) -> Double {
            guard case .absolute(let kg, _) = sets[i].load else { XCTFail("expected .absolute"); return -1 }
            return kg
        }
        func reps(_ i: Int) -> Int {
            guard case .fixed(let value, _) = sets[i].target else { XCTFail("expected .fixed"); return -1 }
            return value
        }

        XCTAssertEqual(kg(0), 30); XCTAssertEqual(reps(0), 10)
        XCTAssertEqual(kg(1), 30); XCTAssertEqual(reps(1), 10)
        XCTAssertEqual(kg(2), 45); XCTAssertEqual(reps(2), 6)
        XCTAssertEqual(kg(3), 45); XCTAssertEqual(reps(3), 6)
        XCTAssertEqual(kg(4), 45); XCTAssertEqual(reps(4), 6)
        XCTAssertEqual(kg(5), 40); XCTAssertEqual(reps(5), 8)
        XCTAssertEqual(kg(6), 40); XCTAssertEqual(reps(6), 8)
    }

    /// CONTRACT-M9.md: target and actual are independently editable again
    /// (reversing M5's merge) -- a Round with different target/actual
    /// quantities must resolve to two genuinely different `RepTarget`s, not
    /// silently collapse to one.
    func testResolvedSetsAllowsTargetAndActualToDiffer() {
        let draft = EntryDraft(exercise: makeExercise(), setsCount: 3, load: .absolute(kg: 40, raw: "40"), targetQuantity: 10, actualQuantity: 8)
        for set in draft.resolvedSets() {
            XCTAssertEqual(set.target, .fixed(value: 10, raw: "10"), "target must reflect targetQuantity")
            XCTAssertEqual(set.actual, .fixed(value: 8, raw: "8"), "actual must reflect actualQuantity, independently of target")
        }
    }

    /// The "happen to be equal" case (e.g. a coach who hit exactly the
    /// planned number) must still resolve to equal `RepTarget`s -- M9 removes
    /// the forced merge, it doesn't prevent them from coinciding.
    func testResolvedSetsTargetEqualsActualWhenQuantitiesCoincide() {
        let draft = EntryDraft(exercise: makeExercise(), setsCount: 3, load: .absolute(kg: 40, raw: "40"), targetQuantity: 8, actualQuantity: 8)
        for set in draft.resolvedSets() {
            XCTAssertEqual(set.target, set.actual)
        }
    }

    /// `plannedSets` (written into `ExerciseEntry.plannedSets` on save) must
    /// be the sum of every Round's setsCount, not just the last Round's or
    /// the first Round's.
    func testPlannedSetsIsSumOfAllRoundsSetsCounts() {
        let draft = EntryDraft(
            exercise: makeExercise(),
            rounds: [
                RoundDraft(setsCount: 2, load: .absolute(kg: 30, raw: "30"), targetQuantity: 10, actualQuantity: 10),
                RoundDraft(setsCount: 3, load: .absolute(kg: 45, raw: "45"), targetQuantity: 6, actualQuantity: 6),
                RoundDraft(setsCount: 2, load: .absolute(kg: 40, raw: "40"), targetQuantity: 8, actualQuantity: 8),
            ]
        )
        XCTAssertEqual(draft.plannedSets, 7)
    }

    /// End-to-end proof mirroring TodayView.save()'s exact object-graph
    /// construction: a real 3-Round entry persists 7 distinct SetLogs with
    /// gapless setIndex 0...6, each carrying its own Round's load/reps, all
    /// isInferred == false.
    func testSavingMultiRoundEntryProducesDistinctGaplessSetLogs() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)

        let client = Client(id: "cl-1", name: "Test Client")
        context.insert(client)
        let exercise = makeExercise()
        context.insert(exercise)

        let entryDraft = EntryDraft(
            exercise: exercise,
            rounds: [
                RoundDraft(setsCount: 2, load: .absolute(kg: 30, raw: "30"), targetQuantity: 10, actualQuantity: 10),
                RoundDraft(setsCount: 3, load: .absolute(kg: 45, raw: "45"), targetQuantity: 6, actualQuantity: 6),
                RoundDraft(setsCount: 2, load: .absolute(kg: 40, raw: "40"), targetQuantity: 8, actualQuantity: 8),
            ]
        )

        let session = WorkoutSession(id: "se-local-1", date: Date(), dateOrigin: .asRecorded, dateRaw: "2026-08-21", weekNumber: 1, sourceSheet: "App", sourceRow: 0, plannedDurationMinutes: 75)
        session.client = client
        context.insert(session)
        let block = SessionBlock(order: 0, blockType: .single, sourceRow: 0)
        block.session = session
        context.insert(block)
        let entry = ExerciseEntry(order: 0, exerciseIdRef: entryDraft.exercise.id, exerciseRaw: entryDraft.exercise.canonicalName, plannedSets: entryDraft.plannedSets, exercise: entryDraft.exercise)
        entry.block = block
        context.insert(entry)

        for (setIndex, values) in entryDraft.resolvedSets().enumerated() {
            let setLog = SetLog(setIndex: setIndex, load: values.load, target: values.target, actual: values.actual, isInferred: false)
            setLog.entry = entry
            context.insert(setLog)
        }
        try context.save()

        let saved = try context.fetch(FetchDescriptor<SetLog>(sortBy: [SortDescriptor(\.setIndex)]))
        XCTAssertEqual(saved.count, 7)
        XCTAssertEqual(saved.map(\.setIndex), Array(0..<7), "setIndex must be gapless 0...6, in Round order")
        XCTAssertTrue(saved.allSatisfy { $0.isInferred == false })
        XCTAssertEqual(entry.plannedSets, 7, "ExerciseEntry.plannedSets must be the sum of all Rounds' setsCount")
        XCTAssertEqual(session.plannedDurationMinutes, 75, "sanity: plannedDurationMinutes round-trips through the model unchanged")

        guard case .absolute(let kg0, _) = saved[0].load else { return XCTFail() }
        guard case .absolute(let kg2, _) = saved[2].load else { return XCTFail() }
        guard case .absolute(let kg5, _) = saved[5].load else { return XCTFail() }
        XCTAssertEqual(kg0, 30, "index 0 is Round 1's first set")
        XCTAssertEqual(kg2, 45, "index 2 is Round 2's first set (right after Round 1's 2 sets)")
        XCTAssertEqual(kg5, 40, "index 5 is Round 3's first set (right after Rounds 1+2's 5 sets)")
    }

    // MARK: - 4-Round cap / 1-Round floor

    func testAddRoundStopsAtFourRounds() {
        let draft = EntryDraft(exercise: makeExercise(), setsCount: 3, load: .absolute(kg: 20, raw: "20"), targetQuantity: 10, actualQuantity: 10)
        XCTAssertEqual(draft.rounds.count, 1)
        XCTAssertTrue(draft.canAddRound)

        draft.addRound()
        draft.addRound()
        draft.addRound()
        XCTAssertEqual(draft.rounds.count, 4)
        XCTAssertFalse(draft.canAddRound, "must not be able to add a 5th Round")

        draft.addRound() // no-op past the cap
        XCTAssertEqual(draft.rounds.count, 4, "addRound() past the cap must be a no-op, not silently grow past 4")
    }

    func testRemoveRoundNeverGoesBelowOneRound() {
        let draft = EntryDraft(exercise: makeExercise(), setsCount: 3, load: .absolute(kg: 20, raw: "20"), targetQuantity: 10, actualQuantity: 10)
        XCTAssertEqual(draft.rounds.count, 1)
        XCTAssertFalse(draft.canRemoveRound, "a single-Round entry must not be removable down to zero")

        let onlyRoundID = draft.rounds[0].id
        draft.removeRound(id: onlyRoundID)
        XCTAssertEqual(draft.rounds.count, 1, "removeRound() at the floor must be a no-op, never leave zero Rounds")
    }

    func testRemoveRoundWorksAboveTheFloor() {
        let draft = EntryDraft(exercise: makeExercise(), setsCount: 3, load: .absolute(kg: 20, raw: "20"), targetQuantity: 10, actualQuantity: 10)
        draft.addRound()
        XCTAssertEqual(draft.rounds.count, 2)
        XCTAssertTrue(draft.canRemoveRound)

        let secondRoundID = draft.rounds[1].id
        draft.removeRound(id: secondRoundID)
        XCTAssertEqual(draft.rounds.count, 1)
    }

    // MARK: - Quantity conversion rule (RepTargetToRoundQuantity)

    /// Documented rule: `.fixed` passes through unchanged for a `.reps` exercise.
    func testQuantityPassesFixedValueThroughForReps() {
        XCTAssertEqual(RepTargetToRoundQuantity.quantity(from: .fixed(value: 12, raw: "12"), metric: .reps), 12)
    }

    /// Documented rule: `.range` -> arithmetic mean, rounded (midpoint).
    /// The historical "8-12" example from CONTRACT-M5.md §3.3.2 must land
    /// on exactly 10.
    func testQuantityRoundsRangeToMidpointForReps() {
        XCTAssertEqual(RepTargetToRoundQuantity.quantity(from: .range(low: 8, high: 12, raw: "8-12"), metric: .reps), 10)
        // Odd sum -> .5 rounds up (documented tie-breaking rule).
        XCTAssertEqual(RepTargetToRoundQuantity.quantity(from: .range(low: 6, high: 9, raw: "6-9"), metric: .reps), 8)
    }

    /// Documented rule: `.perSide` -> mean of left/right, same rounding.
    func testQuantityAveragesPerSideForReps() {
        XCTAssertEqual(RepTargetToRoundQuantity.quantity(from: .perSide(left: 10, right: 8, raw: "10,8"), metric: .reps), 9)
    }

    /// CONTRACT-M8.md: when the historical `RepTarget`'s kind matches the
    /// exercise's own metric, the exact seconds/meters/rounds value passes
    /// through untouched -- this is the core bug fix (pre-M8, all three of
    /// these collapsed to the meaningless constant 10).
    func testQuantityExtractsExactValueWhenTargetKindMatchesMetric() {
        XCTAssertEqual(RepTargetToRoundQuantity.quantity(from: .time(seconds: 45, raw: "0:45"), metric: .time), 45)
        XCTAssertEqual(RepTargetToRoundQuantity.quantity(from: .distance(meters: 500, raw: "500m"), metric: .distance), 500)
        XCTAssertEqual(RepTargetToRoundQuantity.quantity(from: .rounds(count: 4, raw: "4round"), metric: .rounds), 4)
    }

    /// When the historical target's kind does NOT match the exercise's
    /// metric (e.g. reclassified after being logged, or `.unknown` history),
    /// there's no unit-correct number to extract -- falls back to a
    /// per-metric default, not a blanket 10 regardless of metric.
    func testQuantityFallsBackToPerMetricDefaultOnMismatch() {
        XCTAssertEqual(RepTargetToRoundQuantity.quantity(from: .unknown(raw: ""), metric: .reps), 10)
        XCTAssertEqual(RepTargetToRoundQuantity.quantity(from: .unknown(raw: ""), metric: .time), 30)
        XCTAssertEqual(RepTargetToRoundQuantity.quantity(from: .unknown(raw: ""), metric: .distance), 200)
        XCTAssertEqual(RepTargetToRoundQuantity.quantity(from: .unknown(raw: ""), metric: .rounds), 3)
        // A reps-shaped historical value on a since-reclassified time exercise:
        // still no seconds concept in ".fixed", falls back to the time default.
        XCTAssertEqual(RepTargetToRoundQuantity.quantity(from: .fixed(value: 12, raw: "12"), metric: .time), 30)
    }

    // MARK: - resolvedSets() emits the right RepTarget case per exercise metric

    /// CONTRACT-M8.md's actual UI-facing fix: a plank-classified exercise's
    /// Round must persist as `.time(seconds:)`, not `.fixed` (reps) -- this
    /// is what a coach logging "45 seconds" for a plank actually needs
    /// stored, so history/analytics see it as a time-held set, not "45 reps".
    func testResolvedSetsEmitsTimeForTimeMetricExercise() {
        let plank = makeExercise(recordingMetric: .time)
        let draft = EntryDraft(exercise: plank, setsCount: 3, load: .bodyweight(raw: ""), targetQuantity: 45, actualQuantity: 45)
        for set in draft.resolvedSets() {
            XCTAssertEqual(set.target, .time(seconds: 45, raw: "45"))
            XCTAssertEqual(set.actual, .time(seconds: 45, raw: "45"))
        }
    }

    func testResolvedSetsEmitsDistanceForDistanceMetricExercise() {
        let rowing = makeExercise(recordingMetric: .distance)
        let draft = EntryDraft(exercise: rowing, setsCount: 1, load: .bodyweight(raw: ""), targetQuantity: 500, actualQuantity: 500)
        XCTAssertEqual(draft.resolvedSets()[0].target, .distance(meters: 500, raw: "500m"))
    }

    func testResolvedSetsEmitsRoundsForRoundsMetricExercise() {
        let farmerWalk = makeExercise(recordingMetric: .rounds)
        let draft = EntryDraft(exercise: farmerWalk, setsCount: 1, load: .absolute(kg: 32, raw: "32"), targetQuantity: 3, actualQuantity: 3)
        XCTAssertEqual(draft.resolvedSets()[0].target, .rounds(count: 3, raw: "3round"))
    }

    func testResolvedSetsStillEmitsFixedForRepsMetricExercise() {
        let draft = EntryDraft(exercise: makeExercise(), setsCount: 1, load: .absolute(kg: 20, raw: "20"), targetQuantity: 10, actualQuantity: 10)
        XCTAssertEqual(draft.resolvedSets()[0].target, .fixed(value: 10, raw: "10"))
    }
}
