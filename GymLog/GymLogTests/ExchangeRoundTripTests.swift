import XCTest
import SwiftData
@testable import GymLogKit

/// P2 (2026-09-11)：教练学员互传的資料正確性——`ExchangeExporter`/
/// `ExchangeImporter` 獨立於 `BackupExporter`/`BackupImporter`，用真實
/// `ModelContext` 驗證計劃/結果的匯出→匯入往返、冪等、內容變化偵測（簡化版
/// ——保留本地）、動作解析（內置 id 直接命中／自定義同名不同單位不誤判）、
/// 大小限制、未知格式版本拒絕、學員映射記憶。真正的兩台真機互傳無法在這個
/// 環境驗證（見 `工程记录.md` P2 一節的驗收缺口）；這裡驗證的是這些互動
/// 最終會產生的資料形狀能不能正確存、取、去重。
@MainActor
final class ExchangeRoundTripTests: XCTestCase {

    private func makeExercise(id: String, name: String, metric: RecordingMetric = .reps, equipment: Equipment = .barbell) -> Exercise {
        Exercise(
            id: id, canonicalName: name, aliases: [], movementPattern: .push, equipment: equipment,
            loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 0, needsReview: false, reviewReason: nil,
            recordingMetric: metric
        )
    }

    /// `ExchangeExporter.stableRemoteClientID(for:)` caches its result in
    /// real `UserDefaults`, keyed by `client.id` -- a fixed literal id
    /// reused across test methods (or across repeated runs of this same
    /// suite on the same simulator) would silently reuse a PRIOR run's
    /// cached value and `ExchangeClientMapping` entry, defeating exactly
    /// the "first import has no mapping yet" assertions below. A fresh
    /// UUID-based id per call sidesteps that entirely rather than trying to
    /// reset `UserDefaults` state between tests.
    private func makeClient(in context: ModelContext, id: String = "cl-sender-\(UUID().uuidString)") -> Client {
        let client = Client(id: id, name: "Sender Client")
        context.insert(client)
        return client
    }

    // MARK: - 計劃匯出→匯入：目標保留、實際清空、落成待訓練草稿

    func testPlanExportImportStripsActualsAndLandsAsInProgress() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let bench = makeExercise(id: "ex-bench", name: "Bench Press")
        context.insert(bench)
        let client = makeClient(in: context)

        let entry = EntryDraft(exercise: bench, setsCount: 3, load: .absolute(kg: 40, raw: "40"), targetQuantity: 10, actualQuantity: 10)
        let block = BlockDraft(blockType: .single, entries: [entry])

        let package = ExchangeExporter.buildPlanPackage(
            blocks: [block], client: client, trainingDate: Date(timeIntervalSince1970: 1_700_000_000),
            weekNumber: 3, plannedDurationMinutes: 45, existingSessionID: nil
        )
        XCTAssertEqual(package.payloadKind, .plan)
        XCTAssertEqual(package.sessions.count, 1)
        XCTAssertTrue(package.sessions[0].blocks[0].entries[0].sets.allSatisfy { $0.actual == nil }, "計劃包裡每一組的 actual 都必須是 nil，不能帶著草稿裡目前的預設值一起分享出去")

        // 接收端：另一个 client，导入到它自己的 context。
        let destContainer = try TestSupport.makeInMemoryContainer()
        let destContext = ModelContext(destContainer)
        destContext.insert(bench)
        let destClient = Client(id: "cl-receiver", name: "Receiver Client")
        destContext.insert(destClient)

        let result = try ExchangeImporter.commit(package, targetClientID: destClient.id, in: destContext)
        XCTAssertEqual(result.sessionsWritten, 1)

