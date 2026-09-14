import XCTest
import SwiftData
@testable import GymLogKit

/// 2026-09-13 全局語音改造：`VoiceCommandCoordinator` 修正候選/預覽確認的
/// 過時保護——舊版 UI（`VoiceCommandTextEntrySheet`）在使用者「點下候選」
/// 那一刻才呼叫 `draft.currentRevisionToken()`，等於拿「現在」的草稿狀態
/// 跟「現在」比較，恆真，完全沒有驗證候選產生之後草稿有沒有被改動過。
/// 這裡直接驗證協調器保存的是候選/預覽「產生那一刻」的 token，比對的是
/// 兩個不同時間點。
@MainActor
final class VoiceCommandCoordinatorTests: XCTestCase {

    private func makeExercise(id: String, name: String) -> Exercise {
        Exercise(
            id: id, canonicalName: name, aliases: [], movementPattern: .squat, equipment: .barbell,
            loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 0, needsReview: false, reviewReason: nil
        )
    }

    private func makeDraft(clientID: String = "cl-1") -> TodayDraftStore {
        let draft = TodayDraftStore()
        draft.startNew(clientID: clientID)
        return draft
    }

    /// 候選產生之後、使用者點選之前，草稿被別的地方改動過——點選候選必須
    /// 被拒絕（`.staleDraft`），不能因為協調器在「點下去」那一刻重新抓了
    /// 一個新 token 而讓過時檢測形同虛設。
    func testChooseClarificationCandidateRefusesStaleDraftChangedAfterCandidatesGenerated() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let squatA = makeExercise(id: "ex-squat-a", name: "徒手深蹲")
        let squatB = makeExercise(id: "ex-squat-b", name: "槓鈴深蹲推舉")
        context.insert(squatA)
        context.insert(squatB)
        let draft = makeDraft()
        let coordinator = VoiceCommandCoordinator()

        coordinator.submitText("添加深蹲", draft: draft, allExercises: [squatA, squatB], context: context, clientID: "cl-1")
        guard case .needsClarification(_, let candidates, let pending) = coordinator.lastOutcome, let pending, let firstCandidate = candidates.first else {
            return XCTFail("兩個動作名字都含「深蹲」，應該澄清並帶出候選")
        }

        // 候選產生之後，草稿被別的地方改動（例如手動編輯）。
        draft.blocks.append(BlockDraft(blockType: .single, entries: [EntryDraft(exercise: squatA, setsCount: 1, load: .bodyweight(raw: "bw"), targetQuantity: 5, actualQuantity: 5)]))

        coordinator.chooseClarificationCandidate(firstCandidate, pending: pending, draft: draft, allExercises: [squatA, squatB], context: context, clientID: "cl-1")

