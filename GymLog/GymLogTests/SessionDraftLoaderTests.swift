import XCTest
import SwiftData
@testable import GymLogKit

/// `SessionDraftLoader` —— 2026-09-09「暫時保存 / 結束課次」拆分之后新增的那条
/// 反向路径：把一节已经落库的课次读回成可继续编辑的草稿。
///
/// 这套用例盯的是同一件事的两面：
/// - **往返不失真**：`EntryDraft.resolvedSets()` 把 Round 展开成 `SetLog`，
///   这里必须把它们原样收回成同样的 Round。做不到的话，「暫存 → 继续录 → 再
///   暫存」每走一轮就会悄悄改写已经录好的内容。
/// - **单位按记录当时的来**：动作在这次训练之后被改了记录方式，也不能拿新分类
///   去解释旧数字（2026-09-07 审阅 B02 在草稿快照那条路径上已经踩过一次）。
@MainActor
final class SessionDraftLoaderTests: XCTestCase {

    private func makeExercise(
        id: String = "ex-test-1", name: String = "Bench press",
        metric: RecordingMetric = .reps, equipment: Equipment = .barbell
    ) -> Exercise {
        Exercise(
            id: id, canonicalName: name, aliases: [], movementPattern: .push, equipment: equipment,
            loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 0,
            needsReview: false, reviewReason: nil, recordingMetric: metric
        )
    }

    /// 用真正的保存路径（`EntryDraft.resolvedSets()` + 与 `TodayView.commit`
    /// 相同的展开规则）把一份草稿写成课次，好让「读回来」是在验证真实往返，
    /// 而不是在验证一份手搓的对照数据。
    private func persist(
        blocks blockDrafts: [BlockDraft], exercise: Exercise, in context: ModelContext
    ) throws -> WorkoutSession {
        let client = Client(id: "cl-test", name: "Test")
        context.insert(client)
        context.insert(exercise)
        let session = WorkoutSession(
            id: "se-test", date: Date(timeIntervalSince1970: 1_700_000_000), dateOrigin: .asRecorded,
            dateRaw: "2023-11-14", weekNumber: 1, sourceSheet: "App", sourceRow: 0,
            plannedDurationMinutes: 75
        )
        session.client = client
        context.insert(session)

        for (blockIndex, blockDraft) in blockDrafts.enumerated() {
            let block = SessionBlock(
                order: blockIndex, blockType: blockDraft.blockType, restSeconds: blockDraft.restSeconds,
                sourceRow: 0, sectionKind: blockDraft.sectionKind
            )
            block.session = session
            context.insert(block)
            if blockDraft.sectionKind == .wod, let wodDraft = blockDraft.wodDraft {
                block.wodPayload = WODPayload(
                    prescription: wodDraft.resolvedPrescription(prescriptionID: "wod-se-test-block\(blockIndex)"),
                    result: wodDraft.resolvedResult()
                )
                continue
            }
            for (entryIndex, entryDraft) in blockDraft.entries.enumerated() {
                let entry = ExerciseEntry(
                    order: entryIndex, exerciseIdRef: entryDraft.exercise.id,
                    exerciseRaw: entryDraft.exercise.canonicalName, plannedSets: entryDraft.plannedSets,
                    exercise: entryDraft.exercise
                )
                entry.block = block
                context.insert(entry)
                for (setIndex, values) in entryDraft.resolvedSets().enumerated() {
                    let setLog = SetLog(
                        setIndex: setIndex, load: values.load, target: values.target,
                        actual: values.actual, isInferred: false
                    )
                    setLog.entry = entry
                    context.insert(setLog)
                }
            }
        }
        try context.save()
        return session
    }

    // MARK: - Round 往返

    /// 三个 Round（2 组 30kg / 3 组 45kg / 2 组 40kg，正是 CONTRACT-M5.md §3.3
    /// 里教练自己举的例子）保存后读回来，必须还是同样的三个 Round，而不是
    /// 七个各一组、也不是只剩第一个。
    func testRoundsSurviveASaveAndReloadRoundTrip() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let exercise = makeExercise()
        let entry = EntryDraft(exercise: exercise, rounds: [
            RoundDraft(setsCount: 2, load: .absolute(kg: 30, raw: "30"), targetQuantity: 10, actualQuantity: 10),
            RoundDraft(setsCount: 3, load: .absolute(kg: 45, raw: "45"), targetQuantity: 8, actualQuantity: 7),
            RoundDraft(setsCount: 2, load: .absolute(kg: 40, raw: "40"), targetQuantity: 8, actualQuantity: 8),
        ])
        let session = try persist(blocks: [BlockDraft(entries: [entry])], exercise: exercise, in: context)

