import XCTest
@testable import GymLogKit

/// 2026-09-07 审阅 B01: `SetEditDraft` is the value-type draft
/// `SessionEditSheet` edits instead of writing straight into `SetLog` --
/// these tests are the actual bug-fix surface (cancel = zero writes,
/// validation, apply-on-confirm), independent of any SwiftUI rendering.
final class SetEditDraftTests: XCTestCase {
    private func makeSet(load: LoadValue = .absolute(kg: 50, raw: "50"), target: RepTarget = .fixed(value: 8, raw: "8"), actual: RepTarget = .fixed(value: 8, raw: "8")) -> SetLog {
        SetLog(setIndex: 0, load: load, target: target, actual: actual, isInferred: false)
    }

    // MARK: - Cancel is zero-write by construction

    /// The exact regression: edit a draft's text (simulating keystrokes),
    /// then simply discard the draft without ever calling `apply(to:)` --
    /// the underlying `SetLog` must be completely untouched. This is what
    /// "Cancel" reduces to in `SessionEditSheet` now: the draft is @State,
    /// dismissed without ever reaching `apply`.
    func testDiscardingAnEditedDraftNeverTouchesTheOriginalSetLog() {
        let set = makeSet()
        var draft = SetEditDraft(set: set)
        draft.kgText = "999"
        draft.targetPrimaryText = "50"
        draft.actualPrimaryText = "50"
        // Simulate "Cancel": the draft is simply dropped here, `apply` is
        // never called.
        _ = draft

        guard case .absolute(let kg, _) = set.load else { return XCTFail("expected .absolute") }
        XCTAssertEqual(kg, 50, "the original SetLog must be untouched by an edited-then-discarded draft")
        guard case .fixed(let target, _) = set.target, case .fixed(let actual, _) = set.actual else {
            return XCTFail("expected .fixed target/actual")
        }
        XCTAssertEqual(target, 8)
        XCTAssertEqual(actual, 8)
    }

    // MARK: - Apply on confirm

    func testApplyWritesEditedFixedRepsAndWeight() {
        let set = makeSet()
        var draft = SetEditDraft(set: set)
        draft.kgText = "60"
        draft.targetPrimaryText = "10"
        draft.actualPrimaryText = "9"
        XCTAssertNil(draft.validationError)
        draft.apply(to: set)

        guard case .absolute(let kg, _) = set.load else { return XCTFail() }
        XCTAssertEqual(kg, 60)
        guard case .fixed(let target, _) = set.target, case .fixed(let actual, _) = set.actual else { return XCTFail() }
        XCTAssertEqual(target, 10)
        XCTAssertEqual(actual, 9)
    }

    func testApplySupportsTimeDistanceRoundsAndPerSide() {
        let timeSet = makeSet(target: .time(seconds: 30, raw: "30"), actual: .time(seconds: 30, raw: "30"))
        var timeDraft = SetEditDraft(set: timeSet)
        timeDraft.targetPrimaryText = "45"; timeDraft.actualPrimaryText = "40"
        XCTAssertNil(timeDraft.validationError)
        timeDraft.apply(to: timeSet)
        guard case .time(let seconds, _) = timeSet.actual else { return XCTFail() }
        XCTAssertEqual(seconds, 40)

        let distanceSet = makeSet(target: .distance(meters: 500, raw: "500"), actual: .distance(meters: 500, raw: "500"))
        var distanceDraft = SetEditDraft(set: distanceSet)
        distanceDraft.actualPrimaryText = "480"
        XCTAssertNil(distanceDraft.validationError)
        distanceDraft.apply(to: distanceSet)
        guard case .distance(let meters, _) = distanceSet.actual else { return XCTFail() }
        XCTAssertEqual(meters, 480)

        let roundsSet = makeSet(target: .rounds(count: 3, raw: "3"), actual: .rounds(count: 3, raw: "3"))
        var roundsDraft = SetEditDraft(set: roundsSet)
        roundsDraft.actualPrimaryText = "2"
        roundsDraft.apply(to: roundsSet)
        guard case .rounds(let count, _) = roundsSet.actual else { return XCTFail() }
        XCTAssertEqual(count, 2)

        let perSideSet = makeSet(target: .perSide(left: 10, right: 10, raw: "10,10"), actual: .perSide(left: 10, right: 10, raw: "10,10"))
        var perSideDraft = SetEditDraft(set: perSideSet)
        perSideDraft.actualPrimaryText = "8"
        perSideDraft.actualSecondaryText = "9"
        XCTAssertNil(perSideDraft.validationError)
        perSideDraft.apply(to: perSideSet)
        guard case .perSide(let left, let right, _) = perSideSet.actual else { return XCTFail() }
        XCTAssertEqual(left, 8)
        XCTAssertEqual(right, 9)
    }

