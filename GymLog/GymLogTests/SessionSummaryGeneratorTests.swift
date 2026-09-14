import XCTest
import SwiftData
@testable import GymLogKit

/// 课后摘要（2026-09-06 审查报告"适合当前范围的功能"第二批）。
final class SessionSummaryGeneratorTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try TestSupport.makeInMemoryContainer()
        context = ModelContext(container)
    }

    private func makeSession() -> WorkoutSession {
        let client = Client(id: "cl-1", name: "Test Client")
        context.insert(client)

        let exercise = Exercise(
            id: "ex-bench", canonicalName: "Bench press", aliases: [], movementPattern: .push,
            equipment: .barbell, loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 1,
            needsReview: false, reviewReason: nil
        )
        context.insert(exercise)

        let session = WorkoutSession(
            id: "se-1", date: Date(timeIntervalSince1970: 1_700_000_000), dateOrigin: .asRecorded, dateRaw: "raw",
            weekNumber: 5, sourceSheet: "Test", sourceRow: 0, warmup: "Row 5min", warmupNote: "easy pace",
            cooldown: "Stretch", cooldownNote: "10min"
        )
        session.client = client
        context.insert(session)

        let block = SessionBlock(order: 0, blockType: .single, note: "felt strong today", sourceRow: 0)
        block.session = session
        context.insert(block)

        let entry = ExerciseEntry(order: 0, exerciseIdRef: exercise.id, exerciseRaw: exercise.canonicalName, plannedSets: 1, exercise: exercise)
        entry.block = block
        context.insert(entry)

        let set = SetLog(setIndex: 0, load: .absolute(kg: 60, raw: "60"), target: .fixed(value: 8, raw: "8"), actual: .fixed(value: 8, raw: "8"), isInferred: false)
        set.entry = entry
        context.insert(set)

        try? context.save()
        return session
    }

    func testSummaryIncludesClientDateWeekExerciseAndNotes() {
        let session = makeSession()
        let text = SessionSummaryGenerator.summary(for: session, clientName: "Ada", prPointIDs: [])

        XCTAssertTrue(text.contains("Ada"))
        XCTAssertTrue(text.contains("2023-11-14"), "Expected the UTC-encoded session date to appear.")
        XCTAssertTrue(text.contains("5"), "Week number must appear.")
        XCTAssertTrue(text.contains("Bench press"))
        XCTAssertTrue(text.contains("60kg") || text.contains("60"), "The set's load must appear.")
        XCTAssertTrue(text.contains("felt strong today"), "Block note must be included.")
        XCTAssertTrue(text.contains("Row 5min"), "Warm-up must be included.")
        XCTAssertTrue(text.contains("Stretch"), "Cooldown must be included.")
        // `L(...)` defaults to Traditional Chinese when no `appLanguage`
        // preference is set (as in this test process) — see
        // `LoadValueCodableTests.testDisplayText`'s own note on this.
        XCTAssertTrue(text.contains("熱身"))
        XCTAssertTrue(text.contains("放鬆"))
    }

    func testSummaryMarksPRPointsButNotOthers() {
        let session = makeSession()
        let pointID = "se-1#0#0"

        let withPR = SessionSummaryGenerator.summary(for: session, clientName: "Ada", prPointIDs: [pointID])
        XCTAssertTrue(withPR.contains("PR"), "A flagged point must show the PR marker.")

        let withoutPR = SessionSummaryGenerator.summary(for: session, clientName: "Ada", prPointIDs: [])
        XCTAssertFalse(withoutPR.contains("PR"), "An unflagged session must not claim a PR that wasn't computed.")
    }

    func testSummaryOmitsAbsentWarmupCooldownSections() {
        let client = Client(id: "cl-2", name: "No Notes Client")
        context.insert(client)
        let session = WorkoutSession(
            id: "se-2", date: Date(timeIntervalSince1970: 1_700_000_000), dateOrigin: .asRecorded, dateRaw: "raw",
            weekNumber: 1, sourceSheet: "Test", sourceRow: 0
        )
        session.client = client
        context.insert(session)
        try? context.save()

        let text = SessionSummaryGenerator.summary(for: session, clientName: "No Notes", prPointIDs: [])
        XCTAssertFalse(text.contains("熱身"))
        XCTAssertFalse(text.contains("放鬆"))
    }
}
