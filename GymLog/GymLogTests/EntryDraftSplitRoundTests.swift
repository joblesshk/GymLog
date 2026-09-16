import XCTest
@testable import GymLogKit

/// P3/M3a (2026-09-12)：`EntryDraft.splitRound(atPhysicalSetIndex:)` 的不變式
/// ——語音"把第二組實際次數改為八次"這類命令能不能只改一個物理 Set、不動
/// 其他 Set，全靠這個原語正確。純值操作，不需要 `ModelContext`。
@MainActor
final class EntryDraftSplitRoundTests: XCTestCase {

    private func makeExercise(metric: RecordingMetric = .reps) -> Exercise {
        Exercise(
            id: "ex-1", canonicalName: "Test Exercise", aliases: [], movementPattern: .push, equipment: .barbell,
            loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 0, needsReview: false,
            reviewReason: nil, recordingMetric: metric
        )
    }

    // MARK: - 拆分本身不改變 resolvedSets() 的結果

    func testSplittingAloneLeavesResolvedSetsByteIdentical() {
        let entry = EntryDraft(exercise: makeExercise(), setsCount: 3, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 8)
        let before = entry.resolvedSets().map { "\($0.load)|\($0.target)|\($0.actual)" }
        let plannedBefore = entry.plannedSets

        entry.splitRound(atPhysicalSetIndex: 2)

        XCTAssertEqual(entry.plannedSets, plannedBefore, "拆分不應該改變總組數")
        let after = entry.resolvedSets().map { "\($0.load)|\($0.target)|\($0.actual)" }
        XCTAssertEqual(before, after, "拆分本身，沒有進一步修改，resolvedSets() 必須完全不變")
    }

    // MARK: - 拆分後只改目標那一組，不影響其他組

    func testMutatingSplitPieceDoesNotAffectOtherPhysicalSets() {
        let entry = EntryDraft(exercise: makeExercise(), setsCount: 3, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 8)

        guard let roundID = entry.splitRound(atPhysicalSetIndex: 2) else {
            return XCTFail("拆分不應該失敗")
        }
        guard let idx = entry.rounds.firstIndex(where: { $0.id == roundID }) else {
            return XCTFail("找不到拆分後的 round")
        }
        entry.rounds[idx].actual = .fixed(value: 6, raw: "6")

        let resolved = entry.resolvedSets()
        XCTAssertEqual(resolved.count, 3)
        XCTAssertEqual(resolved[0].actual, .fixed(value: 8, raw: "8"), "第一組不受影響")
        XCTAssertEqual(resolved[1].actual, .fixed(value: 6, raw: "6"), "第二組被正確改成 6")
        XCTAssertEqual(resolved[2].actual, .fixed(value: 8, raw: "8"), "第三組不受影響")
    }

    // MARK: - 拆分保留原 id 在「剛好這一個」的片段上

    func testSplitPieceKeepsOriginalRoundID() {
        let entry = EntryDraft(exercise: makeExercise(), setsCount: 3, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 8)
        let originalID = entry.rounds[0].id

        let returnedID = entry.splitRound(atPhysicalSetIndex: 2)

        XCTAssertEqual(returnedID, originalID, "拆分後，剛好覆蓋目標物理 Set 的那個片段必須沿用原本 RoundDraft 的 id")
        XCTAssertEqual(entry.rounds.count, 3, "3 組拆第 2 組，應該變成 3 個各自 setsCount=1 的 round")
        XCTAssertTrue(entry.rounds.allSatisfy { $0.setsCount == 1 })
    }

    // MARK: - 已經是 setsCount == 1 時是 no-op

    func testSplittingAlreadySingleSetRoundIsNoOp() {
        let entry = EntryDraft(exercise: makeExercise(), setsCount: 1, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 8)
        let originalID = entry.rounds[0].id

        let returnedID = entry.splitRound(atPhysicalSetIndex: 1)

        XCTAssertEqual(returnedID, originalID)
        XCTAssertEqual(entry.rounds.count, 1, "已經是單組的 round 不應該被拆分")
    }

    // MARK: - 越界回 nil，不改動任何東西

    func testOutOfRangeIndexReturnsNilAndMutatesNothing() {
        let entry = EntryDraft(exercise: makeExercise(), setsCount: 3, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 8)
        let before = entry.rounds

        XCTAssertNil(entry.splitRound(atPhysicalSetIndex: 0))
        XCTAssertNil(entry.splitRound(atPhysicalSetIndex: 4))
        XCTAssertNil(entry.splitRound(atPhysicalSetIndex: -1))
        XCTAssertEqual(entry.rounds, before, "越界時不應該改動 rounds")
    }

    // MARK: - 邊界拆分只影響對應那一個 RoundDraft

    func testSplittingAtRoundBoundaryOnlyTouchesThatRound() {
        let exercise = makeExercise()
        let round1 = RoundDraft(setsCount: 2, load: .absolute(kg: 40, raw: "40"), targetQuantity: 10, actualQuantity: 10, metric: .reps)
        let round2 = RoundDraft(setsCount: 3, load: .absolute(kg: 50, raw: "50"), targetQuantity: 8, actualQuantity: 8, metric: .reps)
        let entry = EntryDraft(exercise: exercise, rounds: [round1, round2])

        // 第 2 個物理 Set 是 round1 的最後一個 -- 拆分不應該碰到 round2。
        guard let roundID = entry.splitRound(atPhysicalSetIndex: 2) else {
            return XCTFail("拆分不應該失敗")
        }
        XCTAssertTrue(entry.rounds.contains { $0.id == round2.id && $0.setsCount == 3 }, "round2 必須原封不動")
        guard let idx = entry.rounds.firstIndex(where: { $0.id == roundID }) else {
            return XCTFail("找不到拆分後的 round")
        }
        XCTAssertEqual(entry.rounds[idx].setsCount, 1)
        XCTAssertEqual(entry.plannedSets, 5, "總組數必須維持 2+3=5")
    }
}
