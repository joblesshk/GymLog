import XCTest
@testable import GymLogKit

/// 草稿自动保存与恢复（2026-09-06 审查报告"适合当前范围的功能"第一批）：
/// `TodayDraftStore` <-> `TodayDraftSnapshot` round-tripping, and
/// `DraftPersistence`'s disk read/write, in isolation from any SwiftUI/
/// scenePhase wiring (that part lives in the app target and can't be
/// `@testable import`ed here -- see `HeartRateMonitorTests`'s own note on
/// the same limitation for CoreBluetooth).
@MainActor
final class TodayDraftSnapshotTests: XCTestCase {

    private func makeExercise(id: String = "ex-bench") -> Exercise {
        Exercise(id: id, canonicalName: "Bench press", aliases: [], movementPattern: .push, equipment: .barbell, loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 1, needsReview: false, reviewReason: nil)
    }

    // MARK: - TodayDraftStore.snapshot()

    func testSnapshotIsNilWhenNothingIsUnsaved() {
        let store = TodayDraftStore()
        XCTAssertNil(store.snapshot(), "An idle store (not active, or active with zero blocks) has nothing worth persisting.")

        store.startNew(clientID: "cl-1")
        XCTAssertNil(store.snapshot(), "Just-started, still-empty draft matches hasUnsavedWork == false.")
    }

    func testSnapshotAndRestoreRoundTripsFullDraft() {
        let exercise = makeExercise()
        let store = TodayDraftStore()
        store.startNew(clientID: "cl-1", date: Date(timeIntervalSince1970: 1_700_000_000))
        store.plannedDurationMinutes = 45
        let entry = EntryDraft(exercise: exercise, setsCount: 3, load: .absolute(kg: 42.5, raw: "42.5"), targetQuantity: 8, actualQuantity: 8, restSeconds: 90)
        store.blocks.append(BlockDraft(blockType: .single, restSeconds: 90, entries: [entry]))

        guard let snapshot = store.snapshot() else { return XCTFail("Active draft with one block must produce a snapshot.") }
        XCTAssertEqual(snapshot.clientID, "cl-1")
        XCTAssertEqual(snapshot.plannedDurationMinutes, 45)
        XCTAssertEqual(snapshot.blocks.count, 1)
        XCTAssertEqual(snapshot.blocks[0].entries.first?.exerciseID, exercise.id)

        let restoredStore = TodayDraftStore()
        let (dropped, metricUncertain) = restoredStore.restore(from: snapshot, exercises: [exercise])
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(metricUncertain, 0)
        XCTAssertTrue(restoredStore.isActive)
        XCTAssertEqual(restoredStore.clientID, "cl-1")
        XCTAssertEqual(restoredStore.plannedDurationMinutes, 45)
        XCTAssertEqual(restoredStore.blocks.count, 1)
        XCTAssertEqual(restoredStore.blocks[0].entries.first?.exercise.id, exercise.id)
        XCTAssertEqual(restoredStore.blocks[0].entries.first?.rounds.first?.setsCount, 3)
        guard case .absolute(let kg, _) = restoredStore.blocks[0].entries.first?.rounds.first?.load ?? .bodyweight(raw: "") else {
            return XCTFail("expected .absolute load to round-trip")
        }
        XCTAssertEqual(kg, 42.5)
    }

    /// The exercise was deleted/merged away between "save the draft to disk"
    /// and "restore it" -- the entry (and an entirely-emptied block) must be
    /// dropped, not crash, and the caller must be told how many were lost.
    func testRestoreDropsEntriesWhoseExerciseNoLongerExists() {
        let goneExercise = makeExercise(id: "ex-deleted")
        let survivingExercise = makeExercise(id: "ex-still-here")

        let store = TodayDraftStore()
        store.startNew(clientID: "cl-1")
        store.blocks.append(BlockDraft(blockType: .single, entries: [
            EntryDraft(exercise: goneExercise, setsCount: 3, load: .absolute(kg: 40, raw: "40"), targetQuantity: 8, actualQuantity: 8),
        ]))
        store.blocks.append(BlockDraft(blockType: .single, entries: [
            EntryDraft(exercise: survivingExercise, setsCount: 3, load: .absolute(kg: 40, raw: "40"), targetQuantity: 8, actualQuantity: 8),
        ]))
        guard let snapshot = store.snapshot() else { return XCTFail("expected a snapshot") }

        let restoredStore = TodayDraftStore()
        // Only `survivingExercise` is available at restore time.
        let (dropped, _) = restoredStore.restore(from: snapshot, exercises: [survivingExercise])
        XCTAssertEqual(dropped, 1, "The one entry referencing a since-deleted exercise must be counted as dropped.")
        XCTAssertEqual(restoredStore.blocks.count, 1, "The block left with zero entries after the drop must not be restored empty.")
        XCTAssertEqual(restoredStore.blocks.first?.entries.first?.exercise.id, survivingExercise.id)
    }

    // MARK: - B02 (2026-09-07 审阅): recordingMetric change must not reinterpret an existing draft's numbers

