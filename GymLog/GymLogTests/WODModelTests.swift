import XCTest
import SwiftData
@testable import GymLogKit

/// 2026-09-07 M1: the new CrossFit WOD data model (`WorkoutQuantity`,
/// `WODPrescription`, `WODResult`, `WODPayload`) and its wiring into
/// `SessionBlock`/`TemplateBlock` (`sectionKind`, versioned JSON payload
/// columns). Covers: Codable round-trips, lightweight-migration-safe
/// defaults for pre-CrossFit data, and the "future/corrupt payload stays
/// opaque, never silently dropped or lossily rewritten" contract.
final class WODModelTests: XCTestCase {

    // MARK: - WorkoutQuantity

    func testWorkoutQuantityRoundTripsAllKinds() throws {
        let values: [WorkoutQuantity] = [
            .reps(12, raw: "12"), .seconds(45, raw: "45"), .meters(500, raw: "500m"),
            .machineCalories(20, raw: "20cal"), .unknown(raw: "??"),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for value in values {
            let data = try encoder.encode(value)
            let decoded = try decoder.decode(WorkoutQuantity.self, from: data)
            XCTAssertEqual(decoded, value)
        }
    }

    /// Same movement (Rowing), two different prescribed units -- they must
    /// stay distinct values, never compared/merged as if interchangeable
    /// (工程审阅 §5.1's "同一Rowing 500m與20cal，不同計量" acceptance case).
    func testSameNumericValueInDifferentUnitsAreNotEqual() {
        let asMeters = WorkoutQuantity.meters(20, raw: "20m")
        let asCalories = WorkoutQuantity.machineCalories(20, raw: "20cal")
        let asReps = WorkoutQuantity.reps(20, raw: "20")
        XCTAssertNotEqual(asMeters, asCalories)
        XCTAssertNotEqual(asMeters, asReps)
        XCTAssertNotEqual(asCalories, asReps)
    }

    // MARK: - WODPrescription / WODResult / WODPayload round trips

    private func samplePrescription() -> WODPrescription {
        WODPrescription(
            id: "wod-fran", revision: 1, name: "Fran",
            format: .forTime, timeCapSeconds: 720,
            rounds: [
                WODRoundPrescription(roundIndex: 0, movements: [
                    WODMovementPrescription(stepID: "step-thruster", exerciseID: "ex-thruster", exerciseNameSnapshot: "Thruster", quantity: .reps(21, raw: "21"), load: .absolute(kg: 43, raw: "43")),
                    WODMovementPrescription(stepID: "step-pullup", exerciseID: "ex-pullup", exerciseNameSnapshot: "Pull-up", quantity: .reps(21, raw: "21")),
                ]),
                WODRoundPrescription(roundIndex: 1, movements: [
                    WODMovementPrescription(stepID: "step-thruster", exerciseID: "ex-thruster", exerciseNameSnapshot: "Thruster", quantity: .reps(15, raw: "15"), load: .absolute(kg: 43, raw: "43")),
                    WODMovementPrescription(stepID: "step-pullup", exerciseID: "ex-pullup", exerciseNameSnapshot: "Pull-up", quantity: .reps(15, raw: "15")),
                ]),
                WODRoundPrescription(roundIndex: 2, movements: [
                    WODMovementPrescription(stepID: "step-thruster", exerciseID: "ex-thruster", exerciseNameSnapshot: "Thruster", quantity: .reps(9, raw: "9"), load: .absolute(kg: 43, raw: "43")),
                    WODMovementPrescription(stepID: "step-pullup", exerciseID: "ex-pullup", exerciseNameSnapshot: "Pull-up", quantity: .reps(9, raw: "9")),
                ]),
            ],
            scoringRule: .completionTime
        )
    }

    func testWODPrescriptionRoundTrips() throws {
        let prescription = samplePrescription()
        let data = try JSONEncoder().encode(prescription)
        let decoded = try JSONDecoder().decode(WODPrescription.self, from: data)
        XCTAssertEqual(decoded, prescription)
        XCTAssertEqual(decoded.rounds.count, 3, "21-15-9 must be three distinct rounds, not folded into one")
    }

    func testWODResultRoundTripsAMRAPProgress() throws {
        // "5 rounds + 12 reps" -- two integers, never a decimal.
        let result = WODResult(
            status: .completed, completedRounds: 5, partialRoundQuantity: .reps(12, raw: "12"),
            variant: .rx, recordedVia: .timer
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(WODResult.self, from: data)
        XCTAssertEqual(decoded, result)
        XCTAssertEqual(decoded.completedRounds, 5)
        guard case .reps(let partial, _) = decoded.partialRoundQuantity else { return XCTFail() }
        XCTAssertEqual(partial, 12, "must stay two integers (5 and 12), never collapse into 5.12")
    }

    func testWODResultCappedStatusPreservesProgressNotAFakeFinishTime() throws {
        let result = WODResult(status: .capped, elapsedSeconds: nil, cappedAtStepID: "step-run", cappedProgress: .meters(200, raw: "200"))
        XCTAssertEqual(result.status, .capped)
        XCTAssertNil(result.elapsedSeconds, "a capped attempt must never carry a completion time")
        guard case .meters(let m, _) = result.cappedProgress else { return XCTFail() }
        XCTAssertEqual(m, 200)
    }

    func testWODPayloadRoundTrips() throws {
        let payload = WODPayload(prescription: samplePrescription(), result: WODResult(status: .notRecorded))
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(WODPayload.self, from: data)
        XCTAssertEqual(decoded, payload)
    }

    // MARK: - SessionBlock wiring

    func testSessionBlockDefaultsToStrengthSectionKind() {
        let block = SessionBlock(order: 0, blockType: .single, sourceRow: 0)
        XCTAssertEqual(block.sectionKind, .strength, "every block built through the pre-CrossFit initializer signature must default to .strength")
        XCTAssertNil(block.wodPayload)
        XCTAssertNil(block.wodPayloadRawJSON)
        XCTAssertFalse(block.hasUnsupportedWODPayload)
    }

    func testSessionBlockWODPayloadRoundTrips() {
        let block = SessionBlock(order: 0, blockType: .single, sourceRow: 0, sectionKind: .wod)
        let payload = WODPayload(prescription: samplePrescription(), result: WODResult(status: .completed, elapsedSeconds: 512))
        block.wodPayload = payload
        XCTAssertEqual(block.sectionKind, .wod)
        XCTAssertEqual(block.wodPayload, payload)
        XCTAssertNotNil(block.wodPayloadRawJSON)
    }

    /// A payload from a FUTURE app version (higher `schemaVersion` than
    /// this build's `WODPayload.currentSchemaVersion`) must be preserved
    /// verbatim, not decoded/silently nulled/lossily rewritten.
    func testSessionBlockPreservesUnsupportedFutureWODPayloadVerbatim() {
        let block = SessionBlock(order: 0, blockType: .single, sourceRow: 0, sectionKind: .wod)
        let futureJSON = #"{"schemaVersion":999,"prescription":{"someFutureField":"x"},"result":{}}"#
        block.setWODPayloadRawJSON(futureJSON)

        XCTAssertNil(block.wodPayload, "a payload from a newer schema version must not be force-decoded")
        XCTAssertTrue(block.hasUnsupportedWODPayload)
        XCTAssertEqual(block.wodPayloadRawJSON, futureJSON, "the raw bytes must survive completely untouched")
    }

    func testSessionBlockCorruptPayloadIsAlsoTreatedAsUnsupportedNotCrash() {
        let block = SessionBlock(order: 0, blockType: .single, sourceRow: 0, sectionKind: .wod)
        block.setWODPayloadRawJSON("{not valid json")
        XCTAssertNil(block.wodPayload)
        XCTAssertTrue(block.hasUnsupportedWODPayload)
    }

    func testSettingWODPayloadToNilClearsIt() {
        let block = SessionBlock(order: 0, blockType: .single, sourceRow: 0, sectionKind: .wod)
        block.wodPayload = WODPayload(prescription: samplePrescription(), result: WODResult())
        block.wodPayload = nil
        XCTAssertNil(block.wodPayloadRawJSON)
    }

    // MARK: - TemplateBlock wiring (prescription only, never a result)

    func testTemplateBlockWODPrescriptionRoundTrips() {
        let block = TemplateBlock(id: "tb-wod-1", order: 0, blockType: .single, restSeconds: 0, sectionKind: .wod)
        let prescription = samplePrescription()
        block.wodPrescription = prescription
        XCTAssertEqual(block.sectionKind, .wod)
        XCTAssertEqual(block.wodPrescription, prescription)
    }

    func testTemplateBlockPreservesUnsupportedFuturePrescriptionVerbatim() {
        let block = TemplateBlock(id: "tb-wod-2", order: 0, blockType: .single, restSeconds: 0, sectionKind: .wod)
        let futureJSON = #"{"schemaVersion":999,"someFutureField":"x"}"#
        block.setWODPrescriptionRawJSON(futureJSON)
        XCTAssertNil(block.wodPrescription)
        XCTAssertTrue(block.hasUnsupportedWODPrescription)
        XCTAssertEqual(block.wodPrescriptionRawJSON, futureJSON)
    }

    // MARK: - Real SwiftData round trip (in-memory container)

    func testSessionBlockWODPayloadSurvivesModelContextSaveAndRefetch() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = Client(id: "cl-wod", name: "WOD Client")
        context.insert(client)
        let session = WorkoutSession(id: "se-wod", date: Date(), dateOrigin: .asRecorded, dateRaw: "raw", weekNumber: 1, sourceSheet: "App", sourceRow: 0)
        session.client = client
        context.insert(session)
        let block = SessionBlock(order: 0, blockType: .single, sourceRow: 0, sectionKind: .wod)
        block.session = session
        block.wodPayload = WODPayload(prescription: samplePrescription(), result: WODResult(status: .completed, elapsedSeconds: 512))
        context.insert(block)
        try context.save()

        let refetchedSession = try XCTUnwrap(context.fetch(FetchDescriptor<WorkoutSession>()).first)
        let refetchedBlock = try XCTUnwrap(refetchedSession.orderedBlocks.first)
        XCTAssertEqual(refetchedBlock.sectionKind, .wod)
        XCTAssertEqual(refetchedBlock.wodPayload?.result.elapsedSeconds, 512)
        XCTAssertEqual(refetchedBlock.wodPayload?.prescription.name, "Fran")
    }

    /// The lightweight-migration-safety claim this whole design rests on:
    /// a block built with NO section-kind knowledge at all (the exact call
    /// shape every pre-CrossFit call site in this codebase still uses) must
    /// read back as `.strength` with no WOD payload after a real
    /// save/refetch round trip, not just as a freshly-constructed object.
    func testPreCrossFitBlockConstructionRoundTripsAsStrengthWithNoWODData() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let client = Client(id: "cl-legacy", name: "Legacy Client")
        context.insert(client)
        let session = WorkoutSession(id: "se-legacy", date: Date(), dateOrigin: .asRecorded, dateRaw: "raw", weekNumber: 1, sourceSheet: "App", sourceRow: 0)
        session.client = client
        context.insert(session)
        let block = SessionBlock(order: 0, blockType: .single, restSeconds: 90, sourceRow: 0)
        block.session = session
        context.insert(block)
        try context.save()

        let refetched = try XCTUnwrap(context.fetch(FetchDescriptor<WorkoutSession>()).first?.orderedBlocks.first)
        XCTAssertEqual(refetched.sectionKind, .strength)
        XCTAssertNil(refetched.wodPayload)
        XCTAssertFalse(refetched.hasUnsupportedWODPayload)
    }
}
