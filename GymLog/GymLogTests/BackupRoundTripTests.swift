import XCTest
import SwiftData
@testable import GymLogKit

/// 完整备份与恢复（2026-09-06 审查报告"适合当前范围的功能"第一批）：round-trips
/// a full object graph (client + assessment + body metric + session/block/
/// entry/set + exercise + template) through `BackupExporter` ->
/// `BackupImporter`, against real SwiftData `ModelContext`s -- the same
/// "build a real graph, exercise the real seam" approach as
/// `M3ExerciseHistoryAnalyzerTests`/`SeedImporterTests`.
final class BackupRoundTripTests: XCTestCase {

    /// Builds one of everything: a client with a assessment, a body metric,
    /// one session (one block, one entry, two sets), plus a standalone
    /// exercise and a session template referencing it.
    private func makeFullGraph(in context: ModelContext) throws -> (client: Client, exercise: Exercise, template: SessionTemplate) {
        let exercise = Exercise(
            id: "ex-bench", canonicalName: "Bench press", aliases: ["Bench"], movementPattern: .push,
            equipment: .barbell, loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 1,
            needsReview: false, reviewReason: nil, recordingMetric: .reps, nameZh: "臥推", notes: "notes"
        )
        context.insert(exercise)

        let client = Client(
            id: "cl-1", name: "Test Client", phone: "12345", gender: "F", age: 30, heightCm: 165,
            startWeightKg: 60, goal: "goal", frequency: "3x", bmr: 1400, tdee: 2000, habits: "habits", medicalHistory: "history"
        )
        context.insert(client)

        let assessment = Assessment(id: "as-1", pattern: .squat, date: Date(timeIntervalSince1970: 1_700_000_000), level: "L2", notes: "assess notes")
        assessment.client = client
        context.insert(assessment)

        let bodyMetric = BodyMetric(
            id: "bm-1", date: Date(timeIntervalSince1970: 1_700_100_000), weightKg: 59.5, bodyFatPercent: 22.1,
            skeletalMuscleKg: 24.3, bmi: 21.8, visceralFatLevel: 5, bmr: 1390, tdee: 1980, bodyFatMassKg: 13.1, notes: "bm notes"
        )
        bodyMetric.client = client
        context.insert(bodyMetric)

        let session = WorkoutSession(
            id: "se-1", date: Date(timeIntervalSince1970: 1_700_200_000), dateOrigin: .asRecorded, dateRaw: "2023-11-16",
            weekNumber: 3, sourceSheet: "Test", sourceRow: 1, needsReview: false, reviewReason: nil,
            warmup: "warmup", warmupNote: "wnote", cooldown: "cooldown", cooldownNote: "cnote", plannedDurationMinutes: 60
        )
        session.client = client
        session.importSourceFile = "test.xlsx"
        session.importedAt = Date(timeIntervalSince1970: 1_700_200_100)
        session.sourceDigest = "digest-a"
        session.importDigest = "digest-b"
        context.insert(session)

        let block = SessionBlock(order: 0, blockType: .single, restSeconds: 90, restRaw: "90s", note: "block note", sourceRow: 1)
        block.session = session
        context.insert(block)

        let entry = ExerciseEntry(order: 0, exerciseIdRef: exercise.id, exerciseRaw: exercise.canonicalName, plannedSets: 2, exercise: exercise)
        entry.block = block
        context.insert(entry)

        let set0 = SetLog(setIndex: 0, load: .absolute(kg: 50, raw: "50"), target: .fixed(value: 8, raw: "8"), actual: .fixed(value: 8, raw: "8"), isInferred: false)
        set0.entry = entry
        context.insert(set0)
        let set1 = SetLog(setIndex: 1, load: .absolute(kg: 52.5, raw: "52.5"), target: .fixed(value: 6, raw: "6"), actual: .fixed(value: 7, raw: "7"), isInferred: false)
        set1.entry = entry
        context.insert(set1)

        let template = SessionTemplate(id: "tmpl-1", name: "Push Day", templateNote: "tnote", order: 0)
        context.insert(template)
        let templateBlock = TemplateBlock(id: "tb-1", order: 0, blockType: .single, restSeconds: 60)
        templateBlock.template = template
        context.insert(templateBlock)
        let slot = TemplateExerciseSlot(id: "ts-1", order: 0, exerciseID: exercise.id, defaultSets: 3, defaultRepTarget: .fixed(value: 10, raw: "10"))
        slot.block = templateBlock
        context.insert(slot)

        try context.save()
        return (client, exercise, template)
    }

