import XCTest
import SwiftData
@testable import GymLogKit

/// `SessionCommitService` -- the persistence logic behind `TodayView`'s
/// "暫時保存"/"結束課次" (extracted 2026-09-10 so it's testable through the
/// EXACT code path the UI uses, not a hand-rolled stand-in). These tests
/// exercise real end-to-end chains, not isolated conversion functions:
/// repeated "暫存" must never fork into multiple history rows, and a
/// same-standard retest copy must compare correctly in `WODPRAnalyzer`
/// against the ORIGINAL, going through the actual save→copy→save→query path.
@MainActor
final class SessionCommitServiceTests: XCTestCase {
    private func makeExercise(id: String = "ex-thruster") -> Exercise {
        Exercise(
            id: id, canonicalName: "Thruster", aliases: [], movementPattern: .push, equipment: .barbell,
            loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 0, needsReview: false, reviewReason: nil
        )
    }

    private func makeClient(in context: ModelContext) -> Client {
        let client = Client(id: "cl-1", name: "Test")
        context.insert(client)
        return client
    }

    private func baseInput(client: Client, blocks: [BlockDraft], existingSessionID: String? = nil, finishing: Bool) -> SessionCommitService.Input {
        SessionCommitService.Input(
            client: client, draftClientID: client.id, existingSessionID: existingSessionID,
            sessionDateUTC: Date(timeIntervalSince1970: 1_700_000_000), newSessionDateRawText: "2023-11-14",
            weekNumberForNewSession: 1, plannedDurationMinutes: 60, blocks: blocks, finishing: finishing
        )
    }

    // MARK: - 暂存多次→结束：数据库只有同一条课次

    func testRepeatedDraftSavesThenFinishProduceExactlyOneSession() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let exercise = makeExercise()
        let client = makeClient(in: context)

        func entryBlock(reps: Int) -> BlockDraft {
            let entry = EntryDraft(exercise: exercise, setsCount: 1, load: .absolute(kg: 40, raw: "40"), targetQuantity: reps, actualQuantity: reps)
            return BlockDraft(entries: [entry])
        }

        var sessionID: String?
        // 暫存 3 次，每次内容略有不同。
        for reps in [8, 9, 10] {
            let input = baseInput(client: client, blocks: [entryBlock(reps: reps)], existingSessionID: sessionID, finishing: false)
            guard case .success(let output) = SessionCommitService.commit(input, in: context) else { return XCTFail("commit failed") }
            sessionID = output.session.id
        }
        // 結束課次。
        let finishInput = baseInput(client: client, blocks: [entryBlock(reps: 10)], existingSessionID: sessionID, finishing: true)
        guard case .success = SessionCommitService.commit(finishInput, in: context) else { return XCTFail("finish commit failed") }

