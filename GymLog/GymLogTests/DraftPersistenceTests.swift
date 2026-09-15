import XCTest
@testable import GymLogKit

/// R06 (2026-09-16 design-refresh review): `DraftPersistence.load()` used to
/// delete the on-disk file unconditionally after *attempting* to quarantine
/// corrupted bytes, even when that quarantine write itself failed (disk
/// full/permissions) -- the coach's last-in-progress draft could be lost
/// with no copy anywhere. These tests pin the fixed behavior: the source is
/// only ever removed as a side effect of a successful move, and a
/// still-unquarantined corrupted file blocks the next autosave from
/// clobbering it.
final class DraftPersistenceTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DraftPersistenceTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        // Quarantine-failure tests lock `tempDir` itself read-only; restore
        // write permission before XCTest's own cleanup tries to remove it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeSnapshot(plannedDurationMinutes: Int = 60) -> TodayDraftSnapshot {
        TodayDraftSnapshot(
            clientID: "cl-1", sessionDate: Date(timeIntervalSince1970: 1_700_000_000),
            plannedDurationMinutes: plannedDurationMinutes, blocks: [],
            savedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    func testLoadIsNoneWhenNothingWasEverSaved() {
        let persistence = DraftPersistence(directory: tempDir)
        XCTAssertEqual(persistence.load(), .none)
    }

    func testSaveThenLoadRoundTripsAValidSnapshot() {
        let persistence = DraftPersistence(directory: tempDir)
        let snapshot = makeSnapshot()
        XCTAssertTrue(persistence.save(snapshot))
        XCTAssertEqual(persistence.load(), .snapshot(snapshot))
    }

    /// A later valid save must still be able to overwrite an earlier valid
    /// snapshot -- the "unquarantined corruption" block must never catch the
    /// ordinary single-draft-overwrite case.
    func testSecondValidSaveOverwritesTheFirst() {
        let persistence = DraftPersistence(directory: tempDir)
        XCTAssertTrue(persistence.save(makeSnapshot()))
        let second = makeSnapshot(plannedDurationMinutes: 45)
        XCTAssertTrue(persistence.save(second))
        XCTAssertEqual(persistence.load(), .snapshot(second))
    }

    /// The ordinary path: corrupted bytes on disk, quarantine directory is
    /// writable -- the corrupted file is moved aside, not left in place.
    func testCorruptedFileIsQuarantinedAndOriginalRemoved() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("today-draft.json")
        try Data("{ not valid json".utf8).write(to: fileURL)

        let persistence = DraftPersistence(directory: tempDir)
        guard case .corrupted(let quarantinedTo) = persistence.load() else {
            return XCTFail("expected .corrupted")
        }
        let quarantineURL = try XCTUnwrap(quarantinedTo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "original must be gone once it was actually moved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL.path))
    }

    /// T06 core case: quarantine write fails (directory made read-only) --
    /// the corrupted original must survive untouched, not be deleted anyway.
    func testCorruptedFileSurvivesWhenQuarantineMoveFails() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("today-draft.json")
        let corruptBytes = Data("{ not valid json".utf8)
        try corruptBytes.write(to: fileURL)
        // Removing write permission on the containing directory makes
        // `moveItem` (which must add/remove directory entries) fail, without
        // relying on actually filling the disk.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tempDir.path)

        let persistence = DraftPersistence(directory: tempDir)
        XCTAssertEqual(persistence.load(), .corrupted(quarantinedTo: nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "original must NOT be deleted when quarantine failed")
        XCTAssertEqual(try Data(contentsOf: fileURL), corruptBytes, "original bytes must be untouched")
    }

    /// T06's other half: once a corrupted file couldn't be quarantined, the
    /// very next autosave must not silently overwrite it.
    func testSaveRefusesToOverwriteAnUnquarantinedCorruptedFile() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("today-draft.json")
        let corruptBytes = Data("{ not valid json".utf8)
        try corruptBytes.write(to: fileURL)

        let persistence = DraftPersistence(directory: tempDir)
        // Simulate "quarantine already failed once" by directly leaving the
        // corrupted file in place (equivalent post-condition to the previous
        // test, without re-locking the directory here).
        XCTAssertFalse(persistence.save(makeSnapshot()), "save must refuse while an unquarantined corrupted file occupies the slot")
        XCTAssertEqual(try Data(contentsOf: fileURL), corruptBytes, "save must not have touched the corrupted bytes")
    }

    /// Once the corrupted file is cleared (coach acknowledged/discarded it),
    /// saves resume normally.
    func testSaveResumesAfterClear() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("today-draft.json")
        try Data("{ not valid json".utf8).write(to: fileURL)

        let persistence = DraftPersistence(directory: tempDir)
        XCTAssertFalse(persistence.save(makeSnapshot()))
        persistence.clear()
        XCTAssertTrue(persistence.save(makeSnapshot()))
        XCTAssertEqual(persistence.load(), .snapshot(makeSnapshot()))
    }
}
