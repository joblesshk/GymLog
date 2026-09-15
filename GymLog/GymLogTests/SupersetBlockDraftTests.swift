import XCTest
import SwiftData
@testable import GymLogKit

/// P1 (2026-09-11)：Superset 的資料正確性——`SupersetBlockDraftCard`（今天
/// 頁的 UI）本身的成員增刪/排序/解散/組成是 SwiftUI 私有方法，交給
/// `GymLogUITests/SupersetUITests.swift` 用真實 App 進程驗證互動；這裡驗證
/// 的是那些互動最終會產生的**資料形狀**能不能正確地存、取、備份、經模板
/// 往返——即 P1 計畫書開頭調查確認「模型層/持久化/備份/模板/分析已經支援
/// 多動作 block」這件事，針對 Superset 的具體用法（每個成員各自獨立的
/// `rounds` 陣列、輪數可以不齊、`setsCount` 固定為 1）補上直接證據，而不是
/// 停留在「舊的多動作 block 測試理論上也適用」的推論。
@MainActor
final class SupersetBlockDraftTests: XCTestCase {

    private func makeExercise(id: String, name: String, metric: RecordingMetric = .reps, equipment: Equipment = .barbell) -> Exercise {
        Exercise(
            id: id, canonicalName: name, aliases: [], movementPattern: .push, equipment: equipment,
            loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 0, needsReview: false,
            reviewReason: nil, recordingMetric: metric
        )
    }

    private func makeClient(in context: ModelContext, id: String = "cl-1") -> Client {
        let client = Client(id: id, name: "Test Client")
        context.insert(client)
        return client
    }

    private func baseInput(client: Client, blocks: [BlockDraft], existingSessionID: String? = nil, finishing: Bool) -> SessionCommitService.Input {
        SessionCommitService.Input(
            client: client, draftClientID: client.id, existingSessionID: existingSessionID,
            sessionDateUTC: Date(timeIntervalSince1970: 1_700_000_000), newSessionDateRawText: "2026-09-11",
            weekNumberForNewSession: 1, plannedDurationMinutes: 60, blocks: blocks, finishing: finishing
        )
    }

    /// 一輪＝一個 `RoundDraft`，`setsCount` 固定為 1——`SupersetBlockDraftCard`
    /// 實際建立成員時走的就是這個形狀。
    private func supersetRounds(count: Int, load: LoadValue, target: Int, actual: Int, metric: RecordingMetric = .reps) -> [RoundDraft] {
        (0..<count).map { _ in RoundDraft(setsCount: 1, load: load, targetQuantity: target, actualQuantity: actual, metric: metric) }
    }

    // MARK: - 保存→載入→再保存：組數不齊、不同記錄單位/負重

    func testSaveLoadResaveRoundTripsUnevenRoundSupersetLosslessly() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = makeClient(in: context)
        let squat = makeExercise(id: "ex-squat", name: "Squat", metric: .reps, equipment: .barbell)
        let plank = makeExercise(id: "ex-plank", name: "Plank", metric: .time, equipment: .other)
        context.insert(squat)
        context.insert(plank)

        // A1 三輪、A2 只有兩輪——組數不齊是允許的，各自獨立。
        let a1 = EntryDraft(exercise: squat, rounds: supersetRounds(count: 3, load: .absolute(kg: 60, raw: "60"), target: 8, actual: 6, metric: .reps))
        let a2 = EntryDraft(exercise: plank, rounds: supersetRounds(count: 2, load: .bodyweight(raw: "BW"), target: 45, actual: 40, metric: .time))
        let block = BlockDraft(blockType: .superset, restSeconds: 75, entries: [a1, a2], sectionKind: .strength)

        let input = baseInput(client: client, blocks: [block], finishing: false)
        guard case .success(let output) = SessionCommitService.commit(input, in: context) else { return XCTFail("commit failed") }

        let (loadedBlocks, dropped) = SessionDraftLoader.load(from: output.session, exercises: [squat, plank])
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(loadedBlocks.count, 1)
        let loaded = try XCTUnwrap(loadedBlocks.first)
        XCTAssertEqual(loaded.blockType, .superset)
        XCTAssertEqual(loaded.restSeconds, 75)
        XCTAssertEqual(loaded.entries.count, 2)

        let loadedSquat = try XCTUnwrap(loaded.entries.first { $0.exercise.id == "ex-squat" })
        XCTAssertEqual(loadedSquat.rounds.count, 3, "A1 的 3 輪必須完整保留")
        XCTAssertTrue(loadedSquat.rounds.allSatisfy { $0.setsCount == 1 })
        XCTAssertEqual(loadedSquat.rounds.map { RepTargetToRoundQuantity.quantity(from: $0.actual, metric: .reps) }, [6, 6, 6])

