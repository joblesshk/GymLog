import XCTest
@testable import GymLogKit

@MainActor
final class LoadSelectionDraftTests: XCTestCase {
    func testBandCanBecomeManualPoundsAndSurviveCoding() throws {
        var draft = LoadSelectionDraft(load: .band(color: "orange", count: 2, raw: "original"), suggested: .band(colors: ["blue"]))
        draft.mode = .absolute; draft.number = "1234.567"; draft.unit = .lb
        let load = try XCTUnwrap(draft.resolved())
        XCTAssertEqual(load.numericKilograms!, 1234.567 * 0.45359237, accuracy: 0.00000001)
        let restored = try JSONDecoder().decode(LoadValue.self, from: JSONEncoder().encode(load))
        let reopened = LoadSelectionDraft(load: restored, suggested: .band(colors: ["blue"]))
        XCTAssertEqual(reopened.mode, .absolute)
        XCTAssertEqual(reopened.number, "1234.567")
        XCTAssertEqual(reopened.unit, .lb)
        XCTAssertEqual(restored.displayText, "1234.567lb")
        XCTAssertEqual(reopened.resolved(), load)
        XCTAssertEqual(AnalyticsMath.setVolume(load: load, actual: .fixed(value: 10, raw: "10"))!, 1234.567 * 0.45359237 * 10, accuracy: 0.000001)
    }

    func testOpenAndConfirmPreservesEveryOriginalRepresentation() {
        let values: [LoadValue] = [.absolute(kg: 1.25, raw: "1.25 kg source"), .band(color: "ORANGE", count: 2, raw: "2 bands"), .unknown(raw: "unrecognized load"), .machineStack(level: "L7", raw: "level 7"), .perSide(kg: 22.6796, raw: "50 lb"), .bodyweight(raw: "bw"), .assisted(kg: 35, raw: "35"), .sled(kg: 200, raw: "200"), .pinLoad(desc: "two pins", raw: "source")]
        for load in values {
            XCTAssertEqual(LoadSelectionDraft(load: load, suggested: .absolute).resolved(), load)
        }
    }

    func testCustomBandAndFreeDescriptionIgnoreExerciseClassification() throws {
        var draft = LoadSelectionDraft(load: .absolute(kg: 20, raw: "20"), suggested: .absolute)
        draft.mode = .band; draft.bandColor = "custom orange / blue"; draft.bandCount = "3"
        guard case .band(let color, let count, _) = try XCTUnwrap(draft.resolved()) else { return XCTFail() }
        XCTAssertEqual(color, "custom orange / blue"); XCTAssertEqual(count, 3)
        draft.mode = .custom; draft.detail = "two bands plus 5 lb"
        let custom = try XCTUnwrap(draft.resolved())
        XCTAssertEqual(custom.displayText, "two bands plus 5 lb")
        XCTAssertNil(AnalyticsMath.setVolume(load: custom, actual: .fixed(value: 10, raw: "10")))
    }

    func testChangingUnitKeepsNumberButUpdatesPhysicalLoad() throws {
        var draft = LoadSelectionDraft(load: .perSide(kg: 20, raw: "20"), suggested: .perSide)
        draft.unit = .lb
        let result = try XCTUnwrap(draft.resolved())
        XCTAssertEqual(result.numericKilograms!, 9.0718474, accuracy: 0.0000001)
        XCTAssertEqual(LoadSelectionDraft(load: result, suggested: .absolute).number, "20")
    }

    func testInvalidInputCannotCommitAndCustomOptionsExceedOldRange() {
        var draft = LoadSelectionDraft(load: .bodyweight(raw: "BW"), suggested: .bodyweightPlus)
        draft.mode = .absolute
        for text in ["", "-1", "nan", "inf", "1000.5", "100001", "hello"] {
            draft.number = text; XCTAssertNotNil(draft.validationError); XCTAssertNil(draft.resolved())
        }
        draft.number = "999,5"; XCTAssertNotNil(draft.resolved())
        draft.unit = .lb; draft.number = "2204"; XCTAssertNotNil(draft.resolved(), "2204 lb is under 1000 kg")
        draft.number = "2205"; XCTAssertNil(draft.resolved())
        draft.unit = .kg
        XCTAssertTrue(CustomLoadWeights.rows(presets: [20], saved: CustomLoadWeights.adding(1500.25, to: "[]"), current: 20).contains(1500.25))
        draft.mode = .band; draft.bandCount = "0"; XCTAssertNil(draft.resolved())
        draft.mode = .custom; draft.detail = " "; XCTAssertNil(draft.resolved())
    }

    func testExplicitAddedLoadIsNotReinterpretedAsAssistance() throws {
        var draft = LoadSelectionDraft(load: .assisted(kg: 20, raw: "20"), suggested: .assisted)
        draft.mode = .absolute; draft.number = "10"
        let load = try XCTUnwrap(draft.resolved())
        let reps = RepTarget.fixed(value: 10, raw: "10")
        let result = TrainingInsights.strength(id: "test", name: "Chin up", pattern: .pull, sets: [(load, reps, reps)], rest: 60, weight: 80, loadIsAssistance: true)
        XCTAssertFalse(result.rule.contains("assisted"))
        XCTAssertNil(AnalyticsMath.comparableKg(load, direction: .lowerIsStronger))
        XCTAssertNil(AnalyticsMath.comparableKg(.assisted(kg: 20, raw: "20"), direction: .higherIsStronger))
        XCTAssertEqual(AnalyticsMath.comparableKg(.assisted(kg: 20, raw: "20"), direction: .lowerIsStronger), 20)
    }
    func testHistoryLoadOverrideIsTransactionalAndPreservesUnknownActual() throws {
        let original = LoadValue.band(color: "blue", count: 1, raw: "blue band")
        let set = SetLog(setIndex: 0, load: original, target: .range(low: 8, high: 12, raw: "8-12"), actual: .unknown(raw: "not reported"), isInferred: true)
        var draft = SetEditDraft(set: set)
        var selection = LoadSelectionDraft(load: original, suggested: .band(colors: ["blue"]))
        selection.mode = .absolute; selection.number = "25"; selection.unit = .lb
        draft.selectedLoad = try XCTUnwrap(selection.resolved())
        XCTAssertEqual(set.load, original, "Editing the value draft must not write through")
        draft.apply(to: set)
        XCTAssertEqual(set.load.displayText, "25lb")
        XCTAssertEqual(set.actual, .unknown(raw: "not reported"))
        XCTAssertEqual(set.target, .range(low: 8, high: 12, raw: "8-12"))
        XCTAssertFalse(set.isInferred)
    }

}
