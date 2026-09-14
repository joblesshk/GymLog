import XCTest
import SwiftData
@testable import GymLogKit

@MainActor final class CloudVoiceTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    var draft: TodayDraftStore!
    var executor: CloudVoiceExecutor!
    var squat: Exercise!
    var plank: Exercise!
    var exercises: [Exercise] { [squat, plank] }
    override func setUpWithError() throws {
        container = try TestSupport.makeInMemoryContainer(); context = ModelContext(container)
        squat = Exercise(id: "squat", canonicalName: "Back Squat", aliases: ["槓鈴背蹲"], movementPattern: .unknown,
            equipment: .barbell, loadDirection: .unknown, isUnilateral: false, occurrenceCount: 0, needsReview: false, reviewReason: nil)
        plank = Exercise(id: "plank", canonicalName: "Plank", aliases: ["平板支撐"], movementPattern: .unknown,
            equipment: .bodyweight, loadDirection: .unknown, isUnilateral: false, occurrenceCount: 0, needsReview: false, reviewReason: nil,
            recordingMetric: .time)
        context.insert(squat); context.insert(plank)
        draft = TodayDraftStore(); executor = CloudVoiceExecutor()
    }
    func run(_ ops: [CloudVoiceOperation], confirmed: Bool = false) throws -> CloudVoiceExecutor.Result {
        try executor.apply(CloudVoicePlan(operations: ops), transcript: "安排實際", requestID: UUID(), origin: CloudDraftState(draft),
            draft: draft, exercises: exercises, clientID: "client", context: context, confirmed: confirmed)
    }
    func start() throws {
        _ = try run([.init(kind: .startSession, evidence: "安排"), .init(kind: .addExercise, evidence: "安排", exerciseID: "squat", ref: "a")])
    }
    func testWholeDayPlanDefaultsAndUndoToInactive() throws {
        _ = try run([.init(kind: .startSession, evidence: "安排"),
            .init(kind: .addExercise, evidence: "安排", exerciseID: "squat", sets: 4, quantity: 8, unit: "reps", load: .init(kind: "absolute", value: 60, unit: "kg")),
            .init(kind: .addExercise, evidence: "安排", exerciseID: "plank")])
        XCTAssertEqual(draft.allEntries.count, 2)
        XCTAssertEqual(draft.allEntries[0].plannedSets, 4)
        XCTAssertEqual(draft.allEntries[1].rounds[0].targetQuantity, 30)
        XCTAssertEqual(draft.allEntries[1].rounds[0].load, .bodyweight(raw: "BW"))
        for e in draft.allEntries { for set in e.resolvedSets() { XCTAssertEqual(set.actual, .unknown(raw: "")) } }
        try executor.undo(draft: draft, exercises: exercises)
        XCTAssertFalse(draft.isActive); XCTAssertTrue(draft.blocks.isEmpty)
    }
    func testBatchFailureLeavesNoHalfCreatedSession() throws {
        let before = CloudDraftState(draft)
        XCTAssertThrowsError(try run([.init(kind: .startSession, evidence: "安排"),
            .init(kind: .addExercise, evidence: "安排", exerciseID: "squat"), .init(kind: .addExercise, evidence: "安排", exerciseID: "missing")]))
        XCTAssertEqual(CloudDraftState(draft), before); XCTAssertFalse(executor.canUndo)
    }
    func testEarlierReferenceAndPerSidePounds() throws {
        _ = try run([.init(kind: .startSession, evidence: "安排"), .init(kind: .addExercise, evidence: "安排", exerciseID: "squat", ref: "a"),
            .init(kind: .updatePlan, evidence: "安排", target: "a", setIndex: 2, load: .init(kind: "perSide", value: 10, unit: "lb"))])
        let sets = draft.allEntries[0].resolvedSets()
        if case .perSide(let kg, _) = sets[1].load { XCTAssertEqual(kg, 4.5359237, accuracy: 0.00001) } else { XCTFail() }
        XCTAssertEqual(sets[0].load, PrefillResolver.defaultLoad); XCTAssertEqual(sets[2].load, PrefillResolver.defaultLoad)
    }
    func testPhysicalActualOnlyMarksOneSetIncludingZero() throws {
        try start(); let target = draft.allEntries[0].id.uuidString
        _ = try run([.init(kind: .recordActual, evidence: "安排實際", target: target, setIndex: 2, quantity: 0, unit: "reps")])
        let sets = draft.allEntries[0].resolvedSets()
        XCTAssertEqual(sets[0].actual, .unknown(raw: "")); XCTAssertEqual(sets[1].actual, .fixed(value: 0, raw: "0")); XCTAssertEqual(sets[2].actual, .unknown(raw: ""))
    }
    func testLastSetAndMinutesConversion() throws {
        _ = try run([.init(kind: .startSession, evidence: "安排"), .init(kind: .addExercise, evidence: "安排", exerciseID: "plank", ref: "p"),
            .init(kind: .updatePlan, evidence: "安排", target: "p", setIndex: -1, quantity: 0.5, unit: "min")])
        XCTAssertEqual(draft.allEntries[0].resolvedSets().last?.target, .time(seconds: 30, raw: "30"))
    }
    func testWrongDimensionIsAtomic() throws {
        try start(); let before = CloudDraftState(draft)
        XCTAssertThrowsError(try run([.init(kind: .addExercise, evidence: "安排", exerciseID: "plank", quantity: 10, unit: "reps")]))
        XCTAssertEqual(before, CloudDraftState(draft))
    }
    func testUnspokenTargetAndInvalidSetRejected() throws {
        try start()
        XCTAssertThrowsError(try run([.init(kind: .updatePlan, evidence: "安排", target: "unknown", sets: 5)]))
        XCTAssertThrowsError(try run([.init(kind: .recordActual, evidence: "安排實際", target: draft.allEntries[0].id.uuidString, quantity: 8, unit: "reps")]))
        XCTAssertThrowsError(try run([.init(kind: .updatePlan, evidence: "安排", target: draft.allEntries[0].id.uuidString, setIndex: 99, quantity: 8, unit: "reps")]))
    }
    func testWholePlanUpdatePreservesResultsAndOtherFields() throws {
        try start(); let e = draft.allEntries[0]; e.rounds[0].actualQuantity = 7
        let target = e.id.uuidString
        _ = try run([.init(kind: .updatePlan, evidence: "安排", target: target, quantity: 12, unit: "reps")])
        XCTAssertEqual(draft.allEntries[0].resolvedSets()[0].actual, .fixed(value: 7, raw: "7"))
        XCTAssertEqual(draft.allEntries[0].plannedSets, 3)
    }
    func testResizeAddsUnrecordedSets() throws {
        try start(); let e = draft.allEntries[0]; e.rounds[0].actualQuantity = 8
        _ = try run([.init(kind: .updatePlan, evidence: "安排", target: e.id.uuidString, sets: 4)])
        XCTAssertEqual(draft.allEntries[0].resolvedSets().last?.actual, .unknown(raw: ""))
    }
    func testDestructiveConfirmationThenUndoRestoresResults() throws {
        try start(); let e = draft.allEntries[0]; e.rounds[0].actualQuantity = 8
        let before = CloudDraftState(draft)
        let ops = [CloudVoiceOperation(kind: .removeExercise, evidence: "安排", target: e.id.uuidString)]
        XCTAssertThrowsError(try run(ops)) { XCTAssertTrue($0 is CloudVoiceExecutionNeedsConfirmation) }
        XCTAssertEqual(before, CloudDraftState(draft))
        _ = try run(ops, confirmed: true); XCTAssertTrue(draft.allEntries.isEmpty)
        try executor.undo(draft: draft, exercises: exercises); XCTAssertEqual(before, CloudDraftState(draft))
    }
    func testManualEditBlocksUndo() throws {
        try start(); draft.allEntries[0].rounds[0].targetQuantity = 99
        XCTAssertThrowsError(try executor.undo(draft: draft, exercises: exercises)); XCTAssertEqual(draft.allEntries[0].rounds[0].targetQuantity, 99)
    }
    func testEmptyDraftStateIncludesIdentityAndActiveFlag() {
        let before = CloudDraftState(draft); draft.startNew(clientID: "other")
        XCTAssertNotEqual(before, CloudDraftState(draft))
    }
    func testStaleAndDuplicateRequestsRejected() throws {
        let origin = CloudDraftState(draft); let id = UUID(); let plan = CloudVoicePlan(operations: [.init(kind: .startSession, evidence: "安排")])
        _ = try executor.apply(plan, transcript: "安排實際", requestID: id, origin: origin, draft: draft, exercises: exercises, clientID: "client", context: context)
        XCTAssertThrowsError(try executor.apply(plan, transcript: "安排實際", requestID: id, origin: CloudDraftState(draft), draft: draft, exercises: exercises, clientID: "client", context: context))
    }
    func testUnknownActualSurvivesSnapshotAndSetLoader() throws {
        try start()
        let snap = draft.snapshot()!
        let data = try JSONEncoder().encode(snap); let loaded = try JSONDecoder().decode(TodayDraftSnapshot.self, from: data)
        let restored = TodayDraftStore(); restored.restore(from: loaded, exercises: exercises)
        XCTAssertFalse(restored.allEntries[0].rounds[0].actualRecorded)
        XCTAssertEqual(restored.allEntries[0].resolvedSets()[0].actual, .unknown(raw: ""))
    }
    func testOldSnapshotDefaultsToRecorded() throws {
        let r = RoundDraftSnapshot(id: UUID(), setsCount: 1, load: .bodyweight(raw: "BW"), targetQuantity: 10, actualQuantity: 8)
        let e = EntryDraftSnapshot(id: UUID(), exerciseID: "squat", rounds: [r], restSeconds: nil, recordingMetric: .reps)
        XCTAssertTrue(EntryDraft.restore(from: e, exercises: exercises).entry!.rounds[0].actualRecorded)
    }
    func testSupersetCompositionDoesNotInventResults() throws {
        _ = try run([.init(kind: .startSession, evidence: "安排"), .init(kind: .addExercise, evidence: "安排", exerciseID: "squat", ref: "s"),
            .init(kind: .addExercise, evidence: "安排", exerciseID: "plank", ref: "p"),
            .init(kind: .composeSuperset, evidence: "安排", targets: ["s", "p"], restSeconds: 90)])
        XCTAssertEqual(draft.blocks.count, 1); XCTAssertEqual(draft.blocks[0].blockType, .superset)
        XCTAssertEqual(draft.blocks[0].restSeconds, 90)
        XCTAssertTrue(draft.allEntries.flatMap(\.rounds).allSatisfy { !$0.actualRecorded && $0.setsCount == 1 })
        _ = try run([.init(kind: .dissolveSuperset, evidence: "安排", target: draft.allEntries[0].id.uuidString)])
        XCTAssertEqual(draft.blocks.count, 2)
    }
    func testMoveToFirstKeepsIdentity() throws {
        _ = try run([.init(kind: .startSession, evidence: "安排"), .init(kind: .addExercise, evidence: "安排", exerciseID: "squat", ref: "s"),
            .init(kind: .addExercise, evidence: "安排", exerciseID: "plank", ref: "p"), .init(kind: .moveExercise, evidence: "安排", target: "p")])
        XCTAssertEqual(draft.allEntries.first?.exercise.id, "plank")
    }
    func testInferredPlanDecodesAndRemainsReversible() throws {
        let plan = try CloudVoiceInterpreter.decode(#"{"version":1,"assumptions":["推定做深蹲"],"operations":[{"kind":"startSession","evidence":"安排"},{"kind":"addExercise","evidence":"安排","exerciseID":"squat"}]}"#)
        XCTAssertEqual(plan.assumptions, ["推定做深蹲"])
        XCTAssertEqual(try JSONDecoder().decode(CloudVoicePlan.self, from: JSONEncoder().encode(plan)), plan)
        _ = try run(plan.operations)
        XCTAssertTrue(draft.isActive)
        XCTAssertFalse(draft.allEntries[0].rounds[0].actualRecorded)
    }
    func testUnknownFieldsAndTruncatedJSONRejected() {
        XCTAssertThrowsError(try CloudVoiceInterpreter.decode(#"{"version":1,"operations":[{"kind":"startSession","evidence":"開始","executeSQL":"DELETE"}]}"#))
        XCTAssertThrowsError(try CloudVoiceInterpreter.decode(#"{"version":1,"operations":["#))
    }
    func testNoMatchingEvidenceRejected() throws {
        XCTAssertThrowsError(try run([.init(kind: .startSession, evidence: "invented")]))
        XCTAssertFalse(draft.isActive)
    }
    func testHotwordCoverageCountsOnlyActuallySentPhrases() {
        let catalog = ExerciseVocabularyCatalog(exercises: exercises, commonPhrases: [])
        let selection = ContextualHotwordSelector.select(catalog: catalog, currentDraftExerciseIDs: ["squat", "plank"], limit: 1)
        XCTAssertEqual(selection.phrases.count, 1); XCTAssertEqual(selection.uncoveredExerciseIDs.count, 1)
    }
    func testInsecureConfigurationRejected() {
        var config = CloudVoiceConfiguration(); config.llmBaseURL = "http://example.com/v1"
        XCTAssertThrowsError(try config.validate())
    }
}

private actor DeferredVoiceInterpreter: CloudVoiceInterpreting {
    var continuation: CheckedContinuation<CloudVoicePlan, Error>?
    func interpret(transcript: String, context: String, configuration: CloudVoiceConfiguration) async throws -> CloudVoicePlan {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func ready() -> Bool { continuation != nil }
    func resolve(_ plan: CloudVoicePlan) { continuation?.resume(returning: plan); continuation = nil }
}

@MainActor final class CloudVoiceControllerTests: XCTestCase {
    func testCancelledCloudReplyCannotCreateSession() async throws {
        let container = try TestSupport.makeInMemoryContainer(); let context = ModelContext(container)
        let interpreter = DeferredVoiceInterpreter(); let controller = CloudVoiceController(interpreter: interpreter)
        let draft = TodayDraftStore()
        controller.submit("開始", draft: draft, exercises: [], clientID: "one", context: context)
        for _ in 0..<100 { if await interpreter.ready() { break }; await Task.yield() }
        controller.resetForContextChange()
        await interpreter.resolve(CloudVoicePlan(operations: [.init(kind: .startSession, evidence: "開始")]))
        for _ in 0..<30 { await Task.yield() }
        XCTAssertFalse(draft.isActive); XCTAssertFalse(controller.busy)
    }
    func testInactiveStateChangedDuringCloudReplyIsRejected() async throws {
        let container = try TestSupport.makeInMemoryContainer(); let context = ModelContext(container)
        let interpreter = DeferredVoiceInterpreter(); let controller = CloudVoiceController(interpreter: interpreter)
        let draft = TodayDraftStore()
        controller.submit("開始", draft: draft, exercises: [], clientID: "one", context: context)
        for _ in 0..<100 { if await interpreter.ready() { break }; await Task.yield() }
        draft.startNew(clientID: "two")
        await interpreter.resolve(CloudVoicePlan(operations: [.init(kind: .startSession, evidence: "開始")]))
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(draft.clientID, "two"); XCTAssertFalse(controller.succeeded)
    }
}

extension CloudVoiceTests {
    func testSavedPlanDoesNotBecomePerformanceOrPR() throws {
        try start()
        let client = Client(id: "client", name: "Test"); context.insert(client)
        let input = SessionCommitService.Input(client: client, draftClientID: client.id, existingSessionID: nil,
            sessionDateUTC: Date(), newSessionDateRawText: "2026-09-14", weekNumberForNewSession: 1,
            plannedDurationMinutes: 60, blocks: draft.blocks, finishing: true)
        guard case .success(let output) = SessionCommitService.commit(input, in: context) else { return XCTFail() }
        for set in output.session.orderedBlocks.flatMap(\.orderedEntries).flatMap(\.orderedSets) {
            XCTAssertEqual(set.actual, .unknown(raw: ""))
            XCTAssertNil(AnalyticsMath.setVolume(load: set.load, actual: set.actual))
            XCTAssertFalse(AnalyticsMath.isEffectiveCompletion(actual: set.actual))
        }
        let loaded = SessionDraftLoader.load(from: output.session, exercises: exercises)
        XCTAssertFalse(loaded.blocks[0].entries[0].rounds[0].actualRecorded)
    }
    func testActualRequiresExplicitEvidenceMarkerEvenIfModelMisclassifies() throws {
        try start(); let before = CloudDraftState(draft)
        XCTAssertThrowsError(try run([.init(kind: .recordActual, evidence: "安排", target: draft.allEntries[0].id.uuidString,
            setIndex: 2, quantity: 8, unit: "reps")]))
        XCTAssertEqual(CloudDraftState(draft), before)
    }
    func testUnexpectedFieldsAreNotSilentlyIgnored() throws {
        XCTAssertThrowsError(try run([.init(kind: .startSession, evidence: "安排", sets: 3)]))
        XCTAssertFalse(draft.isActive)
    }
    func testDuplicateNewReferencesRollback() throws {
        XCTAssertThrowsError(try run([.init(kind: .startSession, evidence: "安排"),
            .init(kind: .addExercise, evidence: "安排", exerciseID: "squat", ref: "a"),
            .init(kind: .addExercise, evidence: "安排", exerciseID: "plank", ref: "a")]))
        XCTAssertFalse(draft.isActive)
    }
    func testNewManualRoundPreservesUnrecordedState() throws {
        try start(); let e = draft.allEntries[0]; e.addRound()
        XCTAssertFalse(e.rounds.last!.actualRecorded)
    }
    func testCloudASRPreservesSpokenCorrections() {
        let config = VolcStreamingSession.requestConfig(enableSpeakerInfo: false, hotwordsContext: "{}", outputChineseVariant: "traditional")
        let request = config["request"] as! [String: Any]
        XCTAssertEqual(request["enable_ddc"] as? Bool, false)
        XCTAssertEqual((request["corpus"] as? [String: String])?["context"], "{}")
    }
}
