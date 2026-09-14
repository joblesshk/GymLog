import XCTest
@testable import GymLogKit

/// 2026-09-07 M2: `WODSummaryFormatter` -- the one place history list,
/// session detail, CSV export, and the shareable summary all get their WOD
/// text from, so they can't drift into slightly different renderings.
final class WODSummaryFormatterTests: XCTestCase {
    private func movement(_ name: String, _ quantity: WorkoutQuantity, load: LoadValue? = nil) -> WODMovementPrescription {
        WODMovementPrescription(stepID: UUID().uuidString, exerciseID: nil, exerciseNameSnapshot: name, quantity: quantity, load: load)
    }

    func testAMRAPCompactSummaryMatchesReviewExample() {
        let prescription = WODPrescription(
            id: "wod-1", revision: 1, format: .amrap, timeCapSeconds: 720,
            rounds: [WODRoundPrescription(roundIndex: 0, movements: [movement("Burpee", .reps(10, raw: "10"))])],
            scoringRule: .roundsAndReps
        )
        let result = WODResult(status: .completed, completedRounds: 5, partialRoundQuantity: .reps(12, raw: "12"), variant: .scaled)
        let summary = WODSummaryFormatter.compactSummary(WODPayload(prescription: prescription, result: result))
        XCTAssertEqual(summary, "AMRAP 12:00 · 5 輪 + 12 次 · Scaled（調整版）")
    }

    func testForTimeCompletedSummary() {
        let prescription = WODPrescription(id: "wod-fran", revision: 1, format: .forTime, rounds: [], scoringRule: .completionTime)
        let result = WODResult(status: .completed, elapsedSeconds: 512, variant: .rx)
        let summary = WODSummaryFormatter.compactSummary(WODPayload(prescription: prescription, result: result))
        XCTAssertEqual(summary, "計時完成 · 8:32 · Rx")
    }

    /// The header legitimately states the PRESCRIBED cap ("上限 12:00") --
    /// that's not the bug this guards against. The bug would be the SCORE
    /// segment reading as if 12:00 were a completion time; the actual
    /// assertion is that the result renders as "capped", full stop, with no
    /// separate elapsed-time-shaped score segment at all.
    func testForTimeCappedNeverShowsAFakeFinishTime() {
        let prescription = WODPrescription(id: "wod-cap", revision: 1, format: .forTime, timeCapSeconds: 720, rounds: [], scoringRule: .completionTime)
        let result = WODResult(status: .capped)
        let summary = WODSummaryFormatter.compactSummary(WODPayload(prescription: prescription, result: result))
        XCTAssertEqual(summary, "計時完成（上限12:00） · 超時（Capped）")
    }

    func testNotRecordedShowsExplicitly() {
        let prescription = WODPrescription(id: "wod-fresh", revision: 1, format: .emom, intervalSeconds: 60, intervalCount: 12, rounds: [], scoringRule: .manual)
        let summary = WODSummaryFormatter.compactSummary(WODPayload(prescription: prescription, result: WODResult()))
        XCTAssertTrue(summary.contains("未記錄"))
    }

    func testDetailLinesIncludeMovementsAndLoad() {
        let prescription = WODPrescription(
            id: "wod-thruster", revision: 1, format: .forTime, timeCapSeconds: 720,
            rounds: [WODRoundPrescription(roundIndex: 0, movements: [
                movement("Thruster", .reps(21, raw: "21"), load: .absolute(kg: 43, raw: "43")),
                movement("Pull-up", .reps(21, raw: "21")),
            ])],
            scoringRule: .completionTime
        )
        let lines = WODSummaryFormatter.detailLines(WODPayload(prescription: prescription, result: WODResult(status: .completed, elapsedSeconds: 512, notes: "felt strong")))
        XCTAssertTrue(lines.contains { $0.contains("Thruster") && $0.contains("43kg") })
        XCTAssertTrue(lines.contains { $0.contains("Pull-up") })
        XCTAssertTrue(lines.contains { $0.contains("felt strong") })
    }
}
