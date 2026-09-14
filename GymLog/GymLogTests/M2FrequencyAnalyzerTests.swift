import XCTest
import SwiftData
@testable import GymLogKit

/// CONTRACT-UI.md §3.1: 「常用」 construction (recent-8-sessions frequency,
/// padded by all-time frequency) and 次数目标 preset reordering.
final class M2FrequencyAnalyzerTests: XCTestCase {

    private func makeExercise(id: String, name: String, occurrenceCount: Int = 1) -> Exercise {
        Exercise(
            id: id, canonicalName: name, aliases: [],
            movementPattern: .push, equipment: .barbell, loadDirection: .higherIsStronger,
            isUnilateral: false, occurrenceCount: occurrenceCount, needsReview: false, reviewReason: nil
        )
    }

    private func makeSession(id: String, client: Client, dayOffset: Int) -> WorkoutSession {
        let session = WorkoutSession(
            id: id, date: Date(timeIntervalSince1970: Double(dayOffset) * 86_400),
            dateOrigin: .asRecorded, dateRaw: "", weekNumber: 1, sourceSheet: "test", sourceRow: 0
        )
        session.client = client
        return session
    }

    @discardableResult
    private func addEntry(to session: WorkoutSession, order: Int, exercise: Exercise, in context: ModelContext) -> ExerciseEntry {
        let block = SessionBlock(order: order, blockType: .single, sourceRow: 0)
        block.session = session
        context.insert(block)
        let entry = ExerciseEntry(order: 0, exerciseIdRef: exercise.id, exerciseRaw: exercise.canonicalName, plannedSets: 3, exercise: exercise)
        entry.block = block
        context.insert(entry)
        let set = SetLog(setIndex: 0, load: .absolute(kg: 20, raw: "20"), target: .fixed(value: 10, raw: "10"), actual: .fixed(value: 10, raw: "10"), isInferred: true)
        set.entry = entry
        context.insert(set)
        return entry
    }

    /// 10 sessions, 8 most recent (day 3...10) all use "A" once each, and
    /// "B" (older, day 1-2 only) doesn't appear in the recent window at all
    /// -- so 常用 must rank A above B purely from the 8-session window, even
    /// though a naive all-time count would tie or favor B if it appeared
    /// more often historically.
    func testFrequentExercisesRanksByRecentEightSessionWindow() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = Client(id: "cl-1", name: "Test")
        context.insert(client)
        let a = makeExercise(id: "ex-a", name: "A")
        let b = makeExercise(id: "ex-b", name: "B")
        context.insert(a)
        context.insert(b)

        // Two old sessions using B only (outside the recent-8 window once
        // 8 newer sessions exist).
        for day in 1...2 {
            let s = makeSession(id: "se-old-\(day)", client: client, dayOffset: day)
            context.insert(s)
            addEntry(to: s, order: 0, exercise: b, in: context)
        }
        // Eight newer sessions, each using A once.
        for day in 3...10 {
            let s = makeSession(id: "se-new-\(day)", client: client, dayOffset: day)
            context.insert(s)
            addEntry(to: s, order: 0, exercise: a, in: context)
        }
        try context.save()

