import XCTest
@testable import GymLogKit

/// CONTRACT-M7.md §3.4 / §7 step 5. Parity target is `migration/migrate.py`,
/// not intuition -- every expected value here traces to either CONTRACT.md
/// §7/§8's documented examples or a verified real cell in
/// `migration/source.xlsx` (see M7WorkbookParityTests for the full-workbook
/// version of this check).
final class M7ExcelValueParserTests: XCTestCase {
    // MARK: - §7.6 LoadValue (8 of the 9 documented kinds -- `assisted` is
    // never produced by `parseLoadValue` itself, by design: `migrate.py`
    // never emits it either. An assisted exercise's cell still parses as
    // plain `.absolute`; "assisted" semantics live on `Exercise.loadDirection`,
    // set by the classifier from the exercise NAME, not the load cell.)

    func testAbsolute() {
        let result = ExcelValueParsers.parseLoadValue("35", exerciseNameLower: "bench press")
        XCTAssertEqual(result.value, .absolute(kg: 35, raw: "35"))
        XCTAssertFalse(result.needsReview)
    }

    func testAbsoluteConvertedFromPounds() {
        let result = ExcelValueParsers.parseLoadValue("30lbs", exerciseNameLower: "bench press")
        guard case .absolute(let kg, let raw) = result.value else { return XCTFail("expected .absolute") }
        XCTAssertEqual(kg, 13.6078, accuracy: 0.0001)
        XCTAssertEqual(raw, "30lbs")
        XCTAssertFalse(result.needsReview)
    }

    func testPerSideFromEach() {
        let result = ExcelValueParsers.parseLoadValue("6each", exerciseNameLower: "curl")
        XCTAssertEqual(result.value, .perSide(kg: 6, raw: "6each"))
    }

    func testPerSideFromSingle() {
        let result = ExcelValueParsers.parseLoadValue("Single 12", exerciseNameLower: "split squat")
        XCTAssertEqual(result.value, .perSide(kg: 12, raw: "Single 12"))
    }

    func testBodyweight() {
        for text in ["bw", "Bw", "b.w.", "BW"] {
            let result = ExcelValueParsers.parseLoadValue(text, exerciseNameLower: "dips")
            XCTAssertEqual(result.value, .bodyweight(raw: text), "failed for \"\(text)\"")
        }
    }

    func testBandSingleColorWithCount() {
        let result = ExcelValueParsers.parseLoadValue("2blue", exerciseNameLower: "chin up w/band")
        XCTAssertEqual(result.value, .band(color: "blue", count: 2, raw: "2blue"))
        XCTAssertFalse(result.needsReview)
    }

    func testBandSingleColorNoCount() {
        let result = ExcelValueParsers.parseLoadValue("Purple", exerciseNameLower: "chin up w/band")
        XCTAssertEqual(result.value, .band(color: "purple", count: 1, raw: "Purple"))
    }

    func testMachineStack() {
        let result = ExcelValueParsers.parseLoadValue("Machine", exerciseNameLower: "leg press")
        XCTAssertEqual(result.value, .machineStack(level: "Machine", raw: "Machine"))
    }

    func testMachineStackRackLevel() {
        let result = ExcelValueParsers.parseLoadValue("Rack 12", exerciseNameLower: "leg extension")
        XCTAssertEqual(result.value, .machineStack(level: "12", raw: "Rack 12"))
    }

    func testPinLoad() {
        let result = ExcelValueParsers.parseLoadValue("1red1green", exerciseNameLower: "cable row")
        XCTAssertEqual(result.value, .pinLoad(desc: "1red1green", raw: "1red1green"))
    }

    func testSledGatedByExerciseName() {
        let sled = ExcelValueParsers.parseLoadValue("40", exerciseNameLower: "sled push + pull")
        XCTAssertEqual(sled.value, .sled(kg: 40, raw: "40"))
        let notSled = ExcelValueParsers.parseLoadValue("40", exerciseNameLower: "bench press")
        XCTAssertEqual(notSled.value, .absolute(kg: 40, raw: "40"))
    }

    func testUnknownForBlankOrSlash() {
        for text in ["", "/"] {
            let result = ExcelValueParsers.parseLoadValue(text, exerciseNameLower: "x")
            XCTAssertEqual(result.value, .unknown(raw: text))
            XCTAssertFalse(result.needsReview, "blank/slash is a known 'not recorded' case, not a review flag")
        }
    }

