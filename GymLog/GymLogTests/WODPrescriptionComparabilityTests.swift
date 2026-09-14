import XCTest
@testable import GymLogKit

/// `WODPrescription.comparabilitySnapshot`/`isComparablyEquivalent(to:)` --
/// the deterministic, non-hash-based structural comparison
/// `WODBlockDraft.resolveIdentity()` uses to decide whether a re-save should
/// bump `revision`. "标题和备注等不影响运动处方的字段不应意外打断比较"
/// and "动作及顺序、各轮数量与单位、负重、动作标准、時限、間歇配置、計分
/// 方式" are the two halves of the same contract this file checks.
final class WODPrescriptionComparabilityTests: XCTestCase {
    private func basePrescription(id: String = "wod-1", revision: Int = 1, name: String? = nil, standardNotes: String? = nil) -> WODPrescription {
        WODPrescription(
            id: id, revision: revision, name: name, format: .forTime, timeCapSeconds: 900,
            rounds: [
                WODRoundPrescription(roundIndex: 0, movements: [
                    WODMovementPrescription(
                        stepID: "s1", exerciseID: "ex-thruster", exerciseNameSnapshot: "Thruster",
                        quantity: .reps(21, raw: "21"), load: .absolute(kg: 43, raw: "43"), standard: "full depth"
                    ),
                ])
            ],
            scoringRule: .completionTime, standardNotes: standardNotes
        )
    }

    // MARK: - Fields that must NOT break comparability

    func testIdRevisionNameAndStandardNotesDoNotAffectComparability() {
        let a = basePrescription(id: "wod-1", revision: 1, name: nil, standardNotes: nil)
        let b = basePrescription(id: "wod-2", revision: 7, name: "Fran-ish", standardNotes: "2026 Open standards")
        XCTAssertTrue(a.isComparablyEquivalent(to: b), "id/revision/name/standardNotes must never break comparability")
    }

    /// Re-typing the same load/quantity with different display text (e.g.
    /// "20" vs "20.0") must never look like a different prescription --
    /// only the STRUCTURAL value matters.
    func testDisplayOnlyRawTextDoesNotAffectComparability() {
        var a = basePrescription()
        var b = basePrescription()
        a.rounds[0].movements[0].quantity = .reps(21, raw: "21")
        b.rounds[0].movements[0].quantity = .reps(21, raw: "twenty-one")
        a.rounds[0].movements[0].load = .absolute(kg: 43, raw: "43kg")
        b.rounds[0].movements[0].load = .absolute(kg: 43, raw: "43.0")
        XCTAssertTrue(a.isComparablyEquivalent(to: b))
    }

    /// Redirecting an exercise-library id (a merge) is expected to change
    /// the STORED prescription's `exerciseID` field in place, but that
    /// change never flows through `isComparablyEquivalent` in practice --
    /// the redirection service mutates the persisted prescription directly
    /// and never calls `resolveIdentity()`. This test instead documents the
    /// SAFE re-save path: once both sides reference the SAME (post-redirect)
    /// id, they stay comparable.
    func testSameExerciseIDOnBothSidesStaysComparableAfterARedirect() {
        var original = basePrescription()
        original.rounds[0].movements[0].exerciseID = "ex-thruster-merged"
        var candidate = basePrescription()
        candidate.rounds[0].movements[0].exerciseID = "ex-thruster-merged"
        XCTAssertTrue(original.isComparablyEquivalent(to: candidate))
    }

    // MARK: - Fields that MUST break comparability

    func testDifferentMovementQuantityBreaksComparability() {
        var a = basePrescription()
        var b = basePrescription()
        b.rounds[0].movements[0].quantity = .reps(15, raw: "15")
        XCTAssertFalse(a.isComparablyEquivalent(to: b))
        _ = a // silence "never mutated" warning if any
    }

    func testDifferentLoadBreaksComparability() {
        let a = basePrescription()
        var b = basePrescription()
        b.rounds[0].movements[0].load = .absolute(kg: 50, raw: "50")
        XCTAssertFalse(a.isComparablyEquivalent(to: b))
    }

    func testDifferentStandardBreaksComparability() {
        let a = basePrescription()
        var b = basePrescription()
        b.rounds[0].movements[0].standard = "partial depth"
        XCTAssertFalse(a.isComparablyEquivalent(to: b))
    }

    func testDifferentMovementOrderBreaksComparability() {
        var a = basePrescription()
        a.rounds[0].movements.append(
            WODMovementPrescription(stepID: "s2", exerciseID: "ex-pullup", exerciseNameSnapshot: "Pull-up", quantity: .reps(21, raw: "21"))
        )
        var b = a
        b.rounds[0].movements.reverse()
        XCTAssertFalse(a.isComparablyEquivalent(to: b), "movement order is part of what was prescribed")
    }

    func testDifferentRoundCountBreaksComparability() {
        let a = basePrescription()
        var b = basePrescription()
        b.rounds.append(b.rounds[0])
        XCTAssertFalse(a.isComparablyEquivalent(to: b))
    }

    func testDifferentTimeCapBreaksComparability() {
        let a = basePrescription()
        var b = basePrescription()
        b.timeCapSeconds = 600
        XCTAssertFalse(a.isComparablyEquivalent(to: b))
    }

    func testDifferentScoringRuleBreaksComparability() {
        let a = basePrescription()
        var b = basePrescription()
        b.scoringRule = .manual
        XCTAssertFalse(a.isComparablyEquivalent(to: b))
    }

    // MARK: - uniqueMovementNames across rounds

    func testUniqueMovementNamesDedupesAcrossRoundsPreservingOrder() {
        let thruster = WODMovementPrescription(stepID: "s1", exerciseID: "ex-thruster", exerciseNameSnapshot: "Thruster", quantity: .reps(21, raw: "21"))
        let pullup = WODMovementPrescription(stepID: "s2", exerciseID: "ex-pullup", exerciseNameSnapshot: "Pull-up", quantity: .reps(21, raw: "21"))
        let prescription = WODPrescription(
            id: "wod-fran", revision: 1, format: .forTime,
            rounds: [
                WODRoundPrescription(roundIndex: 0, movements: [thruster, pullup]),
                WODRoundPrescription(roundIndex: 1, movements: [thruster, pullup]),
                WODRoundPrescription(roundIndex: 2, movements: [thruster, pullup]),
            ],
            scoringRule: .completionTime
        )
        XCTAssertEqual(prescription.uniqueMovementNames, ["Thruster", "Pull-up"], "21-15-9's three rounds share two movements, not six")
    }
}