    // MARK: - Round trip into a fresh (empty) store

    func testExportThenRestoreIntoFreshStoreReproducesFullGraph() throws {
        let sourceContainer = try TestSupport.makeInMemoryContainer()
        let sourceContext = ModelContext(sourceContainer)
        _ = try makeFullGraph(in: sourceContext)

        let backup = try BackupExporter.makeBackup(from: sourceContext)
        XCTAssertEqual(backup.counts, BackupCounts(clientCount: 1, exerciseCount: 1, sessionCount: 1, entryCount: 1, setLogCount: 2, templateCount: 1))

        // Round-trip through actual JSON bytes, not just the in-memory DTO,
        // so date encoding/decoding is genuinely exercised.
        let data = try BackupExporter.data(from: sourceContext)
        let parsed = try BackupImporter.parse(data)
        XCTAssertEqual(parsed.counts, backup.counts)

        let destContainer = try TestSupport.makeInMemoryContainer()
        let destContext = ModelContext(destContainer)
        let result = try BackupImporter.restore(parsed, into: destContext)
        XCTAssertEqual(result.clientsWritten, 1)
        XCTAssertEqual(result.exercisesWritten, 1)
        XCTAssertEqual(result.sessionsWritten, 1)
        XCTAssertEqual(result.templatesWritten, 1)

        let restoredClients = try destContext.fetch(FetchDescriptor<Client>())
        XCTAssertEqual(restoredClients.count, 1)
        let client = try XCTUnwrap(restoredClients.first)
        XCTAssertEqual(client.name, "Test Client")
        XCTAssertEqual(client.phone, "12345")
        XCTAssertEqual(client.assessments?.count, 1)
        XCTAssertEqual(client.assessments?.first?.pattern, .squat)
        XCTAssertEqual(client.bodyMetrics?.count, 1)
        XCTAssertEqual(client.bodyMetrics?.first?.bodyFatMassKg, 13.1, "bodyFatMassKg must round-trip even though SeedImporter's own construction path never sets it.")

        let sessions = try destContext.fetch(FetchDescriptor<WorkoutSession>())
        XCTAssertEqual(sessions.count, 1)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.id, "se-1")
        XCTAssertEqual(session.sourceDigest, "digest-a")
        XCTAssertEqual(session.importDigest, "digest-b")
        XCTAssertEqual(session.orderedBlocks.count, 1)
        let block = try XCTUnwrap(session.orderedBlocks.first)
        XCTAssertEqual(block.restSeconds, 90)
        XCTAssertEqual(block.orderedEntries.count, 1)
        let entry = try XCTUnwrap(block.orderedEntries.first)
        XCTAssertEqual(entry.exercise?.id, "ex-bench")
        XCTAssertEqual(entry.orderedSets.count, 2)
        guard case .absolute(let kg, _) = entry.orderedSets[0].load else { return XCTFail("expected .absolute") }
        XCTAssertEqual(kg, 50)