        let sessions = try destContext.fetch(FetchDescriptor<WorkoutSession>())
        XCTAssertEqual(sessions.count, 1)
        let imported = try XCTUnwrap(sessions.first)
        XCTAssertTrue(imported.isInProgress, "計劃匯入必須落成 isInProgress=true，才能被既有的「繼續未完成課次」機制撿到")
        let setLog = try XCTUnwrap(imported.orderedBlocks.first?.orderedEntries.first?.orderedSets.first)
        XCTAssertEqual(setLog.target, .fixed(value: 10, raw: "10"))
        XCTAssertEqual(setLog.actual, setLog.target, "沒有實際成績時，actual 應該落回跟 target 相同的預設值（跟普通新建 entry 的既有慣例一致），不是憑空造一個假成績")
    }

    // MARK: - 結果匯出→匯入：完整往返

    func testResultsExportImportRoundTripsCompletely() throws {
        let sourceContainer = try TestSupport.makeInMemoryContainer()
        let sourceContext = ModelContext(sourceContainer)
        let bench = makeExercise(id: "ex-bench", name: "Bench Press")
        sourceContext.insert(bench)
        let client = makeClient(in: sourceContext)

        let session = WorkoutSession(id: "se-1", date: Date(timeIntervalSince1970: 1_700_000_000), dateOrigin: .asRecorded, dateRaw: "2023-11-14", weekNumber: 5, sourceSheet: "App", sourceRow: 0)
        session.client = client
        sourceContext.insert(session)
        let block = SessionBlock(order: 0, blockType: .single, sourceRow: 0)
        block.session = session
        sourceContext.insert(block)
        let entry = ExerciseEntry(order: 0, exerciseIdRef: bench.id, exerciseRaw: bench.canonicalName, plannedSets: 3, exercise: bench)
        entry.block = block
        sourceContext.insert(entry)
        let setLog = SetLog(setIndex: 0, load: .absolute(kg: 60, raw: "60"), target: .fixed(value: 8, raw: "8"), actual: .fixed(value: 7, raw: "7"), isInferred: false)
        setLog.entry = entry
        sourceContext.insert(setLog)

        let package = ExchangeExporter.buildResultsPackage(sessions: [session], client: client)
        XCTAssertEqual(package.payloadKind, .results)
        XCTAssertEqual(package.sessions[0].blocks[0].entries[0].sets[0].actual, .fixed(value: 7, raw: "7"))

        let destContainer = try TestSupport.makeInMemoryContainer()
        let destContext = ModelContext(destContainer)
        destContext.insert(bench)
        let destClient = Client(id: "cl-receiver", name: "Receiver")
        destContext.insert(destClient)

        let result = try ExchangeImporter.commit(package, targetClientID: destClient.id, in: destContext)
        XCTAssertEqual(result.sessionsWritten, 1)
        let imported = try XCTUnwrap(try destContext.fetch(FetchDescriptor<WorkoutSession>()).first)
        XCTAssertFalse(imported.isInProgress, "結果匯入是已完成的記錄")
        XCTAssertEqual(imported.orderedBlocks.first?.orderedEntries.first?.orderedSets.first?.actual, .fixed(value: 7, raw: "7"))
        XCTAssertEqual(imported.sourcePlanID, session.sourcePlanID)
    }

    // MARK: - 冪等：同一個包導入兩次

    func testReimportingTheSamePackageIsIdempotent() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let bench = makeExercise(id: "ex-bench", name: "Bench Press")
        context.insert(bench)
        let client = makeClient(in: context)
        let target = Client(id: "cl-target", name: "Target")
        context.insert(target)

        let entry = EntryDraft(exercise: bench, setsCount: 3, load: .absolute(kg: 40, raw: "40"), targetQuantity: 10, actualQuantity: 10)
        let block = BlockDraft(blockType: .single, entries: [entry])
        let package = ExchangeExporter.buildPlanPackage(blocks: [block], client: client, trainingDate: Date(), weekNumber: 1, plannedDurationMinutes: nil, existingSessionID: nil)

        let first = try ExchangeImporter.commit(package, targetClientID: target.id, in: context)
        XCTAssertEqual(first.sessionsWritten, 1)

        let second = try ExchangeImporter.commit(package, targetClientID: target.id, in: context)
        XCTAssertEqual(second.sessionsWritten, 0, "同一個包重複匯入不能再新增一條記錄")
        XCTAssertEqual(second.sessionsSkippedIdempotent, 1)

        let allSessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        XCTAssertEqual(allSessions.count, 1, "重複匯入後資料庫裡只能有一條課次")
    }

    // MARK: - 內容變化：保留本地版本

    func testContentChangedKeepsLocalVersionAndReportsSkip() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let bench = makeExercise(id: "ex-bench", name: "Bench Press")
        context.insert(bench)
        let client = makeClient(in: context)
        let target = Client(id: "cl-target", name: "Target")
        context.insert(target)

        let entry1 = EntryDraft(exercise: bench, setsCount: 3, load: .absolute(kg: 40, raw: "40"), targetQuantity: 10, actualQuantity: 10)
        let block1 = BlockDraft(blockType: .single, entries: [entry1])
        let sessionID = "se-shared-plan"
        let firstPackage = ExchangeExporter.buildPlanPackage(blocks: [block1], client: client, trainingDate: Date(), weekNumber: 1, plannedDurationMinutes: nil, existingSessionID: sessionID)
        try ExchangeImporter.commit(firstPackage, targetClientID: target.id, in: context)

        // 同一個 recordID，但目標次數改了——模擬「發件人後來改了計劃又重新分享」。
        let entry2 = EntryDraft(exercise: bench, setsCount: 3, load: .absolute(kg: 40, raw: "40"), targetQuantity: 12, actualQuantity: 12)
        let block2 = BlockDraft(blockType: .single, entries: [entry2])
        let secondPackage = ExchangeExporter.buildPlanPackage(blocks: [block2], client: client, trainingDate: Date(), weekNumber: 1, plannedDurationMinutes: nil, existingSessionID: sessionID)
        let result = try ExchangeImporter.commit(secondPackage, targetClientID: target.id, in: context)

        XCTAssertEqual(result.sessionsWritten, 0)
        XCTAssertEqual(result.sessionsSkippedContentChanged, 1)
        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.orderedBlocks.first?.orderedEntries.first?.orderedSets.first?.target, .fixed(value: 10, raw: "10"), "內容變化時必須保留本機原本的值（10），不能被新內容（12）覆蓋")
    }

    // MARK: - 動作解析：內置 id 直接命中；自定義同名不同單位不誤判

    func testExerciseResolutionMatchesByIDAndNeverMergesDifferentUnitsSameName() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        // 接收端已经有一个同名但记录单位不同的自定义动作。
        let localCustom = makeExercise(id: "ex-local-abc", name: "農夫走路", metric: .distance)
        context.insert(localCustom)
        let client = Client(id: "cl-target", name: "Target")
        context.insert(client)

        // 發件人的動作：同名「農夫走路」，但記錄單位是次數（不同單位）。
        let senderExercise = makeExercise(id: "ex-sender-xyz", name: "農夫走路", metric: .reps)
        let entryRef = ExchangeExerciseRef(exerciseID: senderExercise.id, canonicalName: "農夫走路", nameZh: "", recordingMetric: .reps, equipment: .other)
        let setDTO = ExchangeSetDTO(setIndex: 0, load: .bodyweight(raw: "BW"), target: .fixed(value: 10, raw: "10"), actual: nil)
        let entryDTO = ExchangeEntryDTO(order: 0, exerciseRef: entryRef, plannedSets: 1, sets: [setDTO])
        let blockDTO = ExchangeBlockDTO(order: 0, blockType: .single, restSeconds: nil, sectionKind: .strength, entries: [entryDTO], wodPayloadRawJSON: nil)
        let sessionDTO = ExchangeSessionDTO(recordID: "se-1", sourcePlanID: nil, trainingLocalDate: "2026-09-11", weekNumber: 1, plannedDurationMinutes: nil, blocks: [blockDTO])
        let snapshot = ExchangeExerciseSnapshot(
            id: senderExercise.id, canonicalName: "農夫走路", nameZh: "", aliases: [], movementPattern: .carry, equipment: .other,
            recordingMetric: .reps, discipline: .strength, loadDirection: .higherIsStronger, isUnilateral: false
        )
        let clientRef = ExchangeClientRef(remoteClientID: "remote-client-1", displayName: "Sender")
        let digest = ExchangeDigest.compute(payloadKind: .plan, client: clientRef, sessions: [sessionDTO], exercises: [snapshot])
        let package = ExchangePackage(
            packageID: UUID().uuidString, createdAt: Date(), originInstallationID: "origin-1", payloadKind: .plan,
            client: clientRef, sessions: [sessionDTO], exercises: [snapshot], contentDigestSHA256: digest
        )

        let preview = try ExchangeImporter.preview(package, in: context)
        let resolution = try XCTUnwrap(preview.exerciseResolutions.first)
        XCTAssertEqual(resolution.kind, .willCreate, "同名但單位不同的自定義動作絕不能被判定為同一個，必須走新建")

        let result = try ExchangeImporter.commit(package, targetClientID: client.id, in: context)
        XCTAssertEqual(result.exercisesCreated, 1)
        let allExercises = try context.fetch(FetchDescriptor<Exercise>())
        XCTAssertEqual(allExercises.count, 2, "新建的動作必須是獨立的第二條記錄，不能覆蓋/合併本機原有的「農夫走路」")
    }

    func testExerciseResolutionMatchesBuiltInByStableID() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let bench = makeExercise(id: "ex-bench-builtin", name: "Bench Press")
        context.insert(bench)
        let client = Client(id: "cl-target", name: "Target")
        context.insert(client)

        let ref = ExchangeExerciseRef(exerciseID: "ex-bench-builtin", canonicalName: "Bench Press", nameZh: "", recordingMetric: .reps, equipment: .barbell)
        let setDTO = ExchangeSetDTO(setIndex: 0, load: .absolute(kg: 40, raw: "40"), target: .fixed(value: 10, raw: "10"), actual: nil)
        let entryDTO = ExchangeEntryDTO(order: 0, exerciseRef: ref, plannedSets: 1, sets: [setDTO])
        let blockDTO = ExchangeBlockDTO(order: 0, blockType: .single, restSeconds: nil, sectionKind: .strength, entries: [entryDTO], wodPayloadRawJSON: nil)
        let sessionDTO = ExchangeSessionDTO(recordID: "se-1", sourcePlanID: nil, trainingLocalDate: "2026-09-11", weekNumber: 1, plannedDurationMinutes: nil, blocks: [blockDTO])
        let clientRef = ExchangeClientRef(remoteClientID: "remote-1", displayName: "Sender")
        let digest = ExchangeDigest.compute(payloadKind: .plan, client: clientRef, sessions: [sessionDTO], exercises: [])
        let package = ExchangePackage(packageID: UUID().uuidString, createdAt: Date(), originInstallationID: "origin-1", payloadKind: .plan, client: clientRef, sessions: [sessionDTO], exercises: [], contentDigestSHA256: digest)

        let preview = try ExchangeImporter.preview(package, in: context)
        XCTAssertEqual(preview.exerciseResolutions.first?.kind, .matchedByID)

        let result = try ExchangeImporter.commit(package, targetClientID: client.id, in: context)
        XCTAssertEqual(result.exercisesCreated, 0, "內置動作按 id 直接命中，不應該新建")
    }

    // MARK: - 大小/課次數上限

    func testValidateStructureRejectsTooManySessions() throws {
        let clientRef = ExchangeClientRef(remoteClientID: "r1", displayName: "X")
        let sessions = (0..<(ExchangeImporter.maxSessionCount + 1)).map { i in
            ExchangeSessionDTO(recordID: "se-\(i)", sourcePlanID: nil, trainingLocalDate: "2026-09-11", weekNumber: 1, plannedDurationMinutes: nil, blocks: [])
        }
        let digest = ExchangeDigest.compute(payloadKind: .plan, client: clientRef, sessions: sessions, exercises: [])
        let package = ExchangePackage(packageID: "p1", createdAt: Date(), originInstallationID: "o1", payloadKind: .plan, client: clientRef, sessions: sessions, exercises: [], contentDigestSHA256: digest)
        let data = try Self.iso8601Encoder.encode(package)
        XCTAssertThrowsError(try ExchangeImporter.parse(data)) { error in
            guard case ExchangeImporter.ImportError.invalidData = error else { return XCTFail("expected invalidData, got \(error)") }
        }
    }

    // MARK: - 未知更高 formatVersion 拒絕

    func testParseRejectsNewerFormatVersion() throws {
        let clientRef = ExchangeClientRef(remoteClientID: "r1", displayName: "X")
        let package = ExchangePackage(
            formatVersion: ExchangePackage.currentFormatVersion + 1, packageID: "p1", createdAt: Date(), originInstallationID: "o1",
            payloadKind: .plan, client: clientRef, sessions: [], exercises: [], contentDigestSHA256: "x"
        )
        let data = try Self.iso8601Encoder.encode(package)
        XCTAssertThrowsError(try ExchangeImporter.parse(data)) { error in
            guard case ExchangeImporter.ImportError.unsupportedFormatVersion = error else { return XCTFail("expected unsupportedFormatVersion, got \(error)") }
        }
    }

    /// `ExchangeImporter.parse` decodes with `.iso8601` -- a plain
    /// `JSONEncoder()` defaults to encoding `Date` as a raw number, which
    /// would fail decoding for a reason unrelated to whatever this test is
    /// actually checking.
    private static let iso8601Encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    // MARK: - 學員映射：記憶已選過的對應關係

    func testClientMappingIsRememberedAcrossImports() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let bench = makeExercise(id: "ex-bench", name: "Bench Press")
        context.insert(bench)
        let client = makeClient(in: context)
        let target = Client(id: "cl-target", name: "Target")
        context.insert(target)

        let entry = EntryDraft(exercise: bench, setsCount: 1, load: .absolute(kg: 40, raw: "40"), targetQuantity: 10, actualQuantity: 10)
        let block = BlockDraft(blockType: .single, entries: [entry])
        let package = ExchangeExporter.buildPlanPackage(blocks: [block], client: client, trainingDate: Date(), weekNumber: 1, plannedDurationMinutes: nil, existingSessionID: nil)

        let firstPreview = try ExchangeImporter.preview(package, in: context)
        XCTAssertNil(firstPreview.mappedLocalClientID, "第一次匯入這個遠程學員時不應該有現成的映射")

        _ = try ExchangeImporter.commit(package, targetClientID: target.id, in: context)

        // 再匯出一次（新的一份計劃，同一個 remoteClientID，因為 stableRemoteClientID 按 sender 本地 client.id 缓存）。
        let entry2 = EntryDraft(exercise: bench, setsCount: 1, load: .absolute(kg: 45, raw: "45"), targetQuantity: 8, actualQuantity: 8)
        let block2 = BlockDraft(blockType: .single, entries: [entry2])
        let package2 = ExchangeExporter.buildPlanPackage(blocks: [block2], client: client, trainingDate: Date(), weekNumber: 2, plannedDurationMinutes: nil, existingSessionID: nil)
        XCTAssertEqual(package.client.remoteClientID, package2.client.remoteClientID, "同一個發件端 Client 兩次匯出的 remoteClientID 必須穩定不變")

        let secondPreview = try ExchangeImporter.preview(package2, in: context)
        XCTAssertEqual(secondPreview.mappedLocalClientID, target.id, "已經確認過的映射必須在下一次匯入時自動預選")
    }
}