        XCTAssertEqual(coordinator.lastOutcome, .staleDraft, "候選產生之後草稿變了，點選必須被拒絕，不能繞過過時檢測")
        XCTAssertEqual(draft.blocks.count, 1, "只應該有剛才手動加的那一塊，候選命令不能被執行")
    }

    /// 沒有任何變動時，候選點選必須照常成功——確保上面那個修正沒有把
    /// 正常路徑也一起擋掉。
    func testChooseClarificationCandidateStillAppliesWhenNothingChangedInBetween() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let squatA = makeExercise(id: "ex-squat-a", name: "徒手深蹲")
        let squatB = makeExercise(id: "ex-squat-b", name: "槓鈴深蹲推舉")
        context.insert(squatA)
        context.insert(squatB)
        let draft = makeDraft()
        let coordinator = VoiceCommandCoordinator()

        coordinator.submitText("添加深蹲", draft: draft, allExercises: [squatA, squatB], context: context, clientID: "cl-1")
        guard case .needsClarification(_, let candidates, let pending) = coordinator.lastOutcome, let pending,
              let chosen = candidates.first(where: { $0.id == "ex-squat-b" }) else {
            return XCTFail("應該澄清並帶出兩個候選")
        }

        coordinator.chooseClarificationCandidate(chosen, pending: pending, draft: draft, allExercises: [squatA, squatB], context: context, clientID: "cl-1")

        guard case .applied = coordinator.lastOutcome else { return XCTFail("沒有任何變動時應該直接套用成功，實際 \(String(describing: coordinator.lastOutcome))") }
        XCTAssertEqual(draft.blocks.first?.entries.first?.exercise.id, "ex-squat-b")
    }

    /// `needsPreviewConfirm`（例如替換已有記錄成績的動作）同樣需要原始
    /// token 保護——確認之前草稿被改動過，確認必須被拒絕。
    func testConfirmPendingRefusesStaleDraftChangedAfterPreviewGenerated() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let bench = makeExercise(id: "ex-bench", name: "臥推")
        let dbBench = makeExercise(id: "ex-db-bench", name: "啞鈴臥推")
        context.insert(bench)
        context.insert(dbBench)
        let draft = makeDraft()
        let entry = EntryDraft(exercise: bench, setsCount: 3, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 6)
        draft.blocks.append(BlockDraft(blockType: .single, entries: [entry]))
        let coordinator = VoiceCommandCoordinator()

        coordinator.submitText("把臥推換成啞鈴臥推", draft: draft, allExercises: [bench, dbBench], context: context, clientID: "cl-1")
        guard case .needsPreviewConfirm = coordinator.lastOutcome else { return XCTFail("已有實際成績時必須先預覽確認") }

        // 預覽產生之後，草稿被別的地方改動。
        entry.rounds[0].load = .absolute(kg: 65, raw: "65")

        coordinator.confirmPending(draft: draft, allExercises: [bench, dbBench], context: context, clientID: "cl-1")

        XCTAssertEqual(coordinator.lastOutcome, .staleDraft, "預覽產生之後草稿變了，確認必須被拒絕")
        XCTAssertEqual(entry.exercise.id, "ex-bench", "被拒絕的確認不能真的換動作")
    }

    // MARK: - 2026-09-13 真機試用反饋：還沒有進行中課次時語音也要有反應

    func testSubmitTextStartsNewSessionWhenNoneActive() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let draft = TodayDraftStore()
        XCTAssertFalse(draft.isActive)
        let coordinator = VoiceCommandCoordinator()

        coordinator.submitText("新建空課次", draft: draft, allExercises: [], context: context, clientID: "cl-1")

        XCTAssertTrue(draft.isActive, "「新建空課次」應該直接開課，不需要先手動點按鈕")
        guard case .applied = coordinator.lastOutcome else { return XCTFail("應該回報已新建課次，實際 \(String(describing: coordinator.lastOutcome))") }
    }

    /// 同一句話裡開課次意圖跟添加動作意圖疊在一起——開課次之後應該立刻
    /// 把整句話接著跑一次正常管線，把動作也加進去，不需要使用者開課後
    /// 再說一遍。
    func testSubmitTextStartsSessionAndAddsExerciseFromSameUtterance() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let squat = makeExercise(id: "ex-squat", name: "深蹲")
        context.insert(squat)
        let draft = TodayDraftStore()
        let coordinator = VoiceCommandCoordinator()

        coordinator.submitText("新建空課次，添加深蹲，三組，十次", draft: draft, allExercises: [squat], context: context, clientID: "cl-1")

        XCTAssertTrue(draft.isActive)
        XCTAssertEqual(draft.blocks.count, 1, "同一句話裡的添加動作應該一併生效")
        XCTAssertEqual(draft.blocks.first?.entries.first?.exercise.id, "ex-squat")
    }

    /// 沒有開課意圖、單純說一個動作名稱時，不應該靜默無反應，也不應該
    /// 未經明確開課意圖就自動開課——要給出清楚的「請先開課」提示。
    func testSubmitTextWithoutSessionStartIntentAsksToStartSessionFirst() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let squat = makeExercise(id: "ex-squat", name: "深蹲")
        context.insert(squat)
        let draft = TodayDraftStore()
        let coordinator = VoiceCommandCoordinator()

        coordinator.submitText("深蹲", draft: draft, allExercises: [squat], context: context, clientID: "cl-1")

        XCTAssertFalse(draft.isActive, "沒有明確開課意圖不能被靜默當成開課")
        guard case .rejected = coordinator.lastOutcome else { return XCTFail("應該提示需要先開課，實際 \(String(describing: coordinator.lastOutcome))") }
    }

    func testSubmitTextWithoutClientAsksToSelectClientFirst() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let draft = TodayDraftStore()
        let coordinator = VoiceCommandCoordinator()

        coordinator.submitText("新建空課次", draft: draft, allExercises: [], context: context, clientID: "")

        XCTAssertFalse(draft.isActive)
        guard case .rejected = coordinator.lastOutcome else { return XCTFail("沒有學員時應該提示先選學員") }
    }
}
