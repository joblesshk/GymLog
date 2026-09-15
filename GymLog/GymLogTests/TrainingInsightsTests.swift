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
    func testReviewKeepsOnlyRealEvidenceAndToleratesExtraKeys() throws {
        let good = Data(#"{"summary":"test","findings":["test"],"suggestions":["test"],"limitations":["test"],"evidenceIDs":["a"]}"#.utf8)
        XCTAssertNoThrow(try TrainingReviewService.decode(good,validIDs:["a"]))
        XCTAssertThrowsError(try TrainingReviewService.decode(good,validIDs:["b"]), "no evidence names a real record")
        let messy = Data(#"{"summary":" test ","findings":["1","2","3","4","5"],"suggestions":["s"],"limitations":[],"evidenceIDs":["a","invented","a"],"score":99}"#.utf8)
        let review = try TrainingReviewService.decode(messy,validIDs:["a"])
        XCTAssertEqual(review.summary,"test")
        XCTAssertEqual(review.findings.count,4)
        XCTAssertEqual(review.evidenceIDs,["a"])
        let noAdvice = Data(#"{"summary":"test","findings":["f"],"suggestions":[],"limitations":[],"evidenceIDs":["a"]}"#.utf8)
        XCTAssertThrowsError(try TrainingReviewService.decode(noAdvice,validIDs:["a"]))
    }
    func testReviewKeyIsStableForSessionsWithRecordedSets() throws {
        let container = try TestSupport.makeInMemoryContainer();let context = ModelContext(container)
        let client = Client(id:"c",name:"synthetic",goal:"strength");context.insert(client)
        let session = WorkoutSession(id:"s",date:Date(),dateOrigin:.asRecorded,dateRaw:"test",weekNumber:1,sourceSheet:"App",sourceRow:0)
        session.client = client;context.insert(session)
        let block = SessionBlock(order:0,blockType:.single,restSeconds:60,restRaw:"60s",note:nil,sourceRow:0);block.session = session;context.insert(block)
        let entry = ExerciseEntry(order:0,exerciseIdRef:"e",exerciseRaw:"Bench",plannedSets:2);entry.block = block;context.insert(entry)
        for index in 0..<2 {
            let set = SetLog(setIndex:index,load:.absolute(kg:40,raw:"40"),target:.range(low:8,high:12,raw:"8-12"),actual:.fixed(value:10,raw:"10"),isInferred:false)
            set.entry = entry;context.insert(set)
        }
        try context.save()
        let first = TrainingInsights.reviewKey(session)
        for _ in 0..<30 { XCTAssertEqual(TrainingInsights.reviewKey(session), first) }
        let other = WorkoutSession(id:"earlier",date:Date().addingTimeInterval(-86400),dateOrigin:.asRecorded,dateRaw:"test",weekNumber:1,sourceSheet:"App",sourceRow:1)
        other.client = client;context.insert(other)
        XCTAssertEqual(TrainingInsights.reviewKey(session), first, "editing other sessions must not outdate this review")
    }
    func testTruncatedStreamRejected() {
        let data = Data("data: {\"choices\":[{\"delta\":{\"content\":\"{}\"},\"finish_reason\":\"length\"}]}\n\ndata: [DONE]\n\n".utf8)
        XCTAssertThrowsError(try TrainingReviewService.streamContent(data))
    }
    func testRuleAliasesAndReviewContextInvalidation() {
        XCTAssertEqual(TrainingInsights.rule(name:"KB swing",pattern:.conditioning).1,9.8)
        XCTAssertEqual(TrainingInsights.rule(name:"Burpee",pattern:.conditioning).0,"02020")
        XCTAssertEqual(TrainingInsights.rule(name:"Farmer carry",pattern:.conditioning).0,"02022-proxy")
        let c = Client(id:"c",name:"private name",phone:"private phone",goal:"strength")
        let session = WorkoutSession(id:"s",date:Date(),dateOrigin:.asRecorded,dateRaw:"today",weekNumber:1,sourceSheet:"App",sourceRow:0)
        session.client = c
        let before = TrainingInsights.reviewKey(session)
        XCTAssertFalse(TrainingInsights.reviewContext(session).contains("private name"))
        XCTAssertFalse(TrainingInsights.reviewContext(session).contains("private phone"))
        c.goal = "endurance"
        XCTAssertNotEqual(before,TrainingInsights.reviewKey(session))
    }
    func testIntensityFollowsWhatWasLifted() {
        let reps: RepTarget = .fixed(value: 10, raw: "10")
        func line(_ name: String, _ pattern: MovementPattern, _ load: LoadValue, weight: Double = 80) -> EnergyLine {
            TrainingInsights.strength(id: "x", name: name, pattern: pattern, sets: [(load, reps, reps), (load, reps, reps)], rest: 60, weight: weight)
        }
        // Bodyweight-only resistance moves use moderate calisthenics, not weight training.
        XCTAssertEqual(line("Push-up", .push, .bodyweight(raw: "bw")).rule, "02022")
        XCTAssertEqual(line("Bodyweight squat", .squat, .bodyweight(raw: "bw")).rule, "02022")
        // Continuous explosive moves are vigorous calisthenics regardless of pattern.
        XCTAssertEqual(line("Burpee", .conditioning, .bodyweight(raw: "bw")).rule, "02020")
        // Light external load stays moderate; heavy load relative to body weight is vigorous.
        XCTAssertEqual(line("Bench press", .push, .absolute(kg: 40, raw: "40")).rule, "02054")
        XCTAssertEqual(line("Bench press", .push, .absolute(kg: 50, raw: "50")).rule, "02050")
        XCTAssertEqual(line("Dumbbell press", .push, .perSide(kg: 25, raw: "25each")).rule, "02050", "per-side load counts both hands")
        XCTAssertEqual(line("Back squat", .squat, .absolute(kg: 60, raw: "60")).rule, "02052")
        XCTAssertEqual(line("Back squat", .squat, .absolute(kg: 80, raw: "80")).rule, "02050")
        let light = line("Bench press", .push, .absolute(kg: 40, raw: "40")).planned!
        let heavy = line("Bench press", .push, .absolute(kg: 50, raw: "50")).planned!
        XCTAssertGreaterThan(heavy, light)
    }
    func testAssistedMovesCountOnlyTheBodyWeightMoved() throws {
        let reps: RepTarget = .fixed(value: 8, raw: "8")
        let full = TrainingInsights.strength(id: "a", name: "Chin up", pattern: .pull, sets: [(.bodyweight(raw: "bw"), reps, reps)], rest: 60, weight: 80)
        let assisted = TrainingInsights.strength(id: "b", name: "Chin up w/assist", pattern: .pull, sets: [(.assisted(kg: 20, raw: "20"), reps, reps)], rest: 60, weight: 80)
        XCTAssertTrue(assisted.rule.hasSuffix("-assisted"))
        XCTAssertEqual(full.rule, "02022")
        XCTAssertEqual(assisted.rule, "02022-assisted", "assisted pull-ups are still bodyweight moves")
        let ratio = try XCTUnwrap(assisted.planned) / XCTUnwrap(full.planned)
        XCTAssertEqual(ratio, 0.75, accuracy: 0.001, "20 kg assistance on 80 kg leaves 75% of body weight")
        let imported = TrainingInsights.strength(id: "e", name: "Chin up w/assist", pattern: .pull, sets: [(.absolute(kg: 20, raw: "20"), reps, reps)], rest: 60, weight: 80, loadIsAssistance: true)
        XCTAssertEqual(imported.rule, "02022-assisted", "a plain number on a lower-is-stronger move is assistance, not bar load")
        XCTAssertEqual(try XCTUnwrap(imported.planned), try XCTUnwrap(assisted.planned), accuracy: 0.001)
        let extreme = TrainingInsights.strength(id: "d", name: "Assisted dip", pattern: .push, sets: [(.assisted(kg: 200, raw: "200"), reps, reps)], rest: 60, weight: 80)
        XCTAssertNotNil(extreme.planned, "assistance heavier than the athlete is floored, not dropped")
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
