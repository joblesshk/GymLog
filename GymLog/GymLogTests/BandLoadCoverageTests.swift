import XCTest
@testable import GymLogKit

final class BandLoadCoverageTests: XCTestCase {
    private final class BundleToken {}

    func testEveryLibraryBandExerciseAllowsNumericLoadInBothUnits() throws {
        let url = try XCTUnwrap(Bundle(for: BundleToken.self).url(forResource: "exercise_library_seed", withExtension: "json"))
        let seed = try JSONDecoder().decode(SeedFile.self, from: Data(contentsOf: url))
        let candidates = seed.exercises.filter { $0.equipment == .band || ([$0.canonicalName] + $0.aliases).contains { $0.lowercased().contains("band") } }
        XCTAssertEqual(Set(candidates.map(\.id)), ["ex-5eacc80a", "ex-a92dbf6e", "ex-222d9144", "ex-3f78b44b"])
        for exercise in candidates {
            for unit in LoadWeightUnit.allCases {
                var edit = LoadSelectionDraft(load: .band(color: "blue+green", count: 2, raw: "source"), suggested: .band(colors: ["blue", "orange"]))
                edit.mode = .absolute; edit.unit = unit; edit.number = "27.125"
                let load = try XCTUnwrap(edit.resolved(), exercise.canonicalName)
                XCTAssertEqual(load.numericKilograms!, 27.125 * unit.kilogramsPerUnit, accuracy: 0.000001, exercise.canonicalName)
                XCTAssertEqual(load.weightUnit, unit)
            }
        }
    }

    func testHistoricalBandLoadsAllowWeightEvenWithoutBandEquipmentClassification() throws {
        for equipment in Equipment.allCases {
            let exercise = Exercise(id: "legacy-band", canonicalName: "Chin up reverse w/band", aliases: [], movementPattern: .pull, equipment: equipment, loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 0, needsReview: false, reviewReason: nil)
            var edit = LoadSelectionDraft(load: .band(color: "yellow", count: 1, raw: "Yellow"), suggested: LoadWheelResolver.kind(for: exercise, historicalBandColors: ["yellow"]))
            XCTAssertEqual(edit.mode, .band)
            edit.mode = .absolute; edit.number = "12.75"
            XCTAssertEqual(try XCTUnwrap(edit.resolved()).numericKilograms, 12.75)
        }
    }

    func testStandardCompositeAndLightColorsAreMonolingual() {
        let labels = ["blue", "orange", "light green", "light blue", "blue+green", "blue+orange", "green+orange", "綠色", "浅蓝", "Blue（藍）", "light green（淺綠）", "藍＋Green"]
        for label in labels {
            let zh = BandColorName.display(label, language: .zhHant)
            let en = BandColorName.display(label, language: .en)
            XCTAssertNil(zh.range(of: "[A-Za-z]", options: .regularExpression), zh)
            XCTAssertNil(en.range(of: "[一-鿿]", options: .regularExpression), en)
        }
        XCTAssertEqual(BandColorName.display("blue+green", language: .zhHant), "藍＋綠")
        XCTAssertEqual(BandColorName.display("淺綠", language: .en), "Light Green")
        XCTAssertEqual(BandColorName.canonical("橙色彈力帶"), "orange")
        XCTAssertEqual(BandColorName.canonical("blue+blue"), "blue+blue", "Do not collapse two same-color bands")
    }

    func testUnknownModelIsPreservedAndDisplayDoesNotRewriteHistory() {
        XCTAssertEqual(BandColorName.display("Acme X7", language: .zhHant), "Acme X7")
        XCTAssertNil(BandColorName.canonical("Acme X7"))
        let original = LoadValue.band(color: "淺綠", count: 2, raw: "original label")
        XCTAssertEqual(LoadSelectionDraft(load: original, suggested: .band(colors: [])).resolved(), original)
        var edit = LoadSelectionDraft(load: original, suggested: .band(colors: []))
        edit.bandCount = "3"
        XCTAssertEqual(edit.resolved(), .band(color: "light green", count: 3, raw: "light green x3"))
    }
}
