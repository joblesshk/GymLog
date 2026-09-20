import XCTest
@testable import GymLogKit

final class CustomLoadWeightsTests: XCTestCase {
    func testManualWeightRemainsAfterSwitchingBackToPreset() {
        let saved = CustomLoadWeights.adding(21, to: "[]")
        XCTAssertEqual(CustomLoadWeights.rows(presets: [20, 22.5], saved: saved, current: 20), [20, 21, 22.5])
    }

    func testDecimalOptionsAreSortedAndNotDuplicated() {
        let saved = CustomLoadWeights.adding(21.25, to: "[21.25,21]")
        XCTAssertEqual(CustomLoadWeights.rows(presets: [20, 22.5], saved: saved, current: 21.25), [20, 21, 21.25, 22.5])
    }

    func testInvalidStoredValuesAndCorruptStorageDoNotBreakPicker() {
        XCTAssertEqual(CustomLoadWeights.rows(presets: [20], saved: "[-1,0,1000,21]", current: .nan), [20, 21])
        XCTAssertEqual(CustomLoadWeights.rows(presets: [20], saved: "broken", current: 21), [20, 21])
    }
}
