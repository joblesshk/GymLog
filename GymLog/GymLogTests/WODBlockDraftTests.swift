import XCTest
@testable import GymLogKit

/// 2026-09-07 M2: `WODBlockDraft`/`WODMovementDraft` -- the in-progress,
/// never-yet-saved WOD authoring/recording state, its conversion to the
/// real `WODPrescription`/`WODResult` types, and its snapshot round-trip
/// for autosave/restore (reusing M0's `DraftPersistence`/debounce machinery
/// unchanged, per `CONTRACT-M10.md` §7).
@MainActor
final class WODBlockDraftTests: XCTestCase {

    private func makeExercise(id: String = "ex-burpee", metric: RecordingMetric = .reps) -> Exercise {
        Exercise(
            id: id, canonicalName: "Burpee", aliases: [], movementPattern: .conditioning, equipment: .bodyweight,
            loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 0, needsReview: false, reviewReason: nil,
            recordingMetric: metric
        )
    }

    // MARK: - Resolving to the real model types

    func testResolvedPrescriptionForAMRAP() {
        let draft = WODBlockDraft(name: "Cindy-ish", format: .amrap, timeCapSeconds: 720)
        let exercise = makeExercise()
        let movement = WODMovementDraft(exercise: exercise, quantityKind: .reps, quantityValue: 10)
        draft.movements = [movement]

        let prescription = draft.resolvedPrescription(prescriptionID: "wod-1")
        XCTAssertEqual(prescription.format, .amrap)
        XCTAssertEqual(prescription.timeCapSeconds, 720)
        XCTAssertEqual(prescription.rounds.count, 1, "v1 authoring UI produces a single round template")
        XCTAssertEqual(prescription.rounds[0].movements.count, 1)
        XCTAssertEqual(prescription.rounds[0].movements[0].exerciseID, "ex-burpee")
        guard case .reps(let value, _) = prescription.rounds[0].movements[0].quantity else { return XCTFail() }
        XCTAssertEqual(value, 10)
    }

