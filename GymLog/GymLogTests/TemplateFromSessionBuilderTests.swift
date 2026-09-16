import XCTest
import SwiftData
@testable import GymLogKit

/// 2026-09-16「從歷史記錄的某天生成模板」——`TemplateFromSessionBuilder` 是
/// `TemplateSessionBuilder`（模板 → 草稿）的反方向：歷史課次 → 模板。這裡
/// 驗證的三件事跟 `M4ATemplateSessionBuilderTests` 對稱：動作能正確解析成
/// slot、重量絕對不會被帶進模板（模板本來就不帶重量）、動作已刪除的條目
/// 會被跳過並計數而不是靜默消失或崩潰。
@MainActor
final class TemplateFromSessionBuilderTests: XCTestCase {

    private func makeExercise(id: String = "ex-bench", name: String = "Bench press", metric: RecordingMetric = .reps) -> Exercise {
        Exercise(
            id: id, canonicalName: name, aliases: [], movementPattern: .push, equipment: .barbell,
            loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 10, needsReview: false,
            reviewReason: nil, recordingMetric: metric
        )
    }

    /// 直接用模型層構出一節「已經落庫」的課次，跟 `SessionDraftLoaderTests`
    /// 的 `persist` 同一個理由：驗證的是真實資料形狀，不是手搓的對照資料。
    private func makeSession(
        client: Client? = nil, blocks blockSpecs: [(sectionKind: SectionKind, blockType: BlockType, entries: [(exercise: Exercise, plannedSets: Int, sets: [(load: LoadValue, target: RepTarget)])], wodDraft: WODBlockDraft?)],
        in context: ModelContext
    ) throws -> WorkoutSession {
        let resolvedClient: Client
        if let client { resolvedClient = client } else {
            resolvedClient = Client(id: "cl-test", name: "Test")
            context.insert(resolvedClient)
        }
        let session = WorkoutSession(
            id: "se-test", date: Date(timeIntervalSince1970: 1_700_000_000), dateOrigin: .asRecorded,
            dateRaw: "2023-11-14", weekNumber: 1, sourceSheet: "App", sourceRow: 0, plannedDurationMinutes: 60
        )
        session.client = resolvedClient
        context.insert(session)

        for (blockIndex, spec) in blockSpecs.enumerated() {
            let block = SessionBlock(order: blockIndex, blockType: spec.blockType, restSeconds: 60, sourceRow: 0, sectionKind: spec.sectionKind)
            block.session = session
            context.insert(block)
            if spec.sectionKind == .wod, let wodDraft = spec.wodDraft {
                block.wodPayload = WODPayload(
                    prescription: wodDraft.resolvedPrescription(prescriptionID: "wod-\(blockIndex)"),
                    result: wodDraft.resolvedResult()
                )
                continue
            }
            for (entryIndex, entrySpec) in spec.entries.enumerated() {
                let entry = ExerciseEntry(
                    order: entryIndex, exerciseIdRef: entrySpec.exercise.id, exerciseRaw: entrySpec.exercise.canonicalName,
                    plannedSets: entrySpec.plannedSets, exercise: entrySpec.exercise
                )
                entry.block = block
                context.insert(entry)
                for (setIndex, setSpec) in entrySpec.sets.enumerated() {
                    let setLog = SetLog(setIndex: setIndex, load: setSpec.load, target: setSpec.target, actual: setSpec.target, isInferred: false)
                    setLog.entry = entry
                    context.insert(setLog)
                }
            }
        }
        try context.save()
        return session
    }

    // MARK: - Basic conversion

    func testBuildsOneTemplateBlockAndSlotPerSessionBlockAndEntry() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let bench = makeExercise()
        let session = try makeSession(
            blocks: [(
                sectionKind: .strength, blockType: .single,
                entries: [(exercise: bench, plannedSets: 4, sets: [(load: .absolute(kg: 60, raw: "60"), target: .fixed(value: 8, raw: "8"))])],
                wodDraft: nil
            )],
            in: context
        )

        let result = try TemplateFromSessionBuilder.build(from: session, name: "測試範本", in: context)

