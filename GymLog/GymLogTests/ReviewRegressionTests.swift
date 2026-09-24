import SwiftData
import XCTest

@testable import GymLogKit

@MainActor
final class ReviewRegressionTests: XCTestCase {
  func exercise() -> Exercise {
    Exercise(
      id: "e", canonicalName: "Squat", aliases: [], movementPattern: .squat, equipment: .barbell,
      loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 0, needsReview: false,
      reviewReason: nil)
  }
  func testQuickEditPreservesUntouchedWeightAndSourceText() {
    let s = SetLog(
      setIndex: 0, load: .absolute(kg: 1.25, raw: "1.25kg"),
      target: .fixed(value: 10, raw: "10 reps"), actual: .fixed(value: 10, raw: "10 reps"),
      isInferred: true)
    SetEditDraft(set: s).apply(to: s)
    XCTAssertEqual(s.load, .absolute(kg: 1.25, raw: "1.25kg"))
    XCTAssertEqual(s.target, .fixed(value: 10, raw: "10 reps"))
    XCTAssertTrue(s.isInferred)
    var edit = SetEditDraft(set: s)
    edit.actualPrimaryText = "8"
    edit.apply(to: s)
    XCTAssertEqual(s.load, .absolute(kg: 1.25, raw: "1.25kg"))
    XCTAssertEqual(s.target, .fixed(value: 10, raw: "10 reps"))
    XCTAssertEqual(s.actual, .fixed(value: 8, raw: "8"))
    XCTAssertFalse(s.isInferred)
  }
  func testUnknownRawActualSurvivesSnapshotSplitAndExplicitClear() throws {
    let e = exercise()
    let sets = [
      SetLog(
        setIndex: 0, load: .absolute(kg: 60, raw: "60"), target: .fixed(value: 10, raw: "10"),
        actual: .unknown(raw: "pain stopped"), isInferred: false)
    ]
    let rounds = SessionDraftLoader.rounds(from: sets, metric: .reps, equipment: .barbell)
    let draft = EntryDraft(exercise: e, rounds: rounds, recordingMetric: .reps)
    XCTAssertEqual(draft.resolvedSets()[0].actual, .unknown(raw: "pain stopped"))
    let data = try JSONEncoder().encode(draft.snapshot())
    let restored = try XCTUnwrap(
      EntryDraft.restore(
        from: JSONDecoder().decode(EntryDraftSnapshot.self, from: data), exercises: [e]
      ).entry)
    XCTAssertFalse(restored.rounds[0].actualRecorded)
    restored.rounds[0].setsCount = 2
    _ = restored.splitRound(atPhysicalSetIndex: 2)
    XCTAssertEqual(
      restored.resolvedSets().map(\.actual),
      [.unknown(raw: "pain stopped"), .unknown(raw: "pain stopped")])
    restored.rounds[0].actualRecorded = false
    XCTAssertEqual(restored.resolvedSets()[0].actual, .unknown(raw: ""))
    XCTAssertEqual(restored.resolvedSets()[1].actual, .unknown(raw: "pain stopped"))
  }
  func testReopenSameSessionPreservesUnsavedEditsAndEmptyDraft() throws {
    let c = ModelContext(try TestSupport.makeInMemoryContainer())
    let client = Client(id: "c", name: "Test")
    c.insert(client)
    let e = exercise()
    c.insert(e)
    let s = WorkoutSession(
      id: "s", date: Date(), dateOrigin: .asRecorded, dateRaw: "", weekNumber: 1,
      sourceSheet: "App", sourceRow: 0)
    s.client = client
    c.insert(s)
    let b = SessionBlock(order: 0, blockType: .single, sourceRow: 0)
    b.session = s
    c.insert(b)
    let en = ExerciseEntry(
      order: 0, exerciseIdRef: e.id, exerciseRaw: "Squat", plannedSets: 1, exercise: e)
    en.block = b
    c.insert(en)
    let set = SetLog(
      setIndex: 0, load: .absolute(kg: 60, raw: "60"), target: .fixed(value: 10, raw: "10"),
      actual: .fixed(value: 10, raw: "10"), isInferred: false)
    set.entry = en
    c.insert(set)
    try c.save()
    let d = TodayDraftStore()
    SessionEditingCoordinator.open(s, exercises: [e], into: d, tabSelection: nil)
    d.blocks[0].entries[0].rounds[0].actual = .fixed(value: 8, raw: "8")
    SessionEditingCoordinator.open(s, exercises: [e], into: d, tabSelection: nil)
    XCTAssertEqual(d.blocks[0].entries[0].rounds[0].actual, .fixed(value: 8, raw: "8"))
    let tabs = TabSelectionStore(selectedTab: 2)
    d.blocks = []
    let timerID = UUID()
    d.activeWODTimerOwnerID = timerID
    SessionEditingCoordinator.open(s, exercises: [e], into: d, tabSelection: tabs)
    XCTAssertTrue(d.blocks.isEmpty)
    XCTAssertEqual(d.activeWODTimerOwnerID, timerID)
    XCTAssertEqual(tabs.selectedTab, 0)
  }
  func testDuplicateExchangeExerciseIDsRejectedBeforeMutation() throws {
    let e = exercise()
    let c = Client(id: "c", name: "Test")
    var p = ExchangeExporter.buildPlanPackage(
      blocks: [
        BlockDraft(entries: [
          EntryDraft(
            exercise: e,
            rounds: [
              RoundDraft(
                setsCount: 1, load: .absolute(kg: 60, raw: "60"),
                target: .fixed(value: 10, raw: "10"), actual: .unknown(raw: ""))
            ])
        ])
      ], client: c, trainingDate: Date(), weekNumber: 1, plannedDurationMinutes: 60,
      existingSessionID: nil)
    p.exercises.append(p.exercises[0])
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    XCTAssertThrowsError(try ExchangeImporter.parse(enc.encode(p)))
    let context = ModelContext(try TestSupport.makeInMemoryContainer())
    context.insert(c)
    try context.save()
    c.name = "Unsaved local change"
    XCTAssertThrowsError(try ExchangeImporter.commit(p, targetClientID: c.id, in: context))
    XCTAssertEqual(c.name, "Unsaved local change")
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutSession>()), 0)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Exercise>()), 0)
    p.exercises.removeLast()
    p.exercises[0].id = " "
    XCTAssertThrowsError(try ExchangeImporter.parse(enc.encode(p)))
  }
}
