import XCTest
import SwiftData
@testable import GymLogKit

/// P3/M3a (2026-09-12)：`VoiceCommandService` 的完整管線——parse → resolve
/// target → 過時檢測 → apply → undo，用真實 `ModelContext`（`addExercise`
/// 需要 `PrefillResolver` 查歷史記錄）。
@MainActor
final class VoiceCommandServiceTests: XCTestCase {

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

    // MARK: - 添加庫內動作：正常路徑

    func testAddExerciseHappyPath() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let squat = makeExercise(id: "ex-squat", name: "深蹲")
        context.insert(squat)
        let draft = makeDraft()
        let service = VoiceCommandService()

        let outcome = service.execute(rawText: "添加深蹲，三組，每組十次，四十公斤", draft: draft, allExercises: [squat], context: context, clientID: "cl-1")

        guard case .applied(_, let canUndo) = outcome else { return XCTFail("預期 applied，實際 \(outcome)") }
        XCTAssertTrue(canUndo)
        XCTAssertEqual(draft.blocks.count, 1)
        let entry = draft.blocks[0].entries.first
        XCTAssertEqual(entry?.exercise.id, "ex-squat")
        XCTAssertEqual(entry?.rounds.first?.setsCount, 3)
        XCTAssertEqual(entry?.rounds.first?.target, .fixed(value: 10, raw: "10"))
        guard case .absolute(let kg, _) = entry?.rounds.first?.load else { return XCTFail() }
        XCTAssertEqual(kg, 40)
    }

    // MARK: - 修改指定組實際成績：正常路徑 + 觸發拆分

    func testSetActualHappyPathSplitsRoundAndOnlyTouchesTargetSet() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let bench = makeExercise(id: "ex-bench", name: "臥推")
        context.insert(bench)
        let draft = makeDraft()
        // 3 個物理 Set 合併成一個 RoundDraft（setsCount=3）——跟真實草稿常見
        // 的「同一個重量做三組」形狀一致。
        let entry = EntryDraft(exercise: bench, setsCount: 3, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 8)
        draft.blocks.append(BlockDraft(blockType: .single, entries: [entry]))
        let service = VoiceCommandService()

        let outcome = service.execute(rawText: "把臥推第二組實際次數改為六次", draft: draft, allExercises: [bench], context: context, clientID: "cl-1")

        guard case .applied = outcome else { return XCTFail("預期 applied，實際 \(outcome)") }
        let resolved = entry.resolvedSets()
        XCTAssertEqual(resolved.count, 3)
        XCTAssertEqual(resolved[0].actual, .fixed(value: 8, raw: "8"), "第一組不受影響")
        XCTAssertEqual(resolved[1].actual, .fixed(value: 6, raw: "6"), "第二組改成 6")
        XCTAssertEqual(resolved[2].actual, .fixed(value: 8, raw: "8"), "第三組不受影響")
    }

    // MARK: - 設置 Superset 輪間休息：正常路徑

    func testSetSupersetRestHappyPath() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let squat = makeExercise(id: "ex-squat", name: "深蹲")
        let lunge = makeExercise(id: "ex-lunge", name: "箭步蹲")
        context.insert(squat)
        context.insert(lunge)
        let draft = makeDraft()
        let a1 = EntryDraft(exercise: squat, setsCount: 1, load: .absolute(kg: 40, raw: "40"), targetQuantity: 8, actualQuantity: 8)
        let a2 = EntryDraft(exercise: lunge, setsCount: 1, load: .absolute(kg: 20, raw: "20"), targetQuantity: 8, actualQuantity: 8)
        let block = BlockDraft(blockType: .superset, restSeconds: 60, entries: [a1, a2], sectionKind: .strength)
        draft.blocks.append(block)
        let service = VoiceCommandService()

        let outcome = service.execute(rawText: "把第一個超級組的休息改為九十秒", draft: draft, allExercises: [squat, lunge], context: context, clientID: "cl-1")

        guard case .applied = outcome else { return XCTFail("預期 applied，實際 \(outcome)") }
        XCTAssertEqual(block.restSeconds, 90)
    }

    // MARK: - 撤銷：正常路徑

    func testUndoAfterAddExerciseRemovesTheAddedBlock() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let squat = makeExercise(id: "ex-squat", name: "深蹲")
        context.insert(squat)
        let draft = makeDraft()
        let service = VoiceCommandService()
        service.execute(rawText: "添加深蹲，三組，每組十次，四十公斤", draft: draft, allExercises: [squat], context: context, clientID: "cl-1")
        XCTAssertEqual(draft.blocks.count, 1)

        let undoOutcome = service.execute(rawText: "撤銷", draft: draft, allExercises: [squat], context: context, clientID: "cl-1")

        guard case .applied = undoOutcome else { return XCTFail("撤銷本身應該回報 applied") }
        XCTAssertTrue(draft.blocks.isEmpty, "撤銷添加動作，必須把整塊都移除")
    }

    /// §6.3「撤銷不得恢復整份過時草稿而抹掉隨後手動編輯」——這裡直接驗證：
    /// 語音改了 A 動作的實際成績，接著手動改了 B 動作的重量，再撤銷語音
    /// 命令，B 的手動編輯必須完全不受影響。
    func testUndoDoesNotClobberUnrelatedManualEditMadeAfterward() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let bench = makeExercise(id: "ex-bench", name: "臥推")
        let squat = makeExercise(id: "ex-squat", name: "深蹲")
        context.insert(bench)
        context.insert(squat)
        let draft = makeDraft()
        let benchEntry = EntryDraft(exercise: bench, setsCount: 1, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 8)
        let squatEntry = EntryDraft(exercise: squat, setsCount: 1, load: .absolute(kg: 40, raw: "40"), targetQuantity: 8, actualQuantity: 8)
        draft.blocks.append(BlockDraft(blockType: .single, entries: [benchEntry]))
        draft.blocks.append(BlockDraft(blockType: .single, entries: [squatEntry]))
        let service = VoiceCommandService()

        service.execute(rawText: "把臥推第一組實際次數改為六次", draft: draft, allExercises: [bench, squat], context: context, clientID: "cl-1")
        XCTAssertEqual(benchEntry.rounds[0].actual, .fixed(value: 6, raw: "6"))

        // 手動編輯：改深蹲的重量（跟語音命令完全無關的另一個動作）。
        squatEntry.rounds[0].load = .absolute(kg: 50, raw: "50")

        let undoOutcome = service.execute(rawText: "撤銷", draft: draft, allExercises: [bench, squat], context: context, clientID: "cl-1")

        guard case .applied = undoOutcome else { return XCTFail("撤銷本身應該回報 applied") }
        XCTAssertEqual(benchEntry.rounds[0].actual, .fixed(value: 8, raw: "8"), "臥推的實際次數必須還原")
        guard case .absolute(let squatKg, _) = squatEntry.rounds[0].load else { return XCTFail() }
        XCTAssertEqual(squatKg, 50, "深蹲的手動重量編輯不能被撤銷動作抹掉")
    }

    // MARK: - 歧義：同名 2+ 個 entry 永遠澄清，絕不靜默猜

    func testAmbiguousTargetAlwaysClarifiesNeverGuesses() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let bench1 = makeExercise(id: "ex-bench-1", name: "臥推")
        context.insert(bench1)
        let draft = makeDraft()
        let entry1 = EntryDraft(exercise: bench1, setsCount: 1, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 8)
        let entry2 = EntryDraft(exercise: bench1, setsCount: 1, load: .absolute(kg: 65, raw: "65"), targetQuantity: 8, actualQuantity: 8)
        draft.blocks.append(BlockDraft(blockType: .single, entries: [entry1]))
        draft.blocks.append(BlockDraft(blockType: .single, entries: [entry2]))
        let service = VoiceCommandService()

        let outcome = service.execute(rawText: "把臥推第一組實際次數改為六次", draft: draft, allExercises: [bench1], context: context, clientID: "cl-1")

        guard case .needsClarification = outcome else { return XCTFail("2 個同名 entry 沒指定序數時必須澄清，實際 \(outcome)") }
        XCTAssertEqual(entry1.rounds[0].actual, .fixed(value: 8, raw: "8"), "澄清狀態下，兩個 entry 都不應該被改動")
        XCTAssertEqual(entry2.rounds[0].actual, .fixed(value: 8, raw: "8"))
    }

    func testNoMatchingExerciseIsClarificationNotSilentFailure() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let bench = makeExercise(id: "ex-bench", name: "臥推")
        context.insert(bench)
        let draft = makeDraft()
        draft.blocks.append(BlockDraft(blockType: .single, entries: [EntryDraft(exercise: bench, setsCount: 1, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 8)]))
        let service = VoiceCommandService()

        let outcome = service.execute(rawText: "把深蹲第一組實際次數改為六次", draft: draft, allExercises: [bench], context: context, clientID: "cl-1")

        guard case .needsClarification = outcome else { return XCTFail("草稿裡沒有深蹲，應該澄清而不是靜默失敗") }
    }

    // MARK: - 歧義候選可以直接點選套用（真機測試發現：候選原本只是純文字，
    // 使用者得重新完整打一遍/念一遍精確名字才能繼續，語音輸入的意義因此
    // 被打掉大半）

    /// `addExercise` 的歧義走 `VoiceCommandLibraryResolver`（候選是庫內
    /// `Exercise`）——驗證 `.needsClarification` 帶出的候選身份精確對應到
    /// 兩個不同的 `Exercise.id`，且點選其中一個能直接套用「正確的那一個」，
    /// 不需要使用者重新輸入任何文字。
    func testAddExerciseAmbiguousCandidatesCarryExactIdentityAndApplyDirectly() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let squatA = makeExercise(id: "ex-squat-a", name: "徒手深蹲")
        let squatB = makeExercise(id: "ex-squat-b", name: "槓鈴深蹲推舉")
        context.insert(squatA)
        context.insert(squatB)
        let draft = makeDraft()
        let service = VoiceCommandService()
        let token = draft.currentRevisionToken()

        let outcome = service.apply(rawText: "添加深蹲", contextToken: token, draft: draft, allExercises: [squatA, squatB], context: context, clientID: "cl-1")

        guard case .needsClarification(let reason, let candidates, let pending) = outcome else {
            return XCTFail("兩個動作名字都含「深蹲」，應該澄清，實際 \(outcome)")
        }
        XCTAssertEqual(reason, .missingExerciseName)
        XCTAssertEqual(Set(candidates.map(\.id)), ["ex-squat-a", "ex-squat-b"])
        guard let pending else { return XCTFail("應該帶出可以直接套用的 pending，不需要使用者重新輸入") }

        let applyOutcome = service.applyClarifiedChoice(
            pending, chosenCandidateID: "ex-squat-b", contextToken: draft.currentRevisionToken(),
            draft: draft, allExercises: [squatA, squatB], context: context, clientID: "cl-1"
        )

        guard case .applied = applyOutcome else { return XCTFail("點選候選後應該直接套用，實際 \(applyOutcome)") }
        XCTAssertEqual(draft.blocks.count, 1)
        XCTAssertEqual(draft.blocks.first?.entries.first?.exercise.id, "ex-squat-b", "必須是使用者點的那一個，不是另一個候選")
    }

    /// `setActual`/`replaceExercise`/`setPlan` 的歧義走
    /// `VoiceCommandTargetResolver`（候選是草稿裡的 entry，用 `entryID`
    /// 當身份，不是動作名字）——驗證點選候選只會改動使用者選中的那一個
    /// entry，另一個同名 entry 完全不受影響。
    func testSetActualAmbiguousCandidatesCarryEntryIdentityAndApplyDirectly() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let bench = makeExercise(id: "ex-bench", name: "臥推")
        context.insert(bench)
        let draft = makeDraft()
        let entry1 = EntryDraft(exercise: bench, setsCount: 1, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 8)
        let entry2 = EntryDraft(exercise: bench, setsCount: 1, load: .absolute(kg: 65, raw: "65"), targetQuantity: 8, actualQuantity: 8)
        draft.blocks.append(BlockDraft(blockType: .single, entries: [entry1]))
        draft.blocks.append(BlockDraft(blockType: .single, entries: [entry2]))
        let service = VoiceCommandService()
        let token = draft.currentRevisionToken()

        let outcome = service.apply(rawText: "把臥推第一組實際次數改為六次", contextToken: token, draft: draft, allExercises: [bench], context: context, clientID: "cl-1")

        guard case .needsClarification(_, let candidates, let pending) = outcome else {
            return XCTFail("2 個同名 entry 應該澄清，實際 \(outcome)")
        }
        XCTAssertEqual(Set(candidates.map(\.id)), [entry1.id.uuidString, entry2.id.uuidString])
        guard let pending else { return XCTFail("應該帶出可以直接套用的 pending") }

        let applyOutcome = service.applyClarifiedChoice(
            pending, chosenCandidateID: entry2.id.uuidString, contextToken: draft.currentRevisionToken(),
            draft: draft, allExercises: [bench], context: context, clientID: "cl-1"
        )

        guard case .applied = applyOutcome else { return XCTFail("點選候選後應該直接套用，實際 \(applyOutcome)") }
        XCTAssertEqual(entry1.rounds[0].actual, .fixed(value: 8, raw: "8"), "沒被選中的 entry 不應該被動到")
        XCTAssertEqual(entry2.rounds[0].actual, .fixed(value: 6, raw: "6"), "被選中的 entry 應該套用新值")
    }

    /// 點選候選的那一刻，草稿已經被別的地方改動過——跟一般命令的過時檢測
    /// 用同一套機制，不因為走的是「點選候選」這條路就少檢查。
    func testApplyClarifiedChoiceRefusesStaleDraft() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let squatA = makeExercise(id: "ex-squat-a", name: "徒手深蹲")
        let squatB = makeExercise(id: "ex-squat-b", name: "槓鈴深蹲推舉")
        context.insert(squatA)
        context.insert(squatB)
        let draft = makeDraft()
        let service = VoiceCommandService()
        let token = draft.currentRevisionToken()

        let outcome = service.apply(rawText: "添加深蹲", contextToken: token, draft: draft, allExercises: [squatA, squatB], context: context, clientID: "cl-1")
        guard case .needsClarification(_, _, let pending) = outcome, let pending else {
            return XCTFail("應該澄清並帶出 pending，實際 \(outcome)")
        }
        let staleToken = draft.currentRevisionToken()
        draft.blocks.append(BlockDraft(blockType: .single, entries: [EntryDraft(exercise: squatA, setsCount: 1, load: .bodyweight(raw: "bw"), targetQuantity: 5, actualQuantity: 5)]))

        let applyOutcome = service.applyClarifiedChoice(
            pending, chosenCandidateID: "ex-squat-b", contextToken: staleToken,
            draft: draft, allExercises: [squatA, squatB], context: context, clientID: "cl-1"
        )

        XCTAssertEqual(applyOutcome, .staleDraft)
    }

    // MARK: - 過時草稿：送出後、執行前改動草稿

    func testStaleDraftTokenRefusesApply() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let bench = makeExercise(id: "ex-bench", name: "臥推")
        context.insert(bench)
        let draft = makeDraft()
        let entry = EntryDraft(exercise: bench, setsCount: 1, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 8)
        draft.blocks.append(BlockDraft(blockType: .single, entries: [entry]))
        let service = VoiceCommandService()

        guard let request = service.makeRequest(rawText: "把臥推第一組實際次數改為六次", draft: draft) else {
            return XCTFail("應該能成功解析出一個 request")
        }

        // 送出後、執行前，草稿被手動改動。
        entry.rounds[0].load = .absolute(kg: 65, raw: "65")

        let outcome = service.apply(request, draft: draft, allExercises: [bench], context: context, clientID: "cl-1")

        XCTAssertEqual(outcome, .staleDraft)
        XCTAssertEqual(entry.rounds[0].actual, .fixed(value: 8, raw: "8"), "過時的命令不能被執行")
    }

    // MARK: - 同一 requestID 重放冪等

    func testSameRequestIDAppliedTwiceIsIdempotent() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let bench = makeExercise(id: "ex-bench", name: "臥推")
        context.insert(bench)
        let draft = makeDraft()
        let entry = EntryDraft(exercise: bench, setsCount: 1, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 8)
        draft.blocks.append(BlockDraft(blockType: .single, entries: [entry]))
        let service = VoiceCommandService()
        guard let request = service.makeRequest(rawText: "把臥推第一組實際次數改為六次", draft: draft) else {
            return XCTFail()
        }

        let first = service.apply(request, draft: draft, allExercises: [bench], context: context, clientID: "cl-1")
        entry.rounds[0].actual = .fixed(value: 999, raw: "999")  // 模擬重放前又被別的東西改動
        let second = service.apply(request, draft: draft, allExercises: [bench], context: context, clientID: "cl-1")

        XCTAssertEqual(first, second, "同一個 requestID 第二次呼叫必須回傳跟第一次一樣的結果，不重新執行")
        XCTAssertEqual(entry.rounds[0].actual, .fixed(value: 999, raw: "999"), "冪等重放不應該再次寫入")
    }

    // MARK: - 單位/負重不兼容拒絕

    func testUnitMismatchIsRejectedNotReinterpreted() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let plank = makeExercise(id: "ex-plank", name: "平板支撐", metric: .time)
        context.insert(plank)
        let draft = makeDraft()
        let entry = EntryDraft(exercise: plank, setsCount: 1, load: .bodyweight(raw: "BW"), targetQuantity: 30, actualQuantity: 30)
        draft.blocks.append(BlockDraft(blockType: .single, entries: [entry]))
        let service = VoiceCommandService()

        // "次" 是 reps 單位，平板支撐是 time 動作 -- 必須拒絕，不能把 8
        // 當成秒數硬寫進去。
        let outcome = service.execute(rawText: "把平板支撐第一組實際次數改為八次", draft: draft, allExercises: [plank], context: context, clientID: "cl-1")

        guard case .rejected = outcome else { return XCTFail("單位不匹配必須拒絕，實際 \(outcome)") }
        XCTAssertEqual(entry.rounds[0].actual, .time(seconds: 30, raw: "30"), "拒絕的命令不能改動任何數據")
    }

    // MARK: - 2026-09-13 修正：新增動作單位不符必須拒絕，不能沿用默認值

    func testAddExerciseUnitMismatchIsRejectedNotSilentlyDefaulted() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let plank = makeExercise(id: "ex-plank", name: "平板支撐", metric: .time)
        context.insert(plank)
        let draft = makeDraft()
        let service = VoiceCommandService()

        // 「次」是 reps 單位，平板支撐是 time 動作——舊版會沿用 prefill
        // 默認值建立動作、回報「已添加」卻悄悄丟掉口述的數字；新版必須
        // 直接拒絕，不建立任何東西。
        let outcome = service.execute(rawText: "添加平板支撐，三組，十次", draft: draft, allExercises: [plank], context: context, clientID: "cl-1")

        guard case .rejected = outcome else { return XCTFail("單位不符必須拒絕，實際 \(outcome)") }
        XCTAssertTrue(draft.blocks.isEmpty, "拒絕的命令不能留下任何已建立的動作")
    }

    // MARK: - 2026-09-13 修正：撤銷不受 UI 顯示語言影響

    func testApplyUndoWorksDirectlyWithoutGoingThroughTextParser() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let squat = makeExercise(id: "ex-squat", name: "深蹲")
        context.insert(squat)
        let draft = makeDraft()
        let service = VoiceCommandService()
        service.execute(rawText: "添加深蹲，三組，每組十次，四十公斤", draft: draft, allExercises: [squat], context: context, clientID: "cl-1")
        XCTAssertEqual(draft.blocks.count, 1)

        // 舊版 UI 的撤銷按鈕在英文界面下會送出字面 "undo"，`VoiceCommandParser`
        // 只認「撤銷」二字，會直接失敗——`applyUndo` 完全不經過文字解析，
        // 不管 UI 顯示語言是什麼都必須成功。
        let outcome = service.applyUndo(draft: draft)

        guard case .applied = outcome else { return XCTFail("applyUndo 不應該依賴任何文字解析，實際 \(outcome)") }
        XCTAssertTrue(draft.blocks.isEmpty)
    }

    // MARK: - 2026-09-13 真機試用反饋：中文輸入時候選要顯示中文名，不是英文 canonicalName

    func testAmbiguousCandidatesDisplayChineseNameNotCanonicalEnglishName() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let squatA = Exercise(
            id: "ex-squat-a", canonicalName: "Air Squat", aliases: [], movementPattern: .squat, equipment: .bodyweight,
            loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 0, needsReview: false, reviewReason: nil,
            nameZh: "徒手深蹲"
        )
        let squatB = Exercise(
            id: "ex-squat-b", canonicalName: "Back Squat", aliases: [], movementPattern: .squat, equipment: .barbell,
            loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 0, needsReview: false, reviewReason: nil,
            nameZh: "槓鈴深蹲"
        )
        context.insert(squatA)
        context.insert(squatB)
        let draft = makeDraft()
        let service = VoiceCommandService()

        let outcome = service.execute(rawText: "添加深蹲", draft: draft, allExercises: [squatA, squatB], context: context, clientID: "cl-1")

        guard case .needsClarification(_, let candidates, _) = outcome else { return XCTFail("應該澄清，實際 \(outcome)") }
        XCTAssertEqual(Set(candidates.map(\.displayName)), ["徒手深蹲", "槓鈴深蹲"], "候選按鈕必須顯示中文名，不是英文 canonicalName")
    }

    /// 自建動作沒有填中文名時，退回英文 canonicalName，不能顯示空字串。
    func testCandidateFallsBackToCanonicalNameWhenChineseNameIsEmpty() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let customA = makeExercise(id: "ex-custom-a", name: "My Custom Move A")
        let customB = makeExercise(id: "ex-custom-b", name: "My Custom Move B")
        context.insert(customA)
        context.insert(customB)
        let draft = makeDraft()
        let service = VoiceCommandService()

        let outcome = service.execute(rawText: "添加My Custom Move", draft: draft, allExercises: [customA, customB], context: context, clientID: "cl-1")

        guard case .needsClarification(_, let candidates, _) = outcome else { return XCTFail("應該澄清，實際 \(outcome)") }
        XCTAssertEqual(Set(candidates.map(\.displayName)), ["My Custom Move A", "My Custom Move B"])
    }

    // MARK: - 2026-09-13 真機試用反饋：只說出一個運動名稱也要給候選，不要判死

    /// 使用者只說"深蹲"（沒有"添加/改成"這類動詞）——舊版會直接落到
    /// `VoiceCommandParser` 的最後一句"無法識別的指令"，使用者除了換句話
    /// 重講之外沒有其他路可走。現在應該退回去對整句原始文字做一次動作庫
    /// 召回，只要召回到東西就秀出候選，點下去直接當成"添加這個動作"。
    func testBareExerciseNameWithNoVerbStillOffersCandidates() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let squat = makeExercise(id: "ex-squat", name: "徒手深蹲")
        context.insert(squat)
        let draft = makeDraft()
        let service = VoiceCommandService()

        let outcome = service.execute(rawText: "深蹲", draft: draft, allExercises: [squat], context: context, clientID: "cl-1")

        guard case .needsClarification(let reason, let candidates, let pending) = outcome, let pending else {
            return XCTFail("只說動作名稱應該回退成帶候選的澄清，實際 \(outcome)")
        }
        XCTAssertEqual(reason, .missingExerciseName)
        XCTAssertEqual(candidates.map(\.id), ["ex-squat"])

        let applyOutcome = service.applyClarifiedChoice(
            pending, chosenCandidateID: "ex-squat", contextToken: draft.currentRevisionToken(),
            draft: draft, allExercises: [squat], context: context, clientID: "cl-1"
        )
        guard case .applied = applyOutcome else { return XCTFail("點選候選後應該直接套用，實際 \(applyOutcome)") }
        XCTAssertEqual(draft.blocks.first?.entries.first?.exercise.id, "ex-squat")
    }

    /// "深蹲三十公斤"沒有"添加"這類動詞，會先被語法猜成 setPlan，但草稿
    /// 裡還沒有深蹲這個動作，resolver 找不到目標——這條路徑現在也應該
    /// 退回模糊召回，而且要把整句裡講到的重量一併帶到候選的添加命令上，
    /// 不能因為改走回退路徑就把使用者講清楚的數字弄丟。
    func testAmbiguousSetPlanGuessFallsBackToAddCandidateWithLoadPreserved() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let squat = makeExercise(id: "ex-squat", name: "徒手深蹲")
        context.insert(squat)
        let draft = makeDraft()
        let service = VoiceCommandService()

        let outcome = service.execute(rawText: "深蹲三十公斤", draft: draft, allExercises: [squat], context: context, clientID: "cl-1")

        guard case .needsClarification(_, let candidates, let pending) = outcome, let pending else {
            return XCTFail("應該退回帶候選的澄清，實際 \(outcome)")
        }
        guard case .addExercise(let payload) = pending else { return XCTFail("回退應該是添加動作的候選") }
        guard let load = payload.load, case .absolute(let kg, _) = load else { return XCTFail("整句裡的重量必須被保留") }
        XCTAssertEqual(kg, 30)
        XCTAssertEqual(candidates.map(\.id), ["ex-squat"])
    }

    /// 完全無關的內容（沒有任何動作庫裡的東西可以召回）仍然應該維持拒絕，
    /// 不能因為新加的回退機制就對任何句子都硬湊出候選。
    func testCompletelyUnrelatedTextStaysRejectedWithNoCandidates() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let squat = makeExercise(id: "ex-squat", name: "徒手深蹲")
        context.insert(squat)
        let draft = makeDraft()
        let service = VoiceCommandService()

        let outcome = service.execute(rawText: "今天天氣真好", draft: draft, allExercises: [squat], context: context, clientID: "cl-1")

        guard case .rejected = outcome else { return XCTFail("完全無關的內容不該被硬湊出候選，實際 \(outcome)") }
    }

    /// 語法認出來了、且有明確具體原因的拒絕（單位不符）不能被模糊回退蓋過
    /// 去，變成一堆不相關的"要不要新增動作"候選。
    func testSpecificRejectionReasonIsNotOverriddenByFuzzyFallback() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let plank = makeExercise(id: "ex-plank", name: "平板支撐", metric: .time)
        context.insert(plank)
        let draft = makeDraft()
        let entry = EntryDraft(exercise: plank, setsCount: 1, load: .bodyweight(raw: "BW"), targetQuantity: 30, actualQuantity: 30)
        draft.blocks.append(BlockDraft(blockType: .single, entries: [entry]))
        let service = VoiceCommandService()

        let outcome = service.execute(rawText: "把平板支撐第一組實際次數改為八次", draft: draft, allExercises: [plank], context: context, clientID: "cl-1")

        guard case .rejected(let reason) = outcome else { return XCTFail("單位不符仍然應該拒絕，實際 \(outcome)") }
        XCTAssertEqual(reason, "單位與動作記錄方式不符", "具體原因不能被模糊回退蓋過去")
    }

    // MARK: - 計劃 vs 實際默認

    func testSetPlanDoesNotTouchActualQuantity() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let bench = makeExercise(id: "ex-bench", name: "臥推")
        context.insert(bench)
        let draft = makeDraft()
        let entry = EntryDraft(exercise: bench, setsCount: 3, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 5)
        draft.blocks.append(BlockDraft(blockType: .single, entries: [entry]))
        let service = VoiceCommandService()

        let outcome = service.execute(rawText: "把臥推改成十二次", draft: draft, allExercises: [bench], context: context, clientID: "cl-1")

        guard case .applied = outcome else { return XCTFail("預期 applied，實際 \(outcome)") }
        XCTAssertEqual(entry.rounds[0].target, .fixed(value: 12, raw: "12"), "沒有「實際」關鍵詞，只能改目標")
        XCTAssertEqual(entry.rounds[0].actual, .fixed(value: 5, raw: "5"), "既有的實際成績不能被計劃命令動到")
    }

    // MARK: - replaceExercise 對已有實際成績的動作需要預覽確認

    func testReplaceExerciseWithRecordedResultsNeedsPreviewConfirm() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let bench = makeExercise(id: "ex-bench", name: "臥推")
        let dbBench = makeExercise(id: "ex-db-bench", name: "啞鈴臥推")
        context.insert(bench)
        context.insert(dbBench)
        let draft = makeDraft()
        // actualQuantity(6) 跟該記錄單位的默認值(10)不同 -- 代表已經有真實
        // 記錄成績。
        let entry = EntryDraft(exercise: bench, setsCount: 3, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 6)
        draft.blocks.append(BlockDraft(blockType: .single, entries: [entry]))
        let service = VoiceCommandService()

        let firstOutcome = service.execute(rawText: "把臥推換成啞鈴臥推", draft: draft, allExercises: [bench, dbBench], context: context, clientID: "cl-1")
        guard case .needsPreviewConfirm = firstOutcome else { return XCTFail("已有實際成績時必須先預覽確認，實際 \(firstOutcome)") }
        XCTAssertEqual(entry.exercise.id, "ex-bench", "確認前不能真的換動作")

        let confirmedOutcome = service.execute(rawText: "把臥推換成啞鈴臥推", draft: draft, allExercises: [bench, dbBench], context: context, clientID: "cl-1", forceApply: true)
        guard case .applied = confirmedOutcome else { return XCTFail("forceApply 後應該真的套用") }
        XCTAssertEqual(entry.exercise.id, "ex-db-bench")
    }

    // MARK: - P3/M3b：外部捕獲 token 的兩個入口（真實錄音用）

    func testMakeRequestWithExternalTokenRecognizesValidCommand() throws {
        let draft = makeDraft()
        let service = VoiceCommandService()

        let request = service.makeRequest(rawText: "撤銷", contextToken: draft.currentRevisionToken())

        XCTAssertNotNil(request)
        XCTAssertEqual(request?.kind, .undoLastVoiceCommand)
    }

    func testMakeRequestWithExternalTokenReturnsNilForClarificationOrRejection() throws {
        let draft = makeDraft()
        let service = VoiceCommandService()

        XCTAssertNil(service.makeRequest(rawText: "把臥推實際次數改為八次", contextToken: draft.currentRevisionToken()), "缺欄位的命令應該回 nil（呼叫方走 apply(rawText:contextToken:...) 才能拿到具體的澄清/拒絕原因）")
        XCTAssertNil(service.makeRequest(rawText: "今天天氣真好", contextToken: draft.currentRevisionToken()))
    }

    /// 錄音場景的核心正確性：token 在「錄音開始」那一刻捕獲，這幾秒鐘之間
    /// 草稿被手動改動，辨識結果出來後仍然要正確回報過時，不能因為換了一個
    /// 建構 request 的入口就繞過同一套過時檢測。
    func testApplyWithExternallyCapturedTokenRefusesStaleDraft() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let bench = makeExercise(id: "ex-bench", name: "臥推")
        context.insert(bench)
        let draft = makeDraft()
        let entry = EntryDraft(exercise: bench, setsCount: 1, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 8)
        draft.blocks.append(BlockDraft(blockType: .single, entries: [entry]))
        let service = VoiceCommandService()

        // 模擬「開始錄音那一刻」捕獲 token。
        let tokenAtRecordingStart = draft.currentRevisionToken()

        // 錄音進行中，草稿被手動改動（跟語音完全無關的編輯）。
        entry.rounds[0].load = .absolute(kg: 65, raw: "65")

        // 辨識結果出來，用錄音開始時捕獲的 token 執行。
        let outcome = service.apply(rawText: "把臥推第一組實際次數改為六次", contextToken: tokenAtRecordingStart, draft: draft, allExercises: [bench], context: context, clientID: "cl-1")

        XCTAssertEqual(outcome, .staleDraft)
        XCTAssertEqual(entry.rounds[0].actual, .fixed(value: 8, raw: "8"), "過時的命令不能被執行")
    }

    func testApplyWithExternallyCapturedTokenHappyPath() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let bench = makeExercise(id: "ex-bench", name: "臥推")
        context.insert(bench)
        let draft = makeDraft()
        let entry = EntryDraft(exercise: bench, setsCount: 1, load: .absolute(kg: 60, raw: "60"), targetQuantity: 8, actualQuantity: 8)
        draft.blocks.append(BlockDraft(blockType: .single, entries: [entry]))
        let service = VoiceCommandService()
        let tokenAtRecordingStart = draft.currentRevisionToken()

        let outcome = service.apply(rawText: "把臥推第一組實際次數改為六次", contextToken: tokenAtRecordingStart, draft: draft, allExercises: [bench], context: context, clientID: "cl-1")

        guard case .applied = outcome else { return XCTFail("預期 applied，實際 \(outcome)") }
        XCTAssertEqual(entry.rounds[0].actual, .fixed(value: 6, raw: "6"))
    }

    func testApplyWithExternallyCapturedTokenSurfacesClarificationReason() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let draft = makeDraft()
        let service = VoiceCommandService()
        let tokenAtRecordingStart = draft.currentRevisionToken()

        let outcome = service.apply(rawText: "把臥推實際次數改為八次", contextToken: tokenAtRecordingStart, draft: draft, allExercises: [], context: context, clientID: "cl-1")

        guard case .needsClarification(let reason, _, _) = outcome else { return XCTFail("應該回報具體的澄清原因，不是靜默失敗，實際 \(outcome)") }
        XCTAssertEqual(reason, .missingSetIndex)
    }

    func testApplyWithExternallyCapturedTokenSurfacesRejectionReason() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let draft = makeDraft()
        let service = VoiceCommandService()
        let tokenAtRecordingStart = draft.currentRevisionToken()

        let outcome = service.apply(rawText: "今天天氣真好", contextToken: tokenAtRecordingStart, draft: draft, allExercises: [], context: context, clientID: "cl-1")

        guard case .rejected = outcome else { return XCTFail("無法識別的內容應該拒絕，實際 \(outcome)") }
    }
}