        let allSessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        XCTAssertEqual(allSessions.count, 1, "3 次暫存 + 1 次結束必须只留下一条历史记录")
        XCTAssertFalse(allSessions[0].isInProgress)
        XCTAssertEqual(allSessions[0].orderedBlocks.first?.orderedEntries.first?.orderedSets.first?.actual, .fixed(value: 10, raw: "10"))
    }

    // MARK: - 保存→载入→再次保存：复杂 WOD 无损（多轮 + 完整成绩字段）

    func testSaveLoadResaveRoundTripsAMultiRoundWODLosslessly() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let exercise = makeExercise()
        let client = makeClient(in: context)

        let wodDraft = WODBlockDraft(name: "Fran", format: .forTime, timeCapSeconds: 900)
        wodDraft.movements = [WODMovementDraft(exercise: exercise, quantityKind: .reps, quantityValue: 21, loadKg: 43)]
        wodDraft.addRound()
        wodDraft.rounds[1].movements[0].quantityValue = 15
        wodDraft.addRound()
        wodDraft.rounds[2].movements[0].quantityValue = 9
        wodDraft.status = .completed
        wodDraft.elapsedSeconds = 431
        wodDraft.variant = .rx
        wodDraft.applyExistingResult(WODResult(
            status: .completed, elapsedSeconds: 431, variant: .rx,
            actualMovements: [], notes: "felt strong", rpe: 8.0, recordedVia: .timer
        ))
        wodDraft.notes = "felt strong"

        let firstInput = baseInput(client: client, blocks: [BlockDraft(sectionKind: .wod, wodDraft: wodDraft)], finishing: false)
        guard case .success(let firstOutput) = SessionCommitService.commit(firstInput, in: context) else { return XCTFail() }
        let sessionID = firstOutput.session.id

        // 载入 -> 不改 -> 再保存
        let loaded = SessionDraftLoader.load(from: firstOutput.session, exercises: [exercise])
        XCTAssertEqual(loaded.droppedEntryCount, 0)
        let reloadedInput = baseInput(client: client, blocks: loaded.blocks, existingSessionID: sessionID, finishing: true)
        guard case .success = SessionCommitService.commit(reloadedInput, in: context) else { return XCTFail() }

        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        XCTAssertEqual(sessions.count, 1)
        let payload = try XCTUnwrap(sessions[0].orderedBlocks.first?.wodPayload)
        XCTAssertEqual(payload.prescription.rounds.count, 3, "所有三轮都必须原样还在")
        XCTAssertEqual(payload.prescription.rounds.map { $0.movements[0].quantity.value }, [21, 15, 9])
        XCTAssertEqual(payload.prescription.id, wodDraft.prescriptionID)
        XCTAssertEqual(payload.prescription.revision, 1, "内容没变，版本不应该跳")
        XCTAssertEqual(payload.result.elapsedSeconds, 431)
        XCTAssertEqual(payload.result.rpe, 8.0, "没有编辑入口的字段也必须无损保留")
        XCTAssertEqual(payload.result.recordedVia, .timer)
        XCTAssertEqual(payload.result.notes, "felt strong")
    }

    // MARK: - 复制课次→保存新课次→查询历史：PR 跨课次比较正确

    /// 这是本次复审要修的核心 bug：旧实现用 session id + block 位置生成
    /// `prescriptionID`，复制课次做复测时 session id 变了，PR 分组直接失效。
    func testCopiedRetestComparesCorrectlyAgainstTheOriginalAcrossSessions() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let exercise = makeExercise()
        let client = makeClient(in: context)

        // 第一次：10 分钟完赛。
        let firstDraft = WODBlockDraft(format: .forTime, timeCapSeconds: 900, scoringRule: .completionTime)
        firstDraft.movements = [WODMovementDraft(exercise: exercise, quantityKind: .reps, quantityValue: 21)]
        firstDraft.status = .completed
        firstDraft.elapsedSeconds = 600
        firstDraft.variant = .rx
        let firstInput = baseInput(client: client, blocks: [BlockDraft(sectionKind: .wod, wodDraft: firstDraft)], finishing: true)
        guard case .success(let firstOutput) = SessionCommitService.commit(firstInput, in: context) else { return XCTFail() }

        // 复制上次课次做复测（模拟 `TodayView.copyLastSession`）：处方原样，成绩清空。
        let savedPrescription = try XCTUnwrap(firstOutput.session.orderedBlocks.first?.wodPayload?.prescription)
        let retestDraft = WODBlockDraft.fromPrescription(savedPrescription, exercises: [exercise])
        XCTAssertEqual(retestDraft.status, .notRecorded, "复制必须清空成绩")
        retestDraft.status = .completed
        retestDraft.elapsedSeconds = 540 // 9:00 -- faster
        retestDraft.variant = .rx
        let retestInput = baseInput(client: client, blocks: [BlockDraft(sectionKind: .wod, wodDraft: retestDraft)], finishing: true)
        guard case .success(let retestOutput) = SessionCommitService.commit(retestInput, in: context) else { return XCTFail() }

        XCTAssertNotEqual(firstOutput.session.id, retestOutput.session.id, "两次训练是两条独立的历史记录")

        // 查询历史，跑真正的 PR 分析——两条记录都真的存在库里。
        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkoutSession>()).count, 2)
        // 两次训练在这份测试夹具里共用同一个 `sessionDateUTC`，所以按真实录入
        // 顺序（先录的在前）而不是按日期排序，这就是 `WODPRAnalyzer` 要求调用方
        // 保证的"按时间顺序传入"。
        let entries: [WODPRAnalyzer.Entry] = [firstOutput.session, retestOutput.session].compactMap { session in
            session.orderedBlocks.first?.wodPayload.map { WODPRAnalyzer.Entry(date: session.date, payload: $0) }
        }
        let statuses = WODPRAnalyzer.recordStatuses(entries: entries)
        XCTAssertEqual(statuses, [.first, .improved], "复制复测后必须能跨课次正确识别改进，而不是各自算成独立的第一名")
    }

    // MARK: - 编辑处方与编辑成绩分别产生正确的身份和版本行为

    func testEditingResultOnlyKeepsIdentityButEditingPrescriptionBumpsRevision() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let exercise = makeExercise()
        let client = makeClient(in: context)

        let draft = WODBlockDraft(format: .forTime, timeCapSeconds: 900)
        draft.movements = [WODMovementDraft(exercise: exercise, quantityKind: .reps, quantityValue: 21, loadKg: 43)]
        draft.status = .completed
        draft.elapsedSeconds = 600
        draft.variant = .rx
        let firstInput = baseInput(client: client, blocks: [BlockDraft(sectionKind: .wod, wodDraft: draft)], finishing: false)
        guard case .success(let firstOutput) = SessionCommitService.commit(firstInput, in: context) else { return XCTFail() }
        let firstPayload = try XCTUnwrap(firstOutput.session.orderedBlocks.first?.wodPayload)

        // 继续编辑同一次：只改成绩（notes + elapsed），不改处方。
        let reloaded = SessionDraftLoader.load(from: firstOutput.session, exercises: [exercise])
        guard let reloadedWOD = reloaded.blocks.first?.wodDraft else { return XCTFail() }
        reloadedWOD.elapsedSeconds = 590
        reloadedWOD.notes = "typo fix"
        let secondInput = baseInput(client: client, blocks: reloaded.blocks, existingSessionID: firstOutput.session.id, finishing: true)
        guard case .success = SessionCommitService.commit(secondInput, in: context) else { return XCTFail() }
        let secondPayload = try XCTUnwrap(firstOutput.session.orderedBlocks.first?.wodPayload)
        XCTAssertEqual(secondPayload.prescription.id, firstPayload.prescription.id)
        XCTAssertEqual(secondPayload.prescription.revision, firstPayload.prescription.revision, "只改成绩不应该动版本")

        // 再继续编辑：这次改处方本身（负重）。
        let reloadedAgain = SessionDraftLoader.load(from: firstOutput.session, exercises: [exercise])
        guard let reloadedWODAgain = reloadedAgain.blocks.first?.wodDraft else { return XCTFail() }
        reloadedWODAgain.movements[0].loadKg = 50
        let thirdInput = baseInput(client: client, blocks: reloadedAgain.blocks, existingSessionID: firstOutput.session.id, finishing: true)
        guard case .success = SessionCommitService.commit(thirdInput, in: context) else { return XCTFail() }
        let thirdPayload = try XCTUnwrap(firstOutput.session.orderedBlocks.first?.wodPayload)
        XCTAssertEqual(thirdPayload.prescription.id, firstPayload.prescription.id, "同一次训练的身份不变")
        XCTAssertEqual(thirdPayload.prescription.revision, firstPayload.prescription.revision + 1, "改动处方的可比性字段必须跳版本")
    }

    // MARK: - 保存失败：持久化回滚，草稿仍可继续使用

    func testClientMismatchNeverWritesAnything() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let exercise = makeExercise()
        let client = makeClient(in: context)
        let entry = EntryDraft(exercise: exercise, setsCount: 1, load: .absolute(kg: 40, raw: "40"), targetQuantity: 8, actualQuantity: 8)
        let input = SessionCommitService.Input(
            client: client, draftClientID: "cl-someone-else", existingSessionID: nil,
            sessionDateUTC: Date(), newSessionDateRawText: "2023-11-14", weekNumberForNewSession: 1,
            plannedDurationMinutes: 60, blocks: [BlockDraft(entries: [entry])], finishing: true
        )
        guard case .failure(.clientMismatch) = SessionCommitService.commit(input, in: context) else {
            return XCTFail("expected a client-mismatch failure")
        }
        XCTAssertTrue(try context.fetch(FetchDescriptor<WorkoutSession>()).isEmpty, "a blocked commit must not create a session")
    }
}
