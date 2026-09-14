import XCTest
@testable import GymLogKit

/// Whole-workbook parsing against synthetic, in-memory XLSX parts: sheet detection, the
/// documented column layout, and every date form described in docs/EXCEL_FORMAT.md.
final class WorkbookSessionParserTests: XCTestCase {

    // MARK: - Synthetic workbook

    private struct MemoryArchive: ArchiveReading {
        let entries: [String: String]
        func entryNames() -> [String] { Array(entries.keys) }
        func data(forEntry name: String) throws -> Data {
            guard let text = entries[name] else { throw ArchiveReadingError.entryNotFound(name: name) }
            return Data(text.utf8)
        }
    }

    /// A cell value: text, or a number with a style (0 = General, 1 = custom "m/d", 2 = built-in date).
    private enum Cell {
        case text(String)
        case number(Double, style: Int)
    }

    private static let header: [Cell] = ["Exercise", "Sets", "Weights", "Rep range", "Rep completed", "Rest", "Notes"].map { .text($0) }

    private func workbook(sheets: [(name: String, rows: [[Cell]])]) throws -> XLSXWorkbook {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        }
        var entries: [String: String] = [:]
        var sheetTags = "", rels = ""
        for (index, sheet) in sheets.enumerated() {
            let n = index + 1
            sheetTags += #"<sheet name="\#(escape(sheet.name))" sheetId="\#(n)" r:id="rId\#(n)"/>"#
            rels += #"<Relationship Id="rId\#(n)" Target="worksheets/sheet\#(n).xml"/>"#
            var rowsXML = ""
            for (r, cells) in sheet.rows.enumerated() {
                var cellsXML = ""
                for (c, cell) in cells.enumerated() {
                    let ref = String(UnicodeScalar(65 + c)!) + String(r + 1)
                    switch cell {
                    case .text(let value) where value.isEmpty:
                        continue
                    case .text(let value):
                        cellsXML += #"<c r="\#(ref)" t="inlineStr"><is><t>\#(escape(value))</t></is></c>"#
                    case let .number(value, style):
                        cellsXML += #"<c r="\#(ref)" s="\#(style)"><v>\#(value)</v></c>"#
                    }
                }
                rowsXML += #"<row r="\#(r + 1)">\#(cellsXML)</row>"#
            }
            entries["xl/worksheets/sheet\(n).xml"] = "<worksheet><sheetData>\(rowsXML)</sheetData></worksheet>"
        }
        entries["xl/workbook.xml"] = #"<workbook xmlns:r="r"><sheets>\#(sheetTags)</sheets></workbook>"#
        entries["xl/_rels/workbook.xml.rels"] = "<Relationships>\(rels)</Relationships>"
        entries["xl/styles.xml"] = #"<styleSheet><numFmts><numFmt numFmtId="164" formatCode="m/d"/></numFmts><cellXfs><xf numFmtId="0"/><xf numFmtId="164"/><xf numFmtId="14"/></cellXfs></styleSheet>"#
        return try XLSXWorkbook(archive: MemoryArchive(entries: entries))
    }

    /// One session: a "Week N" row with its date cell, the header row, and a single bench-press row.
    private func week(_ number: Int, _ date: Cell) -> [[Cell]] {
        [[.text("Week \(number)"), date], Self.header,
         [.text("Bench press"), .number(3, style: 0), .text("40"), .text("8-12"), .text("10"), .text("90s"), .text("")]]
    }

    private func serial(_ year: Int, _ month: Int, _ day: Int) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let epoch = calendar.date(from: DateComponents(year: 1899, month: 12, day: 30))!
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day))!
        return Double(calendar.dateComponents([.day], from: epoch, to: date).day!)
    }

    private func ymd(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func utc(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: - Layout

    func testDocumentedLayoutParsesBlocksSupersetsAndWarmups() throws {
        let rows: [[Cell]] = [
            [.text("Week 1"), .text("3/2/2025")],
            Self.header,
            [.text("Warm-up"), .text("Rowing 5 min"), .text(""), .text(""), .text(""), .text(""), .text("easy")],
            [.text("Bench press"), .number(3, style: 0), .text("40"), .text("8-12"), .text("10"), .text("90s"), .text("felt good")],
            [.text("DB curl + Plank"), .number(2, style: 0), .text("8each, bw"), .text("12, 30s"), .text("12, 30s"), .text("1min"), .text("")],
            [.text("Cool-down"), .text("Stretching")],
        ]
        let parsed = try WorkbookSessionParser.parse(workbook(sheets: [("Training log", rows)]))

        XCTAssertEqual(parsed.sessions.count, 1)
        let session = try XCTUnwrap(parsed.sessions.first)
        XCTAssertEqual(ymd(session.date), "2025-02-03")
        XCTAssertEqual(session.warmup, "Rowing 5 min")
        XCTAssertEqual(session.warmupNote, "easy")
        XCTAssertEqual(session.cooldown, "Stretching")
        XCTAssertEqual(session.blocks.count, 2)

        let bench = session.blocks[0]
        XCTAssertEqual(bench.blockType, .single)
        XCTAssertEqual(bench.restSeconds, 90)
        XCTAssertEqual(bench.note, "felt good")
        XCTAssertEqual(bench.entries.first?.sets.count, 3)
        XCTAssertEqual(bench.entries.first?.sets.first?.load, .absolute(kg: 40, raw: "40"))
        XCTAssertEqual(bench.entries.first?.sets.first?.target, .range(low: 8, high: 12, raw: "8-12"))
        XCTAssertEqual(bench.entries.first?.sets.first?.actual, .fixed(value: 10, raw: "10"))

        let superset = session.blocks[1]
        XCTAssertEqual(superset.blockType, .superset)
        XCTAssertEqual(superset.restSeconds, 60)
        XCTAssertEqual(superset.entries.map(\.exerciseRaw), ["DB curl", "Plank"])
        XCTAssertEqual(superset.entries[1].sets.first?.target, .time(seconds: 30, raw: "30s"))
    }

    func testInfoSheetWithoutWeekRowsIsIgnoredAndLegacySheetNameStillWorks() throws {
        let info: [[Cell]] = [[.text("Name"), .text("Example Athlete")]]
        let parsed = try WorkbookSessionParser.parse(workbook(sheets: [("Info", info), ("Full body", week(1, .text("1/3/2025")))]))
        XCTAssertEqual(parsed.sessions.map(\.sourceSheet), ["Full body"])
    }

    func testWorkbookWithoutWeekRowsReportsNoLogSheets() throws {
        XCTAssertThrowsError(try WorkbookSessionParser.parse(workbook(sheets: [("Sheet1", [Self.header])]))) {
            XCTAssertEqual($0 as? WorkbookSessionParserError, .noLogSheets)
        }
    }

    func testHeaderMismatchIsReported() throws {
        let rows: [[Cell]] = [[.text("Week 1"), .text("1/3/2025")], [.text("Exercise"), .text("Reps")]]
        XCTAssertThrowsError(try WorkbookSessionParser.parse(workbook(sheets: [("Log", rows)]))) {
            guard case .headerMismatch(sheet: "Log", row: 2, found: _)? = $0 as? WorkbookSessionParserError else {
                return XCTFail("unexpected error \($0)")
            }
        }
    }

    // MARK: - Dates

    func testRealExcelDatesAreImportedAsWritten() throws {
        let rows = week(1, .number(serial(2025, 3, 1), style: 2)) + week(2, .number(serial(2025, 3, 8), style: 2))
            + week(3, .number(serial(2025, 3, 15), style: 2))
        let parsed = try WorkbookSessionParser.parse(workbook(sheets: [("Log", rows)]))
        XCTAssertEqual(parsed.sessions.map { ymd($0.date) }, ["2025-03-01", "2025-03-08", "2025-03-15"])
        XCTAssertEqual(parsed.sessions.map(\.dateOrigin), [.asRecorded, .asRecorded, .asRecorded])
        XCTAssertFalse(parsed.sessions.contains { $0.needsReview })
    }

    func testDayFirstEntriesSwappedByMonthFirstExcelAreRestored() throws {
        // "2/3" meant 2 March, but a month-first Excel stored it as 3 February. Only the
        // swapped reading keeps the neighbouring text dates in order.
        let rows = week(1, .text("20/2/2025")) + week(2, .number(serial(2025, 2, 3), style: 1)) + week(3, .text("10/3"))
        let parsed = try WorkbookSessionParser.parse(workbook(sheets: [("Log", rows)]))
        XCTAssertEqual(parsed.sessions.map { ymd($0.date) }, ["2025-02-20", "2025-03-02", "2025-03-10"])
        XCTAssertEqual(parsed.sessions.map(\.dateOrigin), [.asRecorded, .reconstructed, .asRecorded])
    }

    func testTextDatesWithoutAnyYearUseTheMostRecentPastYear() throws {
        let rows = week(1, .text("20/12")) + week(2, .text("3/1")) + week(3, .text("12/1"))
        let parsed = try WorkbookSessionParser.parse(workbook(sheets: [("Log", rows)]), now: utc(2026, 2, 1))
        XCTAssertEqual(parsed.sessions.map { ymd($0.date) }, ["2025-12-20", "2026-01-03", "2026-01-12"])

        let early = try WorkbookSessionParser.parse(workbook(sheets: [("Log", week(1, .text("12/1")))]), now: utc(2026, 1, 8))
        XCTAssertEqual(early.sessions.map { ymd($0.date) }, ["2025-01-12"], "a date after today belongs to last year")
    }

    func testTwoDigitYearsAndYearRolloverFromAnAnchor() throws {
        let rows = week(1, .text("28/12/24")) + week(2, .text("4/1"))
        let parsed = try WorkbookSessionParser.parse(workbook(sheets: [("Log", rows)]))
        XCTAssertEqual(parsed.sessions.map { ymd($0.date) }, ["2024-12-28", "2025-01-04"])
    }

    func testSmallDateReversalIsKeptAndFlaggedForReview() throws {
        let rows = week(1, .text("24/7/2025")) + week(2, .text("21/7/2025"))
        let parsed = try WorkbookSessionParser.parse(workbook(sheets: [("Log", rows)]))
        XCTAssertEqual(parsed.sessions.count, 2)
        let flagged = parsed.sessions.filter(\.needsReview)
        XCTAssertEqual(flagged.map { ymd($0.date) }, ["2025-07-21"])
    }

    func testLargeDateReversalAbortsTheImport() throws {
        let rows = week(1, .text("24/7/2025")) + week(2, .text("1/5/2025"))
        XCTAssertThrowsError(try WorkbookSessionParser.parse(workbook(sheets: [("Log", rows)]))) {
            guard case .dateOrderingBroken? = $0 as? WorkbookSessionParserError else { return XCTFail("unexpected error \($0)") }
        }
    }

    func testUnreadableOrMissingDatesNameTheRow() throws {
        for (date, raw) in [(Cell.text("next Monday"), "next Monday"), (.text(""), ""), (.text("31/2/2025"), "31/2/2025")] {
            let rows = week(1, date)
            XCTAssertThrowsError(try WorkbookSessionParser.parse(workbook(sheets: [("Log", rows)])), raw) {
                XCTAssertEqual($0 as? WorkbookSessionParserError, .invalidDate(sheet: "Log", row: 1, raw: raw))
            }
        }
    }
}