    func testUnknownForUnparseableTextIsFlaggedForReview() {
        let result = ExcelValueParsers.parseLoadValue("rope", exerciseNameLower: "rope swing")
        XCTAssertEqual(result.value, .unknown(raw: "rope"))
        XCTAssertTrue(result.needsReview)
    }

    // MARK: - §7.9 combined resistance bands

    func testCombinedBandAbbreviationsMergeRegardlessOfOrder() {
        let gb = ExcelValueParsers.parseLoadValue("G+B", exerciseNameLower: "chin up w/band")
        let bg = ExcelValueParsers.parseLoadValue("B+G", exerciseNameLower: "chin up w/band")
        XCTAssertEqual(gb.value, .band(color: "blue+green", count: 2, raw: "G+B"))
        XCTAssertEqual(bg.value, .band(color: "blue+green", count: 2, raw: "B+G"))
        XCTAssertTrue(gb.needsReview, "abbreviation expansion is an inference and must be flagged")
        XCTAssertTrue(bg.needsReview)
    }

    func testCombinedBandFullSpellingDoesNotNeedReview() {
        let result = ExcelValueParsers.parseLoadValue("Green+blue", exerciseNameLower: "chin up w/band")
        XCTAssertEqual(result.value, .band(color: "blue+green", count: 2, raw: "Green+blue"))
        XCTAssertFalse(result.needsReview, "no abbreviation was expanded here, both colors spelled out")
    }

    func testCombinedBandMixedAbbreviationAndFullSpellingStillMerges() {
        let result = ExcelValueParsers.parseLoadValue("Orange+blue", exerciseNameLower: "chin up w/band")
        XCTAssertEqual(result.value, .band(color: "blue+orange", count: 2, raw: "Orange+blue"))
    }

    // MARK: - §7.7 RepTarget (all 7 documented kinds)

    func testRepTargetRange() {
        let result = ExcelValueParsers.parseRepTargetText("8-12", raw: "8-12")
        XCTAssertEqual(result.value, .range(low: 8, high: 12, raw: "8-12"))
    }

    func testRepTargetFixed() {
        let result = ExcelValueParsers.parseRepTargetText("10", raw: "10")
        XCTAssertEqual(result.value, .fixed(value: 10, raw: "10"))
    }

    func testRepTargetApproxFixed() {
        let result = ExcelValueParsers.parseRepTargetText("~3", raw: "~3")
        XCTAssertEqual(result.value, .fixed(value: 3, raw: "~3"))
        XCTAssertFalse(result.needsReview)
    }

    func testRepTargetTimeFromMinutes() {
        let result = ExcelValueParsers.parseRepTargetText("1min", raw: "1min")
        XCTAssertEqual(result.value, .time(seconds: 60, raw: "1min"))
    }

    func testRepTargetTimeFromSeconds() {
        let result = ExcelValueParsers.parseRepTargetText("30s", raw: "30s")
        XCTAssertEqual(result.value, .time(seconds: 30, raw: "30s"))
    }

    func testRepTargetDistance() {
        let result = ExcelValueParsers.parseRepTargetText("200m", raw: "200m")
        XCTAssertEqual(result.value, .distance(meters: 200, raw: "200m"))
    }

    func testRepTargetRoundsWord() {
        let result = ExcelValueParsers.parseRepTargetText("3round", raw: "3round")
        XCTAssertEqual(result.value, .rounds(count: 3, raw: "3round"))
    }

    func testRepTargetRoundsXNotation() {
        let result = ExcelValueParsers.parseRepTargetText("5x3", raw: "5x3")
        XCTAssertEqual(result.value, .rounds(count: 5, raw: "5x3"))
    }

    func testRepTargetPerSideOnlyInSingleBlockPath() {
        let cell = XLSXCell(text: "10,10", styleIndex: 0, isString: true)
        let result = ExcelValueParsers.parseRepTargetCellSingleBlock(cell, category: .general)
        XCTAssertEqual(result.value, .perSide(left: 10, right: 10, raw: "10,10"))
        XCTAssertFalse(result.needsReview)
    }

    func testRepTargetPerSideDoesNotApplyThreeValues() {
        // §7.8: 3+ comma-separated values is NOT perSide (it's per-set reps).
        let cell = XLSXCell(text: "5,5,5", styleIndex: 0, isString: true)
        let result = ExcelValueParsers.parseRepTargetCellSingleBlock(cell, category: .general)
        if case .perSide = result.value { XCTFail("3-value comma list must not become perSide") }
    }

