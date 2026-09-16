import XCTest
@testable import GymLogKit

/// 2026-09-11 P0：修改動作（`EntryRowView` 的滾輪/搜索選擇器）改走
/// `EntryDraft.setExercise(_:)`，不再讓呼叫端直接寫 `draft.exercise =`。
/// 這裡驗證它承諾的兩件事：(1) 同記錄單位换動作時，Round 數據原樣保留，
/// 和舊的直接賦值行為完全一致；(2) 记录单位不同的换動作時，不能把舊單位
/// 底下輸入的原始數字，在新單位下被沉默地重新解釋（"500 米" 变成
/// "500 次" 这种情况），既包括即時 UI 會讀到的 `exercise.recordingMetric`，
/// 也包括保存路径 `resolvedSets()` 实际使用的 `recordingMetric`。
@MainActor
final class EntryDraftSetExerciseTests: XCTestCase {

    private func makeExercise(
        id: String,
        name: String,
        metric: RecordingMetric,
        equipment: Equipment = .barbell
    ) -> Exercise {
        Exercise(
            id: id, canonicalName: name, aliases: [], movementPattern: .push,
            equipment: equipment, loadDirection: .higherIsStronger, isUnilateral: false,
            occurrenceCount: 0, needsReview: false, reviewReason: nil,
            recordingMetric: metric
        )
    }

    // MARK: - Same-metric swap: full fidelity, matches old direct-assignment behavior

    func testSameMetricSwapPreservesEveryRoundFieldExactly() {
        let benchPress = makeExercise(id: "ex-bench", name: "Barbell Bench Press", metric: .reps)
        let dumbbellPress = makeExercise(id: "ex-db-bench", name: "Dumbbell Bench Press", metric: .reps)

        let draft = EntryDraft(
            exercise: benchPress,
            rounds: [
                RoundDraft(setsCount: 2, load: .absolute(kg: 30, raw: "30"), targetQuantity: 10, actualQuantity: 8, metric: .reps),
                RoundDraft(setsCount: 3, load: .absolute(kg: 45, raw: "45"), targetQuantity: 6, actualQuantity: 6, metric: .reps)
            ]
        )
        let roundIDsBefore = draft.rounds.map(\.id)

        draft.setExercise(dumbbellPress)

        XCTAssertEqual(draft.exercise.id, "ex-db-bench")
        XCTAssertEqual(draft.recordingMetric, .reps, "metric unchanged, so the captured recordingMetric must not move either")
        XCTAssertEqual(draft.rounds.map(\.id), roundIDsBefore, "Round identity must survive a same-metric swap unchanged")
        XCTAssertEqual(draft.rounds[0].setsCount, 2)
        XCTAssertEqual(draft.rounds[0].target, .fixed(value: 10, raw: "10"))
        XCTAssertEqual(draft.rounds[0].actual, .fixed(value: 8, raw: "8"))
        guard case .absolute(let kg0, _) = draft.rounds[0].load else { return XCTFail("expected .absolute") }
        XCTAssertEqual(kg0, 30, "load must NOT be reset when the metric didn't change")
        XCTAssertEqual(draft.rounds[1].setsCount, 3)
        XCTAssertEqual(draft.rounds[1].target, .fixed(value: 6, raw: "6"))
        XCTAssertEqual(draft.rounds[1].actual, .fixed(value: 6, raw: "6"))
    }

    // MARK: - Cross-metric swap: never reinterpret the old number under the new unit

    func testDistanceToRepsSwapNeverReinterpretsTheOldNumberAsReps() {
        let row500m = makeExercise(id: "ex-row", name: "500m Row", metric: .distance, equipment: .machine)
        let squat = makeExercise(id: "ex-squat", name: "Squat", metric: .reps, equipment: .barbell)

        let draft = EntryDraft(
            exercise: row500m,
            rounds: [RoundDraft(setsCount: 3, load: .bodyweight(raw: "BW"), targetQuantity: 500, actualQuantity: 500, metric: .distance)]
        )
        XCTAssertEqual(draft.recordingMetric, .distance)

        draft.setExercise(squat)

        XCTAssertEqual(draft.exercise.id, "ex-squat")
        XCTAssertEqual(draft.recordingMetric, .reps, "recordingMetric must follow the new exercise, not stay frozen at .distance")
        XCTAssertEqual(draft.rounds.count, 1)
        XCTAssertEqual(draft.rounds[0].setsCount, 3, "setsCount is unit-agnostic and should survive the swap")
        XCTAssertNotEqual(draft.rounds[0].target, .fixed(value: 500, raw: "500"), "the raw '500' (meters) must never carry over and silently become '500' reps")
        XCTAssertEqual(draft.rounds[0].target, RepTargetToRoundQuantity.repTarget(quantity: RepTargetToRoundQuantity.defaultQuantity(for: .reps), metric: .reps))
        XCTAssertEqual(draft.rounds[0].actual, RepTargetToRoundQuantity.repTarget(quantity: RepTargetToRoundQuantity.defaultQuantity(for: .reps), metric: .reps))
        // R02 (2026-09-16): the old "500m, confirmed" actual must not survive
        // as a silently-confirmed "10 reps" -- the swap resets `actualQuantity`
        // to a placeholder, so `actualRecorded` must reset to `false` too.
        XCTAssertFalse(draft.rounds[0].actualRecorded, "a reset-to-placeholder actual must require re-confirmation, not carry over as already-recorded")

        // The save path (`resolvedSets()`) must encode the new metric's RepTarget
        // kind, not `.distance` left over from the old exercise -- this is the
        // exact persisted-data-corruption case the fix closes: an ExerciseEntry
        // whose exercise is reps-based must never carry a `.distance` RepTarget.
        // `target` is always resolved (a plan doesn't need confirming); `actual`
        // resolves to `.unknown`, not a fabricated `.fixed`, since it's no
        // longer marked as recorded.
        let resolved = draft.resolvedSets()
        XCTAssertEqual(resolved.count, 3)
        for set in resolved {
            guard case .fixed = set.target else { return XCTFail("expected .fixed (reps) RepTarget after swapping to a reps exercise, not .distance") }
            guard case .unknown = set.actual else { return XCTFail("expected .unknown actual (not yet re-confirmed after the swap), not a fabricated .fixed value") }
        }
    }

