import XCTest
import SwiftData
@testable import GymLogKit

final class SeedImporterTests: XCTestCase {

    // MARK: - Basic import correctness

    func testImportFixtureMatchesItsOwnStats() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let data = try TestSupport.loadFixtureData()

        let result = try SeedImporter.importSeed(data: data, into: context)

        XCTAssertEqual(result.clientCount, 2)
        XCTAssertEqual(result.sessionCount, 4)
        XCTAssertEqual(result.exerciseCount, 15)
        XCTAssertEqual(result.entryCount, 22)
        XCTAssertEqual(result.setLogCount, 26)
        XCTAssertEqual(result.exercisesNeedingReviewCount, 2)
        XCTAssertEqual(result.sessionsNeedingReviewCount, 1)

        let storedClients = try context.fetch(FetchDescriptor<Client>())
        let storedSessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        let storedExercises = try context.fetch(FetchDescriptor<Exercise>())
        let storedSets = try context.fetch(FetchDescriptor<SetLog>())
        XCTAssertEqual(storedClients.count, 2)
        XCTAssertEqual(storedSessions.count, 4)
        XCTAssertEqual(storedExercises.count, 15)
        XCTAssertEqual(storedSets.count, 26)
    }

    func testExercisesImportedBeforeClientsMeansReferencesResolve() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let data = try TestSupport.loadFixtureData()
        let result = try SeedImporter.importSeed(data: data, into: context)

        // Every entry's exerciseId in the fixture refers to a real exercise
        // in the same file's exercises[] array, so nothing should be
        // unresolved if import ordering (exercises first) is respected.
        XCTAssertEqual(result.unresolvedExerciseRefs, 0)

        let entries = try context.fetch(FetchDescriptor<ExerciseEntry>())
        XCTAssertTrue(entries.allSatisfy { $0.exercise != nil })
    }

    func testRawTextFieldsPersistedVerbatim() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let data = try TestSupport.loadFixtureData()
        _ = try SeedImporter.importSeed(data: data, into: context)

        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        let se0001 = sessions.first { $0.id == "se-0001" }
        XCTAssertEqual(se0001?.dateRaw, "45547")

        let sets = try context.fetch(FetchDescriptor<SetLog>())
        // Spot check: the Ski erg time-corruption example from CONTRACT.md §8.3.
        let skiEntrySets = sets.filter { $0.target.raw == "2:23" }
        XCTAssertFalse(skiEntrySets.isEmpty)
        if case .time(let seconds, let raw) = skiEntrySets.first!.target {
            XCTAssertEqual(seconds, 143)
            XCTAssertEqual(raw, "2:23")
        } else {
            XCTFail("Expected .time target")
        }
    }

    // MARK: - Idempotency (CONTRACT.md §11.1)

    func testReimportingSameFixtureProducesNoDuplicates() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let data = try TestSupport.loadFixtureData()

        let first = try SeedImporter.importSeed(data: data, into: context)
        let second = try SeedImporter.importSeed(data: data, into: context)
        let third = try SeedImporter.importSeed(data: data, into: context)

        XCTAssertEqual(first.clientCount, second.clientCount)
        XCTAssertEqual(first.sessionCount, second.sessionCount)
        XCTAssertEqual(first.exerciseCount, second.exerciseCount)
        XCTAssertEqual(first.entryCount, second.entryCount)
        XCTAssertEqual(first.setLogCount, second.setLogCount)
        XCTAssertEqual(second.setLogCount, third.setLogCount)

        // The real proof: actual row counts in the store, not just the
        // importer's self-reported numbers.
        let clients = try context.fetch(FetchDescriptor<Client>())
        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        let blocks = try context.fetch(FetchDescriptor<SessionBlock>())
        let entries = try context.fetch(FetchDescriptor<ExerciseEntry>())
        let sets = try context.fetch(FetchDescriptor<SetLog>())

        XCTAssertEqual(clients.count, 2)
        XCTAssertEqual(sessions.count, 4)
        XCTAssertEqual(exercises.count, 15)
        XCTAssertEqual(blocks.count, 20) // se-0001:4 + se-0002:6 + se-0003:5 + se-0004:5
        XCTAssertEqual(entries.count, 22)
        XCTAssertEqual(sets.count, 26)
    }

    func testReimportUpdatesMutatedFieldsRatherThanDuplicating() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        var data = try TestSupport.loadFixtureData()
        _ = try SeedImporter.importSeed(data: data, into: context)

        // Mutate one exercise's canonicalName in the raw JSON and re-import;
        // the existing row should be updated in place, not duplicated.
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var exercises = json["exercises"] as! [[String: Any]]
        exercises[0]["canonicalName"] = "Bench press (renamed)"
        json["exercises"] = exercises
        data = try JSONSerialization.data(withJSONObject: json)

        _ = try SeedImporter.importSeed(data: data, into: context)

        let allExercises = try context.fetch(FetchDescriptor<Exercise>())
        XCTAssertEqual(allExercises.count, 15, "renaming must not create a duplicate exercise")
        XCTAssertTrue(allExercises.contains { $0.canonicalName == "Bench press (renamed)" })
    }

    // MARK: - Atomicity (CONTRACT.md §11.2)

    func testStructurallyMalformedJSONLeavesStoreEmpty() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)

        // Missing required "id" field on the first client -> decode throws
        // before any context writes happen at all.
        let malformed = #"""
        {
          "schemaVersion": 1,
          "generatedAt": "2026-08-19T22:00:00Z",
          "source": "malformed test fixture",
          "stats": { "clientCount": 1, "sessionCount": 0, "exerciseCount": 0, "entryCount": 0, "setLogCount": 0, "needsReviewCount": 0, "exercisesNeedingReviewCount": 0, "sessionsNeedingReviewCount": 0 },
          "exercises": [],
          "clients": [ { "name": "No ID Client", "sessions": [], "assessments": [], "bodyMetrics": [] } ]
        }
        """#

        XCTAssertThrowsError(try SeedImporter.importSeed(data: Data(malformed.utf8), into: context))

        let clients = try context.fetch(FetchDescriptor<Client>())
        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        XCTAssertEqual(clients.count, 0)
        XCTAssertEqual(sessions.count, 0)
    }

    func testStatsMismatchRollsBackFullyBuiltObjectGraph() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        var data = try TestSupport.loadFixtureData()

        // This JSON is structurally valid and will build a full, correct
        // object graph in the context -- but the declared `stats.setLogCount`
        // is deliberately wrong, so the post-import self-check must catch it
        // and roll back everything that was staged, not just refuse to save
        // the mismatched field.
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var stats = json["stats"] as! [String: Any]
        stats["setLogCount"] = 999
        json["stats"] = stats
        data = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try SeedImporter.importSeed(data: data, into: context)) { error in
            guard case SeedImporter.ImportError.statsMismatch = error else {
                return XCTFail("Expected .statsMismatch, got \(error)")
            }
        }

        let clients = try context.fetch(FetchDescriptor<Client>())
        let sessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        let entries = try context.fetch(FetchDescriptor<ExerciseEntry>())
        let sets = try context.fetch(FetchDescriptor<SetLog>())

        XCTAssertEqual(clients.count, 0, "rollback must remove staged clients")
        XCTAssertEqual(sessions.count, 0, "rollback must remove staged sessions")
        XCTAssertEqual(exercises.count, 0, "rollback must remove staged exercises")
        XCTAssertEqual(entries.count, 0, "rollback must remove staged entries")
        XCTAssertEqual(sets.count, 0, "rollback must remove staged set logs")
    }

    func testValidImportAfterFailedImportStillSucceeds() throws {
        // Guards against a rollback leaving the context in a broken state
        // that poisons subsequent imports.
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        var badData = try TestSupport.loadFixtureData()
        var json = try JSONSerialization.jsonObject(with: badData) as! [String: Any]
        var stats = json["stats"] as! [String: Any]
        stats["clientCount"] = 999
        json["stats"] = stats
        badData = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try SeedImporter.importSeed(data: badData, into: context))

        let goodData = try TestSupport.loadFixtureData()
        let result = try SeedImporter.importSeed(data: goodData, into: context)
        XCTAssertEqual(result.clientCount, 2)

        let clients = try context.fetch(FetchDescriptor<Client>())
        XCTAssertEqual(clients.count, 2)
    }
}
