import XCTest
import SwiftData
@testable import GymLogKit

/// `ExerciseReferenceRedirectionService` -- the single shared implementation
/// behind both `SeedImporter.redirectExerciseReferences` (called by one-time
/// device heals) and `ExerciseLibraryView`'s merge button. Before this
/// existed the UI's merge button had its OWN, smaller implementation that
/// never redirected `TemplateExerciseSlot` at all (a real bug this review
/// found) and neither implementation touched WOD payloads/prescriptions
/// (`CONTRACT-M10.md`'s documented M1 gap). This file exercises all four
/// reference kinds through the one shared entry point, plus undo.
@MainActor
final class ExerciseReferenceRedirectionServiceTests: XCTestCase {
    private func makeExercise(id: String, name: String) -> Exercise {
        Exercise(
            id: id, canonicalName: name, aliases: [], movementPattern: .push, equipment: .barbell,
            loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 0, needsReview: false, reviewReason: nil
        )
    }

    // MARK: - ExerciseEntry (strength records)

    func testRedirectsExerciseEntryReferences() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let source = makeExercise(id: "ex-a", name: "Old Name")
        let target = makeExercise(id: "ex-b", name: "New Name")
        context.insert(source)
        context.insert(target)
        let client = Client(id: "cl-1", name: "Test")
        context.insert(client)
        let session = WorkoutSession(id: "se-1", date: Date(), dateOrigin: .asRecorded, dateRaw: "raw", weekNumber: 1, sourceSheet: "App", sourceRow: 0)
        session.client = client
        context.insert(session)
        let block = SessionBlock(order: 0, blockType: .single, sourceRow: 0)
        block.session = session
        context.insert(block)
        let entry = ExerciseEntry(order: 0, exerciseIdRef: "ex-a", exerciseRaw: "Old Name", plannedSets: 3, exercise: source)
        entry.block = block
        context.insert(entry)
        try context.save()

        let (summary, _) = try ExerciseReferenceRedirectionService.redirect(from: source, to: target, in: context)
        try context.save()

