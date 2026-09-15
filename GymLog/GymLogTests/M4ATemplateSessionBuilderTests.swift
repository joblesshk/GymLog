import XCTest
import SwiftData
@testable import GymLogKit

/// CONTRACT-M4.md §4.4 / §5 -- "从模板新建". `TemplateSessionBuilder` is the
/// pure conversion `TodayView.startFromTemplate` delegates to: template
/// blocks/slots -> `BlockDraft`/`EntryDraft`s. Three things the contract
/// specifically calls out get their own tests: exercises resolve correctly
/// from `TemplateExerciseSlot.exerciseID`, weight is **never** taken from
/// the template (always `PrefillResolver`), and a stale `exerciseID` is
/// handled visibly (counted, not silently dropped or crashed on).
@MainActor
final class M4ATemplateSessionBuilderTests: XCTestCase {

    private func makeExercise(id: String, name: String) -> Exercise {
        Exercise(id: id, canonicalName: name, aliases: [], movementPattern: .push, equipment: .barbell, loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 10, needsReview: false, reviewReason: nil)
    }

    private func makeTemplate(id: String = "tpl-1", name: String = "全身力量 A", context: ModelContext) -> SessionTemplate {
        let template = SessionTemplate(id: id, name: name, order: 0)
        context.insert(template)
        return template
    }

    @discardableResult
    private func addSlot(
        to block: TemplateBlock, order: Int, exerciseID: String,
        defaultSets: Int, defaultRepTarget: RepTarget, in context: ModelContext
    ) -> TemplateExerciseSlot {
        let slot = TemplateExerciseSlot(id: "slot-\(block.id)-\(order)", order: order, exerciseID: exerciseID, defaultSets: defaultSets, defaultRepTarget: defaultRepTarget)
        slot.block = block
        context.insert(slot)
        return slot
    }

    // MARK: - Exercise resolution