    // MARK: - Failed attempts (actual = 0) must be enterable, per B03

    func testZeroActualIsAValidCompletedButFailedEntry() {
        let set = makeSet()
        var draft = SetEditDraft(set: set)
        draft.actualPrimaryText = "0"
        XCTAssertNil(draft.validationError, "actual=0 (a failed attempt, B03) must remain a valid entry, not rejected as invalid input")
        draft.apply(to: set)
        guard case .fixed(let actual, _) = set.actual else { return XCTFail() }
        XCTAssertEqual(actual, 0)
    }

    // MARK: - Validation

    func testEmptyFieldsAreInvalid() {
        let set = makeSet()
        var draft = SetEditDraft(set: set)
        draft.actualPrimaryText = ""
        XCTAssertNotNil(draft.validationError)
    }

    func testNegativeRepsAreInvalid() {
        let set = makeSet()
        var draft = SetEditDraft(set: set)
        draft.actualPrimaryText = "-1"
        XCTAssertNotNil(draft.validationError)
    }

    func testNonFiniteOrNegativeWeightIsInvalid() {
        let set = makeSet()
        var draft = SetEditDraft(set: set)
        draft.kgText = "-5"
        XCTAssertNotNil(draft.validationError)

        draft.kgText = "abc"
        XCTAssertNotNil(draft.validationError)

        draft.kgText = "42.5"
        XCTAssertNil(draft.validationError)
    }

    func testOutOfBoundsValuesAreInvalid() {
        let set = makeSet()
        var draft = SetEditDraft(set: set)
        draft.actualPrimaryText = "\(SetEditDraft.maxQuantity + 1)"
        XCTAssertNotNil(draft.validationError)

        draft.actualPrimaryText = "8"
        draft.kgText = "\(SetEditDraft.maxKg + 1)"
        XCTAssertNotNil(draft.validationError)
    }

    func testDecimalWeightIsAccepted() {
        let set = makeSet()
        var draft = SetEditDraft(set: set)
        draft.kgText = "42.5"
        XCTAssertNil(draft.validationError)
        draft.apply(to: set)
        guard case .absolute(let kg, _) = set.load else { return XCTFail() }
        XCTAssertEqual(kg, 42.5)
    }

    // MARK: - Unsupported kinds stay read-only

    func testBodyweightLoadIsNotWeightEditableButRepsStillAre() {
        let set = makeSet(load: .bodyweight(raw: "BW"))
        let draft = SetEditDraft(set: set)
        XCTAssertFalse(draft.isWeightEditable)
        XCTAssertTrue(draft.isEditable, "reps should still be editable even though weight (bodyweight) is not")
    }

    func testRangeTargetIsUnsupportedReadOnly() {
        let set = makeSet(target: .range(low: 8, high: 12, raw: "8-12"), actual: .range(low: 8, high: 12, raw: "8-12"))
        let draft = SetEditDraft(set: set)
        XCTAssertFalse(draft.isEditable)
        XCTAssertNil(draft.validationError, "an unsupported/read-only draft must never block Save")
    }
}
