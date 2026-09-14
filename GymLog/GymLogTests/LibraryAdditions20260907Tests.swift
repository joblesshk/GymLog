import XCTest
import SwiftData
@testable import GymLogKit

/// 2026-09-07 加进标准动作库的 56 个 CrossFit 相关动作
/// （`output/review-2026-09-07/CrossFit动作目录候选.csv`"新增"行），以及让已
/// 装机设备也拿到它们的 `SeedImporter.applyExerciseLibraryAdditions20260907`。
///
/// 与 `LibraryAdditions20260904Tests` 同样的分工原则：这一轮只验证"只塞缺的
/// 那些行，别的一概不碰"——不重复测每条动作的具体字段（`testSeedShipsAllFiftySixCrossFitMovements`
/// 已经覆盖"每条都有完整分类+双语名+说明"这一类不变量），聚焦在幂等、合并教练
/// 手打重复行、模板引用重定向（B04）、以及"复用增强"的 15 行只增别名不改分类。
final class LibraryAdditions20260907Tests: XCTestCase {

    private final class BundleToken {}

    private func seedURL() throws -> URL {
        try XCTUnwrap(Bundle(for: BundleToken.self).url(forResource: "exercise_library_seed", withExtension: "json"))
    }

    private func emptyContext() throws -> ModelContext {
        ModelContext(try TestSupport.makeInMemoryContainer())
    }

    @discardableResult
    private func insertCoachTypedExercise(named name: String, into context: ModelContext) -> Exercise {
        let exercise = Exercise(
            id: "ex-local-\(UUID().uuidString.prefix(8))",
            canonicalName: name,
            aliases: [],
            movementPattern: .unknown,
            equipment: .other,
            loadDirection: .higherIsStronger,
            isUnilateral: false,
            occurrenceCount: 0,
            needsReview: true,
            reviewReason: "錄入時新建"
        )
        context.insert(exercise)
        return exercise
    }

    // MARK: - The seed file itself

    func testSeedShipsAllFiftySixCrossFitMovements() throws {
        let data = try Data(contentsOf: try seedURL())
        let seed = try JSONDecoder().decode(SeedFile.self, from: data)
        let byID = Dictionary(uniqueKeysWithValues: seed.exercises.map { ($0.id, $0) })

        XCTAssertEqual(SeedImporter.libraryAdditionIDs20260907.count, 56)
        XCTAssertEqual(Set(SeedImporter.libraryAdditionIDs20260907).count, 56, "no duplicate ids")

        for id in SeedImporter.libraryAdditionIDs20260907 {
            let exercise = try XCTUnwrap(byID[id], "missing \(id) from the shipped seed")
            XCTAssertFalse(exercise.canonicalName.isEmpty)
            XCTAssertFalse(exercise.nameZh?.isEmpty ?? true, "\(exercise.canonicalName): every new row must ship with a Chinese name")
            XCTAssertFalse(exercise.notes?.isEmpty ?? true, "\(exercise.canonicalName): every new row must ship with a description")
            XCTAssertFalse(exercise.needsReview, "curated additions are not classifier guesses -- needsReview must be false")
        }

        // The nine official CrossFit foundational movements the review
        // flagged as entirely missing before this pass.
        let expectedNames: Set<String> = [
            "Air Squat", "Front Squat", "Overhead Squat", "Shoulder Press",
            "Push Press", "Push Jerk", "Deadlift", "Sumo Deadlift High Pull", "Medicine-ball Clean",
        ]
        let shippedNames = Set(SeedImporter.libraryAdditionIDs20260907.compactMap { byID[$0]?.canonicalName })
        XCTAssertEqual(expectedNames.intersection(shippedNames), expectedNames, "all nine CrossFit foundational movements must be present")
    }

    /// Existing well-known ids the review explicitly required be preserved
    /// (never re-created as a new row, never reclassified) -- the "复用增强"
    /// rows only gained new search aliases directly in the seed file's own
    /// `aliases` array, not through the additions function.
    func testPreservesExistingWellKnownIDsUntouched() throws {
        let data = try Data(contentsOf: try seedURL())
        let seed = try JSONDecoder().decode(SeedFile.self, from: data)
        let byID = Dictionary(uniqueKeysWithValues: seed.exercises.map { ($0.id, $0) })
        let preserved: [(id: String, name: String)] = [
            ("ex-ee6dc4d0", "Wall ball"), ("ex-6a1cec45", "Clean"), ("ex-85435626", "DB clean"),
            ("ex-d7e757e6", "DB snatch"), ("ex-81c4e551", "Rowing"), ("ex-03c970b1", "Ski"),
            ("ex-cebffc62", "KB swing"), ("ex-686c501b", "Box step"),
        ]
        for (id, name) in preserved {
            XCTAssertEqual(byID[id]?.canonicalName, name, "\(id) must keep its original id and name, not be duplicated under a new id")
        }
        // The one "需复核" row must be completely untouched by this batch.
        XCTAssertNotNil(byID["ex-b9c935b2"])
        XCTAssertFalse(SeedImporter.libraryAdditionIDs20260907.contains("ex-b9c935b2"))
    }