        let templates = try destContext.fetch(FetchDescriptor<SessionTemplate>())
        XCTAssertEqual(templates.count, 1)
        XCTAssertEqual(templates.first?.orderedBlocks.first?.orderedSlots.first?.exerciseID, "ex-bench")
    }

    // MARK: - Restore is upsert, not additive-duplicate, and never deletes local-only data

    func testRestoringTwiceDoesNotDuplicate() throws {
        let sourceContainer = try TestSupport.makeInMemoryContainer()
        let sourceContext = ModelContext(sourceContainer)
        _ = try makeFullGraph(in: sourceContext)
        let backup = try BackupExporter.makeBackup(from: sourceContext)

        let destContainer = try TestSupport.makeInMemoryContainer()
        let destContext = ModelContext(destContainer)
        try BackupImporter.restore(backup, into: destContext)
        try BackupImporter.restore(backup, into: destContext)

        XCTAssertEqual(try destContext.fetch(FetchDescriptor<Client>()).count, 1)
        XCTAssertEqual(try destContext.fetch(FetchDescriptor<WorkoutSession>()).count, 1)
        XCTAssertEqual(try destContext.fetch(FetchDescriptor<Exercise>()).count, 1)
        XCTAssertEqual(try destContext.fetch(FetchDescriptor<SessionTemplate>()).count, 1)
        let entries = try destContext.fetch(FetchDescriptor<ExerciseEntry>())
        XCTAssertEqual(entries.count, 1, "Rebuilding a matched session's block/entry/set subtree twice must not leave duplicate entries behind.")
    }

    func testRestoreNeverDeletesLocalOnlyData() throws {
        let destContainer = try TestSupport.makeInMemoryContainer()
        let destContext = ModelContext(destContainer)
        let localOnlyClient = Client(id: "cl-local-only", name: "Local Only Client")
        destContext.insert(localOnlyClient)
        try destContext.save()

        let sourceContainer = try TestSupport.makeInMemoryContainer()
        let sourceContext = ModelContext(sourceContainer)
        _ = try makeFullGraph(in: sourceContext)
        let backup = try BackupExporter.makeBackup(from: sourceContext)

        try BackupImporter.restore(backup, into: destContext)

        let allClients = try destContext.fetch(FetchDescriptor<Client>())
        XCTAssertEqual(allClients.count, 2, "The pre-existing local client must survive a restore that doesn't mention it.")
        XCTAssertTrue(allClients.contains { $0.id == "cl-local-only" })
        XCTAssertTrue(allClients.contains { $0.id == "cl-1" })
    }

    func testUpsertOverwritesFieldsForMatchingID() throws {
        let destContainer = try TestSupport.makeInMemoryContainer()
        let destContext = ModelContext(destContainer)
        let client = Client(id: "cl-1", name: "Old Name")
        destContext.insert(client)
        try destContext.save()

        let sourceContainer = try TestSupport.makeInMemoryContainer()
        let sourceContext = ModelContext(sourceContainer)
        _ = try makeFullGraph(in: sourceContext)
        let backup = try BackupExporter.makeBackup(from: sourceContext)

        try BackupImporter.restore(backup, into: destContext)

        let clients = try destContext.fetch(FetchDescriptor<Client>())
        XCTAssertEqual(clients.count, 1)
        XCTAssertEqual(clients.first?.name, "Test Client", "An existing client matched by id must be overwritten with the backup's field values, not left stale.")
    }

    // MARK: - Preview (dry run)

    func testPreviewReportsNewVsUpdatedWithoutWriting() throws {
        let destContainer = try TestSupport.makeInMemoryContainer()
        let destContext = ModelContext(destContainer)
        let existingClient = Client(id: "cl-1", name: "Stale Name")
        destContext.insert(existingClient)
        try destContext.save()

        let sourceContainer = try TestSupport.makeInMemoryContainer()
        let sourceContext = ModelContext(sourceContainer)
        _ = try makeFullGraph(in: sourceContext)
        let backup = try BackupExporter.makeBackup(from: sourceContext)

        let preview = try BackupImporter.preview(backup, in: destContext)
        XCTAssertEqual(preview.updatedClients, 1)
        XCTAssertEqual(preview.newClients, 0)
        XCTAssertEqual(preview.newExercises, 1)
        XCTAssertEqual(preview.newSessions, 1)
        XCTAssertEqual(preview.newTemplates, 1)

        // Nothing should actually have been written by a preview.
        XCTAssertEqual(try destContext.fetch(FetchDescriptor<Client>()).count, 1)
        XCTAssertEqual(try destContext.fetch(FetchDescriptor<Client>()).first?.name, "Stale Name", "preview() must not mutate the store.")
        XCTAssertEqual(try destContext.fetch(FetchDescriptor<Exercise>()).count, 0)
    }

    // MARK: - Corruption / version guards

    func testParseRejectsCorruptedCounts() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try makeFullGraph(in: context)
        var backup = try BackupExporter.makeBackup(from: context)
        // Simulate truncation: counts still say 1 session, but the client's
        // sessions array is now empty.
        backup.clients[0].sessions = []

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(backup)

        XCTAssertThrowsError(try BackupImporter.parse(data)) { error in
            guard case BackupImporter.ImportError.corruptCounts = error else {
                return XCTFail("expected .corruptCounts, got \(error)")
            }
        }
    }

    /// 2026-09-07 审阅 B05: the audit's diagnostic test showed a duplicate
    /// client id passing count validation (2 declared, 2 found -- the count
    /// check alone can never catch a duplicate, since the count is right
    /// either way) and restore silently coalescing them into one record.
    /// The corrected expectation is that `parse` refuses the file outright.
    func testParseRejectsDuplicateClientIDs() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try makeFullGraph(in: context)
        var backup = try BackupExporter.makeBackup(from: context)
        backup.clients.append(backup.clients[0])
        backup.counts = BackupCounts.compute(exercises: backup.exercises, clients: backup.clients, templates: backup.templates)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(backup)

        XCTAssertThrowsError(try BackupImporter.parse(data)) { error in
            guard case BackupImporter.ImportError.invalidData = error else {
                return XCTFail("expected .invalidData for a duplicate client id, got \(error)")
            }
        }
    }

    func testParseRejectsDuplicateSetIndexWithinAnEntry() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try makeFullGraph(in: context)
        var backup = try BackupExporter.makeBackup(from: context)
        // Two sets both claiming setIndex 0 within the same entry.
        backup.clients[0].sessions[0].blocks[0].entries[0].sets[1] = SetLogBackupDTO(
            setIndex: 0, load: .absolute(kg: 52.5, raw: "52.5"), target: .fixed(value: 6, raw: "6"), actual: .fixed(value: 7, raw: "7"), isInferred: false
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(backup)

        XCTAssertThrowsError(try BackupImporter.parse(data)) { error in
            guard case BackupImporter.ImportError.invalidData = error else {
                return XCTFail("expected .invalidData for a duplicate setIndex, got \(error)")
            }
        }
    }

    func testParseRejectsNegativeSchemaVersion() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try makeFullGraph(in: context)
        var backup = try BackupExporter.makeBackup(from: context)
        backup.schemaVersion = -1

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(backup)

        XCTAssertThrowsError(try BackupImporter.parse(data)) { error in
            guard case BackupImporter.ImportError.unsupportedSchemaVersion = error else {
                return XCTFail("expected .unsupportedSchemaVersion for a negative version, got \(error)")
            }
        }
    }

    // MARK: - B06 (2026-09-07 审阅): ownership conflicts

    /// The audit's diagnostic test showed a session restored from A's
    /// backup keeping B's (the LOCAL, pre-restore) ownership while still
    /// overwriting the content -- worst of both. The corrected expectation:
    /// by default, a conflicting session is skipped entirely (neither
    /// ownership nor content changes), and the conflict is surfaced in
    /// `preview` beforehand.
    func testRestoreSkipsConflictingSessionOwnershipByDefault() throws {
        let destContainer = try TestSupport.makeInMemoryContainer()
        let destContext = ModelContext(destContainer)
        let clientB = Client(id: "cl-b", name: "B")
        destContext.insert(clientB)
        let localSession = WorkoutSession(id: "se-1", date: Date(timeIntervalSince1970: 1_600_000_000), dateOrigin: .asRecorded, dateRaw: "local", weekNumber: 1, sourceSheet: "App", sourceRow: 0)
        localSession.client = clientB
        destContext.insert(localSession)
        try destContext.save()

        let sourceContainer = try TestSupport.makeInMemoryContainer()
        let sourceContext = ModelContext(sourceContainer)
        let clientA = Client(id: "cl-a", name: "A")
        sourceContext.insert(clientA)
        let backupSession = WorkoutSession(id: "se-1", date: Date(timeIntervalSince1970: 1_700_300_000), dateOrigin: .asRecorded, dateRaw: "backup", weekNumber: 5, sourceSheet: "App", sourceRow: 0)
        backupSession.client = clientA
        sourceContext.insert(backupSession)
        try sourceContext.save()
        let backup = try BackupExporter.makeBackup(from: sourceContext)

        let preview = try BackupImporter.preview(backup, in: destContext)
        XCTAssertEqual(preview.ownershipConflicts, [BackupImporter.OwnershipConflict(sessionID: "se-1", localClientID: "cl-b", backupClientID: "cl-a")])

        let result = try BackupImporter.restore(backup, into: destContext)
        XCTAssertEqual(result.sessionsSkippedDueToOwnershipConflict, 1)
        XCTAssertEqual(result.sessionsWritten, 0)

        let survivor = try XCTUnwrap(destContext.fetch(FetchDescriptor<WorkoutSession>()).first)
        XCTAssertEqual(survivor.client?.id, "cl-b", "ownership must not silently change on an unresolved conflict")
        XCTAssertEqual(survivor.weekNumber, 1, "content must not be overwritten either, when ownership conflicts and wasn't explicitly resolved")
    }

    /// Explicitly approving a specific session's id in
    /// `reassignSessionOwnership` (what the coach would do after reviewing
    /// `preview`'s `ownershipConflicts`) adopts the backup's ownership AND
    /// content for that session, and only that session.
    func testRestoreAppliesExplicitlyApprovedOwnershipReassignment() throws {
        let destContainer = try TestSupport.makeInMemoryContainer()
        let destContext = ModelContext(destContainer)
        let clientB = Client(id: "cl-b", name: "B")
        destContext.insert(clientB)
        let localSession = WorkoutSession(id: "se-1", date: Date(timeIntervalSince1970: 1_600_000_000), dateOrigin: .asRecorded, dateRaw: "local", weekNumber: 1, sourceSheet: "App", sourceRow: 0)
        localSession.client = clientB
        destContext.insert(localSession)
        try destContext.save()

        let sourceContainer = try TestSupport.makeInMemoryContainer()
        let sourceContext = ModelContext(sourceContainer)
        let clientA = Client(id: "cl-a", name: "A")
        sourceContext.insert(clientA)
        let backupSession = WorkoutSession(id: "se-1", date: Date(timeIntervalSince1970: 1_700_300_000), dateOrigin: .asRecorded, dateRaw: "backup", weekNumber: 5, sourceSheet: "App", sourceRow: 0)
        backupSession.client = clientA
        sourceContext.insert(backupSession)
        try sourceContext.save()
        let backup = try BackupExporter.makeBackup(from: sourceContext)

        let result = try BackupImporter.restore(backup, into: destContext, reassignSessionOwnership: ["se-1"])
        XCTAssertEqual(result.sessionsWritten, 1)
        XCTAssertEqual(result.sessionsSkippedDueToOwnershipConflict, 0)

        let survivor = try XCTUnwrap(destContext.fetch(FetchDescriptor<WorkoutSession>()).first)
        XCTAssertEqual(survivor.client?.id, "cl-a")
        XCTAssertEqual(survivor.weekNumber, 5)
    }

    // MARK: - M1 (2026-09-07): WOD payload survives backup export/restore

    func testWODBlockSectionKindAndPayloadRoundTripThroughBackup() throws {
        let sourceContainer = try TestSupport.makeInMemoryContainer()
        let sourceContext = ModelContext(sourceContainer)
        let client = Client(id: "cl-wod", name: "WOD Client")
        sourceContext.insert(client)
        let session = WorkoutSession(id: "se-wod", date: Date(timeIntervalSince1970: 1_700_000_000), dateOrigin: .asRecorded, dateRaw: "raw", weekNumber: 1, sourceSheet: "App", sourceRow: 0)
        session.client = client
        sourceContext.insert(session)
        let block = SessionBlock(order: 0, blockType: .single, sourceRow: 0, sectionKind: .wod)
        block.session = session
        let prescription = WODPrescription(
            id: "wod-1", revision: 1, format: .amrap, timeCapSeconds: 720,
            rounds: [WODRoundPrescription(roundIndex: 0, movements: [
                WODMovementPrescription(stepID: "s1", exerciseID: nil, exerciseNameSnapshot: "Burpee", quantity: .reps(10, raw: "10")),
            ])],
            scoringRule: .roundsAndReps
        )
        block.wodPayload = WODPayload(prescription: prescription, result: WODResult(status: .completed, completedRounds: 5, partialRoundQuantity: .reps(3, raw: "3")))
        sourceContext.insert(block)
        try sourceContext.save()

        let backup = try BackupExporter.makeBackup(from: sourceContext)
        let destContainer = try TestSupport.makeInMemoryContainer()
        let destContext = ModelContext(destContainer)
        try BackupImporter.restore(backup, into: destContext)

        let restoredSession = try XCTUnwrap(destContext.fetch(FetchDescriptor<WorkoutSession>()).first)
        let restoredBlock = try XCTUnwrap(restoredSession.orderedBlocks.first)
        XCTAssertEqual(restoredBlock.sectionKind, .wod)
        XCTAssertEqual(restoredBlock.wodPayload?.prescription.format, .amrap)
        XCTAssertEqual(restoredBlock.wodPayload?.result.completedRounds, 5)
    }

    /// 2026-09-10：多轮处方（21-15-9）+ 这版 UI 没有编辑入口的成绩字段
    /// （`rpe`/`actualMovements`/`recordedVia: .timer`/`intervalResults`）
    /// 一起导出到空库再导入，必须逐字段完整——备份层对 WOD payload 一直是
    /// 原文直通（不解码不重写），所以这条链路本来就该"免费"过，这里用一个
    /// 更复杂的夹具把这个假设钉成一个真正的回归测试。
    func testComplexMultiRoundWODWithFullResultFieldsSurvivesBackupToEmptyStore() throws {
        let sourceContainer = try TestSupport.makeInMemoryContainer()
        let sourceContext = ModelContext(sourceContainer)
        let client = Client(id: "cl-complex-wod", name: "Complex WOD Client")
        sourceContext.insert(client)
        let session = WorkoutSession(id: "se-complex-wod", date: Date(timeIntervalSince1970: 1_700_000_000), dateOrigin: .asRecorded, dateRaw: "raw", weekNumber: 1, sourceSheet: "App", sourceRow: 0)
        session.client = client
        sourceContext.insert(session)
        let block = SessionBlock(order: 0, blockType: .single, sourceRow: 0, sectionKind: .wod)
        block.session = session
        let rounds = [21, 15, 9].enumerated().map { index, reps in
            WODRoundPrescription(roundIndex: index, movements: [
                WODMovementPrescription(
                    stepID: "s\(index)", exerciseID: "ex-thruster", exerciseNameSnapshot: "Thruster",
                    quantity: .reps(reps, raw: "\(reps)"), load: .absolute(kg: 43, raw: "43"), standard: "full depth"
                ),
            ])
        }
        let prescription = WODPrescription(id: "wod-fran", revision: 2, name: "Fran", format: .forTime, timeCapSeconds: 900, rounds: rounds, scoringRule: .completionTime, standardNotes: "2026 Open standards")
        let result = WODResult(
            status: .completed, elapsedSeconds: 431, variant: .rx,
            actualMovements: [WODMovementPrescription(stepID: "s0", exerciseID: nil, exerciseNameSnapshot: "Ring Row (sub)", quantity: .reps(21, raw: "21"))],
            notes: "subbed ring rows on round 1", rpe: 9.0, recordedVia: .timer
        )
        block.wodPayload = WODPayload(prescription: prescription, result: result)
        sourceContext.insert(block)
        try sourceContext.save()

        let backup = try BackupExporter.makeBackup(from: sourceContext)
        let destContainer = try TestSupport.makeInMemoryContainer() // 全新的空库
        let destContext = ModelContext(destContainer)
        try BackupImporter.restore(backup, into: destContext)

        let restoredBlock = try XCTUnwrap(destContext.fetch(FetchDescriptor<WorkoutSession>()).first?.orderedBlocks.first)
        let restoredPayload = try XCTUnwrap(restoredBlock.wodPayload)
        XCTAssertEqual(restoredPayload.prescription.rounds.count, 3, "三轮必须原样都在")
        XCTAssertEqual(restoredPayload.prescription.rounds.map { $0.movements[0].quantity.value }, [21, 15, 9])
        XCTAssertEqual(restoredPayload.prescription.rounds[0].movements[0].standard, "full depth")
        XCTAssertEqual(restoredPayload.prescription.revision, 2)
        XCTAssertEqual(restoredPayload.prescription.standardNotes, "2026 Open standards")
        XCTAssertEqual(restoredPayload.result.rpe, 9.0)
        XCTAssertEqual(restoredPayload.result.recordedVia, .timer)
        XCTAssertEqual(restoredPayload.result.actualMovements.first?.exerciseNameSnapshot, "Ring Row (sub)")
    }

    /// A v1 backup file encoded before `sectionKind`/`wodPayloadRawJSON`
    /// existed on `SessionBlockBackupDTO` (i.e. those keys are simply
    /// absent from the JSON) must still decode and restore -- every
    /// pre-CrossFit block defaults to `.strength` with no WOD data.
    func testPreCrossFitBackupJSONWithoutSectionKindFieldsStillRestores() throws {
        let sourceContainer = try TestSupport.makeInMemoryContainer()
        let sourceContext = ModelContext(sourceContainer)
        _ = try makeFullGraph(in: sourceContext)
        let backup = try BackupExporter.makeBackup(from: sourceContext)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try JSONSerialization.jsonObject(with: encoder.encode(backup)) as! [String: Any]
        // Strip the new keys out of every block, simulating a genuinely
        // old v1 file that predates this field's existence.
        var clients = json["clients"] as! [[String: Any]]
        for ci in clients.indices {
            var sessions = clients[ci]["sessions"] as! [[String: Any]]
            for si in sessions.indices {
                var blocks = sessions[si]["blocks"] as! [[String: Any]]
                for bi in blocks.indices {
                    blocks[bi].removeValue(forKey: "sectionKind")
                    blocks[bi].removeValue(forKey: "wodPayloadRawJSON")
                }
                sessions[si]["blocks"] = blocks
            }
            clients[ci]["sessions"] = sessions
        }
        json["clients"] = clients
        let strippedData = try JSONSerialization.data(withJSONObject: json)

        let parsed = try BackupImporter.parse(strippedData)
        let destContainer = try TestSupport.makeInMemoryContainer()
        let destContext = ModelContext(destContainer)
        try BackupImporter.restore(parsed, into: destContext)

        let restoredBlock = try XCTUnwrap(destContext.fetch(FetchDescriptor<WorkoutSession>()).first?.orderedBlocks.first)
        XCTAssertEqual(restoredBlock.sectionKind, .strength, "a block with no sectionKind key in the backup JSON must default to .strength")
        XCTAssertNil(restoredBlock.wodPayload)
    }

    /// A payload written by a FUTURE app version must round-trip through
    /// backup/restore byte-for-byte, without this build attempting to
    /// decode, modify, or drop it.
    func testUnsupportedFutureWODPayloadRoundTripsVerbatimThroughBackup() throws {
        let sourceContainer = try TestSupport.makeInMemoryContainer()
        let sourceContext = ModelContext(sourceContainer)
        let client = Client(id: "cl-future", name: "Future Client")
        sourceContext.insert(client)
        let session = WorkoutSession(id: "se-future", date: Date(timeIntervalSince1970: 1_700_000_000), dateOrigin: .asRecorded, dateRaw: "raw", weekNumber: 1, sourceSheet: "App", sourceRow: 0)
        session.client = client
        sourceContext.insert(session)
        let block = SessionBlock(order: 0, blockType: .single, sourceRow: 0, sectionKind: .wod)
        block.session = session
        let futureJSON = #"{"schemaVersion":999,"prescription":{"someFutureField":"x"},"result":{}}"#
        block.setWODPayloadRawJSON(futureJSON)
        sourceContext.insert(block)
        try sourceContext.save()

        let backup = try BackupExporter.makeBackup(from: sourceContext)
        let destContainer = try TestSupport.makeInMemoryContainer()
        let destContext = ModelContext(destContainer)
        try BackupImporter.restore(backup, into: destContext)

        let restoredBlock = try XCTUnwrap(destContext.fetch(FetchDescriptor<WorkoutSession>()).first?.orderedBlocks.first)
        XCTAssertNil(restoredBlock.wodPayload, "this build still can't decode it")
        XCTAssertEqual(restoredBlock.wodPayloadRawJSON, futureJSON, "but the bytes must survive the round trip untouched")
    }

    func testParseRejectsNewerSchemaVersion() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        _ = try makeFullGraph(in: context)
        var backup = try BackupExporter.makeBackup(from: context)
        backup.schemaVersion = BackupFile.currentSchemaVersion + 1

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(backup)

        XCTAssertThrowsError(try BackupImporter.parse(data)) { error in
            guard case BackupImporter.ImportError.unsupportedSchemaVersion = error else {
                return XCTFail("expected .unsupportedSchemaVersion, got \(error)")
            }
        }
    }
}