        let loadedPlank = try XCTUnwrap(loaded.entries.first { $0.exercise.id == "ex-plank" })
        XCTAssertEqual(loadedPlank.rounds.count, 2, "A2 只有 2 輪，不能被 A1 的輪數撐大")
        XCTAssertEqual(loadedPlank.rounds.map { RepTargetToRoundQuantity.quantity(from: $0.actual, metric: .time) }, [40, 40])

        // 再保存一次（暫存→再暫存），不能产生第二条历史记录。
        let secondInput = baseInput(client: client, blocks: loadedBlocks, existingSessionID: output.session.id, finishing: false)
        guard case .success = SessionCommitService.commit(secondInput, in: context) else { return XCTFail("re-commit failed") }
        let allSessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        XCTAssertEqual(allSessions.count, 1, "同一節課暫存兩次不能變成兩條歷史記錄")
    }

    // MARK: - 每輪各自不同的實際值都要保留，不能被壓成同一個值

    func testEachRoundKeepsItsOwnDistinctActualValue() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = makeClient(in: context)
        let bench = makeExercise(id: "ex-bench", name: "Bench Press")
        let row = makeExercise(id: "ex-row", name: "Row")
        context.insert(bench)
        context.insert(row)

        let benchRounds = [
            RoundDraft(setsCount: 1, load: .absolute(kg: 40, raw: "40"), targetQuantity: 10, actualQuantity: 10, metric: .reps),
            RoundDraft(setsCount: 1, load: .absolute(kg: 40, raw: "40"), targetQuantity: 10, actualQuantity: 8, metric: .reps),
            RoundDraft(setsCount: 1, load: .absolute(kg: 40, raw: "40"), targetQuantity: 10, actualQuantity: 7, metric: .reps)
        ]
        let rowRounds = [
            RoundDraft(setsCount: 1, load: .absolute(kg: 30, raw: "30"), targetQuantity: 12, actualQuantity: 12, metric: .reps),
            RoundDraft(setsCount: 1, load: .absolute(kg: 30, raw: "30"), targetQuantity: 12, actualQuantity: 11, metric: .reps),
            RoundDraft(setsCount: 1, load: .absolute(kg: 30, raw: "30"), targetQuantity: 12, actualQuantity: 9, metric: .reps)
        ]
        let a1 = EntryDraft(exercise: bench, rounds: benchRounds)
        let a2 = EntryDraft(exercise: row, rounds: rowRounds)
        let block = BlockDraft(blockType: .superset, restSeconds: 60, entries: [a1, a2], sectionKind: .strength)

        let input = baseInput(client: client, blocks: [block], finishing: true)
        guard case .success(let output) = SessionCommitService.commit(input, in: context) else { return XCTFail("commit failed") }

        let (loadedBlocks, _) = SessionDraftLoader.load(from: output.session, exercises: [bench, row])
        let loaded = try XCTUnwrap(loadedBlocks.first)
        let loadedBench = try XCTUnwrap(loaded.entries.first { $0.exercise.id == "ex-bench" })
        let loadedRow = try XCTUnwrap(loaded.entries.first { $0.exercise.id == "ex-row" })
        XCTAssertEqual(loadedBench.rounds.map { RepTargetToRoundQuantity.quantity(from: $0.actual, metric: .reps) }, [10, 8, 7], "每輪各自不同的實際次數必須逐輪保留")
        XCTAssertEqual(loadedRow.rounds.map { RepTargetToRoundQuantity.quantity(from: $0.actual, metric: .reps) }, [12, 11, 9])
    }

    // MARK: - 訓練量/分析按動作各自歸屬，不因同屬一個 Superset block 而混算

    func testVolumeIsAttributedPerExerciseNotAcrossTheWholeSuperset() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = makeClient(in: context)
        let bench = makeExercise(id: "ex-bench", name: "Bench Press")
        let row = makeExercise(id: "ex-row", name: "Row")
        context.insert(bench)
        context.insert(row)

        // Bench: 3 组 @ 40kg x 10 reps = 1200kg。Row: 2 组 @ 30kg x 12 reps = 720kg。
        let a1 = EntryDraft(exercise: bench, rounds: supersetRounds(count: 3, load: .absolute(kg: 40, raw: "40"), target: 10, actual: 10))
        let a2 = EntryDraft(exercise: row, rounds: supersetRounds(count: 2, load: .absolute(kg: 30, raw: "30"), target: 12, actual: 12))
        let block = BlockDraft(blockType: .superset, restSeconds: 60, entries: [a1, a2], sectionKind: .strength)

        let input = baseInput(client: client, blocks: [block], finishing: true)
        guard case .success = SessionCommitService.commit(input, in: context) else { return XCTFail("commit failed") }

        let allEntries = try context.fetch(FetchDescriptor<ExerciseEntry>())
        XCTAssertEqual(allEntries.count, 2, "一個 2 成員的 Superset 必須落成兩條獨立 ExerciseEntry，不是一條")

        let benchEntries = allEntries.filter { $0.exerciseIdRef == "ex-bench" }
        let rowEntries = allEntries.filter { $0.exerciseIdRef == "ex-row" }
        let benchPoints = ExerciseHistoryAnalyzer.points(from: benchEntries, loadDirection: .higherIsStronger, includeInferred: true)
        let rowPoints = ExerciseHistoryAnalyzer.points(from: rowEntries, loadDirection: .higherIsStronger, includeInferred: true)

        XCTAssertEqual(benchPoints.count, 1)
        XCTAssertEqual(rowPoints.count, 1)
        XCTAssertEqual(benchPoints[0].volumeKg, 40 * 10 * 3, "Bench 的訓練量只能來自它自己的 3 組，不能疊加 Row 的")
        XCTAssertEqual(rowPoints[0].volumeKg, 30 * 12 * 2, "Row 的訓練量只能來自它自己的 2 組，不能疊加 Bench 的")
    }

    // MARK: - 混合課次：普通動作 + Superset + WOD 一起完整往返

    func testMixedSessionWithNormalSupersetAndWODRoundTripsAllBlockTypes() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = makeClient(in: context)
        let squat = makeExercise(id: "ex-squat", name: "Squat")
        let bench = makeExercise(id: "ex-bench", name: "Bench Press")
        let row = makeExercise(id: "ex-row", name: "Row")
        let burpee = makeExercise(id: "ex-burpee", name: "Burpee", metric: .reps, equipment: .other)
        for ex in [squat, bench, row, burpee] { context.insert(ex) }

        let normalEntry = EntryDraft(exercise: squat, setsCount: 3, load: .absolute(kg: 80, raw: "80"), targetQuantity: 5, actualQuantity: 5)
        let normalBlock = BlockDraft(blockType: .single, entries: [normalEntry])

        let supersetA1 = EntryDraft(exercise: bench, rounds: supersetRounds(count: 3, load: .absolute(kg: 40, raw: "40"), target: 10, actual: 10))
        let supersetA2 = EntryDraft(exercise: row, rounds: supersetRounds(count: 3, load: .absolute(kg: 30, raw: "30"), target: 12, actual: 12))
        let supersetBlock = BlockDraft(blockType: .superset, restSeconds: 60, entries: [supersetA1, supersetA2], sectionKind: .strength)

        let movement = WODMovementDraft(exercise: burpee, nameText: "Burpee")
        movement.applyExercise(burpee)
        let wodDraft = WODBlockDraft(movements: [movement])
        let wodBlock = BlockDraft(sectionKind: .wod, wodDraft: wodDraft)

        let input = baseInput(client: client, blocks: [normalBlock, supersetBlock, wodBlock], finishing: true)
        guard case .success(let output) = SessionCommitService.commit(input, in: context) else { return XCTFail("commit failed") }

        let (loadedBlocks, dropped) = SessionDraftLoader.load(from: output.session, exercises: [squat, bench, row, burpee])
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(loadedBlocks.count, 3, "普通動作 + Superset + WOD 三塊都要在，順序不能亂")
        XCTAssertEqual(loadedBlocks[0].blockType, .single)
        XCTAssertEqual(loadedBlocks[0].entries.first?.exercise.id, "ex-squat")
        XCTAssertEqual(loadedBlocks[1].blockType, .superset)
        XCTAssertEqual(loadedBlocks[1].entries.count, 2)
        XCTAssertEqual(loadedBlocks[2].sectionKind, .wod)
        XCTAssertNotNil(loadedBlocks[2].wodDraft)
    }

    // MARK: - 模板：Superset 型的 TemplateBlock 經 TemplateSessionBuilder 建出正確的 BlockDraft

    func testTemplateSupersetBlockBuildsIntoASupersetBlockDraft() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let bench = makeExercise(id: "ex-bench", name: "Bench Press")
        let row = makeExercise(id: "ex-row", name: "Row")
        context.insert(bench)
        context.insert(row)

        let template = SessionTemplate(id: "tpl-1", name: "上肢 Superset", order: 0)
        context.insert(template)
        let templateBlock = TemplateBlock(id: "blk-1", order: 0, blockType: .superset, restSeconds: 60)
        templateBlock.template = template
        context.insert(templateBlock)
        let slot1 = TemplateExerciseSlot(id: "slot-1", order: 0, exerciseID: "ex-bench", defaultSets: 3, defaultRepTarget: .fixed(value: 10, raw: "10"))
        slot1.block = templateBlock
        context.insert(slot1)
        let slot2 = TemplateExerciseSlot(id: "slot-2", order: 1, exerciseID: "ex-row", defaultSets: 3, defaultRepTarget: .fixed(value: 12, raw: "12"))
        slot2.block = templateBlock
        context.insert(slot2)

        let result = TemplateSessionBuilder.build(from: template, clientID: "cl-1", allExercises: [bench, row], in: context)
        XCTAssertEqual(result.unresolvedSlotCount, 0)
        XCTAssertEqual(result.blocks.count, 1)
        let block = try XCTUnwrap(result.blocks.first)
        XCTAssertEqual(block.blockType, .superset, "組合模板存的 Superset 類型必須原樣帶到新課次的 BlockDraft")
        XCTAssertEqual(block.entries.count, 2)
        XCTAssertEqual(Set(block.entries.map(\.exercise.id)), ["ex-bench", "ex-row"])
    }

    // MARK: - 備份匯出/匯入：Superset block 完整往返到另一個 context

    func testBackupExportImportRoundTripsSupersetBlock() throws {
        let sourceContainer = try TestSupport.makeInMemoryContainer()
        let sourceContext = ModelContext(sourceContainer)
        let client = makeClient(in: sourceContext)
        let bench = makeExercise(id: "ex-bench", name: "Bench Press")
        let row = makeExercise(id: "ex-row", name: "Row")
        sourceContext.insert(bench)
        sourceContext.insert(row)

        let a1 = EntryDraft(exercise: bench, rounds: supersetRounds(count: 2, load: .absolute(kg: 40, raw: "40"), target: 10, actual: 9))
        let a2 = EntryDraft(exercise: row, rounds: supersetRounds(count: 2, load: .absolute(kg: 30, raw: "30"), target: 12, actual: 11))
        let block = BlockDraft(blockType: .superset, restSeconds: 90, entries: [a1, a2], sectionKind: .strength)
        let input = baseInput(client: client, blocks: [block], finishing: true)
        guard case .success = SessionCommitService.commit(input, in: sourceContext) else { return XCTFail("commit failed") }

        let backup = try BackupExporter.makeBackup(from: sourceContext)

        let destContainer = try TestSupport.makeInMemoryContainer()
        let destContext = ModelContext(destContainer)
        _ = try BackupImporter.restore(backup, into: destContext)

        let restoredBlocks = try destContext.fetch(FetchDescriptor<SessionBlock>())
        let restoredSuperset = try XCTUnwrap(restoredBlocks.first { $0.blockType == .superset })
        XCTAssertEqual(restoredSuperset.orderedEntries.count, 2, "備份還原後 Superset 的兩個成員都要在")
        XCTAssertEqual(restoredSuperset.restSeconds, 90)
        let restoredExerciseIDs = Set(restoredSuperset.orderedEntries.map(\.exerciseIdRef))
        XCTAssertEqual(restoredExerciseIDs, ["ex-bench", "ex-row"])
    }

    // MARK: - 解散為獨立動作：資料原樣保留，只是拆成 N 個 .single block

    func testDissolvingASupersetPreservesEveryMembersDataExactly() throws {
        let bench = makeExercise(id: "ex-bench", name: "Bench Press")
        let row = makeExercise(id: "ex-row", name: "Row")
        let a1 = EntryDraft(exercise: bench, rounds: supersetRounds(count: 3, load: .absolute(kg: 40, raw: "40"), target: 10, actual: 8))
        let a2 = EntryDraft(exercise: row, rounds: supersetRounds(count: 2, load: .absolute(kg: 30, raw: "30"), target: 12, actual: 11))
        let block = BlockDraft(blockType: .superset, restSeconds: 60, entries: [a1, a2], sectionKind: .strength)

        // 与 TodayView.dissolveSuperset 完全相同的转换：每个成员各自包成一个
        // .single block，不改动任何 Round 数据。
        let dissolved = block.entries.map { BlockDraft(blockType: .single, entries: [$0], sectionKind: block.sectionKind) }

        XCTAssertEqual(dissolved.count, 2)
        XCTAssertEqual(dissolved[0].blockType, .single)
        XCTAssertEqual(dissolved[0].entries.first?.exercise.id, "ex-bench")
        XCTAssertEqual(dissolved[0].entries.first?.rounds.map { RepTargetToRoundQuantity.quantity(from: $0.actual, metric: .reps) }, [8, 8, 8])
        XCTAssertEqual(dissolved[1].entries.first?.exercise.id, "ex-row")
        XCTAssertEqual(dissolved[1].entries.first?.rounds.map { RepTargetToRoundQuantity.quantity(from: $0.actual, metric: .reps) }, [11, 11])
    }
}