    // MARK: - Insertion into an already-populated library

    func testInsertsAllFiftySixIntoAnAlreadyPopulatedLibrary() throws {
        let context = try emptyContext()
        context.insert(Exercise(
            id: "ex-preexisting", canonicalName: "Bench press", aliases: [], movementPattern: .push,
            equipment: .barbell, loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 5,
            needsReview: false, reviewReason: nil
        ))
        try context.save()

        let inserted = try SeedImporter.applyExerciseLibraryAdditions20260907(seedURL: try seedURL(), context: context)
        XCTAssertEqual(inserted, 56)

        let after = try context.fetch(FetchDescriptor<Exercise>())
        let afterIDs = Set(after.map(\.id))
        for id in SeedImporter.libraryAdditionIDs20260907 {
            XCTAssertTrue(afterIDs.contains(id))
        }
        XCTAssertTrue(afterIDs.contains("ex-preexisting"), "the coach's pre-existing row must survive untouched")
    }

    func testDoesNotTouchAnyUnrelatedExercise() throws {
        let context = try emptyContext()
        let custom = Exercise(
            id: "ex-custom-1", canonicalName: "教練自建動作", aliases: ["教練自建動作"], movementPattern: .push,
            equipment: .other, loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 0,
            needsReview: false, reviewReason: nil
        )
        context.insert(custom)
        try context.save()

        try SeedImporter.applyExerciseLibraryAdditions20260907(seedURL: try seedURL(), context: context)

        let survivor = try XCTUnwrap(try context.fetch(FetchDescriptor<Exercise>()).first { $0.id == "ex-custom-1" })
        XCTAssertEqual(survivor.canonicalName, "教練自建動作")
    }

