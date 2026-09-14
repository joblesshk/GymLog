import XCTest
import SwiftData
@testable import GymLogKit

/// CONTRACT-UI.md §3.6: "新建的 SetLog 一律 isInferred = false" -- the
/// migrated 2372 SetLogs are all `isInferred == true`; this distinction
/// must not blur for anything the entry flow writes.
///
/// CONTRACT-M5.md §3.3 replaced `EntryDraft`'s old flat setsCount/repTarget/
/// load trio (and the entire per-set-editing/`isExpanded` subsystem this
/// file used to cover) with `rounds: [RoundDraft]`. The behavior these two
/// tests originally proved -- "an entry broadcasts one load/target to every
/// set it resolves to" and "saving an EntryDraft produces isInferred==false
/// SetLogs" -- still holds, just expressed through a single-Round entry
/// instead of the removed `perSetOverrides`/`expand()`/`collapse()` API.
/// The Round-specific behavior this replacement introduces (multi-Round
/// expansion, setIndex numbering, the 4-Round cap, the 1-Round floor, the
/// reps-rounding rule) is covered separately in `M5ARoundDraftTests.swift`.
@MainActor
final class M2EntryDraftTests: XCTestCase {

    private func makeExercise() -> Exercise {
        Exercise(id: "ex-1", canonicalName: "Bench press", aliases: [], movementPattern: .push, equipment: .barbell, loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 1, needsReview: false, reviewReason: nil)
    }

    // MARK: - EntryDraft.resolvedSets()

    func testSingleRoundEntryBroadcastsOneWeightAndRepsToAllSets() {
        let draft = EntryDraft(exercise: makeExercise(), setsCount: 4, load: .absolute(kg: 40, raw: "40"), targetQuantity: 10, actualQuantity: 10)
        let sets = draft.resolvedSets()
        XCTAssertEqual(sets.count, 4)
        for set in sets {
            guard case .absolute(let kg, _) = set.load else { return XCTFail("expected .absolute") }
            XCTAssertEqual(kg, 40)
            guard case .fixed(let reps, _) = set.target else { return XCTFail("expected .fixed") }
            XCTAssertEqual(reps, 10)
            guard case .fixed(let actualReps, _) = set.actual else { return XCTFail("expected .fixed") }
            XCTAssertEqual(actualReps, 10, "target and actual must be identical for a new entry (CONTRACT-M5.md §3.3.2: 次数目标/实际次数合并成一个记录单元)")
        }
    }

    // MARK: - isInferred == false on save (CONTRACT-UI.md §3.6)

    /// Replicates the exact object-graph construction TodayView.save() does
    /// (WorkoutSession -> SessionBlock -> ExerciseEntry -> SetLog, same
    /// relationship-wiring pattern as SeedImporter) so this is a genuine
    /// proof that anything built from an EntryDraft lands with
    /// `isInferred == false`, not just an assertion about the draft struct
    /// in isolation.
    func testSavingEntryDraftsProducesSetLogsWithIsInferredFalse() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)

        let client = Client(id: "cl-1", name: "Test Client")
        context.insert(client)
        let exercise = makeExercise()
        context.insert(exercise)

        let entryDraft = EntryDraft(exercise: exercise, setsCount: 3, load: .absolute(kg: 40, raw: "40"), targetQuantity: 10, actualQuantity: 10)
        let blockDraft = BlockDraft(blockType: .single, entries: [entryDraft])

        let session = WorkoutSession(id: "se-local-1", date: Date(), dateOrigin: .asRecorded, dateRaw: "2026-08-20", weekNumber: 1, sourceSheet: "App", sourceRow: 0)
        session.client = client
        context.insert(session)

        let block = SessionBlock(order: 0, blockType: blockDraft.blockType, restSeconds: blockDraft.restSeconds, sourceRow: 0)
        block.session = session
        context.insert(block)

        let entry = ExerciseEntry(order: 0, exerciseIdRef: entryDraft.exercise.id, exerciseRaw: entryDraft.exercise.canonicalName, plannedSets: entryDraft.plannedSets, exercise: entryDraft.exercise)
        entry.block = block
        context.insert(entry)

        for (setIndex, values) in entryDraft.resolvedSets().enumerated() {
            let setLog = SetLog(setIndex: setIndex, load: values.load, target: values.target, actual: values.actual, isInferred: false)
            setLog.entry = entry
            context.insert(setLog)
        }

        try context.save()

        let savedSets = try context.fetch(FetchDescriptor<SetLog>())
        XCTAssertEqual(savedSets.count, 3)
        XCTAssertTrue(savedSets.allSatisfy { $0.isInferred == false },
                       "every SetLog created through the entry flow must have isInferred == false, unlike the 2372 migrated rows which are all true")
    }
}