    func testResolvedResultAMRAPProgress() {
        let draft = WODBlockDraft(format: .amrap)
        draft.status = .completed
        draft.completedRounds = 5
        draft.partialRoundReps = 12

        let result = draft.resolvedResult()
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.completedRounds, 5)
        guard case .reps(let partial, _) = result.partialRoundQuantity else { return XCTFail() }
        XCTAssertEqual(partial, 12, "must stay two integers (5 rounds, 12 reps), never 5.12")
    }

    func testResolvedResultForTimeElapsedOnlySetWhenCompleted() {
        let draft = WODBlockDraft(format: .forTime)
        draft.status = .capped
        draft.elapsedSeconds = 512 // set by mistake/leftover state
        let result = draft.resolvedResult()
        XCTAssertNil(result.elapsedSeconds, "a capped attempt must never carry a completion time, even if the field happens to hold a stale value")
    }

    func testResolvedResultForTimeCompleted() {
        let draft = WODBlockDraft(format: .forTime)
        draft.status = .completed
        draft.elapsedSeconds = 512
        let result = draft.resolvedResult()
        XCTAssertEqual(result.elapsedSeconds, 512)
    }

    // MARK: - Movement management

    func testAddAndRemoveMovementRespectsMinimumOfOne() {
        let draft = WODBlockDraft()
        XCTAssertEqual(draft.movements.count, 1, "starts with exactly one blank movement row")
        // 2026-09-09 起动作行都是"先选动作再建行"，名字是必填参数。
        draft.addMovement(named: "Wall ball")
        XCTAssertEqual(draft.movements.count, 2)
        XCTAssertEqual(draft.movements[1].nameText, "Wall ball")
        let firstID = draft.movements[0].id
        draft.removeMovement(id: firstID)
        XCTAssertEqual(draft.movements.count, 1)
        // Cannot remove the last remaining movement.
        let lastID = draft.movements[0].id
        draft.removeMovement(id: lastID)
        XCTAssertEqual(draft.movements.count, 1, "a WOD must always have at least one movement")
    }

    func testApplyExerciseSeedsNameAndDefaultQuantityKindFromRecordingMetric() {
        let movement = WODMovementDraft()
        let timedExercise = makeExercise(id: "ex-plank", metric: .time)
        movement.applyExercise(timedExercise)
        XCTAssertEqual(movement.nameText, "Burpee") // canonicalName is "Burpee" in this fixture regardless of id
        XCTAssertEqual(movement.quantityKind, .seconds)

        let distanceExercise = makeExercise(id: "ex-row", metric: .distance)
        let movement2 = WODMovementDraft()
        movement2.applyExercise(distanceExercise)
        XCTAssertEqual(movement2.quantityKind, .meters)
    }

    func testApplyFormatDefaultsSetsConventionalScoringRule() {
        let draft = WODBlockDraft(format: .amrap, scoringRule: .roundsAndReps)
        draft.applyFormatDefaults(.forTime)
        XCTAssertEqual(draft.format, .forTime)
        XCTAssertEqual(draft.scoringRule, .completionTime)
    }

    // MARK: - Snapshot round trip

    func testWODBlockDraftSnapshotRoundTrips() {
        let exercise = makeExercise()
        let draft = WODBlockDraft(name: "Fran", format: .forTime, timeCapSeconds: 720)
        draft.movements = [WODMovementDraft(exercise: exercise, quantityKind: .reps, quantityValue: 21, loadKg: 43)]
        draft.status = .completed
        draft.elapsedSeconds = 512

        let snapshot = draft.snapshot()
        let restored = WODBlockDraft.restore(from: snapshot, exercises: [exercise])
        XCTAssertEqual(restored.name, "Fran")
        XCTAssertEqual(restored.format, .forTime)
        XCTAssertEqual(restored.status, .completed)
        XCTAssertEqual(restored.elapsedSeconds, 512)
        XCTAssertEqual(restored.movements.first?.exercise?.id, "ex-burpee")
        XCTAssertEqual(restored.movements.first?.loadKg, 43)
    }

    /// The exercise was deleted/merged away between snapshot and restore --
    /// the movement must still restore (its `nameText` was captured
    /// independently), just with `exercise == nil`, never dropped like a
    /// strength entry would be.
    func testWODMovementSurvivesExerciseDeletionUnlikeStrengthEntries() {
        let exercise = makeExercise()
        let movement = WODMovementDraft(exercise: exercise, nameText: "Burpee", quantityKind: .reps, quantityValue: 10)
        let snapshot = movement.snapshot()

        let restored = WODMovementDraft.restore(from: snapshot, exercises: []) // exercise no longer exists
        XCTAssertNil(restored.exercise)
        XCTAssertEqual(restored.nameText, "Burpee", "the name snapshot must survive independent of the exercise library")
        XCTAssertEqual(restored.quantityValue, 10)
    }

    func testBlockDraftRestoreDispatchesToWODPath() {
        let exercise = makeExercise()
        let wodDraft = WODBlockDraft(name: "Test WOD", format: .emom)
        wodDraft.movements = [WODMovementDraft(exercise: exercise, quantityKind: .reps, quantityValue: 15)]
        let blockDraft = BlockDraft(sectionKind: .wod, wodDraft: wodDraft)

        let snapshot = blockDraft.snapshot()
        XCTAssertEqual(snapshot.sectionKind, .wod)
        XCTAssertNotNil(snapshot.wodDraft)

        let (restored, dropped, uncertain) = BlockDraft.restore(from: snapshot, exercises: [exercise])
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(uncertain, 0)
        XCTAssertEqual(restored?.sectionKind, .wod)
        XCTAssertEqual(restored?.wodDraft?.name, "Test WOD")
        XCTAssertEqual(restored?.wodDraft?.format, .emom)
    }

    // MARK: - Identity/version (resolveIdentity) -- 2026-09-10

    func testFromScratchBlockMintsAStableIDCachedForRepeatedResolves() {
        let draft = WODBlockDraft()
        let (id1, revision1) = draft.resolveIdentity()
        XCTAssertEqual(revision1, 1)
        XCTAssertFalse(id1.isEmpty)
        // Resolving identity CACHES it onto the draft (`prescriptionID`) --
        // essential for "暫存三次再結束": `TodayView` re-commits the SAME
        // live draft instance on every "暫存" press with no reload in
        // between, so a second resolve on the same never-reloaded instance
        // must reuse the SAME id, not mint a fresh random one each time.
        let (id2, revision2) = draft.resolveIdentity()
        XCTAssertEqual(id1, id2, "repeated resolves on the SAME unmodified draft instance must be stable")
        XCTAssertEqual(revision2, 1, "nothing changed between the two resolves -- revision must not bump")
    }

    /// The core bug this review found: copying a saved prescription for a
    /// same-standard retest must carry over the EXACT SAME id and revision,
    /// otherwise `WODPRAnalyzer` can never compare the retest against the
    /// original (every retest would start its own brand-new PR group and
    /// falsely register as a "first-ever" record).
    func testCopyingAnUnmodifiedPrescriptionKeepsSameIDAndRevision() {
        let exercise = makeExercise()
        let original = WODBlockDraft(format: .forTime, timeCapSeconds: 900)
        original.movements = [WODMovementDraft(exercise: exercise, quantityKind: .reps, quantityValue: 21)]
        let (originalID, originalRevision) = original.resolveIdentity()
        XCTAssertEqual(originalRevision, 1)

        // Simulate "复制上次课次": re-load the ALREADY-SAVED prescription
        // (as it would come back from `SessionBlock.wodPayload.prescription`)
        // into a fresh draft the same way `copyLastSession` does.
        let savedPrescription = original.resolvedPrescription(prescriptionID: originalID, revision: originalRevision)
        let copy = WODBlockDraft.fromPrescription(savedPrescription, exercises: [exercise])
        let (copyID, copyRevision) = copy.resolveIdentity()

        XCTAssertEqual(copyID, originalID, "an unmodified retest copy must keep the exact same prescription id")
        XCTAssertEqual(copyRevision, originalRevision, "an unmodified retest copy must keep the exact same revision")
    }

    /// Editing a comparability field (here: the prescribed load) before
    /// saving the copy must bump the revision -- the retest is no longer
    /// "the same workout", so it must not silently blend into the original
    /// prescription's PR group.
    func testEditingAComparabilityFieldAfterCopyingBumpsRevision() {
        let exercise = makeExercise()
        let original = WODBlockDraft(format: .forTime, timeCapSeconds: 900)
        original.movements = [WODMovementDraft(exercise: exercise, quantityKind: .reps, quantityValue: 21, loadKg: 43)]
        let (originalID, originalRevision) = original.resolveIdentity()

        let savedPrescription = original.resolvedPrescription(prescriptionID: originalID, revision: originalRevision)
        let copy = WODBlockDraft.fromPrescription(savedPrescription, exercises: [exercise])
        copy.movements[0].loadKg = 50 // coach bumped the weight before saving

        let (copyID, copyRevision) = copy.resolveIdentity()
        XCTAssertEqual(copyID, originalID, "still the same underlying WOD identity")
        XCTAssertEqual(copyRevision, originalRevision + 1, "a comparability-affecting edit must bump revision")
    }

    /// Editing ONLY the result (score/notes/variant) -- never the
    /// prescription -- must never touch identity or revision, even when
    /// re-saving the SAME session repeatedly ("暫存三次再結束").
    func testEditingOnlyTheResultNeverChangesIdentityOrRevision() {
        let exercise = makeExercise()
        let draft = WODBlockDraft(format: .forTime, timeCapSeconds: 900)
        draft.movements = [WODMovementDraft(exercise: exercise, quantityKind: .reps, quantityValue: 21)]
        let (id1, revision1) = draft.resolveIdentity()

        let savedPrescription = draft.resolvedPrescription(prescriptionID: id1, revision: revision1)
        let continued = WODBlockDraft.fromPrescription(savedPrescription, exercises: [exercise])
        continued.applyExistingResult(WODResult(status: .notRecorded))
        continued.status = .completed
        continued.elapsedSeconds = 512
        continued.notes = "felt good"

        let (id2, revision2) = continued.resolveIdentity()
        XCTAssertEqual(id2, id1)
        XCTAssertEqual(revision2, revision1)
    }

    /// Reordering blocks in "今天" must never change a WOD's identity --
    /// once a block has an established identity (loaded via
    /// `fromPrescription`, exactly what happens on every re-commit of an
    /// already-saved block), `resolveIdentity()` has no notion of
    /// session/block position at all, so re-resolving it (as a second
    /// "暫存" of the SAME draft would, regardless of where this block now
    /// sits in some session's block array) always reproduces the SAME id.
    func testIdentityHasNoDependencyOnAnyExternalPositionInformation() {
        let exercise = makeExercise()
        let draft = WODBlockDraft(format: .forTime)
        draft.movements = [WODMovementDraft(exercise: exercise, quantityKind: .reps, quantityValue: 21)]
        let (savedID, savedRevision) = draft.resolveIdentity()
        let savedPrescription = draft.resolvedPrescription(prescriptionID: savedID, revision: savedRevision)
        let reloaded = WODBlockDraft.fromPrescription(savedPrescription, exercises: [exercise])

        let (idBefore, _) = reloaded.resolveIdentity()
        let (idAfter, _) = reloaded.resolveIdentity()
        XCTAssertEqual(idBefore, idAfter)
        XCTAssertEqual(idBefore, savedID, "an established identity is stable across repeated re-commits, independent of block position")
    }

    // MARK: - Full result preservation on continue-edit round trip

    /// "打开历史→不修改→保存" must keep `actualMovements`/`rpe`/
    /// `recordedVia`/`intervalResults` -- fields this v1 UI has no editor
    /// for -- exactly as they were, never silently zeroed.
    func testContinueEditingPreservesFieldsWithNoUIEditor() {
        let exercise = makeExercise()
        let draft = WODBlockDraft(format: .forTime, timeCapSeconds: 900)
        draft.movements = [WODMovementDraft(exercise: exercise, quantityKind: .reps, quantityValue: 21)]
        let originalResult = WODResult(
            status: .completed, elapsedSeconds: 512, variant: .rx,
            actualMovements: [WODMovementPrescription(stepID: "s1", exerciseID: nil, exerciseNameSnapshot: "Ring Row (substituted)", quantity: .reps(21, raw: "21"))],
            notes: "subbed ring rows for pull-ups", rpe: 8.5, recordedVia: .timer
        )
        draft.applyExistingResult(originalResult)

        // "不修改直接保存"
        let resaved = draft.resolvedResult()
        XCTAssertEqual(resaved.actualMovements, originalResult.actualMovements)
        XCTAssertEqual(resaved.rpe, 8.5)
        XCTAssertEqual(resaved.recordedVia, .timer, "recordedVia must not be silently forced back to .manual on a continue-edit save")
        XCTAssertEqual(resaved.notes, "subbed ring rows for pull-ups")
    }

    func testCappedProgressIsDroppedOnceStatusNoLongerCappedOrStopped() {
        let draft = WODBlockDraft(format: .forTime)
        draft.applyExistingResult(WODResult(status: .capped, cappedAtStepID: "s1", cappedProgress: .reps(7, raw: "7")))
        draft.status = .completed
        draft.elapsedSeconds = 500
        let result = draft.resolvedResult()
        XCTAssertNil(result.cappedAtStepID, "a stale cap location must not survive once the outcome is no longer capped/stopped")
        XCTAssertNil(result.cappedProgress)
    }

    /// A `.emom`/`.interval` total recorded in one unit (say, meters) must
    /// round-trip in THAT unit, not silently become reps.
    func testTotalCompletedValueRoundTripsItsActualUnit() {
        let draft = WODBlockDraft(format: .interval)
        draft.applyExistingResult(WODResult(status: .completed, typedTotals: [.meters(500, raw: "500")], variant: .rx))
        XCTAssertEqual(draft.totalCompletedValue, 500)
        XCTAssertEqual(draft.totalCompletedQuantityKind, .meters)
        let result = draft.resolvedResult()
        guard case .meters(let value, _) = result.typedTotals.first else { return XCTFail("expected meters, got \(String(describing: result.typedTotals.first))") }
        XCTAssertEqual(value, 500, "must never silently become reps")
    }

    // MARK: - Multi-round authoring (21-15-9)

    func testAddRoundClonesMovementsFromTheLastRound() {
        let exercise = makeExercise(id: "ex-thruster")
        let draft = WODBlockDraft(format: .forTime)
        draft.movements = [WODMovementDraft(exercise: exercise, quantityKind: .reps, quantityValue: 21)]
        draft.addRound()
        XCTAssertEqual(draft.rounds.count, 2)
        XCTAssertEqual(draft.rounds[1].movements.count, 1)
        XCTAssertEqual(draft.rounds[1].movements[0].exercise?.id, "ex-thruster")
        XCTAssertEqual(draft.rounds[1].movements[0].quantityValue, 21, "cloned round starts at the same quantity, independently editable afterward")

        // Independent editing: changing round 2's quantity must not affect round 1's.
        draft.rounds[1].movements[0].quantityValue = 15
        XCTAssertEqual(draft.rounds[0].movements[0].quantityValue, 21)
    }

    func testRemoveRoundRespectsMinimumOfOne() {
        let draft = WODBlockDraft()
        XCTAssertEqual(draft.rounds.count, 1)
        draft.removeRound(id: draft.rounds[0].id)
        XCTAssertEqual(draft.rounds.count, 1, "a WOD must always have at least one round")
    }

    func testMoveRoundUpAndDown() {
        let draft = WODBlockDraft()
        draft.movements = [WODMovementDraft(nameText: "Thruster", quantityValue: 21)]
        draft.addRound()
        draft.rounds[1].movements[0].quantityValue = 15
        draft.addRound()
        draft.rounds[2].movements[0].quantityValue = 9
        XCTAssertEqual(draft.rounds.map { $0.movements[0].quantityValue }, [21, 15, 9])

        draft.moveRoundDown(id: draft.rounds[0].id)
        XCTAssertEqual(draft.rounds.map { $0.movements[0].quantityValue }, [15, 21, 9])
        draft.moveRoundUp(id: draft.rounds[2].id)
        XCTAssertEqual(draft.rounds.map { $0.movements[0].quantityValue }, [15, 9, 21])
    }

    /// 21-15-9 is three ROUNDS with different quantities, not one round with
    /// a "total reps" field standing in for all three.
    func testResolvedPrescriptionProducesIndependentRoundsFor211591() {
        let exercise = makeExercise(id: "ex-thruster")
        let draft = WODBlockDraft(format: .forTime)
        draft.movements = [WODMovementDraft(exercise: exercise, quantityKind: .reps, quantityValue: 21)]
        draft.addRound()
        draft.rounds[1].movements[0].quantityValue = 15
        draft.addRound()
        draft.rounds[2].movements[0].quantityValue = 9

        let prescription = draft.resolvedPrescription(prescriptionID: "wod-1")
        XCTAssertEqual(prescription.rounds.count, 3)
        let quantities = prescription.rounds.map { round -> Int in
            guard case .reps(let v, _) = round.movements[0].quantity else { return -1 }
            return v
        }
        XCTAssertEqual(quantities, [21, 15, 9])
    }

    /// Loading a saved multi-round prescription back into a draft must
    /// bring back ALL rounds, not just the first -- the exact data-loss bug
    /// this review flagged (`WODBlockDraft.fromPrescription` used to do
    /// `prescription.rounds.first?.movements`).
    func testFromPrescriptionRestoresAllRoundsNotJustTheFirst() {
        let exercise = makeExercise(id: "ex-thruster")
        let rounds = [21, 15, 9].enumerated().map { index, reps in
            WODRoundPrescription(roundIndex: index, movements: [
                WODMovementPrescription(stepID: "s\(index)", exerciseID: "ex-thruster", exerciseNameSnapshot: "Thruster", quantity: .reps(reps, raw: "\(reps)")),
            ])
        }
        let prescription = WODPrescription(id: "wod-fran", revision: 1, format: .forTime, rounds: rounds, scoringRule: .completionTime)

        let draft = WODBlockDraft.fromPrescription(prescription, exercises: [exercise])
        XCTAssertEqual(draft.rounds.count, 3, "all three rounds must survive fromPrescription, not just the first")
        XCTAssertEqual(draft.rounds.map { $0.movements[0].quantityValue }, [21, 15, 9])
    }

    /// A legacy snapshot (`sectionKind == nil`, pre-M2) must restore exactly
    /// as before -- the strength path, unaffected.
    func testLegacySnapshotWithoutSectionKindStillRestoresAsStrength() {
        let exercise = makeExercise()
        let entrySnapshot = EntryDraftSnapshot(
            id: UUID(), exerciseID: exercise.id,
            rounds: [RoundDraftSnapshot(id: UUID(), setsCount: 3, load: .absolute(kg: 40, raw: "40"), target: .fixed(value: 8, raw: "8"), actual: .fixed(value: 8, raw: "8"))],
            restSeconds: nil, recordingMetric: .reps
        )
        let legacyBlockSnapshot = BlockDraftSnapshot(id: UUID(), blockType: .single, restSeconds: nil, entries: [entrySnapshot])
        XCTAssertNil(legacyBlockSnapshot.sectionKind)

        let (restored, dropped, _) = BlockDraft.restore(from: legacyBlockSnapshot, exercises: [exercise])
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(restored?.sectionKind, .strength)
        XCTAssertNil(restored?.wodDraft)
        XCTAssertEqual(restored?.entries.count, 1)
    }
}