    func testRepsToTimeSwapResetsQuantitiesButKeepsSetsCountPerRound() {
        let squat = makeExercise(id: "ex-squat", name: "Squat", metric: .reps)
        let plank = makeExercise(id: "ex-plank", name: "Plank", metric: .time, equipment: .other)

        let draft = EntryDraft(
            exercise: squat,
            rounds: [
                RoundDraft(setsCount: 4, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 8, metric: .reps),
                RoundDraft(setsCount: 2, load: .absolute(kg: 60, raw: "60"), targetQuantity: 5, actualQuantity: 3, metric: .reps)
            ]
        )

        draft.setExercise(plank)

        XCTAssertEqual(draft.recordingMetric, .time)
        XCTAssertEqual(draft.rounds.count, 2)
        XCTAssertEqual(draft.rounds[0].setsCount, 4, "Round 1's setsCount survives")
        XCTAssertEqual(draft.rounds[1].setsCount, 2, "Round 2's setsCount survives")
        let expectedDefault = RepTargetToRoundQuantity.repTarget(quantity: RepTargetToRoundQuantity.defaultQuantity(for: .time), metric: .time)
        XCTAssertEqual(draft.rounds[0].target, expectedDefault)
        XCTAssertEqual(draft.rounds[0].actual, expectedDefault)
        XCTAssertEqual(draft.rounds[1].target, expectedDefault)
        XCTAssertEqual(draft.rounds[1].actual, expectedDefault)

        let resolved = draft.resolvedSets()
        XCTAssertEqual(resolved.count, 6, "4 + 2 sets across both rounds")
        for set in resolved {
            guard case .time = set.target else { return XCTFail("expected .time RepTarget after swapping to a time exercise") }
        }
    }

    /// R02 (2026-09-16): a cross-metric swap resets `actualQuantity` to a
    /// generic per-metric placeholder (see the two tests above) -- it must
    /// also reset `actualRecorded` to `false`. Carrying over a `true` from
    /// before the swap would let the UI/save path treat that placeholder
    /// number as a real confirmed result nobody actually measured.
    func testCrossMetricSwapResetsActualRecordedEvenIfItWasTrueBefore() {
        let row500m = makeExercise(id: "ex-row", name: "500m Row", metric: .distance, equipment: .machine)
        let squat = makeExercise(id: "ex-squat", name: "Squat", metric: .reps)
        let draft = EntryDraft(exercise: row500m, rounds: [
            RoundDraft(setsCount: 3, load: .bodyweight(raw: "BW"), targetQuantity: 500, actualQuantity: 500, metric: .distance, actualRecorded: true),
        ])
        XCTAssertTrue(draft.rounds[0].actualRecorded, "sanity: the actual was confirmed before the swap")

        draft.setExercise(squat)

        XCTAssertFalse(draft.rounds[0].actualRecorded, "a reset-to-placeholder quantity must never masquerade as a confirmed actual")
    }

    /// R02 (2026-09-16): `RoundTableView` (EntryRowView.swift) must read
    /// `draft.recordingMetric`, never `draft.exercise.recordingMetric` live
    /// -- `Exercise` is a shared SwiftData reference the coach can
    /// reclassify (動作庫 -> 編輯 -> 記錄單位) independently of any draft/entry
    /// already pointing at it, entirely without going through
    /// `setExercise`. This pins the contract the view fix depends on: once
    /// an `EntryDraft` exists, its own `recordingMetric` never moves just
    /// because the underlying `Exercise` object's classification does.
    func testRecordingMetricStaysFrozenWhenTheUnderlyingExerciseIsReclassifiedWithoutSetExercise() {
        let row500m = makeExercise(id: "ex-row", name: "500m Row", metric: .distance, equipment: .machine)
        let draft = EntryDraft(exercise: row500m, setsCount: 1, load: .bodyweight(raw: "BW"), targetQuantity: 500, actualQuantity: 500)
        XCTAssertEqual(draft.recordingMetric, .distance)

        // The coach reclassifies "500m Row" in 動作庫 -- same `Exercise`
        // instance `draft.exercise` still points at, no `setExercise` call.
        row500m.recordingMetric = .reps

        XCTAssertEqual(draft.exercise.recordingMetric, .reps, "sanity: the live object really did change")
        XCTAssertEqual(draft.recordingMetric, .distance, "the draft's own frozen metric must NOT follow the library's live reclassification")
    }

    func testExerciseRecordingMetricStaysInSyncForLiveUIReadsAfterSwap() {
        // `RoundTableView` (EntryRowView.swift) reads `draft.exercise.recordingMetric`
        // live for display -- confirm that after setExercise, this and the
        // captured `draft.recordingMetric` the save path uses always agree,
        // so the on-screen unit label and the persisted unit can never diverge.
        let row500m = makeExercise(id: "ex-row", name: "500m Row", metric: .distance)
        let squat = makeExercise(id: "ex-squat", name: "Squat", metric: .reps)
        let draft = EntryDraft(exercise: row500m, setsCount: 3, load: .bodyweight(raw: "BW"), targetQuantity: 500, actualQuantity: 500)

        draft.setExercise(squat)

        XCTAssertEqual(draft.exercise.recordingMetric, draft.recordingMetric)
    }
}
