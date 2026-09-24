import XCTest
import SwiftData
@testable import GymLogKit

/// "打开 → 不改 → 保存" through the full-edit path (`SessionDraftLoader.load`
/// → `SessionCommitService.commit`) must not erase persisted fields the
/// Today editor has no UI for: Excel-imported block notes / rest text / raw
/// exercise names / inferred-set flags, an unrecorded duration, or a WOD this
/// build cannot decode.
@MainActor
final class ImportedSessionEditRoundTripTests: XCTestCase {
    private func makeExercise(id: String, name: String) -> Exercise {
        Exercise(
            id: id, canonicalName: name, aliases: [], movementPattern: .squat, equipment: .barbell,
            loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 0, needsReview: false, reviewReason: nil
        )
    }

    /// An Excel-imported-looking session: no duration, a block note and rest
    /// text, a raw exercise fragment, and three inferred sets.
    private func makeImportedSession(in context: ModelContext, exercise: Exercise) -> (Client, WorkoutSession) {
        let client = Client(id: "cl-1", name: "Test")
        context.insert(client)
        context.insert(exercise)
        let session = WorkoutSession(
            id: "se-import-1", date: Date(timeIntervalSince1970: 1_700_000_000), dateOrigin: .asRecorded,
            dateRaw: "14/11", weekNumber: 3, sourceSheet: "Full body", sourceRow: 40
        )
        session.client = client
        context.insert(session)
        let block = SessionBlock(order: 0, blockType: .single, restSeconds: 90, restRaw: "90s", note: "膝蓋不適，減重", sourceRow: 42)
        block.session = session
        context.insert(block)
        let entry = ExerciseEntry(order: 0, exerciseIdRef: exercise.id, exerciseRaw: "BB squat (heavy)", plannedSets: 3, exercise: exercise)
        entry.block = block
        context.insert(entry)
        for index in 0..<3 {
            let set = SetLog(setIndex: index, load: .absolute(kg: 60, raw: "60"), target: .fixed(value: 10, raw: "10"), actual: .fixed(value: 10, raw: "10"), isInferred: true)
            set.entry = entry
            context.insert(set)
        }
        return (client, session)
    }

    private func resave(_ session: WorkoutSession, client: Client, blocks: [BlockDraft], duration: Int?, in context: ModelContext) throws {
        let input = SessionCommitService.Input(
            client: client, draftClientID: client.id, existingSessionID: session.id, sessionDateUTC: session.date,
            newSessionDateRawText: "", weekNumberForNewSession: 1, plannedDurationMinutes: duration,
            blocks: blocks, finishing: true
        )
        guard case .success = SessionCommitService.commit(input, in: context) else {
            return XCTFail("commit failed")
        }
    }

    func testUntouchedFullEditKeepsImportedFieldsAndUnrecordedDuration() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let exercise = makeExercise(id: "ex-squat", name: "Back Squat")
        let (client, session) = makeImportedSession(in: context, exercise: exercise)
        try context.save()

        let loaded = SessionDraftLoader.load(from: session, exercises: [exercise])
        try resave(session, client: client, blocks: loaded.blocks, duration: session.plannedDurationMinutes, in: context)

