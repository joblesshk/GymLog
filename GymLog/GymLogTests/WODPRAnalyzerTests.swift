import XCTest
@testable import GymLogKit

/// 2026-09-07 M3: `WODPRAnalyzer` -- PR comparison across WOD attempts,
/// scoped to genuinely comparable groups (same prescription id + revision +
/// scoring rule + variant), never assuming "bigger number wins" the way
/// strength PRs do.
final class WODPRAnalyzerTests: XCTestCase {
    private func forTimeEntry(date: Date, id: String = "wod-fran", revision: Int = 1, elapsed: Int?, status: WODResultStatus = .completed, variant: WODVariant = .rx) -> WODPRAnalyzer.Entry {
        let prescription = WODPrescription(id: id, revision: revision, format: .forTime, rounds: [], scoringRule: .completionTime)
        let result = WODResult(status: status, elapsedSeconds: elapsed, variant: variant)
        return WODPRAnalyzer.Entry(date: date, payload: WODPayload(prescription: prescription, result: result))
    }

    private func amrapEntry(date: Date, rounds: Int?, partial: Int?, status: WODResultStatus = .completed, variant: WODVariant = .rx) -> WODPRAnalyzer.Entry {
        let prescription = WODPrescription(id: "wod-amrap", revision: 1, format: .amrap, timeCapSeconds: 720, rounds: [], scoringRule: .roundsAndReps)
        let result = WODResult(status: status, completedRounds: rounds, partialRoundQuantity: partial.map { .reps($0, raw: "\($0)") }, variant: variant)
        return WODPRAnalyzer.Entry(date: date, payload: WODPayload(prescription: prescription, result: result))
    }

