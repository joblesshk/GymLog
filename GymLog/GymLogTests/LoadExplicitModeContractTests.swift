import XCTest
@testable import GymLogKit

/// The explicit-mode raw prefix ("absolute: 45 lb") is what keeps an added
/// weight on an assisted exercise from being read as assistance. Every channel
/// that stores or transfers a `LoadValue` must carry it verbatim.
@MainActor
final class LoadExplicitModeContractTests: XCTestCase {
    private func explicitAddedLoad() throws -> LoadValue {
        var draft = LoadSelectionDraft(load: .assisted(kg: 20, raw: "20"), suggested: .assisted)
        draft.mode = .absolute; draft.number = "10"; draft.unit = .lb
        return try XCTUnwrap(draft.resolved())
    }

    private func assertStillExplicit(_ load: LoadValue, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(load.hasExplicitLoadMode, file: file, line: line)
        XCTAssertNil(AnalyticsMath.comparableKg(load, direction: .lowerIsStronger), "added weight must not join an assistance PR series", file: file, line: line)
        XCTAssertEqual(load.weightUnit, .lb, file: file, line: line)
    }

    func testExplicitModeSurvivesBackupExchangeAndDraftSnapshots() throws {
        let load = try explicitAddedLoad()
        XCTAssertEqual(load.raw, "absolute: 10 lb")
        let reps = RepTarget.fixed(value: 8, raw: "8")

        let backup = SetLogBackupDTO(setIndex: 0, load: load, target: reps, actual: reps, isInferred: false)
        assertStillExplicit(try JSONDecoder().decode(SetLogBackupDTO.self, from: JSONEncoder().encode(backup)).load)

        let exchange = ExchangeSetDTO(setIndex: 0, load: load, target: reps, actual: reps)
        assertStillExplicit(try JSONDecoder().decode(ExchangeSetDTO.self, from: JSONEncoder().encode(exchange)).load)

        let round = RoundDraft(setsCount: 1, load: load, target: reps, actual: reps)
        assertStillExplicit(try JSONDecoder().decode(RoundDraftSnapshot.self, from: JSONEncoder().encode(round.snapshot())).load)
    }

    func testLegacyNumericQuickEditKeepsExplicitPrefix() throws {
        let absolute = SetLog(setIndex: 0, load: .absolute(kg: 5, raw: "absolute: 5 kg"), target: .fixed(value: 8, raw: "8"), actual: .fixed(value: 8, raw: "8"), isInferred: false)
        var draft = SetEditDraft(set: absolute)
        draft.kgText = "7.5"
        draft.apply(to: absolute)
        XCTAssertEqual(absolute.load, .absolute(kg: 7.5, raw: "absolute: 7.5 kg"))
    }

    func testImportedPinLoadsKeepTheirLabelButFreeDescriptionsDoNot() {
        XCTAssertEqual(LoadValue.pinLoad(desc: "10 red 5 blue", raw: "10 red 5 blue").displayText, L("插銷配重 10 red 5 blue", "Pin load 10 red 5 blue"))
        XCTAssertEqual(LoadValue.pinLoad(desc: "two bands plus 5 lb", raw: "two bands plus 5 lb").displayText, "two bands plus 5 lb")
        let parsed = ExcelValueParsers.parseLoadValue("10 red 5 blue", exerciseNameLower: "leg press")
        guard case .pinLoad = parsed.value else { return XCTFail("importer and display must share the pin-load pattern") }
    }

    func testNumberFormattingDropsFloatingPointNoise() {
        XCTAssertEqual(SetEditDraft.formatNumber(0.1 + 0.2), "0.3")
        XCTAssertEqual(SetEditDraft.formatNumber(45 * 0.45359237), "20.412")
        XCTAssertEqual(SetEditDraft.formatNumber(22.5), "22.5")
        XCTAssertEqual(SetEditDraft.formatNumber(100), "100")
        XCTAssertEqual(SetEditDraft.formatNumber(19.9996), "20")
        XCTAssertEqual(SetEditDraft.formatNumber(1234.567), "1234.567")
    }

    func testOutlierConfirmation() {
        var draft = LoadSelectionDraft(load: .absolute(kg: 50, raw: "50"), suggested: .absolute)
        draft.number = "60"; XCTAssertNil(draft.outlierConfirmation)
        draft.number = "150"; XCTAssertNotNil(draft.outlierConfirmation)
        var light = LoadSelectionDraft(load: .absolute(kg: 5, raw: "5"), suggested: .absolute)
        light.number = "12"; XCTAssertNil(light.outlierConfirmation, "doubling a light load is normal progression")
        var fresh = LoadSelectionDraft(load: .bodyweight(raw: "BW"), suggested: .bodyweightPlus)
        fresh.mode = .absolute
        fresh.number = "250"; XCTAssertNil(fresh.outlierConfirmation)
        fresh.number = "350"; XCTAssertNotNil(fresh.outlierConfirmation)
    }

    /// Draft recovery must be lossless: snapshot -> restore -> snapshot yields
    /// the same draft, including provenance the editor cannot display.
    func testDraftSnapshotRestoreSnapshotIsStable() throws {
        let squat = Exercise(id: "ex-squat", canonicalName: "Back Squat", aliases: [], movementPattern: .squat, equipment: .barbell,
                             loadDirection: .higherIsStronger, isUnilateral: false, occurrenceCount: 0, needsReview: false, reviewReason: nil)
        let chin = Exercise(id: "ex-chin", canonicalName: "Chin up w/band", aliases: [], movementPattern: .pull, equipment: .band,
                            loadDirection: .lowerIsStronger, isUnilateral: false, occurrenceCount: 0, needsReview: false, reviewReason: nil)
        let reps = RepTarget.fixed(value: 8, raw: "8")
        let first = EntryDraft(exercise: squat, rounds: [
            RoundDraft(setsCount: 2, load: .absolute(kg: 60, raw: "60"), target: .range(low: 8, high: 12, raw: "8-12"), actual: .unknown(raw: "stopped early"),
                       actualRecorded: false, isInferred: true, unrecordedActualRaw: "stopped early"),
            RoundDraft(setsCount: 1, load: try explicitAddedLoad(), target: reps, actual: reps)
        ])
        first.source = EntrySourceFields(exerciseID: squat.id, exerciseRaw: "BB squat (heavy)")
        let second = EntryDraft(exercise: chin, rounds: [
            RoundDraft(setsCount: 3, load: .band(color: "blue+orange", count: 2, raw: "blue+orange x2"), target: reps, actual: reps, actualRecorded: false)
        ])
        let block = BlockDraft(blockType: .single, restSeconds: 90, entries: [first])
        block.source = BlockSourceFields(note: "膝蓋不適", restRaw: "90s", restSeconds: 90, sourceRow: 12)

        let store = TodayDraftStore()
        store.clientID = "cl-1"; store.isActive = true; store.plannedDurationMinutes = nil
        store.persistedSessionID = "se-1"; store.openedFromHistory = true
        store.blocks = [block, BlockDraft(blockType: .superset, restSeconds: nil, entries: [second])]

        let original = try XCTUnwrap(store.snapshot())
        let decoded = try JSONDecoder().decode(TodayDraftSnapshot.self, from: JSONEncoder().encode(original))
        let restored = TodayDraftStore()
        let outcome = restored.restore(from: decoded, exercises: [squat, chin])
        XCTAssertEqual(outcome.droppedCount, 0)
        XCTAssertEqual(outcome.metricUncertainCount, 0)
        var again = try XCTUnwrap(restored.snapshot())
        again.savedAt = original.savedAt
        XCTAssertEqual(again, original)
    }
}