        XCTAssertNil(session.plannedDurationMinutes, "an unrecorded duration must not become 60")
        let block = try XCTUnwrap(session.orderedBlocks.first)
        XCTAssertEqual(block.note, "膝蓋不適，減重")
        XCTAssertEqual(block.restRaw, "90s")
        XCTAssertEqual(block.sourceRow, 42)
        let entry = try XCTUnwrap(block.orderedEntries.first)
        XCTAssertEqual(entry.exerciseRaw, "BB squat (heavy)")
        XCTAssertEqual(entry.orderedSets.map(\.isInferred), [true, true, true])
    }

    func testEditsDropOnlyTheSourceFieldsTheyInvalidate() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let exercise = makeExercise(id: "ex-squat", name: "Back Squat")
        let front = makeExercise(id: "ex-front", name: "Front Squat")
        context.insert(front)
        let (client, session) = makeImportedSession(in: context, exercise: exercise)
        try context.save()

        let loaded = SessionDraftLoader.load(from: session, exercises: [exercise, front])
        let blockDraft = try XCTUnwrap(loaded.blocks.first)
        blockDraft.restSeconds = 120
        let entryDraft = try XCTUnwrap(blockDraft.entries.first)
        let splitID = try XCTUnwrap(entryDraft.splitRound(atPhysicalSetIndex: 3))
        let index = try XCTUnwrap(entryDraft.rounds.firstIndex { $0.id == splitID })
        entryDraft.rounds[index].actual = .fixed(value: 8, raw: "8")
        entryDraft.setExercise(front)
        try resave(session, client: client, blocks: loaded.blocks, duration: 45, in: context)

        XCTAssertEqual(session.plannedDurationMinutes, 45)
        let block = try XCTUnwrap(session.orderedBlocks.first)
        XCTAssertEqual(block.note, "膝蓋不適，減重", "notes are independent of the rest value")
        XCTAssertNil(block.restRaw, "stale rest text must not describe the new rest")
        let entry = try XCTUnwrap(block.orderedEntries.first)
        XCTAssertEqual(entry.exerciseRaw, "Front Squat", "a swapped exercise uses its own name")
        XCTAssertEqual(entry.orderedSets.map(\.isInferred), [true, true, false], "only the edited set stops being inferred")
    }

    func testDraftSnapshotCarriesSourceFieldsAndDuration() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let exercise = makeExercise(id: "ex-squat", name: "Back Squat")
        let (client, session) = makeImportedSession(in: context, exercise: exercise)
        try context.save()

        let store = TodayDraftStore()
        store.clientID = client.id
        store.isActive = true
        store.plannedDurationMinutes = session.plannedDurationMinutes
        store.blocks = SessionDraftLoader.load(from: session, exercises: [exercise]).blocks
        let data = try JSONEncoder().encode(try XCTUnwrap(store.snapshot()))
        let snapshot = try JSONDecoder().decode(TodayDraftSnapshot.self, from: data)

        let restored = TodayDraftStore()
        restored.restore(from: snapshot, exercises: [exercise])
        XCTAssertNil(restored.plannedDurationMinutes)
        let block = try XCTUnwrap(restored.blocks.first)
        XCTAssertEqual(block.source?.note, "膝蓋不適，減重")
        XCTAssertEqual(block.resolvedRestRaw, "90s")
        XCTAssertEqual(block.entries.first?.resolvedExerciseRaw, "BB squat (heavy)")
        XCTAssertEqual(block.entries.first?.resolvedInferredFlags(), [true, true, true])
    }

    func testUnknownActualSurvivesFullEditButIsNotCopiedIntoANewSession() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let exercise = makeExercise(id: "ex-squat", name: "Back Squat")
        let (client, session) = makeImportedSession(in: context, exercise: exercise)
        let set = try XCTUnwrap(session.orderedBlocks.first?.orderedEntries.first?.orderedSets.first)
        set.actual = .unknown(raw: "stopped early")
        try context.save()
        let loaded = SessionDraftLoader.load(from: session, exercises: [exercise])
        try resave(session, client: client, blocks: loaded.blocks, duration: nil, in: context)
        XCTAssertEqual(session.orderedBlocks[0].orderedEntries[0].orderedSets[0].actual, .unknown(raw: "stopped early"))
        let copied = SessionDraftLoader.copy(from: session, exercises: [exercise])
        XCTAssertEqual(copied.blocks[0].entries[0].resolvedSets()[0].actual, .unknown(raw: ""))
        XCTAssertFalse(copied.blocks[0].entries[0].rounds[0].actualRecorded)
    }

    func testUnsupportedWODPayloadIsReportedSoFullEditCanRefuse() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let exercise = makeExercise(id: "ex-squat", name: "Back Squat")
        let (_, session) = makeImportedSession(in: context, exercise: exercise)
        let wod = SessionBlock(order: 1, blockType: .single, sourceRow: 0, sectionKind: .wod)
        wod.setWODPayloadRawJSON(#"{"schemaVersion":999}"#)
        wod.session = session
        context.insert(wod)
        try context.save()

        XCTAssertTrue(wod.hasUnsupportedWODPayload)
        XCTAssertEqual(SessionDraftLoader.unsupportedBlockCount(in: session), 1)
        XCTAssertEqual(SessionDraftLoader.load(from: session, exercises: [exercise]).blocks.count, 1, "load cannot represent it, which is why callers must refuse")
    }
}