    private func day(_ offset: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + Double(offset) * 86_400)
    }

    // MARK: - For Time: lower is better

    func testForTimeImprovementIsLowerElapsed() {
        let entries = [
            forTimeEntry(date: day(0), elapsed: 600),
            forTimeEntry(date: day(1), elapsed: 550),
            forTimeEntry(date: day(2), elapsed: 580),
        ]
        XCTAssertEqual(WODPRAnalyzer.prFlags(entries: entries), [true, true, false])
    }

    /// The review's own acceptance example, verbatim: 8:32 (512s) then a
    /// same-standard retest at 8:20 (500s) must register as an improvement.
    func testFasterRetestOfSameStandardIsAnImprovement() {
        let entries = [forTimeEntry(date: day(0), elapsed: 512), forTimeEntry(date: day(1), elapsed: 500)]
        XCTAssertEqual(WODPRAnalyzer.prFlags(entries: entries), [true, true])
    }

    /// A 12-minute cap (never a completion time) must never register as a
    /// PR, regardless of how the cap duration compares numerically to a
    /// real finish time.
    func testCappedAttemptNeverCountsAsAPR() {
        let entries = [forTimeEntry(date: day(0), elapsed: 512), forTimeEntry(date: day(1), elapsed: nil, status: .capped)]
        XCTAssertEqual(WODPRAnalyzer.prFlags(entries: entries), [true, false])
    }

    // MARK: - AMRAP: rounds then partial progress, never a decimal merge

    func testAMRAPImprovementIsMoreRoundsOrMorePartialProgress() {
        let entries = [
            amrapEntry(date: day(0), rounds: 5, partial: 3),
            amrapEntry(date: day(1), rounds: 5, partial: 12), // same rounds, more partial reps -- improvement
            amrapEntry(date: day(2), rounds: 4, partial: 999), // fewer full rounds -- NOT an improvement no matter the partial reps
            amrapEntry(date: day(3), rounds: 6, partial: 0), // one more full round -- improvement
        ]
        XCTAssertEqual(WODPRAnalyzer.prFlags(entries: entries), [true, true, false, true])
    }

    // MARK: - Revision isolation

    func testDifferentPrescriptionRevisionsDoNotCompare() {
        let entries = [
            forTimeEntry(date: day(0), revision: 1, elapsed: 600),
            forTimeEntry(date: day(1), revision: 2, elapsed: 400), // different (edited) prescription -- own group
        ]
        // Both are the FIRST entry in their own revision's group, so both
        // register as a (first-ever) PR -- but critically the second's low
        // time must not be compared against/replace the first revision's.
        XCTAssertEqual(WODPRAnalyzer.prFlags(entries: entries), [true, true])
        let groups = WODPRAnalyzer.bestPerGroup(entries: entries)
        XCTAssertEqual(groups.count, 2)
    }

    // MARK: - Variant isolation: Scaled never breaks an Rx record

    func testScaledNeverBreaksAnRxRecord() {
        let entries = [
            forTimeEntry(date: day(0), elapsed: 600, variant: .rx),
            forTimeEntry(date: day(1), elapsed: 300, variant: .scaled), // much faster, but Scaled
        ]
        XCTAssertEqual(WODPRAnalyzer.prFlags(entries: entries), [true, true], "each variant gets its own first-time PR, but they must be in separate groups")
        let groups = WODPRAnalyzer.bestPerGroup(entries: entries)
        XCTAssertEqual(groups.count, 2)
        let rxKey = WODPRAnalyzer.GroupKey(prescriptionID: "wod-fran", revision: 1, scoringRule: .completionTime, variant: .rx)
        XCTAssertEqual(groups[rxKey]?.value, .time(600))
    }

    // MARK: - Substituted attempts opt out of automatic comparison

    func testSubstitutedMovementAttemptIsExcludedFromComparison() {
        let prescription = WODPrescription(id: "wod-sub", revision: 1, format: .forTime, rounds: [], scoringRule: .completionTime)
        let normal = WODPRAnalyzer.Entry(date: day(0), payload: WODPayload(prescription: prescription, result: WODResult(status: .completed, elapsedSeconds: 600, variant: .rx)))
        let substituted = WODPRAnalyzer.Entry(
            date: day(1),
            payload: WODPayload(
                prescription: prescription,
                result: WODResult(
                    status: .completed, elapsedSeconds: 300, variant: .rx,
                    actualMovements: [WODMovementPrescription(stepID: "s1", exerciseID: nil, exerciseNameSnapshot: "Substituted Movement", quantity: .reps(10, raw: "10"))]
                )
            )
        )
        XCTAssertNil(WODPRAnalyzer.groupKey(for: substituted))
        XCTAssertEqual(WODPRAnalyzer.prFlags(entries: [normal, substituted]), [true, false], "a substituted attempt must never silently join the unmodified group's PR curve")
    }

    // MARK: - Not-recorded / manual scoring never auto-compares

    func testNotRecordedNeverCountsAsAPR() {
        let entries = [forTimeEntry(date: day(0), elapsed: nil, status: .notRecorded)]
        XCTAssertEqual(WODPRAnalyzer.prFlags(entries: entries), [false])
    }

    func testManualScoringRuleNeverAutoCompares() {
        let prescription = WODPrescription(id: "wod-manual", revision: 1, format: .emom, rounds: [], scoringRule: .manual)
        let entry = WODPRAnalyzer.Entry(date: day(0), payload: WODPayload(prescription: prescription, result: WODResult(status: .completed, variant: .rx)))
        XCTAssertNil(WODPRAnalyzer.comparableScore(entry.payload))
        XCTAssertEqual(WODPRAnalyzer.prFlags(entries: [entry]), [false])
    }

    // MARK: - worstInterval / totalQuantity scoring

    func testWorstIntervalScoringComparesTheMinimumInterval() {
        let prescription = WODPrescription(id: "wod-tabata", revision: 1, format: .interval, rounds: [], scoringRule: .worstInterval)
        func entry(date: Date, values: [Int]) -> WODPRAnalyzer.Entry {
            let results = values.enumerated().map { WODIntervalResult(intervalIndex: $0.offset, outcome: .completed, completedQuantity: .reps($0.element, raw: "\($0.element)")) }
            return WODPRAnalyzer.Entry(date: date, payload: WODPayload(prescription: prescription, result: WODResult(status: .completed, intervalResults: results, variant: .rx)))
        }
        let entries = [entry(date: day(0), values: [20, 18, 15, 19]), entry(date: day(1), values: [20, 19, 17, 20])]
        // Worst of [20,18,15,19] = 15; worst of [20,19,17,20] = 17 -- higher worst-interval is better.
        XCTAssertEqual(WODPRAnalyzer.prFlags(entries: entries), [true, true])
    }

    func testTotalQuantityScoringComparesTheSummedTotal() {
        let prescription = WODPrescription(id: "wod-total", revision: 1, format: .interval, rounds: [], scoringRule: .totalQuantity)
        func entry(date: Date, total: Int) -> WODPRAnalyzer.Entry {
            WODPRAnalyzer.Entry(date: date, payload: WODPayload(prescription: prescription, result: WODResult(status: .completed, typedTotals: [.reps(total, raw: "\(total)")], variant: .rx)))
        }
        let entries = [entry(date: day(0), total: 100), entry(date: day(1), total: 90)]
        XCTAssertEqual(WODPRAnalyzer.prFlags(entries: entries), [true, false])
    }

    /// 总量比较必须校验单位一致，不能把公尺总量和卡路里总量直接相减/相比。
    func testTotalQuantityScoringRefusesToCompareMismatchedUnits() {
        let prescription = WODPrescription(id: "wod-total-mixed", revision: 1, format: .interval, rounds: [], scoringRule: .totalQuantity)
        let metersEntry = WODPRAnalyzer.Entry(date: day(0), payload: WODPayload(prescription: prescription, result: WODResult(status: .completed, typedTotals: [.meters(500, raw: "500")], variant: .rx)))
        let caloriesEntry = WODPRAnalyzer.Entry(date: day(1), payload: WODPayload(prescription: prescription, result: WODResult(status: .completed, typedTotals: [.machineCalories(600, raw: "600")], variant: .rx)))
        // Both individually score fine, but the second must not be judged an
        // "improvement" over the first purely because 600 > 500 -- the units
        // don't match, so `isImprovement` must refuse to compare them.
        XCTAssertNotNil(WODPRAnalyzer.comparableScore(metersEntry.payload))
        XCTAssertNotNil(WODPRAnalyzer.comparableScore(caloriesEntry.payload))
        XCTAssertEqual(WODPRAnalyzer.prFlags(entries: [metersEntry, caloriesEntry]), [true, false])
    }

    /// A result whose own `typedTotals` mixes units (e.g. a rowing+wall-ball
    /// interval keeping separate meters and reps totals) has no single
    /// well-defined "total" and must not silently pick the first entry as
    /// if it were the whole score.
    func testTotalQuantityScoringRefusesAmbiguousMixedUnitSingleResult() {
        let prescription = WODPrescription(id: "wod-total-self-mixed", revision: 1, format: .interval, rounds: [], scoringRule: .totalQuantity)
        let result = WODResult(status: .completed, typedTotals: [.reps(50, raw: "50"), .meters(200, raw: "200")], variant: .rx)
        let payload = WODPayload(prescription: prescription, result: result)
        XCTAssertNil(WODPRAnalyzer.comparableScore(payload))
    }

    // MARK: - First-time baseline vs. genuine improvement

    /// 用户明确要求的验收样例：同标准 For Time 三次 10、11、9 分钟 -- 第一次是
    /// 基准（不是"新纪录"，因为还没有任何东西可比较），第二次不是新纪录（比第
    /// 一次慢），第三次才是新纪录。
    func testTenElevenNineMinutesOnlyTheThirdIsARecord() {
        let entries = [
            forTimeEntry(date: day(0), elapsed: 600),  // 10:00 -- first, a baseline
            forTimeEntry(date: day(1), elapsed: 660),  // 11:00 -- slower, not a record
            forTimeEntry(date: day(2), elapsed: 540),  // 9:00 -- faster than the 10:00 baseline, a record
        ]
        XCTAssertEqual(WODPRAnalyzer.recordStatuses(entries: entries), [.first, .none, .improved])
        XCTAssertEqual(WODPRAnalyzer.prFlags(entries: entries), [true, false, true], "prFlags stays true for both 'first' and 'improved', for callers that only need a boolean")
    }

    func testRecordStatusDistinguishesFirstFromImprovedAcrossRoundsAndReps() {
        let entries = [
            amrapEntry(date: day(0), rounds: 5, partial: 3),
            amrapEntry(date: day(1), rounds: 5, partial: 3), // exact tie -- never an improvement
            amrapEntry(date: day(2), rounds: 5, partial: 4), // genuinely better
        ]
        XCTAssertEqual(WODPRAnalyzer.recordStatuses(entries: entries), [.first, .none, .improved])
    }
}
