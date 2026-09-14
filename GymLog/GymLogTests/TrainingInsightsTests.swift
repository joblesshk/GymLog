import XCTest
import SwiftData
@testable import GymLogKit

@MainActor
final class TrainingInsightsTests: XCTestCase {
    func testActiveEnergyFormulaAndInvalidInputs() {
        XCTAssertEqual(TrainingInsights.kcal(met: 5, weight: 70, seconds: 600)!, 49, accuracy: 0.001)
        XCTAssertNil(TrainingInsights.kcal(met: 5, weight: nil, seconds: 600))
        XCTAssertNil(TrainingInsights.kcal(met: 5, weight: .nan, seconds: 600))
        XCTAssertNil(TrainingInsights.kcal(met: 5, weight: 70, seconds: -1))
    }
    func testMissingIsNotZeroAndUnitsNotInvented() {
        XCTAssertNil(TrainingInsights.seconds(.unknown(raw: "")))
        XCTAssertEqual(TrainingInsights.seconds(.fixed(value: 0, raw: "0")), 0)
        XCTAssertNil(TrainingInsights.seconds(.distance(meters: 500, raw: "500m")))
        XCTAssertNil(TrainingInsights.seconds(.rounds(count: 3, raw: "3 rounds")))
        XCTAssertEqual(TrainingInsights.seconds(.perSide(left: 8, right: 10, raw: "8,10")),54)
        XCTAssertNil(TrainingInsights.seconds(.range(low: 10, high: 5, raw: "invalid")))
    }
    func testPartialResultsAreExplicitAndZeroHasNoRest() {
        let line = TrainingInsights.strength(id:"a", name:"Bench", pattern:.push, sets:[(.absolute(kg:40,raw:"40"),.fixed(value:10,raw:"10"),.unknown(raw:"")),(.absolute(kg:40,raw:"40"),.fixed(value:10,raw:"10"),.fixed(value:0,raw:"0"))],rest:60,weight:70)
        XCTAssertEqual(line.actual,0); XCTAssertEqual(line.recordedSets,1)
        XCTAssertTrue(EnergyReport(weightKg:70,lines:[line]).isPartial)
    }
    func testSharedRestCountedOnceAndPlanActualAgree() {
        let client = Client(id:"c",name:"",startWeightKg:70)
        let draft = TodayDraftStore();draft.startNew(clientID:client.id)
        let ex = Exercise(id:"e",canonicalName:"Bench",aliases:[],movementPattern:.push,equipment:.barbell,loadDirection:.higherIsStronger,isUnilateral:false,occurrenceCount:0,needsReview:false,reviewReason:nil)
        draft.blocks = [BlockDraft(blockType:.superset,restSeconds:60,entries:(0..<2).map { _ in EntryDraft(exercise:ex,setsCount:3,load:.absolute(kg:40,raw:"40"),targetQuantity:10,actualQuantity:10) })]
        let report = TrainingInsights.draft(draft,client:client)
        XCTAssertEqual(report.lines.compactMap(\.plannedSeconds).reduce(0,+),300)
        XCTAssertEqual(report.planned,report.actual)
    }
    func testFutureWeightNotUsedForHistory() {
        let client = Client(id:"c",name:"",startWeightKg:80)
        XCTAssertNil(TrainingInsights.weight(client,date:Date(timeIntervalSince1970:0)).0)
    }
    func testForTimeCapIsNotActualOrExpectedDuration() {
        let p = WODPrescription(id:"p",revision:1,format:.forTime,timeCapSeconds:720,rounds:[],scoringRule:.completionTime)
        let r = WODResult(status:.notRecorded)
        let line = TrainingInsights.wod(id:"b",payload:WODPayload(prescription:p,result:r),weight:70)
        XCTAssertNil(line.planned);XCTAssertNil(line.actual)
    }
    func testReviewRejectsInventedEvidenceAndExtraKeys() throws {
        let good = Data(#"{"summary":"test","findings":["test"],"suggestions":["test"],"limitations":["test"],"evidenceIDs":["a"]}"#.utf8)
        XCTAssertNoThrow(try TrainingReviewService.decode(good,validIDs:["a"]))
        XCTAssertThrowsError(try TrainingReviewService.decode(good,validIDs:["b"]))
        let extra = Data(#"{"summary":"test","findings":["test"],"suggestions":["test"],"limitations":["test"],"evidenceIDs":["a"],"score":99}"#.utf8)
        XCTAssertThrowsError(try TrainingReviewService.decode(extra,validIDs:["a"]))
    }
    func testTruncatedStreamRejected() {
        let data = Data("data: {\"choices\":[{\"delta\":{\"content\":\"{}\"},\"finish_reason\":\"length\"}]}\n\ndata: [DONE]\n\n".utf8)
        XCTAssertThrowsError(try TrainingReviewService.streamContent(data))
    }
    func testRuleAliasesAndReviewContextInvalidation() {
        XCTAssertEqual(TrainingInsights.rule(name:"KB swing",pattern:.conditioning).1,9.8)
        XCTAssertEqual(TrainingInsights.rule(name:"Burpee",pattern:.conditioning).0,"02022-proxy")
        let c = Client(id:"c",name:"private name",phone:"private phone",goal:"strength")
        let session = WorkoutSession(id:"s",date:Date(),dateOrigin:.asRecorded,dateRaw:"today",weekNumber:1,sourceSheet:"App",sourceRow:0)
        session.client = c
        let before = TrainingInsights.reviewKey(session)
        XCTAssertFalse(TrainingInsights.reviewContext(session).contains("private name"))
        XCTAssertFalse(TrainingInsights.reviewContext(session).contains("private phone"))
        c.goal = "endurance"
        XCTAssertNotEqual(before,TrainingInsights.reviewKey(session))
    }
    func testNewManualExerciseAndAddedRoundDoNotInventActual() throws {
        let container = try TestSupport.makeInMemoryContainer();let context = ModelContext(container)
        let client = Client(id:"c",name:"",startWeightKg:70);context.insert(client)
        let ex = Exercise(id:"e",canonicalName:"Bench",aliases:[],movementPattern:.push,equipment:.barbell,loadDirection:.higherIsStronger,isUnilateral:false,occurrenceCount:0,needsReview:false,reviewReason:nil);context.insert(ex)
        let draft = TodayDraftStore();draft.startNew(clientID:client.id)
        TodayDraftMutationService.addEntry(ex,clientID:client.id,placement:.newBlock,draft:draft,context:context)
        XCTAssertNil(TrainingInsights.draft(draft,client:client).actual)
        let e = try XCTUnwrap(draft.allEntries.first)
        e.rounds[0].actualQuantity = 10
        XCTAssertNotNil(TrainingInsights.draft(draft,client:client).actual)
        e.addRound()
        XCTAssertFalse(e.rounds.last!.actualRecorded)
    }
    func testInsightBackupRoundTrip() throws {
        let source = try TestSupport.makeInMemoryContainer();let context = ModelContext(source)
        let c = Client(id:"c",name:"synthetic");context.insert(c)
        let s = WorkoutSession(id:"s",date:Date(),dateOrigin:.asRecorded,dateRaw:"test",weekNumber:1,sourceSheet:"App",sourceRow:0)
        s.client = c;context.insert(s)
        TrainingInsights.capture(s);try context.save()
        let backup = try BackupExporter.makeBackup(from:context)
        let dest = try TestSupport.makeInMemoryContainer();let dc = ModelContext(dest)
        try BackupImporter.restore(backup,into:dc)
        let restored = try XCTUnwrap(dc.fetch(FetchDescriptor<WorkoutSession>()).first)
        XCTAssertEqual(s.insightJSON,restored.insightJSON)
    }
}
