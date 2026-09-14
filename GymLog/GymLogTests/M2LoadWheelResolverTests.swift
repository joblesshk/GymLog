import XCTest
import SwiftData
@testable import GymLogKit

/// CONTRACT-UI.md §3.3: which 重量 wheel content a given exercise resolves
/// to, and the "数值越小越强" hint's precondition (`loadDirection ==
/// .lowerIsStronger`).
final class M2LoadWheelResolverTests: XCTestCase {

    private func makeExercise(equipment: Equipment, loadDirection: LoadDirection = .higherIsStronger, isUnilateral: Bool = false) -> Exercise {
        Exercise(id: "ex-1", canonicalName: "Test", aliases: [], movementPattern: .push, equipment: equipment, loadDirection: loadDirection, isUnilateral: isUnilateral, occurrenceCount: 1, needsReview: false, reviewReason: nil)
    }

    func testAssistedTakesPriorityRegardlessOfEquipment() {
        let ex = makeExercise(equipment: .other, loadDirection: .lowerIsStronger)
        XCTAssertEqual(LoadWheelResolver.kind(for: ex, historicalBandColors: []), .assisted)
    }

    func testBodyweightDefaultsToAdjustableBodyweightPlusWheel() {
        let ex = makeExercise(equipment: .bodyweight)
        XCTAssertEqual(LoadWheelResolver.kind(for: ex, historicalBandColors: []), .bodyweightPlus)
    }

    func testBandUsesHistoricalColorsWhenAvailable() {
        let ex = makeExercise(equipment: .band)
        XCTAssertEqual(LoadWheelResolver.kind(for: ex, historicalBandColors: ["purple", "green"]), .band(colors: ["purple", "green"]))
    }

    func testBandFallsBackToDefaultColorsWhenNoHistory() {
        let ex = makeExercise(equipment: .band)
        XCTAssertEqual(LoadWheelResolver.kind(for: ex, historicalBandColors: []), .band(colors: LoadWheelResolver.fallbackBandColors))
    }

    func testUnilateralNonBandUsesPerSide() {
        let ex = makeExercise(equipment: .machine, isUnilateral: true)
        XCTAssertEqual(LoadWheelResolver.kind(for: ex, historicalBandColors: []), .perSide)
    }

    func testDefaultIsAbsolute() {
        let ex = makeExercise(equipment: .barbell)
        XCTAssertEqual(LoadWheelResolver.kind(for: ex, historicalBandColors: []), .absolute)
    }

    func testHistoricalBandColorsRanksByFrequency() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = Client(id: "cl-1", name: "Test")
        context.insert(client)
        let ex = makeExercise(equipment: .band)
        context.insert(ex)

        let session = WorkoutSession(id: "se-1", date: Date(), dateOrigin: .asRecorded, dateRaw: "", weekNumber: 1, sourceSheet: "test", sourceRow: 0)
        session.client = client
        context.insert(session)
        let block = SessionBlock(order: 0, blockType: .single, sourceRow: 0)
        block.session = session
        context.insert(block)
        let entry = ExerciseEntry(order: 0, exerciseIdRef: ex.id, exerciseRaw: "Test", plannedSets: 3, exercise: ex)
        entry.block = block
        context.insert(entry)

        let colors = ["purple", "purple", "green"]
        for (i, color) in colors.enumerated() {
            let set = SetLog(setIndex: i, load: .band(color: color, count: 1, raw: color), target: .fixed(value: 10, raw: "10"), actual: .fixed(value: 10, raw: "10"), isInferred: true)
            set.entry = entry
            context.insert(set)
        }
        try context.save()

        let ranked = LoadWheelResolver.historicalBandColors(forExerciseID: ex.id, in: context)
        XCTAssertEqual(ranked.first, "purple", "purple appears twice and must rank first")
        XCTAssertEqual(Set(ranked), Set(["purple", "green"]))
    }
}
