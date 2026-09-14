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
                RoundDraft(setsCount: 2, load: .absolute(kg: 30, raw: "30"), targetQuantity: 10, actualQuantity: 8),
                RoundDraft(setsCount: 3, load: .absolute(kg: 45, raw: "45"), targetQuantity: 6, actualQuantity: 6)
            ]
        )
        let roundIDsBefore = draft.rounds.map(\.id)

        draft.setExercise(dumbbellPress)

        XCTAssertEqual(draft.exercise.id, "ex-db-bench")
        XCTAssertEqual(draft.recordingMetric, .reps, "metric unchanged, so the captured recordingMetric must not move either")
        XCTAssertEqual(draft.rounds.map(\.id), roundIDsBefore, "Round identity must survive a same-metric swap unchanged")
        XCTAssertEqual(draft.rounds[0].setsCount, 2)
        XCTAssertEqual(draft.rounds[0].targetQuantity, 10)
        XCTAssertEqual(draft.rounds[0].actualQuantity, 8)
        guard case .absolute(let kg0, _) = draft.rounds[0].load else { return XCTFail("expected .absolute") }
        XCTAssertEqual(kg0, 30, "load must NOT be reset when the metric didn't change")
        XCTAssertEqual(draft.rounds[1].setsCount, 3)
        XCTAssertEqual(draft.rounds[1].targetQuantity, 6)
        XCTAssertEqual(draft.rounds[1].actualQuantity, 6)
    }

    // MARK: - Cross-metric swap: never reinterpret the old number under the new unit

    func testDistanceToRepsSwapNeverReinterpretsTheOldNumberAsReps() {
        let row500m = makeExercise(id: "ex-row", name: "500m Row", metric: .distance, equipment: .machine)
        let squat = makeExercise(id: "ex-squat", name: "Squat", metric: .reps, equipment: .barbell)

        let draft = EntryDraft(
            exercise: row500m,
            rounds: [RoundDraft(setsCount: 3, load: .bodyweight(raw: "BW"), targetQuantity: 500, actualQuantity: 500)]
        )
        XCTAssertEqual(draft.recordingMetric, .distance)

        draft.setExercise(squat)

        XCTAssertEqual(draft.exercise.id, "ex-squat")
        XCTAssertEqual(draft.recordingMetric, .reps, "recordingMetric must follow the new exercise, not stay frozen at .distance")
        XCTAssertEqual(draft.rounds.count, 1)
        XCTAssertEqual(draft.rounds[0].setsCount, 3, "setsCount is unit-agnostic and should survive the swap")
        XCTAssertNotEqual(draft.rounds[0].targetQuantity, 500, "the raw '500' (meters) must never carry over and silently become '500' reps")
        XCTAssertEqual(draft.rounds[0].targetQuantity, RepTargetToRoundQuantity.defaultQuantity(for: .reps))
        XCTAssertEqual(draft.rounds[0].actualQuantity, RepTargetToRoundQuantity.defaultQuantity(for: .reps))

        // The save path (`resolvedSets()`) must encode the new metric's RepTarget
        // kind, not `.distance` left over from the old exercise -- this is the
        // exact persisted-data-corruption case the fix closes: an ExerciseEntry
        // whose exercise is reps-based must never carry a `.distance` RepTarget.
        let resolved = draft.resolvedSets()
        XCTAssertEqual(resolved.count, 3)
        for set in resolved {
            guard case .fixed = set.target else { return XCTFail("expected .fixed (reps) RepTarget after swapping to a reps exercise, not .distance") }
            guard case .fixed = set.actual else { return XCTFail("expected .fixed (reps) RepTarget after swapping to a reps exercise, not .distance") }
        }
    }

    func testRepsToTimeSwapResetsQuantitiesButKeepsSetsCountPerRound() {
        let squat = makeExercise(id: "ex-squat", name: "Squat", metric: .reps)
        let plank = makeExercise(id: "ex-plank", name: "Plank", metric: .time, equipment: .other)

        let draft = EntryDraft(
            exercise: squat,
            rounds: [
                RoundDraft(setsCount: 4, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 8),
                RoundDraft(setsCount: 2, load: .absolute(kg: 60, raw: "60"), targetQuantity: 5, actualQuantity: 3)
            ]
        )

        draft.setExercise(plank)

        XCTAssertEqual(draft.recordingMetric, .time)
        XCTAssertEqual(draft.rounds.count, 2)
        XCTAssertEqual(draft.rounds[0].setsCount, 4, "Round 1's setsCount survives")
        XCTAssertEqual(draft.rounds[1].setsCount, 2, "Round 2's setsCount survives")
        let expectedDefault = RepTargetToRoundQuantity.defaultQuantity(for: .time)
        XCTAssertEqual(draft.rounds[0].targetQuantity, expectedDefault)
        XCTAssertEqual(draft.rounds[0].actualQuantity, expectedDefault)
        XCTAssertEqual(draft.rounds[1].targetQuantity, expectedDefault)
        XCTAssertEqual(draft.rounds[1].actualQuantity, expectedDefault)

        let resolved = draft.resolvedSets()
        XCTAssertEqual(resolved.count, 6, "4 + 2 sets across both rounds")
        for set in resolved {
            guard case .time = set.target else { return XCTFail("expected .time RepTarget after swapping to a time exercise") }
        }
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
