import XCTest
import SwiftData
@testable import GymLogKit

/// P3/M3a (2026-09-12)：`TodayDraftMutationService` 是把原本只以 private 方法
/// 形式散落在 `TodayView`/`SupersetBlockDraftCard` 裡的 block/entry-list
/// 操作抽取出來的結果，讓語音命令服務跟 UI 呼叫同一份實現。這裡的場景直接
/// 鏡像 `SupersetBlockDraftTests.swift` 已經驗證過的成員管理行為，改成直接
/// 呼叫新服務（不透過 View 私有方法）——是這次重構「沒有改變行為」最直接的
/// 證據；`SupersetBlockDraftTests`/`SupersetUITests` 本身完全沒有改動，繼續
/// 當回歸試金石。
@MainActor
final class TodayDraftMutationServiceTests: XCTestCase {

    private func makeExercise(id: String, name: String, metric: RecordingMetric = .reps, equipment: Equipment = .barbell) -> Exercise {
        Exercise(
            id: id, canonicalName: name, aliases: [], movementPattern: .push, equipment: equipment,
            loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 0, needsReview: false,
            reviewReason: nil, recordingMetric: metric
        )
    }

    private func makeDraft(clientID: String = "cl-1") -> TodayDraftStore {
        let draft = TodayDraftStore()
        draft.startNew(clientID: clientID)
        return draft
    }

    // MARK: - addEntry

    func testAddEntryNewBlockCreatesASingleBlock() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let squat = makeExercise(id: "ex-squat", name: "Squat")
        context.insert(squat)
        let draft = makeDraft()

        let (blockID, entryID) = TodayDraftMutationService.addEntry(squat, clientID: "cl-1", placement: .newBlock, draft: draft, context: context)

