import XCTest
import SwiftData
@testable import GymLogKit

/// `ExerciseHistoryAnalyzer` tests against real SwiftData model graphs (in
/// memory) — the seam between the pure `AnalyticsMath` functions (tested in
/// isolation in M3AnalyticsMathTests) and the actual `ExerciseEntry`/`SetLog`
/// relationship structure the app queries.
final class M3ExerciseHistoryAnalyzerTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try TestSupport.makeInMemoryContainer()
        context = ModelContext(container)
    }

    // MARK: - Fixture builder

    /// Builds one client + one exercise + N sessions, each with a single
    /// single-entry block containing exactly the given sets, in the given
    /// order. Returns the built entries in session order.
    @discardableResult
    private func makeHistory(
        exerciseID: String,
        exerciseName: String,
        loadDirection: LoadDirection,
        setsPerSession: [[SetLog.Spec]]
    ) -> [ExerciseEntry] {
        let client = Client(id: "cl-test", name: "Test Client")
        context.insert(client)

        let exercise = Exercise(
            id: exerciseID, canonicalName: exerciseName, aliases: [],
            movementPattern: .pull, equipment: .machine, loadDirection: loadDirection,
            isUnilateral: false, occurrenceCount: setsPerSession.count, needsReview: false, reviewReason: nil
        )
        context.insert(exercise)

        var entries: [ExerciseEntry] = []
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for (i, specs) in setsPerSession.enumerated() {
            let session = WorkoutSession(
                id: "se-test-\(i)", date: base.addingTimeInterval(Double(i) * 86400),
                dateOrigin: .asRecorded, dateRaw: "raw", weekNumber: i + 1,
                sourceSheet: "Test", sourceRow: i
            )
            session.client = client
            context.insert(session)

            let block = SessionBlock(order: 0, blockType: .single, sourceRow: i)
            block.session = session
            context.insert(block)

            let entry = ExerciseEntry(order: 0, exerciseIdRef: exerciseID, exerciseRaw: exerciseName, plannedSets: specs.count, exercise: exercise)
            entry.block = block
            context.insert(entry)

            for (setIndex, spec) in specs.enumerated() {
                let setLog = SetLog(setIndex: setIndex, load: spec.load, target: spec.target, actual: spec.actual, isInferred: spec.isInferred)
                setLog.entry = entry
                context.insert(setLog)
            }
            entries.append(entry)
        }
        return entries
    }

    // MARK: - Rule ① — PR direction

    func testPRDirection_higherIsStronger_maxWins() {
        let entries = makeHistory(
            exerciseID: "ex-bench", exerciseName: "Bench press", loadDirection: .higherIsStronger,
            setsPerSession: [
                [.init(load: .absolute(kg: 50, raw: "50"), target: .fixed(value: 8, raw: "8"), actual: .fixed(value: 8, raw: "8"), isInferred: true)],
                [.init(load: .absolute(kg: 55, raw: "55"), target: .fixed(value: 8, raw: "8"), actual: .fixed(value: 8, raw: "8"), isInferred: true)],
                [.init(load: .absolute(kg: 60, raw: "60"), target: .fixed(value: 8, raw: "8"), actual: .fixed(value: 8, raw: "8"), isInferred: true)],
            ]
        )
        let points = ExerciseHistoryAnalyzer.points(from: entries, loadDirection: .higherIsStronger, includeInferred: true)
        XCTAssertEqual(points.map(\.maxLoadKg), [50, 55, 60])
        XCTAssertEqual(ExerciseHistoryAnalyzer.prFlags(points: points, direction: .higherIsStronger), [true, true, true])
        XCTAssertEqual(ExerciseHistoryAnalyzer.currentPR(points: points, direction: .higherIsStronger)?.value, 60)
    }

    /// The test that MUST fail if rule ① (`.lowerIsStronger` inversion) is
    /// ever dropped: assist weight falling 50→40→30 must be treated as
    /// three consecutive PRs, and the "current PR" must be the MINIMUM (30),
    /// not the maximum (50).
    func testPRDirection_lowerIsStronger_minWinsAndFallingIsProgress() {
        let entries = makeHistory(
            exerciseID: "ex-chinup-assist", exerciseName: "Chin up w/assist", loadDirection: .lowerIsStronger,
            setsPerSession: [
                [.init(load: .assisted(kg: 50, raw: "50"), target: .fixed(value: 8, raw: "8"), actual: .fixed(value: 8, raw: "8"), isInferred: true)],
                [.init(load: .assisted(kg: 40, raw: "40"), target: .fixed(value: 8, raw: "8"), actual: .fixed(value: 8, raw: "8"), isInferred: true)],
                [.init(load: .assisted(kg: 30, raw: "30"), target: .fixed(value: 8, raw: "8"), actual: .fixed(value: 8, raw: "8"), isInferred: true)],
            ]
        )
        let points = ExerciseHistoryAnalyzer.points(from: entries, loadDirection: .lowerIsStronger, includeInferred: true)
        XCTAssertEqual(points.map(\.maxLoadKg), [50, 40, 30])

        let flags = ExerciseHistoryAnalyzer.prFlags(points: points, direction: .lowerIsStronger)
        XCTAssertEqual(flags, [true, true, true], "Every step down in assist weight must register as a new PR.")

        let pr = ExerciseHistoryAnalyzer.currentPR(points: points, direction: .lowerIsStronger)
        XCTAssertEqual(pr?.value, 30, "PR for a lowerIsStronger exercise must be the MINIMUM assist weight, not the maximum.")

        // Delta check mirroring the UI's own logic (rule ①'s own example):
        // "较上次 -5kg 应呈现为进步".
        let last = points[2].maxLoadKg!
        let prev = points[1].maxLoadKg!
        XCTAssertEqual(last - prev, -10)
        XCTAssertTrue(AnalyticsMath.isImprovement(candidate: last, overBest: prev, direction: .lowerIsStronger))
    }

    func testPRDirection_lowerIsStronger_risingAssistIsRegression() {
        let entries = makeHistory(
            exerciseID: "ex-dip-assist", exerciseName: "Dips w/assist", loadDirection: .lowerIsStronger,
            setsPerSession: [
                [.init(load: .assisted(kg: 20, raw: "20"), target: .fixed(value: 8, raw: "8"), actual: .fixed(value: 8, raw: "8"), isInferred: true)],
                [.init(load: .assisted(kg: 35, raw: "35"), target: .fixed(value: 8, raw: "8"), actual: .fixed(value: 8, raw: "8"), isInferred: true)],
            ]
        )
        let points = ExerciseHistoryAnalyzer.points(from: entries, loadDirection: .lowerIsStronger, includeInferred: true)
        let flags = ExerciseHistoryAnalyzer.prFlags(points: points, direction: .lowerIsStronger)
        XCTAssertEqual(flags, [true, false], "Assist weight going UP (needing more help) must NOT register as a new PR.")
    }

    // MARK: - Rule ① × ② interaction — 1RM must stay refused for assisted exercises

    /// Contrived edge case: a `.lowerIsStronger` exercise that happens to
    /// carry an `.absolute` + `.fixed(1...12)` set (rule ② alone would
    /// permit computing 1RM here). Rule ① must independently veto it. This
    /// is the exact "① interacting with ②" trap called out in the task
    /// brief — it only catches a regression if rule ① is enforced as an
    /// explicit guard rather than relying on assisted loads never being
    /// `.absolute` in practice.
    func testNo1RM_forLowerIsStronger_evenWithAbsoluteFixedLoad() {
        let entries = makeHistory(
            exerciseID: "ex-edge", exerciseName: "Edge Case Assisted", loadDirection: .lowerIsStronger,
            setsPerSession: [
                [.init(load: .absolute(kg: 20, raw: "20"), target: .fixed(value: 5, raw: "5"), actual: .fixed(value: 5, raw: "5"), isInferred: true)],
            ]
        )
        let points = ExerciseHistoryAnalyzer.points(from: entries, loadDirection: .lowerIsStronger, includeInferred: true)
        XCTAssertEqual(points.count, 1)
        XCTAssertNil(points[0].bestEstimated1RM, "Rule ① must refuse 1RM for lowerIsStronger exercises regardless of load/actual shape.")
    }

    // MARK: - Rule ③ — perSide never doubled

    func testPerSideLoad_neverDoubled() {
        let entries = makeHistory(
            exerciseID: "ex-legext", exerciseName: "Leg extension SL", loadDirection: .higherIsStronger,
            setsPerSession: [
                [
                    .init(load: .perSide(kg: 15, raw: "15each"), target: .fixed(value: 10, raw: "10"), actual: .fixed(value: 10, raw: "10"), isInferred: true),
                    .init(load: .perSide(kg: 15, raw: "15each"), target: .fixed(value: 10, raw: "10"), actual: .fixed(value: 10, raw: "10"), isInferred: true),
                ],
            ]
        )
        let points = ExerciseHistoryAnalyzer.points(from: entries, loadDirection: .higherIsStronger, includeInferred: true)
        XCTAssertEqual(points[0].maxLoadKg, 15, "Per-side kg must never be summed/doubled into a fake 'total' of 30.")
    }

    // MARK: - Rule ⑤ — isInferred default inclusion

    func testIncludeInferred_defaultTrue_populatesChart() {
        let entries = makeHistory(
            exerciseID: "ex-inf", exerciseName: "Migrated Exercise", loadDirection: .higherIsStronger,
            setsPerSession: [
                [.init(load: .absolute(kg: 40, raw: "40"), target: .fixed(value: 8, raw: "8"), actual: .fixed(value: 8, raw: "8"), isInferred: true)],
            ]
        )
        let included = ExerciseHistoryAnalyzer.points(from: entries, loadDirection: .higherIsStronger, includeInferred: true)
        XCTAssertEqual(included.count, 1, "All-migrated (isInferred=true) data must still populate the chart when included.")

        let excluded = ExerciseHistoryAnalyzer.points(from: entries, loadDirection: .higherIsStronger, includeInferred: false)
        XCTAssertTrue(excluded.isEmpty, "Excluding inferred data should drop entries whose every set is inferred.")
    }

    func testIncludeInferred_partialEntry_keepsOnlyRealSets() {
        let entries = makeHistory(
            exerciseID: "ex-mixed", exerciseName: "Mixed Exercise", loadDirection: .higherIsStronger,
            setsPerSession: [
                [
                    .init(load: .absolute(kg: 40, raw: "40"), target: .fixed(value: 8, raw: "8"), actual: .fixed(value: 8, raw: "8"), isInferred: true),
                    .init(load: .absolute(kg: 42.5, raw: "42.5"), target: .fixed(value: 8, raw: "8"), actual: .fixed(value: 8, raw: "8"), isInferred: false),
                ],
            ]
        )
        let excluded = ExerciseHistoryAnalyzer.points(from: entries, loadDirection: .higherIsStronger, includeInferred: false)
        XCTAssertEqual(excluded.count, 1)
        XCTAssertEqual(excluded[0].sets.count, 1)
        XCTAssertEqual(excluded[0].maxLoadKg, 42.5, "Only the non-inferred set should remain.")
        XCTAssertFalse(excluded[0].anyInferred)
    }

    // MARK: - Rule ④ — volume exclusion accounting

    func testVolumeSummary_excludedCountAndTotalAreHonest() {
        let entries = makeHistory(
            exerciseID: "ex-vol", exerciseName: "Mixed Volume Exercise", loadDirection: .higherIsStronger,
            setsPerSession: [
                [
                    .init(load: .absolute(kg: 20, raw: "20"), target: .fixed(value: 10, raw: "10"), actual: .fixed(value: 10, raw: "10"), isInferred: true), // countable: 200
                    .init(load: .bodyweight(raw: "bw"), target: .fixed(value: 10, raw: "10"), actual: .fixed(value: 10, raw: "10"), isInferred: true),       // excluded
                ],
            ]
        )
        let points = ExerciseHistoryAnalyzer.points(from: entries, loadDirection: .higherIsStronger, includeInferred: true)
        XCTAssertEqual(points[0].volumeKg, 200)
        XCTAssertEqual(points[0].volumeExcludedSetCount, 1)

        let summary = ExerciseHistoryAnalyzer.volumeSummary(points: points)
        XCTAssertEqual(summary.total, 200)
        XCTAssertEqual(summary.excludedSetCount, 1, "The excluded set must be counted, never silently absorbed into the total.")
    }

    // MARK: - 时间/距离/轮次类动作趋势（2026-09-06 审查报告"适合当前范围的功能"
    // 第二批）

    func testTimeMetricExercise_bestDurationTracksLongestSetNotSum() {
        let entries = makeHistory(
            exerciseID: "ex-plank", exerciseName: "Plank", loadDirection: .higherIsStronger,
            setsPerSession: [
                [
                    .init(load: .bodyweight(raw: "bw"), target: .time(seconds: 60, raw: "60s"), actual: .time(seconds: 55, raw: "55s"), isInferred: false),
                    .init(load: .bodyweight(raw: "bw"), target: .time(seconds: 60, raw: "60s"), actual: .time(seconds: 62, raw: "62s"), isInferred: false),
                ],
                [
                    .init(load: .bodyweight(raw: "bw"), target: .time(seconds: 70, raw: "70s"), actual: .time(seconds: 70, raw: "70s"), isInferred: false),
                ],
            ]
        )
        let points = ExerciseHistoryAnalyzer.points(from: entries, loadDirection: .higherIsStronger, includeInferred: true)
        XCTAssertEqual(points.map(\.bestDurationSeconds), [62, 70], "Must take the longest single set, not sum the session's sets together.")
        XCTAssertNil(points[0].maxLoadKg, "Bodyweight load has no comparable kg figure.")
        XCTAssertNil(points[0].completedReps, "A time-based actual must not be miscounted as completed reps.")
        XCTAssertNil(points[0].bestDistanceMeters)
        XCTAssertNil(points[0].bestRoundsCount)
    }

    func testDistanceMetricExercise_bestDistanceExtracted() {
        let entries = makeHistory(
            exerciseID: "ex-row", exerciseName: "Rowing", loadDirection: .higherIsStronger,
            setsPerSession: [
                [.init(load: .bodyweight(raw: "bw"), target: .distance(meters: 500, raw: "500m"), actual: .distance(meters: 480, raw: "480m"), isInferred: false)],
            ]
        )
        let points = ExerciseHistoryAnalyzer.points(from: entries, loadDirection: .higherIsStronger, includeInferred: true)
        XCTAssertEqual(points[0].bestDistanceMeters, 480)
    }

    func testRoundsMetricExercise_bestRoundsExtracted() {
        let entries = makeHistory(
            exerciseID: "ex-carry", exerciseName: "Farmer Carry", loadDirection: .higherIsStronger,
            setsPerSession: [
                [.init(load: .absolute(kg: 24, raw: "24"), target: .rounds(count: 3, raw: "3round"), actual: .rounds(count: 4, raw: "4round"), isInferred: false)],
            ]
        )
        let points = ExerciseHistoryAnalyzer.points(from: entries, loadDirection: .higherIsStronger, includeInferred: true)
        XCTAssertEqual(points[0].bestRoundsCount, 4)
        XCTAssertEqual(points[0].maxLoadKg, 24, "A rounds-based exercise can still carry a comparable weight (e.g. farmer carry load).")
    }

    // MARK: - Regression: 2026-09-06 审查报告 #3 — duplicate trend point IDs

    /// The exact scenario from the review report: one session with TWO
    /// independent blocks, each containing the same exercise once (so both
    /// entries have `entry.order == 0`, since that index only counts within
    /// its own block). Before the fix, both points got the id
    /// "session.id#0" and collided -- PR lookups and chart identity for the
    /// second occurrence could silently latch onto the first's state.
    func testTwoBlocksSameSessionSameExercise_pointsHaveUniqueIDsAndOrderByBlock() {
        let client = Client(id: "cl-dup", name: "Dup Client")
        context.insert(client)

        let exercise = Exercise(
            id: "ex-bench-dup", canonicalName: "Bench press", aliases: [],
            movementPattern: .push, equipment: .barbell, loadDirection: .higherIsStronger,
            isUnilateral: false, occurrenceCount: 2, needsReview: false, reviewReason: nil
        )
        context.insert(exercise)

        let session = WorkoutSession(
            id: "se-dup", date: Date(timeIntervalSince1970: 1_700_000_000),
            dateOrigin: .asRecorded, dateRaw: "raw", weekNumber: 1,
            sourceSheet: "Test", sourceRow: 0
        )
        session.client = client
        context.insert(session)

        func makeEntry(blockOrder: Int, kg: Double) -> ExerciseEntry {
            let block = SessionBlock(order: blockOrder, blockType: .single, sourceRow: blockOrder)
            block.session = session
            context.insert(block)
            let entry = ExerciseEntry(order: 0, exerciseIdRef: exercise.id, exerciseRaw: exercise.canonicalName, plannedSets: 1, exercise: exercise)
            entry.block = block
            context.insert(entry)
            let setLog = SetLog(setIndex: 0, load: .absolute(kg: kg, raw: "\(kg)"), target: .fixed(value: 8, raw: "8"), actual: .fixed(value: 8, raw: "8"), isInferred: false)
            setLog.entry = entry
            context.insert(setLog)
            return entry
        }

        let entryInBlock0 = makeEntry(blockOrder: 0, kg: 50)
        let entryInBlock1 = makeEntry(blockOrder: 1, kg: 60)

        let points = ExerciseHistoryAnalyzer.points(from: [entryInBlock0, entryInBlock1], loadDirection: .higherIsStronger, includeInferred: true)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(Set(points.map(\.id)).count, 2, "Two entries in different blocks of the same session must not collide on id.")
        XCTAssertEqual(points.map(\.maxLoadKg), [50, 60], "Same-day occurrences must sort by block order (block 0 before block 1).")

        // Fetch order reversed (mirrors an @Query not guaranteeing entry
        // order) must not change the result -- the sort is by block/entry
        // order, not by input array position.
        let reversed = ExerciseHistoryAnalyzer.points(from: [entryInBlock1, entryInBlock0], loadDirection: .higherIsStronger, includeInferred: true)
        XCTAssertEqual(reversed.map(\.maxLoadKg), [50, 60], "Sort order must not depend on the input array's fetch order.")

        let flags = ExerciseHistoryAnalyzer.prFlags(points: points, direction: .higherIsStronger)
        XCTAssertEqual(flags, [true, true], "Each distinct occurrence must be evaluated for PR independently, not merged via a colliding id.")
    }

    // MARK: - B03 (2026-09-07 审阅): a failed attempt must never register as a PR

    /// The exact case the audit's diagnostic test reproduced: a single
    /// `.absolute(150kg)` set with `.fixed(0)` actual (a missed lift) must
    /// not surface as a 150kg max load, let alone a PR.
    func testFailedZeroRepAttemptIsNotAMaxLoadOrPR() {
        let entries = makeHistory(
            exerciseID: "ex-clean", exerciseName: "Clean", loadDirection: .higherIsStronger,
            setsPerSession: [
                [.init(load: .absolute(kg: 150, raw: "150"), target: .fixed(value: 1, raw: "1"), actual: .fixed(value: 0, raw: "0"), isInferred: false)],
            ]
        )
        let points = ExerciseHistoryAnalyzer.points(from: entries, loadDirection: .higherIsStronger, includeInferred: true)
        XCTAssertEqual(points.count, 1)
        XCTAssertNil(points[0].maxLoadKg, "A missed lift (actual=0) must not surface any comparable load.")
        XCTAssertEqual(ExerciseHistoryAnalyzer.prFlags(points: points, direction: .higherIsStronger), [false])
        XCTAssertNil(ExerciseHistoryAnalyzer.currentPR(points: points, direction: .higherIsStronger))
    }

    /// 100kg succeeds, 110kg fails, 105kg succeeds -- the failed 110kg must
    /// not become the running PR, and 105kg (a real completion below the
    /// still-standing 100kg PR... no, above it) must correctly register.
    /// Matches the review's own acceptance example verbatim.
    func testFailedAttemptBetweenTwoSuccessesDoesNotBreakOrBlockThePRSequence() {
        let entries = makeHistory(
            exerciseID: "ex-squat", exerciseName: "Back squat", loadDirection: .higherIsStronger,
            setsPerSession: [
                [.init(load: .absolute(kg: 100, raw: "100"), target: .fixed(value: 1, raw: "1"), actual: .fixed(value: 1, raw: "1"), isInferred: false)],
                [.init(load: .absolute(kg: 110, raw: "110"), target: .fixed(value: 1, raw: "1"), actual: .fixed(value: 0, raw: "0"), isInferred: false)],
                [.init(load: .absolute(kg: 105, raw: "105"), target: .fixed(value: 1, raw: "1"), actual: .fixed(value: 1, raw: "1"), isInferred: false)],
            ]
        )
        let points = ExerciseHistoryAnalyzer.points(from: entries, loadDirection: .higherIsStronger, includeInferred: true)
        XCTAssertEqual(points.map(\.maxLoadKg), [100, nil, 105])
        XCTAssertEqual(ExerciseHistoryAnalyzer.prFlags(points: points, direction: .higherIsStronger), [true, false, true])
        XCTAssertEqual(ExerciseHistoryAnalyzer.currentPR(points: points, direction: .higherIsStronger)?.value, 105)
    }

    /// Within one entry, a failed set at a higher weight must not leak into
    /// that occurrence's own max load either -- filtering happens per set,
    /// not just across entries.
    func testFailedSetExcludedFromMaxLoadEvenWhenOtherSetsInSameEntrySucceed() {
        let client = Client(id: "cl-multiset", name: "Multiset Client")
        context.insert(client)
        let exercise = Exercise(
            id: "ex-deadlift", canonicalName: "Deadlift", aliases: [], movementPattern: .hipHinge, equipment: .barbell,
            loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 1, needsReview: false, reviewReason: nil
        )
        context.insert(exercise)
        let session = WorkoutSession(id: "se-multiset", date: Date(), dateOrigin: .asRecorded, dateRaw: "raw", weekNumber: 1, sourceSheet: "Test", sourceRow: 0)
        session.client = client
        context.insert(session)
        let block = SessionBlock(order: 0, blockType: .single, sourceRow: 0)
        block.session = session
        context.insert(block)
        let entry = ExerciseEntry(order: 0, exerciseIdRef: exercise.id, exerciseRaw: exercise.canonicalName, plannedSets: 2, exercise: exercise)
        entry.block = block
        context.insert(entry)
        let completed = SetLog(setIndex: 0, load: .absolute(kg: 100, raw: "100"), target: .fixed(value: 5, raw: "5"), actual: .fixed(value: 5, raw: "5"), isInferred: false)
        completed.entry = entry
        context.insert(completed)
        let failed = SetLog(setIndex: 1, load: .absolute(kg: 140, raw: "140"), target: .fixed(value: 1, raw: "1"), actual: .fixed(value: 0, raw: "0"), isInferred: false)
        failed.entry = entry
        context.insert(failed)

        let points = ExerciseHistoryAnalyzer.points(from: [entry], loadDirection: .higherIsStronger, includeInferred: true)
        XCTAssertEqual(points[0].maxLoadKg, 100, "The failed 140kg set must not leak into this entry's own max load.")
    }

    /// Time/distance/rounds metrics apply the same zero-is-failure rule.
    func testZeroDurationDistanceRoundsAreExcludedFromBestFigures() {
        XCTAssertNil(AnalyticsMath.setDurationSeconds(actual: .time(seconds: 0, raw: "0")))
        XCTAssertNil(AnalyticsMath.setDistanceMeters(actual: .distance(meters: 0, raw: "0")))
        XCTAssertNil(AnalyticsMath.setRoundsCount(actual: .rounds(count: 0, raw: "0")))
        XCTAssertEqual(AnalyticsMath.setDurationSeconds(actual: .time(seconds: 1, raw: "1")), 1)
    }
}

// MARK: - Test-only fixture spec

extension SetLog {
    /// A plain-value spec for building `SetLog`s in tests without repeating
    /// the full initializer call each time.
    struct Spec {
        let load: LoadValue
        let target: RepTarget
        let actual: RepTarget
        let isInferred: Bool
    }
}