        XCTAssertEqual(result.droppedEntryCount, 0)
        XCTAssertEqual(result.template.name, "測試範本")
        XCTAssertEqual(result.template.orderedBlocks.count, 1)
        let slot = try XCTUnwrap(result.template.orderedBlocks.first?.orderedSlots.first)
        XCTAssertEqual(slot.exerciseID, bench.id)
        XCTAssertEqual(slot.defaultSets, 4, "沿用 ExerciseEntry.plannedSets，不是 sets 陣列長度")
        XCTAssertEqual(slot.defaultRepTarget, .fixed(value: 8, raw: "8"))
    }

    /// 模板本來就不帶重量（`TemplateExerciseSlot` 沒有 `LoadValue` 欄位）——
    /// 這不是需要驗證「有沒有正確存重量」，而是結構上就不存在這個欄位可存，
    /// 這裡驗證的是轉換本身不會因為要塞重量而出錯或意外把它編碼進
    /// `defaultRepTarget` 之類的地方。
    func testTemplateSlotNeverCarriesLoad() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let bench = makeExercise()
        let session = try makeSession(
            blocks: [(
                sectionKind: .strength, blockType: .single,
                entries: [(exercise: bench, plannedSets: 3, sets: [(load: .absolute(kg: 92.5, raw: "92.5"), target: .fixed(value: 8, raw: "8"))])],
                wodDraft: nil
            )],
            in: context
        )

        let result = try TemplateFromSessionBuilder.build(from: session, name: "測試範本", in: context)
        let slot = try XCTUnwrap(result.template.orderedBlocks.first?.orderedSlots.first)
        // `TemplateExerciseSlot` 沒有 load 屬性可讀——這裡確認 `defaultRepTarget`
        // 本身沒有被塞進任何重量資訊，仍然乾淨地只是次數。
        XCTAssertEqual(slot.defaultRepTarget, .fixed(value: 8, raw: "8"))
    }

    // MARK: - Multiple blocks/entries

    func testMultipleBlocksAndEntriesAllConvert() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let bench = makeExercise(id: "ex-bench", name: "Bench")
        let row = makeExercise(id: "ex-row", name: "Row")
        let session = try makeSession(
            blocks: [
                (sectionKind: .strength, blockType: .single, entries: [(exercise: bench, plannedSets: 4, sets: [(load: .absolute(kg: 60, raw: "60"), target: .fixed(value: 8, raw: "8"))])], wodDraft: nil),
                (sectionKind: .strength, blockType: .single, entries: [(exercise: row, plannedSets: 3, sets: [(load: .absolute(kg: 40, raw: "40"), target: .fixed(value: 10, raw: "10"))])], wodDraft: nil),
            ],
            in: context
        )

        let result = try TemplateFromSessionBuilder.build(from: session, name: "測試範本", in: context)
        XCTAssertEqual(result.template.orderedBlocks.count, 2)
        XCTAssertEqual(result.template.orderedBlocks.map { $0.orderedSlots.first?.exerciseID }, ["ex-bench", "ex-row"])
    }

    // MARK: - Deleted exercise

    func testEntryWhoseExerciseIsGoneIsSkippedAndCounted() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let bench = makeExercise(id: "ex-bench", name: "Bench")
        let row = makeExercise(id: "ex-row", name: "Row")
        let session = try makeSession(
            blocks: [(
                sectionKind: .strength, blockType: .single,
                entries: [
                    (exercise: bench, plannedSets: 4, sets: [(load: .absolute(kg: 60, raw: "60"), target: .fixed(value: 8, raw: "8"))]),
                    (exercise: row, plannedSets: 3, sets: [(load: .absolute(kg: 40, raw: "40"), target: .fixed(value: 10, raw: "10"))]),
                ],
                wodDraft: nil
            )],
            in: context
        )
        context.delete(row)
        try context.save()

        let result = try TemplateFromSessionBuilder.build(from: session, name: "測試範本", in: context)
        XCTAssertEqual(result.droppedEntryCount, 1)
        XCTAssertEqual(result.template.orderedBlocks.first?.orderedSlots.count, 1, "刪除的動作被跳過，但沒刪除的那個動作仍要在")
        XCTAssertEqual(result.template.orderedBlocks.first?.orderedSlots.first?.exerciseID, "ex-bench")
    }

    /// 一個區塊裡全部動作都已刪除——不該留一個空的 `TemplateBlock`，跟
    /// `SessionDraftLoader.load`「整块都没剩下时这一块也不再出现」同一個
    /// 慣例。
    func testBlockWithAllExercisesGoneIsDroppedEntirely() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let bench = makeExercise(id: "ex-bench", name: "Bench")
        let session = try makeSession(
            blocks: [(
                sectionKind: .strength, blockType: .single,
                entries: [(exercise: bench, plannedSets: 4, sets: [(load: .absolute(kg: 60, raw: "60"), target: .fixed(value: 8, raw: "8"))])],
                wodDraft: nil
            )],
            in: context
        )
        context.delete(bench)
        try context.save()

        let result = try TemplateFromSessionBuilder.build(from: session, name: "測試範本", in: context)
        XCTAssertEqual(result.droppedEntryCount, 1)
        XCTAssertTrue(result.template.orderedBlocks.isEmpty, "整塊都沒有可用動作時不該留一個空塊")
    }

    // MARK: - WOD

    func testWODBlockCopiesOnlyThePrescriptionNeverAResult() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let exercise = makeExercise(id: "ex-wallball", name: "Wall ball")
        let wodDraft = WODBlockDraft(
            name: "Karen", format: .forTime, timeCapSeconds: 900,
            movements: [WODMovementDraft(nameText: "Wall ball", quantityKind: .reps, quantityValue: 150)],
            status: .completed, elapsedSeconds: 431, notes: "20lb 球"
        )
        let session = try makeSession(
            blocks: [(sectionKind: .wod, blockType: .single, entries: [], wodDraft: wodDraft)],
            in: context
        )

        let result = try TemplateFromSessionBuilder.build(from: session, name: "測試範本", in: context)
        let templateBlock = try XCTUnwrap(result.template.orderedBlocks.first)
        XCTAssertEqual(templateBlock.sectionKind, .wod)
        let prescription = try XCTUnwrap(templateBlock.wodPrescription)
        XCTAssertEqual(prescription.name, "Karen")
        // `TemplateBlock` 结构上没有存 `WODResult` 的位置——`wodPrescription`
        // 本身就只有处方字段，这里只需确认拿得到处方、且它是这次课次的处方。
        XCTAssertEqual(prescription.format, .forTime)
    }

    // MARK: - Template order

    func testNewTemplateOrderIsAfterExistingTemplates() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(SessionTemplate(id: "tpl-existing-1", name: "既有 1", order: 0))
        context.insert(SessionTemplate(id: "tpl-existing-2", name: "既有 2", order: 3))
        try context.save()
        let bench = makeExercise()
        let session = try makeSession(
            blocks: [(sectionKind: .strength, blockType: .single, entries: [(exercise: bench, plannedSets: 3, sets: [(load: .absolute(kg: 60, raw: "60"), target: .fixed(value: 8, raw: "8"))])], wodDraft: nil)],
            in: context
        )

        let result = try TemplateFromSessionBuilder.build(from: session, name: "新範本", in: context)
        XCTAssertEqual(result.template.order, 4, "新模板排在既有模板最大 order 之後，不會插隊或撞號")
    }
}