        XCTAssertEqual(draft.blocks.count, 1)
        XCTAssertEqual(draft.blocks[0].id, blockID)
        XCTAssertEqual(draft.blocks[0].blockType, .single)
        XCTAssertEqual(draft.blocks[0].entries.first?.id, entryID)
        XCTAssertEqual(draft.blocks[0].entries.first?.exercise.id, "ex-squat")
    }

    func testAddEntryExistingBlockAutoPromotesToSuperset() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let squat = makeExercise(id: "ex-squat", name: "Squat")
        let lunge = makeExercise(id: "ex-lunge", name: "Lunge")
        context.insert(squat)
        context.insert(lunge)
        let draft = makeDraft()

        let (blockID, _) = TodayDraftMutationService.addEntry(squat, clientID: "cl-1", placement: .newBlock, draft: draft, context: context)
        TodayDraftMutationService.addEntry(lunge, clientID: "cl-1", placement: .existingBlock(blockID), draft: draft, context: context)

        XCTAssertEqual(draft.blocks.count, 1)
        XCTAssertEqual(draft.blocks[0].entries.count, 2)
        XCTAssertEqual(draft.blocks[0].blockType, .superset, "一個 block 裡出現第二個動作，默認轉成超級組")
    }

    func testAddEntryNewSupersetSeedsThreeRounds() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let squat = makeExercise(id: "ex-squat", name: "Squat")
        context.insert(squat)
        let draft = makeDraft()

        let (blockID, entryID) = TodayDraftMutationService.addEntry(squat, clientID: "cl-1", placement: .newSuperset, draft: draft, context: context)

        let block = draft.blocks.first { $0.id == blockID }
        XCTAssertEqual(block?.blockType, .superset)
        XCTAssertEqual(block?.restSeconds, 60)
        let entry = block?.entries.first { $0.id == entryID }
        XCTAssertEqual(entry?.rounds.count, 3, "新建 Superset 起手固定 3 輪")
        XCTAssertTrue(entry?.rounds.allSatisfy { $0.setsCount == 1 } ?? false)
    }

    // MARK: - removeEntry

    func testRemoveEntryRemovesWholeBlockWhenLastEntryGoes() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let squat = makeExercise(id: "ex-squat", name: "Squat")
        context.insert(squat)
        let draft = makeDraft()
        let (blockID, entryID) = TodayDraftMutationService.addEntry(squat, clientID: "cl-1", placement: .newBlock, draft: draft, context: context)

        TodayDraftMutationService.removeEntry(entryID, from: blockID, draft: draft)

        XCTAssertTrue(draft.blocks.isEmpty, "唯一的 entry 被移除後，空 block 必須跟著消失")
    }

    // MARK: - composeSuperset / dissolveSuperset

    func testComposeSupersetMergesInOriginalRelativeOrder() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let squat = makeExercise(id: "ex-squat", name: "Squat")
        let bench = makeExercise(id: "ex-bench", name: "Bench")
        context.insert(squat)
        context.insert(bench)
        let draft = makeDraft()
        let (squatBlockID, _) = TodayDraftMutationService.addEntry(squat, clientID: "cl-1", placement: .newBlock, draft: draft, context: context)
        let (benchBlockID, _) = TodayDraftMutationService.addEntry(bench, clientID: "cl-1", placement: .newBlock, draft: draft, context: context)

        TodayDraftMutationService.composeSuperset(selectedBlockIDs: [squatBlockID, benchBlockID], draft: draft)

        XCTAssertEqual(draft.blocks.count, 1)
        XCTAssertEqual(draft.blocks[0].blockType, .superset)
        XCTAssertEqual(draft.blocks[0].entries.map(\.exercise.id), ["ex-squat", "ex-bench"])
    }

    func testDissolveSupersetSplitsBackWithDataIntact() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let squat = makeExercise(id: "ex-squat", name: "Squat")
        let bench = makeExercise(id: "ex-bench", name: "Bench")
        context.insert(squat)
        context.insert(bench)
        let draft = makeDraft()
        let (squatBlockID, _) = TodayDraftMutationService.addEntry(squat, clientID: "cl-1", placement: .newBlock, draft: draft, context: context)
        let (benchBlockID, _) = TodayDraftMutationService.addEntry(bench, clientID: "cl-1", placement: .newBlock, draft: draft, context: context)
        TodayDraftMutationService.composeSuperset(selectedBlockIDs: [squatBlockID, benchBlockID], draft: draft)
        let supersetBlockID = draft.blocks[0].id

        TodayDraftMutationService.dissolveSuperset(supersetBlockID, draft: draft)

        XCTAssertEqual(draft.blocks.count, 2)
        XCTAssertTrue(draft.blocks.allSatisfy { $0.blockType == .single })
        XCTAssertEqual(Set(draft.blocks.flatMap { $0.entries.map(\.exercise.id) }), ["ex-squat", "ex-bench"])
    }

    // MARK: - removeBlock

    func testRemoveBlockRemovesExactlyThatBlock() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let squat = makeExercise(id: "ex-squat", name: "Squat")
        let bench = makeExercise(id: "ex-bench", name: "Bench")
        context.insert(squat)
        context.insert(bench)
        let draft = makeDraft()
        let (squatBlockID, _) = TodayDraftMutationService.addEntry(squat, clientID: "cl-1", placement: .newBlock, draft: draft, context: context)
        TodayDraftMutationService.addEntry(bench, clientID: "cl-1", placement: .newBlock, draft: draft, context: context)

        TodayDraftMutationService.removeBlock(squatBlockID, draft: draft)

        XCTAssertEqual(draft.blocks.count, 1)
        XCTAssertEqual(draft.blocks[0].entries.first?.exercise.id, "ex-bench")
    }

    // MARK: - Block-scoped member operations (mirrors SupersetBlockDraftTests's own scenarios)

    func testAddMemberSeedsRoundsMatchingExistingMemberCount() throws {
        let squat = makeExercise(id: "ex-squat", name: "Squat")
        let bench = makeExercise(id: "ex-bench", name: "Bench")
        let a1 = EntryDraft(exercise: squat, rounds: (0..<3).map { _ in RoundDraft(setsCount: 1, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 8, metric: .reps) })
        let block = BlockDraft(blockType: .superset, restSeconds: 60, entries: [a1], sectionKind: .strength)

        TodayDraftMutationService.addMember(bench, to: block)

        XCTAssertEqual(block.entries.count, 2)
        XCTAssertEqual(block.entries[1].rounds.count, 3, "新成員的輪數要補齊到跟既有成員一致")
        XCTAssertTrue(block.entries[1].rounds.allSatisfy { $0.setsCount == 1 })
    }

    func testReplaceExerciseUsesSetExerciseUnitSafety() throws {
        let squat = makeExercise(id: "ex-squat", name: "Squat", metric: .reps)
        let plank = makeExercise(id: "ex-plank", name: "Plank", metric: .time)
        let entry = EntryDraft(exercise: squat, setsCount: 3, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 8)
        let block = BlockDraft(blockType: .single, entries: [entry])

        let didReplace = TodayDraftMutationService.replaceExercise(entry.id, in: block, with: plank)

        XCTAssertTrue(didReplace)
        XCTAssertEqual(entry.exercise.id, "ex-plank")
        XCTAssertEqual(entry.recordingMetric, .time, "換了不同記錄單位的動作，recordingMetric 必須跟著換，不能沿用舊數字")
    }

    func testRemoveMemberDownToOneReturnsRemovedAndDemotesToSingle() throws {
        let squat = makeExercise(id: "ex-squat", name: "Squat")
        let bench = makeExercise(id: "ex-bench", name: "Bench")
        let a1 = EntryDraft(exercise: squat, setsCount: 1, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 8)
        let a2 = EntryDraft(exercise: bench, setsCount: 1, load: .absolute(kg: 40, raw: "40"), targetQuantity: 8, actualQuantity: 8)
        let block = BlockDraft(blockType: .superset, entries: [a1, a2], sectionKind: .strength)

        let outcome = TodayDraftMutationService.removeMember(a2.id, from: block)

        XCTAssertEqual(outcome, .removed)
        XCTAssertEqual(block.entries.count, 1)
        XCTAssertEqual(block.blockType, .single, "減到只剩一個成員時自動轉普通動作")
    }

    func testRemoveMemberOnLastOneNeedsWholeBlockDeleteConfirmation() throws {
        let squat = makeExercise(id: "ex-squat", name: "Squat")
        let entry = EntryDraft(exercise: squat, setsCount: 1, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 8)
        let block = BlockDraft(blockType: .single, entries: [entry])

        let outcome = TodayDraftMutationService.removeMember(entry.id, from: block)

        XCTAssertEqual(outcome, .needsWholeBlockDeleteConfirmation)
        XCTAssertEqual(block.entries.count, 1, "只剩一個成員時，服務層不能自己刪掉整塊——要交給呼叫方決定")
    }

    func testAddRoundToAllMembersKeepsIndependentRoundCounts() throws {
        let squat = makeExercise(id: "ex-squat", name: "Squat")
        let plank = makeExercise(id: "ex-plank", name: "Plank", metric: .time)
        let a1 = EntryDraft(exercise: squat, rounds: (0..<3).map { _ in RoundDraft(setsCount: 1, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 8, metric: .reps) })
        let a2 = EntryDraft(exercise: plank, rounds: (0..<2).map { _ in RoundDraft(setsCount: 1, load: .bodyweight(raw: "BW"), targetQuantity: 45, actualQuantity: 40, metric: .time) })
        let block = BlockDraft(blockType: .superset, entries: [a1, a2], sectionKind: .strength)

        TodayDraftMutationService.addRoundToAllMembers(block)

        XCTAssertEqual(a1.rounds.count, 4)
        XCTAssertEqual(a2.rounds.count, 3, "每個成員各自加一輪，不齊的輪數繼續不齊")
    }

    func testRemoveLastRoundFromAllMembersOnlyTouchesMembersAtMaxCount() throws {
        let squat = makeExercise(id: "ex-squat", name: "Squat")
        let plank = makeExercise(id: "ex-plank", name: "Plank", metric: .time)
        let a1 = EntryDraft(exercise: squat, rounds: (0..<3).map { _ in RoundDraft(setsCount: 1, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 8, metric: .reps) })
        let a2 = EntryDraft(exercise: plank, rounds: (0..<2).map { _ in RoundDraft(setsCount: 1, load: .bodyweight(raw: "BW"), targetQuantity: 45, actualQuantity: 40, metric: .time) })
        let block = BlockDraft(blockType: .superset, entries: [a1, a2], sectionKind: .strength)

        TodayDraftMutationService.removeLastRoundFromAllMembers(block)

        XCTAssertEqual(a1.rounds.count, 2, "只有輪數等於當前最大值的成員才被刪掉最後一輪")
        XCTAssertEqual(a2.rounds.count, 2, "已經是較少輪數的成員不受影響")
    }
}
