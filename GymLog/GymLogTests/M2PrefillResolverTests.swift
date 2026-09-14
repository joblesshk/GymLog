import XCTest
import SwiftData
@testable import GymLogKit

/// CONTRACT-UI.md §3.2 -- the M2 acceptance criterion. All fixtures here are
/// hand-built in-memory (no seed file needed) so each scenario is explicit
/// about exactly what structure it's proving the resolver walks correctly.
final class M2PrefillResolverTests: XCTestCase {

    private func makeExercise(id: String, name: String) -> Exercise {
        Exercise(
            id: id, canonicalName: name, aliases: [],
            movementPattern: .push, equipment: .barbell, loadDirection: .higherIsStronger,
            isUnilateral: false, occurrenceCount: 10, needsReview: false, reviewReason: nil
        )
    }

    private func makeSession(id: String, client: Client, date: Date) -> WorkoutSession {
        let session = WorkoutSession(
            id: id, date: date, dateOrigin: .asRecorded, dateRaw: "",
            weekNumber: 1, sourceSheet: "test", sourceRow: 0
        )
        session.client = client
        return session
    }

    /// Inserts a single-entry block for `exercise` into `session`, with one
    /// set at the given load/target.
    @discardableResult
    private func addSingleBlock(
        to session: WorkoutSession, order: Int, exercise: Exercise,
        plannedSets: Int, kg: Double, reps: Int, in context: ModelContext
    ) -> SessionBlock {
        let block = SessionBlock(order: order, blockType: .single, sourceRow: 0)
        block.session = session
        context.insert(block)
        let entry = ExerciseEntry(order: 0, exerciseIdRef: exercise.id, exerciseRaw: exercise.canonicalName, plannedSets: plannedSets, exercise: exercise)
        entry.block = block
        context.insert(entry)
        let set = SetLog(
            setIndex: 0,
            load: .absolute(kg: kg, raw: "\(kg)"),
            target: .fixed(value: reps, raw: "\(reps)"),
            actual: .fixed(value: reps, raw: "\(reps)"),
            isInferred: true
        )
        set.entry = entry
        context.insert(set)
        return block
    }