        let loaded = SessionDraftLoader.load(from: session, exercises: [exercise])
        XCTAssertEqual(loaded.droppedEntryCount, 0)
        XCTAssertEqual(loaded.blocks.count, 1)
        let rounds = try XCTUnwrap(loaded.blocks.first?.entries.first?.rounds)
        XCTAssertEqual(rounds.map(\.setsCount), [2, 3, 2])
        XCTAssertEqual(rounds.map(\.targetQuantity), [10, 8, 8])
        XCTAssertEqual(rounds.map(\.actualQuantity), [10, 7, 8])
        XCTAssertEqual(rounds.map(\.load), [
            .absolute(kg: 30, raw: "30"), .absolute(kg: 45, raw: "45"), .absolute(kg: 40, raw: "40"),
        ])
    }

    /// 重量相同但目标/实际不同的两段不能被并成一个 Round——教练「计划 10 次、
    /// 实际只做到 7 次」正是要单独看见的那一行。
    func testRunsAreSplitOnTargetOrActualNotJustLoad() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let exercise = makeExercise()
        let entry = EntryDraft(exercise: exercise, rounds: [
            RoundDraft(setsCount: 2, load: .absolute(kg: 40, raw: "40"), targetQuantity: 10, actualQuantity: 10),
            RoundDraft(setsCount: 1, load: .absolute(kg: 40, raw: "40"), targetQuantity: 10, actualQuantity: 7),
        ])
        let session = try persist(blocks: [BlockDraft(entries: [entry])], exercise: exercise, in: context)

        let rounds = try XCTUnwrap(SessionDraftLoader.load(from: session, exercises: [exercise]).blocks.first?.entries.first?.rounds)
        XCTAssertEqual(rounds.map(\.setsCount), [2, 1])
        XCTAssertEqual(rounds.map(\.actualQuantity), [10, 7])
    }

    // MARK: - 单位

    /// 一条 500 公尺的记录，在这次训练之后动作被改成按「次數」记——读回编辑器
    /// 时必须仍然是 500 公尺。按动作库当前分类去解释，就会变成「500 次」。
    func testUnitComesFromTheRecordNotTheLibrarysCurrentClassification() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let exercise = makeExercise(id: "ex-row", name: "Rowing", metric: .distance, equipment: .ergometer)
        let entry = EntryDraft(exercise: exercise, rounds: [
            RoundDraft(setsCount: 1, load: .bodyweight(raw: "BW"), targetQuantity: 500, actualQuantity: 500),
        ])
        let session = try persist(blocks: [BlockDraft(entries: [entry])], exercise: exercise, in: context)

        // 教练事后在動作庫里把它改成了「次數」。
        exercise.recordingMetric = .reps
        try context.save()

        let restored = try XCTUnwrap(SessionDraftLoader.load(from: session, exercises: [exercise]).blocks.first?.entries.first)
        XCTAssertEqual(restored.recordingMetric, .distance)
        XCTAssertEqual(restored.rounds.first?.targetQuantity, 500)
    }

    // MARK: - WOD

    /// 「复制上次课次」要清空成绩（同标准复测）；「继续编辑同一次」正相反，
    /// 成绩必须原样带回来，否则打开再保存就把这次的成绩抹平了。
    func testWODResultIsCarriedBackUnlikeCopyLastSession() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let exercise = makeExercise(id: "ex-wallball", name: "Wall ball", metric: .reps, equipment: .ball)
        let wodDraft = WODBlockDraft(
            name: "Karen", format: .forTime, timeCapSeconds: 900,
            movements: [WODMovementDraft(nameText: "Wall ball", quantityKind: .reps, quantityValue: 150)],
            status: .completed, elapsedSeconds: 431, notes: "20lb 球"
        )
        wodDraft.variant = .rx
        let session = try persist(
            blocks: [BlockDraft(sectionKind: .wod, wodDraft: wodDraft)], exercise: exercise, in: context
        )

        let loadedWOD = try XCTUnwrap(SessionDraftLoader.load(from: session, exercises: [exercise]).blocks.first?.wodDraft)
        XCTAssertEqual(loadedWOD.name, "Karen")
        XCTAssertEqual(loadedWOD.format, .forTime)
        XCTAssertEqual(loadedWOD.status, .completed)
        XCTAssertEqual(loadedWOD.elapsedSeconds, 431)
        XCTAssertEqual(loadedWOD.variant, .rx)
        XCTAssertEqual(loadedWOD.notes, "20lb 球")
        XCTAssertEqual(loadedWOD.movements.first?.nameText, "Wall ball")
        XCTAssertEqual(loadedWOD.movements.first?.quantityValue, 150)
    }

    /// 多轮处方（21-15-9）+ 没有编辑入口的成绩字段（`rpe`/`actualMovements`/
    /// `recordedVia`/超時定位）都必须原样带回来——`WODBlockDraft
    /// .fromPrescription` 曾经只带第一轮，`SessionDraftLoader.apply` 曾经只
    /// 抄五个字段，两处都会在这条路径上悄悄丢数据。
    func testMultiRoundWODWithFullResultFieldsIsCarriedBackLosslessly() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let exercise = makeExercise(id: "ex-thruster", name: "Thruster", metric: .reps, equipment: .barbell)
        let wodDraft = WODBlockDraft(name: "Fran", format: .forTime, timeCapSeconds: 900)
        wodDraft.movements = [WODMovementDraft(exercise: exercise, quantityKind: .reps, quantityValue: 21, loadKg: 43)]
        wodDraft.addRound()
        wodDraft.rounds[1].movements[0].quantityValue = 15
        wodDraft.addRound()
        wodDraft.rounds[2].movements[0].quantityValue = 9
        wodDraft.status = .capped
        wodDraft.variant = .rx
        wodDraft.applyExistingResult(WODResult(
            status: .capped, cappedAtStepID: "step-9", cappedProgress: .reps(6, raw: "6"), variant: .rx,
            actualMovements: [WODMovementPrescription(stepID: "s0", exerciseID: nil, exerciseNameSnapshot: "Ring Row (sub)", quantity: .reps(21, raw: "21"))],
            notes: "capped at 15:00", rpe: 9.5, recordedVia: .timer
        ))
        let session = try persist(blocks: [BlockDraft(sectionKind: .wod, wodDraft: wodDraft)], exercise: exercise, in: context)

        let loadedWOD = try XCTUnwrap(SessionDraftLoader.load(from: session, exercises: [exercise]).blocks.first?.wodDraft)
        XCTAssertEqual(loadedWOD.rounds.count, 3, "所有三轮都必须还在，不能只剩第一轮")
        XCTAssertEqual(loadedWOD.rounds.map { $0.movements[0].quantityValue }, [21, 15, 9])
        XCTAssertEqual(loadedWOD.status, .capped)

        // 「打开→不改→保存」之后成绩必须逐字段一致。
        let resaved = loadedWOD.resolvedResult()
        XCTAssertEqual(resaved.cappedAtStepID, "step-9")
        XCTAssertEqual(resaved.cappedProgress, .reps(6, raw: "6"))
        XCTAssertEqual(resaved.actualMovements.first?.exerciseNameSnapshot, "Ring Row (sub)")
        XCTAssertEqual(resaved.rpe, 9.5)
        XCTAssertEqual(resaved.recordedVia, .timer, "recordedVia 不能在继续编辑之后被悄悄改回 .manual")
        XCTAssertEqual(resaved.notes, "capped at 15:00")
    }

    // MARK: - 动作已从动作库删除

    /// 动作被删掉的条目跳过，但要报数——调用方（「今天」）据此弹窗告诉教练，
    /// 而不是让这节课的内容悄悄变少。
    func testEntriesWhoseExerciseIsGoneAreCountedNotSilentlyDropped() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let exercise = makeExercise()
        let entry = EntryDraft(exercise: exercise, setsCount: 3, load: .absolute(kg: 40, raw: "40"), targetQuantity: 10, actualQuantity: 10)
        let session = try persist(blocks: [BlockDraft(entries: [entry])], exercise: exercise, in: context)

        context.delete(exercise)
        try context.save()

        let loaded = SessionDraftLoader.load(from: session, exercises: [])
        XCTAssertEqual(loaded.droppedEntryCount, 1)
        XCTAssertTrue(loaded.blocks.isEmpty, "整块都没剩下时不该留一个空块")
    }

    // MARK: - 段落类型

    /// 力量 / 技術 / WOD 三种段落读回来仍是原来的类型——教练可以在编辑器里改
    /// 它，但「打开」这一步本身不能改。
    func testSectionKindIsPreserved() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let exercise = makeExercise()
        let skillEntry = EntryDraft(exercise: exercise, setsCount: 1, load: .bodyweight(raw: "BW"), targetQuantity: 5, actualQuantity: 5)
        let session = try persist(
            blocks: [BlockDraft(entries: [skillEntry], sectionKind: .skill)], exercise: exercise, in: context
        )
        XCTAssertEqual(SessionDraftLoader.load(from: session, exercises: [exercise]).blocks.first?.sectionKind, .skill)
    }
}