    func testResolvesExerciseFromSlotExerciseIDAndUsesSlotSetsAndTarget() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)

        let client = Client(id: "cl-1", name: "Test Client")
        context.insert(client)
        let bench = makeExercise(id: "ex-bench", name: "Bench press")
        context.insert(bench)

        let template = makeTemplate(context: context)
        let block = TemplateBlock(id: "blk-1", order: 0, blockType: .single, restSeconds: 90)
        block.template = template
        context.insert(block)
        addSlot(to: block, order: 0, exerciseID: bench.id, defaultSets: 4, defaultRepTarget: .range(low: 6, high: 10, raw: "6-10"), in: context)
        try context.save()

        let result = TemplateSessionBuilder.build(from: template, clientID: client.id, allExercises: [bench], in: context)
        XCTAssertEqual(result.unresolvedSlotCount, 0)
        XCTAssertEqual(result.blocks.count, 1)
        let entries = result.blocks[0].entries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].exercise.id, "ex-bench", "must resolve the real Exercise object, not just carry the id")
        XCTAssertEqual(entries[0].rounds.count, 1, "a freshly-built template entry starts with exactly one Round")
        XCTAssertEqual(entries[0].rounds[0].setsCount, 4, "Round 1's setsCount must come from defaultSets")
        // CONTRACT-M5.md §3.3.2: defaultRepTarget (.range(6,10)) must be
        // converted to a single exact Int via the documented rounding rule
        // (midpoint, rounded) -- (6+10)/2 = 8.
        XCTAssertEqual(entries[0].rounds[0].target, .fixed(value: 8, raw: "8"), "range defaultRepTarget must convert to its rounded midpoint")
        // CONTRACT-M9.md: a template slot has no "actual" concept yet (this
        // Round has never been performed) -- 目标/实际 start equal.
        XCTAssertEqual(entries[0].rounds[0].actual, .fixed(value: 8, raw: "8"), "a freshly-built template Round has no actual history yet, so actual starts equal to target")
        XCTAssertEqual(result.blocks[0].restSeconds, 90, "block rest must carry over from the template block")
    }

    func testMultipleBlocksAndSlotsAllConvert() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = Client(id: "cl-1", name: "Test Client")
        context.insert(client)
        let bench = makeExercise(id: "ex-bench", name: "Bench press")
        let row = makeExercise(id: "ex-row", name: "Machine row")
        context.insert(bench); context.insert(row)

        let template = makeTemplate(context: context)
        let block0 = TemplateBlock(id: "blk-0", order: 0, blockType: .single, restSeconds: 60)
        block0.template = template
        context.insert(block0)
        addSlot(to: block0, order: 0, exerciseID: bench.id, defaultSets: 3, defaultRepTarget: .fixed(value: 10, raw: "10"), in: context)

        let block1 = TemplateBlock(id: "blk-1", order: 1, blockType: .single, restSeconds: 60)
        block1.template = template
        context.insert(block1)
        addSlot(to: block1, order: 0, exerciseID: row.id, defaultSets: 3, defaultRepTarget: .fixed(value: 12, raw: "12"), in: context)
        try context.save()

        let result = TemplateSessionBuilder.build(from: template, clientID: client.id, allExercises: [bench, row], in: context)
        XCTAssertEqual(result.blocks.count, 2)
        XCTAssertEqual(result.blocks[0].entries[0].exercise.id, "ex-bench")
        XCTAssertEqual(result.blocks[1].entries[0].exercise.id, "ex-row")
    }

    // MARK: - Weight is never taken from the template

    /// CONTRACT-M4.md §4.4: "重量仍走既有的『上次值预填』逻辑...不从模板取值".
    /// This is the test that would fail loudest if that rule were violated:
    /// the client has a real prior record of this exercise at 45kg: the
    /// converted entry's load must be exactly that prefilled 45kg, never a
    /// value derived from the template (which structurally has no load
    /// field to derive from in the first place -- `TemplateExerciseSlot`
    /// carries no `LoadValue` at all, so this also proves the builder
    /// doesn't invent one).
    func testWeightAlwaysComesFromPrefillResolverNeverFromTemplate() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = Client(id: "cl-1", name: "Test Client")
        context.insert(client)
        let bench = makeExercise(id: "ex-bench", name: "Bench press")
        context.insert(bench)

        // Client's real prior history: last logged Bench press at 45kg.
        let priorSession = WorkoutSession(id: "se-1", date: Date(timeIntervalSince1970: 86_400), dateOrigin: .asRecorded, dateRaw: "", weekNumber: 1, sourceSheet: "test", sourceRow: 0)
        priorSession.client = client
        context.insert(priorSession)
        let priorBlock = SessionBlock(order: 0, blockType: .single, sourceRow: 0)
        priorBlock.session = priorSession
        context.insert(priorBlock)
        let priorEntry = ExerciseEntry(order: 0, exerciseIdRef: bench.id, exerciseRaw: "Bench press", plannedSets: 4, exercise: bench)
        priorEntry.block = priorBlock
        context.insert(priorEntry)
        let priorSet = SetLog(setIndex: 0, load: .absolute(kg: 45, raw: "45"), target: .fixed(value: 8, raw: "8"), actual: .fixed(value: 8, raw: "8"), isInferred: false)
        priorSet.entry = priorEntry
        context.insert(priorSet)

        let template = makeTemplate(context: context)
        let block = TemplateBlock(id: "blk-1", order: 0, blockType: .single, restSeconds: 90)
        block.template = template
        context.insert(block)
        // Template's own defaultSets/defaultRepTarget are deliberately
        // different from the client's history, to prove the load comes
        // from prefill (45kg) and NOT from anything template-adjacent.
        addSlot(to: block, order: 0, exerciseID: bench.id, defaultSets: 5, defaultRepTarget: .fixed(value: 3, raw: "3"), in: context)
        try context.save()

        let result = TemplateSessionBuilder.build(from: template, clientID: client.id, allExercises: [bench], in: context)
        let entry = result.blocks[0].entries[0]
        guard case .absolute(let kg, _) = entry.rounds[0].load else { return XCTFail("expected .absolute load") }
        XCTAssertEqual(kg, 45, "load must come from PrefillResolver's real last-value lookup, not the template")
        XCTAssertEqual(entry.rounds[0].setsCount, 5, "Round 1's setsCount still comes from the template, unlike load")
    }

    /// No prior history at all: load must fall back to `PrefillResolver`'s
    /// documented default (CONTRACT-UI.md §3.2: 20kg), still never template-
    /// derived (the template has no load field to derive from).
    func testWeightFallsBackToPrefillDefaultWhenClientHasNoPriorHistory() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = Client(id: "cl-1", name: "Test Client")
        context.insert(client)
        let bench = makeExercise(id: "ex-bench", name: "Bench press")
        context.insert(bench)

        let template = makeTemplate(context: context)
        let block = TemplateBlock(id: "blk-1", order: 0, blockType: .single, restSeconds: 90)
        block.template = template
        context.insert(block)
        addSlot(to: block, order: 0, exerciseID: bench.id, defaultSets: 3, defaultRepTarget: .fixed(value: 10, raw: "10"), in: context)
        try context.save()

        let result = TemplateSessionBuilder.build(from: template, clientID: client.id, allExercises: [bench], in: context)
        guard case .absolute(let kg, _) = result.blocks[0].entries[0].rounds[0].load else { return XCTFail() }
        XCTAssertEqual(kg, PrefillResolver.defaultLoad.kgIfAbsolute, "must fall back to the documented default, not a template-derived value")
    }

    // MARK: - Stale exerciseID handled visibly, not silently or crash

    /// A slot referencing an exercise no longer in the library (e.g. merged
    /// away) must be skipped -- not crash, not silently produce a broken
    /// entry -- and counted so the caller can surface it to the coach.
    func testStaleExerciseIDIsSkippedAndCounted() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = Client(id: "cl-1", name: "Test Client")
        context.insert(client)
        let bench = makeExercise(id: "ex-bench", name: "Bench press")
        context.insert(bench)

        let template = makeTemplate(context: context)
        let block = TemplateBlock(id: "blk-1", order: 0, blockType: .single, restSeconds: 90)
        block.template = template
        context.insert(block)
        addSlot(to: block, order: 0, exerciseID: bench.id, defaultSets: 3, defaultRepTarget: .fixed(value: 10, raw: "10"), in: context)
        // Second slot references an exercise id that doesn't resolve.
        addSlot(to: block, order: 1, exerciseID: "ex-stale-deleted", defaultSets: 3, defaultRepTarget: .fixed(value: 10, raw: "10"), in: context)
        try context.save()

        let result = TemplateSessionBuilder.build(from: template, clientID: client.id, allExercises: [bench], in: context)
        XCTAssertEqual(result.unresolvedSlotCount, 1, "the stale slot must be counted, not silently dropped without a trace")
        XCTAssertEqual(result.blocks.count, 1, "the block must still be produced")
        XCTAssertEqual(result.blocks[0].entries.count, 1, "only the resolvable slot becomes an entry")
        XCTAssertEqual(result.blocks[0].entries[0].exercise.id, "ex-bench")
    }

    /// A block whose every slot is stale must be dropped entirely (an empty
    /// block is not useful), while the unresolved count still reflects it.
    func testBlockWithAllSlotsStaleIsDroppedButStillCounted() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = Client(id: "cl-1", name: "Test Client")
        context.insert(client)

        let template = makeTemplate(context: context)
        let block = TemplateBlock(id: "blk-1", order: 0, blockType: .single, restSeconds: 90)
        block.template = template
        context.insert(block)
        addSlot(to: block, order: 0, exerciseID: "ex-gone-1", defaultSets: 3, defaultRepTarget: .fixed(value: 10, raw: "10"), in: context)
        addSlot(to: block, order: 1, exerciseID: "ex-gone-2", defaultSets: 3, defaultRepTarget: .fixed(value: 10, raw: "10"), in: context)
        try context.save()

        let result = TemplateSessionBuilder.build(from: template, clientID: client.id, allExercises: [], in: context)
        XCTAssertEqual(result.unresolvedSlotCount, 2)
        XCTAssertTrue(result.blocks.isEmpty, "an entirely-unresolvable block must not produce an empty BlockDraft")
    }

    // MARK: - M2 (2026-09-07): WOD template blocks

    /// Starting a session from a template with a WOD block copies the
    /// PRESCRIPTION only -- the result must always start `.notRecorded`,
    /// never bring in a previous attempt's score (there is none stored on a
    /// template block anyway, but the draft's own defaults must reflect
    /// this too).
    func testWODTemplateBlockCopiesOnlyThePrescription() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = Client(id: "cl-wod", name: "WOD Client")
        context.insert(client)
        let burpee = makeExercise(id: "ex-burpee", name: "Burpee")
        context.insert(burpee)

        let template = makeTemplate(id: "tpl-wod", name: "Metcon Day", context: context)
        let block = TemplateBlock(id: "blk-wod", order: 0, blockType: .single, restSeconds: 0, sectionKind: .wod)
        block.template = template
        block.wodPrescription = WODPrescription(
            id: "wod-tpl-1", revision: 1, name: "Test AMRAP", format: .amrap, timeCapSeconds: 600,
            rounds: [WODRoundPrescription(roundIndex: 0, movements: [
                WODMovementPrescription(stepID: "s1", exerciseID: "ex-burpee", exerciseNameSnapshot: "Burpee", quantity: .reps(10, raw: "10")),
            ])],
            scoringRule: .roundsAndReps
        )
        context.insert(block)
        try context.save()

        let result = TemplateSessionBuilder.build(from: template, clientID: client.id, allExercises: [burpee], in: context)
        XCTAssertEqual(result.blocks.count, 1)
        let wodBlockDraft = try XCTUnwrap(result.blocks.first)
        XCTAssertEqual(wodBlockDraft.sectionKind, .wod)
        let wodDraft = try XCTUnwrap(wodBlockDraft.wodDraft)
        XCTAssertEqual(wodDraft.name, "Test AMRAP")
        XCTAssertEqual(wodDraft.format, .amrap)
        XCTAssertEqual(wodDraft.timeCapSeconds, 600)
        XCTAssertEqual(wodDraft.movements.first?.exercise?.id, "ex-burpee")
        XCTAssertEqual(wodDraft.status, .notRecorded, "a fresh draft from a template must never carry a prior result")
    }

    /// A WOD template block with no prescription set yet (e.g. a
    /// half-authored template) must be skipped, not crash or produce an
    /// empty WOD draft.
    func testWODTemplateBlockWithNoPrescriptionIsSkipped() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = Client(id: "cl-wod2", name: "WOD Client 2")
        context.insert(client)
        let template = makeTemplate(id: "tpl-wod-empty", name: "Empty WOD Template", context: context)
        let block = TemplateBlock(id: "blk-wod-empty", order: 0, blockType: .single, restSeconds: 0, sectionKind: .wod)
        block.template = template
        context.insert(block)
        try context.save()

        let result = TemplateSessionBuilder.build(from: template, clientID: client.id, allExercises: [], in: context)
        XCTAssertTrue(result.blocks.isEmpty)
    }
}

private extension LoadValue {
    /// Test-only convenience so `testWeightFallsBackToPrefillDefaultWhenClientHasNoPriorHistory`
    /// stays robust to `PrefillResolver.defaultLoad`'s exact raw text.
    var kgIfAbsolute: Double {
        if case .absolute(let kg, _) = self { return kg }
        return -1
    }
}