    func testFindsMostRecentRecordAcrossSessions() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)

        let client = Client(id: "cl-1", name: "Test Client")
        context.insert(client)
        let bench = makeExercise(id: "ex-bench", name: "Bench press")
        context.insert(bench)

        let older = makeSession(id: "se-1", client: client, date: Date(timeIntervalSince1970: 0))
        context.insert(older)
        addSingleBlock(to: older, order: 0, exercise: bench, plannedSets: 3, kg: 30, reps: 10, in: context)

        let newer = makeSession(id: "se-2", client: client, date: Date(timeIntervalSince1970: 86_400 * 10))
        context.insert(newer)
        addSingleBlock(to: newer, order: 0, exercise: bench, plannedSets: 4, kg: 35, reps: 8, in: context)

        try context.save()

        let prefill = PrefillResolver.lastRecord(clientID: client.id, exerciseID: bench.id, in: context)
        XCTAssertNotNil(prefill, "should find the client's most recent record")
        XCTAssertEqual(prefill?.sets, 4, "must take the NEWER session's plannedSets, not the older one")
        guard case .absolute(let kg, _) = prefill!.load else {
            return XCTFail("expected .absolute load")
        }
        XCTAssertEqual(kg, 35, "must take the newer session's weight")
        guard case .fixed(let reps, _) = prefill!.targetRepTarget else {
            return XCTFail("expected .fixed target")
        }
        XCTAssertEqual(reps, 8, "must take the newer session's rep target")
    }

    /// The risk explicitly called out in the task brief: an exercise that
    /// has only ever been logged inside a superset block must still be
    /// found by prefill. This fixture deliberately puts the target exercise
    /// as the SECOND entry of a two-entry superset block, and makes it the
    /// only place that exercise appears anywhere in the client's history --
    /// so a resolver that only scans single-entry blocks, or only looks at
    /// a block's first entry, fails this test.
    func testFindsExerciseOnlyEverLoggedInsideASuperset() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)

        let client = Client(id: "cl-1", name: "Test Client")
        context.insert(client)
        let row = makeExercise(id: "ex-row", name: "Machine row")
        let plank = makeExercise(id: "ex-plank", name: "SA plank")
        context.insert(row)
        context.insert(plank)

        let session = makeSession(id: "se-1", client: client, date: Date(timeIntervalSince1970: 86_400))
        context.insert(session)

        let supersetBlock = SessionBlock(order: 0, blockType: .superset, sourceRow: 0)
        supersetBlock.session = session
        context.insert(supersetBlock)

        let entryA = ExerciseEntry(order: 0, exerciseIdRef: row.id, exerciseRaw: "Machine row", plannedSets: 3, exercise: row)
        entryA.block = supersetBlock
        context.insert(entryA)
        let setA = SetLog(setIndex: 0, load: .absolute(kg: 12.5, raw: "12.5"), target: .range(low: 10, high: 15, raw: "10-15"), actual: .range(low: 10, high: 12, raw: "10-12"), isInferred: true)
        setA.entry = entryA
        context.insert(setA)

        // entryB is the SECOND entry in this superset -- the case a naive
        // "only look at block.entries.first" implementation would miss.
        let entryB = ExerciseEntry(order: 1, exerciseIdRef: plank.id, exerciseRaw: "SA plank", plannedSets: 3, exercise: plank)
        entryB.block = supersetBlock
        context.insert(entryB)
        let setB = SetLog(setIndex: 0, load: .bodyweight(raw: "bw"), target: .time(seconds: 30, raw: "0:30"), actual: .time(seconds: 28, raw: "0:28"), isInferred: true)
        setB.entry = entryB
        context.insert(setB)

        try context.save()

        let prefill = PrefillResolver.lastRecord(clientID: client.id, exerciseID: plank.id, in: context)
        XCTAssertNotNil(prefill, "must find an exercise that only ever appears as a superset's 2nd+ entry")
        XCTAssertEqual(prefill?.sets, 3)
        guard case .time(let seconds, _) = prefill!.targetRepTarget else {
            return XCTFail("expected .time target for SA plank")
        }
        XCTAssertEqual(seconds, 30)
        // CONTRACT-M9.md: target and actual are read independently -- setB
        // deliberately has different target (30s) vs actual (28s) values.
        guard case .time(let actualSeconds, _) = prefill!.actualRepTarget else {
            return XCTFail("expected .time actual for SA plank")
        }
        XCTAssertEqual(actualSeconds, 28, "actual must be read from the set's own .actual, not mirror target")
    }

    func testReturnsNilWhenClientHasNoRecordOfThisExercise() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = Client(id: "cl-1", name: "Test Client")
        context.insert(client)
        let bench = makeExercise(id: "ex-bench", name: "Bench press")
        context.insert(bench)
        try context.save()

        XCTAssertNil(PrefillResolver.lastRecord(clientID: client.id, exerciseID: bench.id, in: context))
    }

    func testResolvedPrefillFallsBackToDocumentedDefaults() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = Client(id: "cl-1", name: "Test Client")
        context.insert(client)
        let bench = makeExercise(id: "ex-bench", name: "Bench press")
        context.insert(bench)
        try context.save()

        let prefill = PrefillResolver.resolvedPrefill(clientID: client.id, exerciseID: bench.id, in: context)
        XCTAssertEqual(prefill.sets, 3, "CONTRACT-UI.md §3.2 default: 3 组")
        guard case .fixed(let reps, _) = prefill.targetRepTarget else { return XCTFail("expected .fixed") }
        XCTAssertEqual(reps, 10, "CONTRACT-UI.md §3.2 default: 10")
        guard case .absolute(let kg, _) = prefill.load else { return XCTFail("expected .absolute") }
        XCTAssertEqual(kg, 20, "CONTRACT-UI.md §3.2 default: 20kg")
    }

    /// CONTRACT-UI.md §3.3 (2026-08 revision): a never-before-recorded
    /// `.bodyweight` exercise must prefill at "自重", not the generic 20kg
    /// default -- that default predates the `.bodyweightPlus` wheel and was
    /// only ever meant for weighted equipment.
    func testResolvedPrefillDefaultsBodyweightExerciseToBodyweightNotKg() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = Client(id: "cl-1", name: "Test Client")
        context.insert(client)
        let plank = Exercise(
            id: "ex-plank", canonicalName: "plank", aliases: [],
            movementPattern: .core, equipment: .bodyweight, loadDirection: .higherIsStronger,
            isUnilateral: false, occurrenceCount: 3, needsReview: false, reviewReason: nil,
            recordingMetric: .time
        )
        context.insert(plank)
        try context.save()

        let prefill = PrefillResolver.resolvedPrefill(clientID: client.id, exerciseID: plank.id, equipment: .bodyweight, in: context)
        guard case .bodyweight = prefill.load else { return XCTFail("expected .bodyweight, got \(prefill.load)") }
    }

    /// A different client's history for the same exercise must never leak
    /// into this client's prefill.
    func testDoesNotLeakAnotherClientsRecords() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)

        let clientA = Client(id: "cl-a", name: "Client A")
        let clientB = Client(id: "cl-b", name: "Client B")
        context.insert(clientA)
        context.insert(clientB)
        let bench = makeExercise(id: "ex-bench", name: "Bench press")
        context.insert(bench)

        let sessionA = makeSession(id: "se-a", client: clientA, date: Date(timeIntervalSince1970: 86_400 * 5))
        context.insert(sessionA)
        addSingleBlock(to: sessionA, order: 0, exercise: bench, plannedSets: 5, kg: 60, reps: 5, in: context)

        try context.save()

        XCTAssertNil(PrefillResolver.lastRecord(clientID: clientB.id, exerciseID: bench.id, in: context))
    }
}