        let frequent = FrequencyAnalyzer.frequentExercises(clientID: client.id, in: context, limit: 20)
        XCTAssertEqual(frequent.first?.id, a.id, "A appears in all 8 recent sessions and must rank first")
        XCTAssertTrue(frequent.contains { $0.id == b.id }, "B must still be included via the all-time padding rule")
        let aIndex = frequent.firstIndex { $0.id == a.id }!
        let bIndex = frequent.firstIndex { $0.id == b.id }!
        XCTAssertLessThan(aIndex, bIndex, "recent-window exercises must rank ahead of padding-only exercises")
    }

    /// Fewer than 20 distinct exercises appear in the recent window -> pad
    /// with all-time frequency, without duplicating an already-included one.
    func testPadsWithAllTimeFrequencyWhenRecentWindowIsSmall() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = Client(id: "cl-1", name: "Test")
        context.insert(client)

        let recentEx = makeExercise(id: "ex-recent", name: "Recent Only")
        let paddedEx = makeExercise(id: "ex-padded", name: "Padded")
        context.insert(recentEx)
        context.insert(paddedEx)

        let recentSession = makeSession(id: "se-1", client: client, dayOffset: 5)
        context.insert(recentSession)
        addEntry(to: recentSession, order: 0, exercise: recentEx, in: context)

        let oldSession = makeSession(id: "se-0", client: client, dayOffset: 1)
        context.insert(oldSession)
        addEntry(to: oldSession, order: 0, exercise: paddedEx, in: context)

        try context.save()

        // Recent window is only 2 sessions (< 8 total exist), so both
        // sessions are "recent" here; this still exercises the pad-from-
        // all-time path when total distinct exercises < the 20 limit,
        // and proves no duplicate entries appear.
        let frequent = FrequencyAnalyzer.frequentExercises(clientID: client.id, in: context, limit: 20)
        XCTAssertEqual(frequent.count, 2)
        XCTAssertEqual(Set(frequent.map(\.id)).count, 2, "no duplicates")
    }

    func testExercisesInCategoryRanksUsedBeforeNeverUsed() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = Client(id: "cl-1", name: "Test")
        context.insert(client)

        let used = makeExercise(id: "ex-used", name: "Used", occurrenceCount: 1)
        let neverUsedHighGlobal = makeExercise(id: "ex-never-high", name: "Never High", occurrenceCount: 100)
        let neverUsedLowGlobal = makeExercise(id: "ex-never-low", name: "Never Low", occurrenceCount: 5)
        context.insert(used)
        context.insert(neverUsedHighGlobal)
        context.insert(neverUsedLowGlobal)

        let session = makeSession(id: "se-1", client: client, dayOffset: 1)
        context.insert(session)
        addEntry(to: session, order: 0, exercise: used, in: context)
        try context.save()

        let ordered = FrequencyAnalyzer.exercises(
            in: .push,
            allExercises: [used, neverUsedHighGlobal, neverUsedLowGlobal],
            clientID: client.id,
            in: context
        )
        XCTAssertEqual(ordered.map(\.id), [used.id, neverUsedHighGlobal.id, neverUsedLowGlobal.id],
                        "client-used exercises must rank before never-used ones, which fall back to global occurrenceCount")
    }

    func testVisibleCategoriesOmitsUnknownWhenNoExerciseIsUnknown() {
        let known = Exercise(id: "ex-1", canonicalName: "X", aliases: [], movementPattern: .push, equipment: .barbell, loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 1, needsReview: false, reviewReason: nil)
        let categories = FrequencyAnalyzer.visibleCategories(allExercises: [known])
        XCTAssertFalse(categories.contains(.unknown))
        XCTAssertEqual(categories.count, 7)
    }

    func testVisibleCategoriesIncludesUnknownWhenPresent() {
        let unknownEx = Exercise(id: "ex-1", canonicalName: "X", aliases: [], movementPattern: .unknown, equipment: .other, loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 1, needsReview: true, reviewReason: nil)
        let categories = FrequencyAnalyzer.visibleCategories(allExercises: [unknownEx])
        XCTAssertTrue(categories.contains(.unknown))
        XCTAssertEqual(categories.count, 8)
    }

    // MARK: - RepTarget preset reordering

    func testRepTargetPresetOrderRanksByClientFrequencyStableForTies() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = Client(id: "cl-1", name: "Test")
        context.insert(client)
        let ex = makeExercise(id: "ex-1", name: "X")
        context.insert(ex)

        // "5" is the 11th preset in the base order but gets used the most
        // by this client -- it must rise to the top after reordering.
        let session = makeSession(id: "se-1", client: client, dayOffset: 1)
        context.insert(session)
        let block = SessionBlock(order: 0, blockType: .single, sourceRow: 0)
        block.session = session
        context.insert(block)
        let entry = ExerciseEntry(order: 0, exerciseIdRef: ex.id, exerciseRaw: "X", plannedSets: 3, exercise: ex)
        entry.block = block
        context.insert(entry)
        for i in 0..<5 {
            let set = SetLog(setIndex: i, load: .absolute(kg: 20, raw: "20"), target: .fixed(value: 5, raw: "5"), actual: .fixed(value: 5, raw: "5"), isInferred: true)
            set.entry = entry
            context.insert(set)
        }
        try context.save()

        let order = FrequencyAnalyzer.repTargetPresetOrder(clientID: client.id, in: context)
        XCTAssertEqual(order.first?.label, "5", "the client's most-used preset must rank first")
        XCTAssertEqual(order.last?.label, FrequencyAnalyzer.customPreset.label, "自定义… must always stay last")
        XCTAssertEqual(order.count, FrequencyAnalyzer.baseRepTargetPresets.count + 1)
    }

    func testRepTargetPresetOrderDefaultsToContractOrderWithNoHistory() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = Client(id: "cl-1", name: "Test")
        context.insert(client)
        try context.save()

        let order = FrequencyAnalyzer.repTargetPresetOrder(clientID: client.id, in: context)
        XCTAssertEqual(order.map(\.label), FrequencyAnalyzer.baseRepTargetPresets.map(\.label) + [FrequencyAnalyzer.customPreset.label],
                        "with no usage history, order must be stable and match the contract's documented default order exactly")
    }
}