    // MARK: - §8.2: rep-range values Excel converted to date serials
    // (verified mappings straight from CONTRACT.md §8.2's own table)

    func testKnownSerialReconstructions() {
        let cases: [(serial: Int, low: Int, high: Int)] = [
            (45724, 3, 8),
            (45945, 10, 15),
            (45818, 6, 10),
            (45721, 3, 5),
            (45881, 8, 12),
        ]
        for c in cases {
            let result = ExcelValueParsers.parseRepTargetFromSerial(c.serial, raw: "\(c.serial)")
            XCTAssertEqual(result.value, .range(low: c.low, high: c.high, raw: "\(c.serial)"), "serial \(c.serial)")
            XCTAssertFalse(result.needsReview, "serial \(c.serial)")
        }
    }

    func testCorruptedSerialsAreRejectedByConstraintTwo() {
        // §8.2 constraint 2: 56789 passes constraint 1 (reconstructs to a
        // legal-looking 6-24 range) but fails constraint 2 (more than a year
        // after today -- it decodes to the year 2055). Constraint 1 alone
        // is not enough to catch it.
        let result = ExcelValueParsers.parseRepTargetFromSerial(56789, raw: "56789")
        XCTAssertEqual(result.value, .unknown(raw: "56789"))
        XCTAssertTrue(result.needsReview)
    }

    func testRepRangesTypedInAnyRecentYearAreReconstructed() {
        // "8-12" typed in 2019 and in August 2027 -- both outside the original 2023-2027 window.
        for serial in [43689, 46611] {
            let result = ExcelValueParsers.parseRepTargetFromSerial(serial, raw: "\(serial)")
            XCTAssertEqual(result.value, .range(low: 8, high: 12, raw: "\(serial)"), "serial \(serial)")
        }
    }

    // MARK: - §8.3: cardio times Excel read as h:mm instead of m:ss

    func testTimeSerialReconstruction() {
        // 0.0430555... days -> Excel reads as 1:02 (h:mm) -> reinterpreted
        // as 1 min 02 sec = 62 seconds (Ski 200m).
        let ski = ExcelValueParsers.parseRepTargetFromTimeSerial("0.0430555555555556", raw: "0.0430555555555556")
        XCTAssertEqual(ski.value, .time(seconds: 62, raw: "0.0430555555555556"))

        // 0.0993055... -> Excel reads as 2:23 -> 143 seconds (Rowing 500m).
        let rowing = ExcelValueParsers.parseRepTargetFromTimeSerial("0.0993055555555556", raw: "0.0993055555555556")
        XCTAssertEqual(rowing.value, .time(seconds: 143, raw: "0.0993055555555556"))
    }

    // MARK: - §8.4 Sets column anomalies

    func testSetsCellDateFormattedIsRejectedNotGuessed() {
        let cell = XLSXCell(text: "45516", styleIndex: 0, isString: false)
        let result = ExcelValueParsers.parseSetsCell(cell, category: .dateMonthDashDay)
        XCTAssertNil(result.sets)
        XCTAssertTrue(result.needsReview)
    }

    func testSetsCellPlainIntegerParses() {
        let cell = XLSXCell(text: "3", styleIndex: 0, isString: false)
        let result = ExcelValueParsers.parseSetsCell(cell, category: .general)
        XCTAssertEqual(result.sets, 3)
        XCTAssertFalse(result.needsReview)
    }

    func testSetsCellImplausibleMagnitudeRejected() {
        let cell = XLSXCell(text: "56789", styleIndex: 0, isString: false)
        let result = ExcelValueParsers.parseSetsCell(cell, category: .general)
        XCTAssertNil(result.sets)
        XCTAssertTrue(result.needsReview)
    }

    // MARK: - Rest

    func testRestMinutes() {
        XCTAssertEqual(ExcelValueParsers.parseRest("1min").seconds, 60)
    }

    func testRestSeconds() {
        XCTAssertEqual(ExcelValueParsers.parseRest("30s").seconds, 30)
    }

    // MARK: - Full-date guard (CONTRACT-M7.md §3.2, not present in migrate.py)

    func testDateBuiltinCategoryNeverGoesThroughSerialReconstruction() {
        let cell = XLSXCell(text: "45516", styleIndex: 0, isString: false)
        let result = ExcelValueParsers.parseRepTargetCell(cell, category: .dateBuiltin)
        XCTAssertEqual(result.value, .unknown(raw: "45516"))
        XCTAssertTrue(result.needsReview)
    }
}