    /// The exact case the audit's diagnostic test reproduced: a 500m row
    /// Round is snapshotted, the exercise is reclassified to reps in the
    /// meantime, and restoring must still read back 500 METERS, not 500
    /// reps.
    func testReclassifyingExerciseAfterSnapshotDoesNotReinterpretQuantity() {
        let exercise = Exercise(
            id: "ex-row", canonicalName: "Row", aliases: [], movementPattern: .conditioning, equipment: .ergometer,
            loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 0, needsReview: false, reviewReason: nil,
            recordingMetric: .distance
        )
        let entry = EntryDraft(exercise: exercise, setsCount: 1, load: .bodyweight(raw: "BW"), targetQuantity: 500, actualQuantity: 500)
        let snapshot = entry.snapshot()
        XCTAssertEqual(snapshot.recordingMetric, .distance)

        // The exercise gets reclassified after the snapshot was taken --
        // same live `Exercise` object, mutated in place, exactly like
        // editing it through ExerciseLibraryView would.
        exercise.recordingMetric = .reps

        let (restored, metricUncertain) = EntryDraft.restore(from: snapshot, exercises: [exercise])
        XCTAssertFalse(metricUncertain, "The snapshot carries its own recordingMetric, so this must be treated as certain even though the library's current classification disagrees.")
        guard case .distance(let meters, _) = restored?.resolvedSets().first?.actual else {
            return XCTFail("expected the original 500 meters to survive the reclassification, not become 500 reps")
        }
        XCTAssertEqual(meters, 500)
    }

    /// A snapshot written before `recordingMetric` existed on disk (`nil`)
    /// must still restore -- using the exercise's current classification as
    /// a best-effort fallback -- but must be flagged as unverified rather
    /// than silently presented as exact.
    func testLegacySnapshotWithoutRecordingMetricFallsBackAndFlagsUncertain() {
        let exercise = makeExercise()
        let legacySnapshot = EntryDraftSnapshot(
            id: UUID(), exerciseID: exercise.id,
            rounds: [RoundDraftSnapshot(id: UUID(), setsCount: 3, load: .absolute(kg: 40, raw: "40"), target: .fixed(value: 8, raw: "8"), actual: .fixed(value: 8, raw: "8"))],
            restSeconds: nil, recordingMetric: nil
        )
        let (restored, metricUncertain) = EntryDraft.restore(from: legacySnapshot, exercises: [exercise])
        XCTAssertNotNil(restored)
        XCTAssertTrue(metricUncertain, "A pre-fix snapshot with no persisted unit must be flagged, not silently trusted.")
    }

    // MARK: - DraftPersistence (real file I/O, isolated temp directory)

    private func makeTempPersistence() -> (persistence: DraftPersistence, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GymLogDraftTests-\(UUID().uuidString)", isDirectory: true)
        return (DraftPersistence(directory: dir), { try? FileManager.default.removeItem(at: dir) })
    }

    func testDraftPersistenceLoadIsNilWhenNothingSaved() {
        let (persistence, cleanup) = makeTempPersistence()
        defer { cleanup() }
        XCTAssertEqual(persistence.load(), .none)
    }

    func testDraftPersistenceSaveThenLoadRoundTrips() {
        let (persistence, cleanup) = makeTempPersistence()
        defer { cleanup() }

        let snapshot = TodayDraftSnapshot(
            clientID: "cl-1", sessionDate: Date(timeIntervalSince1970: 1_700_000_000),
            plannedDurationMinutes: 60, blocks: [], savedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        XCTAssertTrue(persistence.save(snapshot))
        guard case .snapshot(let loaded) = persistence.load() else { return XCTFail("expected a decoded snapshot") }
        XCTAssertEqual(loaded.clientID, "cl-1")
        XCTAssertEqual(loaded.plannedDurationMinutes, 60)
    }

    func testDraftPersistenceClearRemovesSavedSnapshot() {
        let (persistence, cleanup) = makeTempPersistence()
        defer { cleanup() }

        persistence.save(TodayDraftSnapshot(clientID: "cl-1", sessionDate: Date(), plannedDurationMinutes: 60, blocks: [], savedAt: Date()))
        XCTAssertNotEqual(persistence.load(), .none)
        persistence.clear()
        XCTAssertEqual(persistence.load(), .none, "clear() must remove the file so a stale draft never resurfaces.")
    }

    /// A second `save` must fully replace the first -- there is only ever
    /// one in-progress draft (CONTRACT-UI.md's single-draft model), so this
    /// must never become additive/append-only.
    func testDraftPersistenceSaveOverwritesPreviousSnapshot() {
        let (persistence, cleanup) = makeTempPersistence()
        defer { cleanup() }

        persistence.save(TodayDraftSnapshot(clientID: "cl-1", sessionDate: Date(), plannedDurationMinutes: 60, blocks: [], savedAt: Date()))
        persistence.save(TodayDraftSnapshot(clientID: "cl-2", sessionDate: Date(), plannedDurationMinutes: 30, blocks: [], savedAt: Date()))
        guard case .snapshot(let loaded) = persistence.load() else { return XCTFail("expected a decoded snapshot") }
        XCTAssertEqual(loaded.clientID, "cl-2")
    }

    /// 2026-09-07 审阅 B08: a corrupted on-disk file must be reported
    /// distinctly from "nothing was ever saved", and the raw bytes moved
    /// aside for inspection rather than silently dropped.
    func testDraftPersistenceCorruptedFileIsQuarantinedNotSilentlyDropped() throws {
        let (persistence, cleanup) = makeTempPersistence()
        defer { cleanup() }
        try FileManager.default.createDirectory(at: persistence.directory, withIntermediateDirectories: true)
        let fileURL = persistence.directory.appendingPathComponent("today-draft.json")
        try Data("{not valid json".utf8).write(to: fileURL)

        guard case .corrupted(let quarantinedTo) = persistence.load() else { return XCTFail("expected .corrupted") }
        XCTAssertNotNil(quarantinedTo, "the corrupt bytes should be preserved somewhere for diagnosis")
        if let quarantinedTo {
            XCTAssertTrue(FileManager.default.fileExists(atPath: quarantinedTo.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "the corrupted file must be moved out of the primary slot so it isn't mistaken for a valid draft next time")
        XCTAssertEqual(persistence.load(), .none, "after quarantining, a fresh load must behave like nothing is saved")
    }
}
