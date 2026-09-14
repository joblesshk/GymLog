import XCTest
import SwiftData
@testable import GymLogKit

/// "歷史里面需要增加一个功能，把已经输入或记载的历史输出出来" -- CSV export of a
/// client's full recorded history (`Sources/Export/HistoryCSVExporter.swift`).
@MainActor
final class HistoryCSVExporterTests: XCTestCase {
    private func utcDate(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    private func makeExercise(recordingMetric: RecordingMetric = .reps) -> Exercise {
        Exercise(id: "ex-bench", canonicalName: "Bench press", aliases: [], movementPattern: .push, equipment: .barbell, loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 1, needsReview: false, reviewReason: nil, recordingMetric: recordingMetric)
    }

    /// Builds one real client with one session/block/entry/2 sets, using a
    /// real in-memory `ModelContext` (relationship arrays like
    /// `client.sessions` only reliably populate once saved -- mirrors the
    /// pattern `M5ARoundDraftTests.swift` already established).
    private func makeClientWithHistory() throws -> Client {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)

        let client = Client(id: "cl-1", name: "Example Athlete")
        context.insert(client)
        let exercise = makeExercise()
        context.insert(exercise)

        let session = WorkoutSession(id: "se-1", date: utcDate(year: 2025, month: 1, day: 31), dateOrigin: .asRecorded, dateRaw: "2025-01-31", weekNumber: 5, sourceSheet: "App", sourceRow: 0)
        session.client = client
        context.insert(session)

        let block = SessionBlock(order: 0, blockType: .single, sourceRow: 0)
        block.note = "備註, 含逗號"
        block.session = session
        context.insert(block)

        let entry = ExerciseEntry(order: 0, exerciseIdRef: exercise.id, exerciseRaw: "Bench press", plannedSets: 2, exercise: exercise)
        entry.block = block
        context.insert(entry)

        let set0 = SetLog(setIndex: 0, load: .absolute(kg: 40, raw: "40"), target: .fixed(value: 10, raw: "10"), actual: .fixed(value: 8, raw: "8"), isInferred: false)
        set0.entry = entry
        context.insert(set0)
        let set1 = SetLog(setIndex: 1, load: .absolute(kg: 40, raw: "40"), target: .fixed(value: 10, raw: "10"), actual: .fixed(value: 10, raw: "10"), isInferred: false)
        set1.entry = entry
        context.insert(set1)

        try context.save()
        return client
    }

    func testCSVStartsWithUTF8BOMAndHeaderRow() throws {
        let client = try makeClientWithHistory()
        let csv = HistoryCSVExporter.csv(for: client)
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}"), "must lead with a UTF-8 BOM so Excel doesn't misdetect encoding")
        let firstLine = csv.dropFirst().components(separatedBy: "\r\n").first
        XCTAssertEqual(firstLine, "日期,週數,訓練塊類型,動作,組別,重量,目標,實際,備註")
    }

    func testOneRowPerSetLogWithFullContext() throws {
        let client = try makeClientWithHistory()
        let csv = HistoryCSVExporter.csv(for: client)
        let lines = csv.dropFirst().components(separatedBy: "\r\n")
        XCTAssertEqual(lines.count, 3, "header + 2 SetLogs")

        // lines[0] is the header (see the previous test); data rows follow.
        // Row for set 0 (target 10, actual 8 -- CONTRACT-M9.md: genuinely
        // different, the export must carry both, not just one).
        XCTAssertEqual(lines[1], "2025-01-31,5,單組,Bench press,1,40kg,10 次,8 次,\"備註, 含逗號\"")
        // Row for set 1 (target 10, actual 10 -- the "happened to hit it" case).
        XCTAssertEqual(lines[2], "2025-01-31,5,單組,Bench press,2,40kg,10 次,10 次,\"備註, 含逗號\"")
    }

    func testEmptyClientProducesHeaderOnlyCSV() {
        let client = Client(id: "cl-empty", name: "No History")
        let csv = HistoryCSVExporter.csv(for: client)
        let lines = csv.dropFirst().components(separatedBy: "\r\n")
        XCTAssertEqual(lines.count, 1, "no sessions -> just the header row")
    }

    func testSuggestedFileNameSanitizesSlashesAndIsDeterministicByDate() {
        let client = Client(id: "cl-1", name: "A/B Client")
        let date = utcDate(year: 2025, month: 1, day: 31)
        let name = HistoryCSVExporter.suggestedFileName(for: client, exportedAt: date)
        XCTAssertFalse(name.contains("/"), "a raw '/' in the client name must not leak into a filename")
        XCTAssertTrue(name.hasSuffix(".csv"))
        XCTAssertTrue(name.contains("2025-01-31"))
    }

    func testWriteTempFileProducesReadableFileWithMatchingContent() throws {
        let client = try makeClientWithHistory()
        let url = try HistoryCSVExporter.writeTempFile(for: client)
        defer { try? FileManager.default.removeItem(at: url) }
        // Byte-for-byte, not decoded-String, comparison: `String(contentsOf:
        // encoding: .utf8)` silently consumes a leading BOM as part of
        // decoding (that's the BOM's whole job), so a String-level compare
        // would spuriously fail even though the file's bytes are exactly
        // right -- which is the thing actually worth asserting here.
        let writtenData = try Data(contentsOf: url)
        XCTAssertEqual(writtenData, HistoryCSVExporter.data(for: client))
    }

    /// CSV-escaping edge case independent of the model layer: a field
    /// containing a literal double-quote must have it doubled per RFC 4180.
    func testFieldsWithEmbeddedQuotesAreEscapedCorrectly() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = Client(id: "cl-1", name: "Test")
        context.insert(client)
        let exercise = makeExercise()
        context.insert(exercise)
        let session = WorkoutSession(id: "se-1", date: Date(), dateOrigin: .asRecorded, dateRaw: "2025-01-01", weekNumber: 1, sourceSheet: "App", sourceRow: 0)
        session.client = client
        context.insert(session)
        let block = SessionBlock(order: 0, blockType: .single, sourceRow: 0)
        block.note = "教練說 \"加油\""
        block.session = session
        context.insert(block)
        let entry = ExerciseEntry(order: 0, exerciseIdRef: exercise.id, exerciseRaw: "Bench press", plannedSets: 1, exercise: exercise)
        entry.block = block
        context.insert(entry)
        let set = SetLog(setIndex: 0, load: .absolute(kg: 40, raw: "40"), target: .fixed(value: 10, raw: "10"), actual: .fixed(value: 10, raw: "10"), isInferred: false)
        set.entry = entry
        context.insert(set)
        try context.save()

        let csv = HistoryCSVExporter.csv(for: client)
        XCTAssertTrue(csv.contains("\"教練說 \"\"加油\"\"\""), "embedded quote must be doubled inside the quoted field")
    }
}