        XCTAssertEqual(summary.entryCount, 1)
        XCTAssertEqual(entry.exercise?.id, "ex-b")
        XCTAssertEqual(entry.exerciseIdRef, "ex-b")
    }

    // MARK: - TemplateExerciseSlot (the bug the UI merge button had)

    func testRedirectsTemplateExerciseSlotReferences() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let source = makeExercise(id: "ex-a", name: "Old Name")
        let target = makeExercise(id: "ex-b", name: "New Name")
        context.insert(source)
        context.insert(target)
        let template = SessionTemplate(id: "tpl-1", name: "Push Day", order: 0)
        context.insert(template)
        let block = TemplateBlock(id: "tb-1", order: 0, blockType: .single, restSeconds: 60)
        block.template = template
        context.insert(block)
        let slot = TemplateExerciseSlot(id: "slot-1", order: 0, exerciseID: "ex-a", defaultSets: 3, defaultRepTarget: .fixed(value: 10, raw: "10"))
        slot.block = block
        context.insert(slot)
        try context.save()

        let (summary, _) = try ExerciseReferenceRedirectionService.redirect(from: source, to: target, in: context)
        try context.save()

        XCTAssertEqual(summary.templateSlotCount, 1)
        XCTAssertEqual(slot.exerciseID, "ex-b")
    }

    // MARK: - WOD payload (SessionBlock) and prescription (TemplateBlock)

    private func wodPrescription(exerciseID: String) -> WODPrescription {
        WODPrescription(
            id: "wod-1", revision: 1, name: "Test WOD", format: .forTime, timeCapSeconds: 720,
            rounds: [WODRoundPrescription(roundIndex: 0, movements: [
                WODMovementPrescription(stepID: "s1", exerciseID: exerciseID, exerciseNameSnapshot: "Old Name", quantity: .reps(21, raw: "21"), load: .absolute(kg: 43, raw: "43")),
            ])],
            scoringRule: .completionTime
        )
    }

    func testRedirectsWODPayloadExerciseIDWithoutTouchingOtherFields() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let source = makeExercise(id: "ex-a", name: "Old Name")
        let target = makeExercise(id: "ex-b", name: "New Name")
        context.insert(source)
        context.insert(target)
        let client = Client(id: "cl-1", name: "Test")
        context.insert(client)
        let session = WorkoutSession(id: "se-1", date: Date(), dateOrigin: .asRecorded, dateRaw: "raw", weekNumber: 1, sourceSheet: "App", sourceRow: 0)
        session.client = client
        context.insert(session)
        let block = SessionBlock(order: 0, blockType: .single, sourceRow: 0, sectionKind: .wod)
        block.session = session
        block.wodPayload = WODPayload(prescription: wodPrescription(exerciseID: "ex-a"), result: WODResult(status: .completed, elapsedSeconds: 512, variant: .rx))
        context.insert(block)
        try context.save()

        let (summary, _) = try ExerciseReferenceRedirectionService.redirect(from: source, to: target, in: context)
        try context.save()

        XCTAssertEqual(summary.wodPayloadCount, 1)
        let movement = try XCTUnwrap(block.wodPayload?.prescription.rounds.first?.movements.first)
        XCTAssertEqual(movement.exerciseID, "ex-b", "the id itself is redirected")
        // Everything that was actually recorded stays exactly as recorded --
        // redirecting an id is not "editing the workout" (工程审阅: "身份重
        // 定向不得覆盖历史名称、负重、标准、数量等原始快照").
        XCTAssertEqual(movement.exerciseNameSnapshot, "Old Name")
        XCTAssertEqual(movement.load, .absolute(kg: 43, raw: "43"))
        XCTAssertEqual(block.wodPayload?.prescription.id, "wod-1")
        XCTAssertEqual(block.wodPayload?.prescription.revision, 1, "redirecting an id must never bump the prescription's revision")
        XCTAssertEqual(block.wodPayload?.result.elapsedSeconds, 512)
    }

    func testRedirectsWODPayloadActualMovementsSubstitutionReference() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let source = makeExercise(id: "ex-a", name: "Old Name")
        let target = makeExercise(id: "ex-b", name: "New Name")
        context.insert(source)
        context.insert(target)
        let client = Client(id: "cl-1", name: "Test")
        context.insert(client)
        let session = WorkoutSession(id: "se-1", date: Date(), dateOrigin: .asRecorded, dateRaw: "raw", weekNumber: 1, sourceSheet: "App", sourceRow: 0)
        session.client = client
        context.insert(session)
        let block = SessionBlock(order: 0, blockType: .single, sourceRow: 0, sectionKind: .wod)
        block.session = session
        let result = WODResult(
            status: .completed, elapsedSeconds: 500, variant: .rx,
            actualMovements: [WODMovementPrescription(stepID: "s1", exerciseID: "ex-a", exerciseNameSnapshot: "Substituted", quantity: .reps(21, raw: "21"))]
        )
        block.wodPayload = WODPayload(prescription: wodPrescription(exerciseID: "ex-other"), result: result)
        context.insert(block)
        try context.save()

        let (summary, _) = try ExerciseReferenceRedirectionService.redirect(from: source, to: target, in: context)
        try context.save()

        XCTAssertEqual(summary.wodPayloadCount, 1)
        XCTAssertEqual(block.wodPayload?.result.actualMovements.first?.exerciseID, "ex-b")
    }

    func testRedirectsTemplateBlockWODPrescription() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let source = makeExercise(id: "ex-a", name: "Old Name")
        let target = makeExercise(id: "ex-b", name: "New Name")
        context.insert(source)
        context.insert(target)
        let template = SessionTemplate(id: "tpl-1", name: "WOD Day", order: 0)
        context.insert(template)
        let block = TemplateBlock(id: "tb-1", order: 0, blockType: .single, restSeconds: 0, sectionKind: .wod, wodPrescription: wodPrescription(exerciseID: "ex-a"))
        block.template = template
        context.insert(block)
        try context.save()

        let (summary, _) = try ExerciseReferenceRedirectionService.redirect(from: source, to: target, in: context)
        try context.save()

        XCTAssertEqual(summary.wodPrescriptionCount, 1)
        XCTAssertEqual(block.wodPrescription?.rounds.first?.movements.first?.exerciseID, "ex-b")
    }

    /// A WOD payload that doesn't reference the source exercise at all must
    /// be left completely untouched -- not re-encoded, not counted.
    func testDoesNotTouchWODPayloadsThatDoNotReferenceTheSourceExercise() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let source = makeExercise(id: "ex-a", name: "Old Name")
        let target = makeExercise(id: "ex-b", name: "New Name")
        let unrelated = makeExercise(id: "ex-c", name: "Unrelated")
        context.insert(source)
        context.insert(target)
        context.insert(unrelated)
        let client = Client(id: "cl-1", name: "Test")
        context.insert(client)
        let session = WorkoutSession(id: "se-1", date: Date(), dateOrigin: .asRecorded, dateRaw: "raw", weekNumber: 1, sourceSheet: "App", sourceRow: 0)
        session.client = client
        context.insert(session)
        let block = SessionBlock(order: 0, blockType: .single, sourceRow: 0, sectionKind: .wod)
        block.session = session
        block.wodPayload = WODPayload(prescription: wodPrescription(exerciseID: "ex-c"), result: WODResult())
        context.insert(block)
        try context.save()
        let rawBefore = block.wodPayloadRawJSON

        let (summary, _) = try ExerciseReferenceRedirectionService.redirect(from: source, to: target, in: context)

        XCTAssertEqual(summary.wodPayloadCount, 0)
        XCTAssertEqual(block.wodPayloadRawJSON, rawBefore, "an unrelated block's payload must not even be re-encoded")
    }

    // MARK: - Undo restores exactly what this call changed

    func testUndoRestoresEntriesSlotsAndWODReferencesToTheOriginalExercise() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let source = makeExercise(id: "ex-a", name: "Old Name")
        let target = makeExercise(id: "ex-b", name: "New Name")
        context.insert(source)
        context.insert(target)
        let client = Client(id: "cl-1", name: "Test")
        context.insert(client)
        let session = WorkoutSession(id: "se-1", date: Date(), dateOrigin: .asRecorded, dateRaw: "raw", weekNumber: 1, sourceSheet: "App", sourceRow: 0)
        session.client = client
        context.insert(session)
        let strengthBlock = SessionBlock(order: 0, blockType: .single, sourceRow: 0)
        strengthBlock.session = session
        context.insert(strengthBlock)
        let entry = ExerciseEntry(order: 0, exerciseIdRef: "ex-a", exerciseRaw: "Old Name", plannedSets: 3, exercise: source)
        entry.block = strengthBlock
        context.insert(entry)
        let wodBlock = SessionBlock(order: 1, blockType: .single, sourceRow: 0, sectionKind: .wod)
        wodBlock.session = session
        wodBlock.wodPayload = WODPayload(prescription: wodPrescription(exerciseID: "ex-a"), result: WODResult())
        context.insert(wodBlock)
        let template = SessionTemplate(id: "tpl-1", name: "Push Day", order: 0)
        context.insert(template)
        let templateBlock = TemplateBlock(id: "tb-1", order: 0, blockType: .single, restSeconds: 60)
        templateBlock.template = template
        context.insert(templateBlock)
        let slot = TemplateExerciseSlot(id: "slot-1", order: 0, exerciseID: "ex-a", defaultSets: 3, defaultRepTarget: .fixed(value: 10, raw: "10"))
        slot.block = templateBlock
        context.insert(slot)
        try context.save()
        let wodRawBefore = wodBlock.wodPayloadRawJSON

        let (_, undo) = try ExerciseReferenceRedirectionService.redirect(from: source, to: target, in: context)
        try context.save()
        XCTAssertEqual(entry.exercise?.id, "ex-b")
        XCTAssertEqual(slot.exerciseID, "ex-b")
        XCTAssertEqual(wodBlock.wodPayload?.prescription.rounds.first?.movements.first?.exerciseID, "ex-b")

        ExerciseReferenceRedirectionService.undo(undo, source: source, in: context)
        try context.save()

        XCTAssertEqual(entry.exercise?.id, "ex-a")
        XCTAssertEqual(entry.exerciseIdRef, "ex-a")
        XCTAssertEqual(slot.exerciseID, "ex-a")
        XCTAssertEqual(wodBlock.wodPayloadRawJSON, wodRawBefore, "undo restores the EXACT original bytes, not a re-derived approximation")
    }

    /// Undo must never touch a block this specific redirect call didn't
    /// itself modify, even if that block references the SAME source
    /// exercise -- it was added/changed by some later, independent
    /// operation and its own history should not be silently reverted.
    func testUndoNeverTouchesABlockAddedAfterTheRedirectEvenIfItReferencesTheSameExercise() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let source = makeExercise(id: "ex-a", name: "Old Name")
        let target = makeExercise(id: "ex-b", name: "New Name")
        context.insert(source)
        context.insert(target)
        let client = Client(id: "cl-1", name: "Test")
        context.insert(client)
        let session = WorkoutSession(id: "se-1", date: Date(), dateOrigin: .asRecorded, dateRaw: "raw", weekNumber: 1, sourceSheet: "App", sourceRow: 0)
        session.client = client
        context.insert(session)
        let block = SessionBlock(order: 0, blockType: .single, sourceRow: 0)
        block.session = session
        context.insert(block)
        let entry = ExerciseEntry(order: 0, exerciseIdRef: "ex-a", exerciseRaw: "Old Name", plannedSets: 3, exercise: source)
        entry.block = block
        context.insert(entry)
        try context.save()

        let (_, undo) = try ExerciseReferenceRedirectionService.redirect(from: source, to: target, in: context)
        try context.save()

        // A SEPARATE, later entry against the SAME source exercise (e.g.
        // the coach added a brand new set logged against "ex-a" again,
        // unrelated to the merge above -- possible if the source exercise
        // was never deleted).
        let laterEntry = ExerciseEntry(order: 1, exerciseIdRef: "ex-a", exerciseRaw: "Old Name", plannedSets: 1, exercise: source)
        laterEntry.block = block
        context.insert(laterEntry)
        try context.save()

        ExerciseReferenceRedirectionService.undo(undo, source: source, in: context)
        try context.save()

        XCTAssertEqual(entry.exercise?.id, "ex-a", "the originally-redirected entry is restored")
        XCTAssertEqual(laterEntry.exercise?.id, "ex-a", "the later, independent entry was never touched by either the redirect or its undo")
    }
}