    func testIsANoOpOnAFreshInstall() throws {
        // A "fresh install" for this function's purposes is the shipped
        // seed already fully imported (mirrors `importFixtureIfNeeded`'s
        // own guard) -- inserted == 0, nothing duplicated.
        let context = try emptyContext()
        _ = try SeedImporter.importSeed(from: try seedURL(), into: context)
        let beforeCount = try context.fetchCount(FetchDescriptor<Exercise>())

        let inserted = try SeedImporter.applyExerciseLibraryAdditions20260907(seedURL: try seedURL(), context: context)
        XCTAssertEqual(inserted, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Exercise>()), beforeCount)
    }

    func testIsIdempotentWhenCalledTwice() throws {
        let context = try emptyContext()
        let url = try seedURL()
        try SeedImporter.applyExerciseLibraryAdditions20260907(seedURL: url, context: context)
        try SeedImporter.applyExerciseLibraryAdditions20260907(seedURL: url, context: context)

        let all = try context.fetch(FetchDescriptor<Exercise>())
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "no duplicate ids after running twice")
        for id in SeedImporter.libraryAdditionIDs20260907 {
            XCTAssertEqual(all.filter { $0.id == id }.count, 1)
        }
    }

    // MARK: - Folding the coach's own hand-typed duplicates (name match)

    func testFoldsACoachTypedAirSquatIntoTheCanonicalRow() throws {
        let context = try emptyContext()
        let handTyped = insertCoachTypedExercise(named: "Air Squat", into: context)
        let handTypedID = handTyped.id
        let entry = attachEntry(to: handTyped, in: context)
        try context.save()
        let entryID = entry.persistentModelID

        try SeedImporter.applyExerciseLibraryAdditions20260907(seedURL: try seedURL(), context: context)

        let after = try context.fetch(FetchDescriptor<Exercise>())
        XCTAssertNil(after.first { $0.id == handTypedID }, "hand-typed duplicate must be merged away")
        let canonical = try XCTUnwrap(after.first { $0.canonicalName == "Air Squat" && $0.id.hasPrefix("ex-") && !$0.id.hasPrefix("ex-local-") })
        XCTAssertEqual(canonical.entries?.count, 1, "history must move to the canonical row, not be dropped with the deleted one")

        let movedEntry = try XCTUnwrap(context.model(for: entryID) as? ExerciseEntry)
        XCTAssertEqual(movedEntry.exercise?.id, canonical.id)
        XCTAssertEqual(movedEntry.exerciseIdRef, canonical.id)
    }

    /// A near-miss spelling must NOT be swallowed -- it's not an exact
    /// normalized match against the canonical row's own name/aliases.
    func testLeavesANearMissSpellingUnmerged() throws {
        let context = try emptyContext()
        insertCoachTypedExercise(named: "Air Squats (warmup)", into: context)
        try context.save()

        try SeedImporter.applyExerciseLibraryAdditions20260907(seedURL: try seedURL(), context: context)

        let after = try context.fetch(FetchDescriptor<Exercise>())
        XCTAssertTrue(after.contains { $0.canonicalName == "Air Squats (warmup)" }, "a near-miss name must not be guessed away")
    }

    /// 2026-09-07 审阅 B04: a template slot referencing the coach's
    /// hand-typed duplicate must be redirected onto the canonical row too,
    /// not left dangling.
    private func attachEntry(to exercise: Exercise, in context: ModelContext) -> ExerciseEntry {
        let client = Client(id: "cl-test", name: "測試學員")
        let session = WorkoutSession(
            id: "se-test-\(UUID().uuidString.prefix(6))", date: Date(timeIntervalSince1970: 1_757_000_000),
            dateOrigin: .asRecorded, dateRaw: "2026-09-07", weekNumber: 1, sourceSheet: "App", sourceRow: 0
        )
        session.client = client
        let block = SessionBlock(order: 0, blockType: .single, restSeconds: 60, sourceRow: 0)
        block.session = session
        let entry = ExerciseEntry(order: 0, exerciseIdRef: exercise.id, exerciseRaw: exercise.canonicalName, plannedSets: 3, exercise: exercise)
        entry.block = block
        context.insert(client); context.insert(session); context.insert(block); context.insert(entry)
        return entry
    }

    func testFoldsTemplateSlotReferenceOntoCanonicalRow() throws {
        let context = try emptyContext()
        let handTyped = insertCoachTypedExercise(named: "Burpee", into: context)
        let handTypedID = handTyped.id
        let template = SessionTemplate(id: "tpl-cf-test", name: "測試模板", order: 0)
        context.insert(template)
        let block = TemplateBlock(id: "tpl-cf-test-block0", order: 0, blockType: .single, restSeconds: 60)
        block.template = template
        context.insert(block)
        let slot = TemplateExerciseSlot(id: "tpl-cf-test-block0-slot0", order: 0, exerciseID: handTypedID, defaultSets: 3, defaultRepTarget: .fixed(value: 15, raw: "15"))
        slot.block = block
        context.insert(slot)
        try context.save()
        let slotID = slot.persistentModelID

        try SeedImporter.applyExerciseLibraryAdditions20260907(seedURL: try seedURL(), context: context)

        let after = try context.fetch(FetchDescriptor<Exercise>())
        XCTAssertNil(after.first { $0.id == handTypedID })
        let canonical = try XCTUnwrap(after.first { $0.canonicalName == "Burpee" && !$0.id.hasPrefix("ex-local-") })
        let survivingSlot = try XCTUnwrap(context.model(for: slotID) as? TemplateExerciseSlot)
        XCTAssertEqual(survivingSlot.exerciseID, canonical.id, "template slot must be redirected, not left dangling on the deleted id")
    }

    // MARK: - "复用增强": existing rows only gain aliases, never reclassified

    func testReuseEnhancedRowsOnlyGainAliasesNeverReclassified() throws {
        let data = try Data(contentsOf: try seedURL())
        let seed = try JSONDecoder().decode(SeedFile.self, from: data)
        let byID = Dictionary(uniqueKeysWithValues: seed.exercises.map { ($0.id, $0) })

        let wallBall = try XCTUnwrap(byID["ex-ee6dc4d0"])
        XCTAssertEqual(wallBall.canonicalName, "Wall ball", "canonicalName must not change")
        XCTAssertEqual(wallBall.equipment, .ball, "equipment classification must not change")
        XCTAssertTrue(wallBall.aliases.contains("Wall-ball Shot"), "new search alias must have been added")

        let kbSwing = try XCTUnwrap(byID["ex-cebffc62"])
        XCTAssertFalse(kbSwing.aliases.contains { $0.localizedCaseInsensitiveContains("American") }, "chest-height KB swing must not gain an American-swing alias -- they are not the same standard")
    }
}
