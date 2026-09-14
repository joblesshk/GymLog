import XCTest
@testable import GymLogKit

/// Pure-function tests for `AnalyticsMath` (CONTRACT-UI.md §4.2). No
/// SwiftData involved — every branch of rules ①–④ is directly reachable
/// here. These are the tests that MUST fail if the `.lowerIsStronger`
/// inversion (rule ①) is ever dropped or the 1RM/volume/perSide guards are
/// loosened.
final class M3AnalyticsMathTests: XCTestCase {

    // MARK: - Rule ① — direction inversion (the single most important test in this file)

    func testIsImprovement_higherIsStronger_biggerWins() {
        XCTAssertTrue(AnalyticsMath.isImprovement(candidate: 60, overBest: 55, direction: .higherIsStronger))
        XCTAssertFalse(AnalyticsMath.isImprovement(candidate: 50, overBest: 55, direction: .higherIsStronger))
    }

    /// The critical inversion test: for an assisted-style exercise, a LOWER
    /// number is the improvement. If someone "fixes" `isImprovement` to
    /// always mean "bigger is better", this assertion flips and fails.
    func testIsImprovement_lowerIsStronger_smallerWins() {
        XCTAssertTrue(AnalyticsMath.isImprovement(candidate: 30, overBest: 50, direction: .lowerIsStronger),
                      "Chin up w/assist: 30kg assist after 50kg assist MUST read as improvement.")
        XCTAssertFalse(AnalyticsMath.isImprovement(candidate: 50, overBest: 30, direction: .lowerIsStronger),
                       "Going from 30kg assist back up to 50kg assist MUST NOT read as improvement.")
    }

    func testIsImprovement_equalIsNeverAnImprovement() {
        // "同值不算破纪录" — rule ⑤.
        XCTAssertFalse(AnalyticsMath.isImprovement(candidate: 55, overBest: 55, direction: .higherIsStronger))
        XCTAssertFalse(AnalyticsMath.isImprovement(candidate: 30, overBest: 30, direction: .lowerIsStronger))
    }

    func testBetterValue_higherIsStronger_picksMax() {
        XCTAssertEqual(AnalyticsMath.betterValue(40, 55, direction: .higherIsStronger), 55)
    }

    /// PR must be the MINIMUM assist weight, not the maximum — the direct
    /// consequence of rule ① that rule ⑤ depends on.
    func testBetterValue_lowerIsStronger_picksMin() {
        XCTAssertEqual(AnalyticsMath.betterValue(50, 30, direction: .lowerIsStronger), 30)
        XCTAssertEqual(AnalyticsMath.betterValue(30, 50, direction: .lowerIsStronger), 30)
    }

    // MARK: - Rule ② — estimated 1RM eligibility

    func testEstimatedOneRepMax_eligible_absoluteFixedInRange() throws {
        // Epley: 55 * (1 + 3/30) = 60.5
        let value = try XCTUnwrap(AnalyticsMath.estimatedOneRepMax(
            load: .absolute(kg: 55, raw: "55"),
            actual: .fixed(value: 3, raw: "3")
        ))
        XCTAssertEqual(value, 60.5, accuracy: 0.0001)
    }

    func testEstimatedOneRepMax_boundaryReps_1And12Included() {
        XCTAssertNotNil(AnalyticsMath.estimatedOneRepMax(load: .absolute(kg: 40, raw: "40"), actual: .fixed(value: 1, raw: "1")))
        XCTAssertNotNil(AnalyticsMath.estimatedOneRepMax(load: .absolute(kg: 40, raw: "40"), actual: .fixed(value: 12, raw: "12")))
    }

    func testEstimatedOneRepMax_boundaryReps_13ExcludedAnd0Excluded() {
        XCTAssertNil(AnalyticsMath.estimatedOneRepMax(load: .absolute(kg: 40, raw: "40"), actual: .fixed(value: 13, raw: "13")))
        XCTAssertNil(AnalyticsMath.estimatedOneRepMax(load: .absolute(kg: 40, raw: "40"), actual: .fixed(value: 0, raw: "0")))
    }

    func testEstimatedOneRepMax_refused_rangeActual_neverMidpointSubstituted() {
        // Rule ②: "不要用区间中值...顶替 actual". A range actual must refuse,
        // never silently use its midpoint as if it were a fixed rep count.
        XCTAssertNil(AnalyticsMath.estimatedOneRepMax(load: .absolute(kg: 55, raw: "55"), actual: .range(low: 8, high: 12, raw: "8-12")))
    }

    func testEstimatedOneRepMax_refused_forEveryNonAbsoluteLoadKind() {
        let actual = RepTarget.fixed(value: 8, raw: "8")
        XCTAssertNil(AnalyticsMath.estimatedOneRepMax(load: .perSide(kg: 15, raw: "15each"), actual: actual))
        XCTAssertNil(AnalyticsMath.estimatedOneRepMax(load: .bodyweight(raw: "bw"), actual: actual))
        XCTAssertNil(AnalyticsMath.estimatedOneRepMax(load: .assisted(kg: 30, raw: "30"), actual: actual))
        XCTAssertNil(AnalyticsMath.estimatedOneRepMax(load: .band(color: "purple", count: 1, raw: "Purple"), actual: actual))
        XCTAssertNil(AnalyticsMath.estimatedOneRepMax(load: .machineStack(level: "Rack 12", raw: "Rack 12"), actual: actual))
        XCTAssertNil(AnalyticsMath.estimatedOneRepMax(load: .pinLoad(desc: "1red1green", raw: "1red1green"), actual: actual))
        XCTAssertNil(AnalyticsMath.estimatedOneRepMax(load: .sled(kg: 40, raw: "40"), actual: actual))
        XCTAssertNil(AnalyticsMath.estimatedOneRepMax(load: .unknown(raw: ""), actual: actual))
    }

    func testEstimatedOneRepMax_refused_forNonFixedActualKinds() {
        let load = LoadValue.absolute(kg: 55, raw: "55")
        XCTAssertNil(AnalyticsMath.estimatedOneRepMax(load: load, actual: .time(seconds: 30, raw: "30s")))
        XCTAssertNil(AnalyticsMath.estimatedOneRepMax(load: load, actual: .distance(meters: 500, raw: "500m")))
        XCTAssertNil(AnalyticsMath.estimatedOneRepMax(load: load, actual: .rounds(count: 3, raw: "3round")))
        XCTAssertNil(AnalyticsMath.estimatedOneRepMax(load: load, actual: .perSide(left: 10, right: 10, raw: "10,10")))
        XCTAssertNil(AnalyticsMath.estimatedOneRepMax(load: load, actual: .unknown(raw: "")))
    }

    // MARK: - Rule ③ — comparableKg never doubles `.perSide`

    func testComparableKg_perSide_isNotDoubled() {
        // "Leg extension SL 15kg" style dumbbell-per-side load: comparable
        // figure must be 15, never 30.
        XCTAssertEqual(AnalyticsMath.comparableKg(.perSide(kg: 15, raw: "15each")), 15)
    }

    func testComparableKg_absolute_assisted_sled_areComparable() {
        XCTAssertEqual(AnalyticsMath.comparableKg(.absolute(kg: 55, raw: "55")), 55)
        XCTAssertEqual(AnalyticsMath.comparableKg(.assisted(kg: 30, raw: "30")), 30)
        XCTAssertEqual(AnalyticsMath.comparableKg(.sled(kg: 40, raw: "40")), 40)
    }

    func testComparableKg_nonNumericKinds_returnNil() {
        XCTAssertNil(AnalyticsMath.comparableKg(.bodyweight(raw: "bw")))
        XCTAssertNil(AnalyticsMath.comparableKg(.band(color: "purple", count: 1, raw: "Purple")))
        XCTAssertNil(AnalyticsMath.comparableKg(.machineStack(level: "Rack 12", raw: "Rack 12")))
        XCTAssertNil(AnalyticsMath.comparableKg(.pinLoad(desc: "1red1green", raw: "1red1green")))
        XCTAssertNil(AnalyticsMath.comparableKg(.unknown(raw: "")))
    }

    // MARK: - Rule ④ — volume, per-branch table (as amended)

    func testVolume_absoluteFixed() {
        XCTAssertEqual(AnalyticsMath.setVolume(load: .absolute(kg: 35, raw: "35"), actual: .fixed(value: 10, raw: "10")), 350)
    }

    func testVolume_absoluteRange_usesMidpointAndFlagsEstimated() {
        let load = LoadValue.absolute(kg: 20, raw: "20")
        let actual = RepTarget.range(low: 8, high: 12, raw: "8-12")
        XCTAssertEqual(AnalyticsMath.setVolume(load: load, actual: actual), 200) // 20 * 10 (midpoint)
        XCTAssertTrue(AnalyticsMath.isVolumeEstimated(load: load, actual: actual))
    }

    /// The corrected branch (post-review): absolute pin-loaded machine,
    /// reps counted per leg (`Leg extension SL`-style). ~194 real SetLogs.
    func testVolume_absoluteLoad_perSideActual_countsBothSides() {
        let load = LoadValue.absolute(kg: 15, raw: "15")
        let actual = RepTarget.perSide(left: 10, right: 10, raw: "10,10")
        XCTAssertEqual(AnalyticsMath.setVolume(load: load, actual: actual), 300) // 15 * (10+10)
        XCTAssertFalse(AnalyticsMath.isVolumeEstimated(load: load, actual: actual))
    }

    func testVolume_perSideLoad_perSideActual() {
        let load = LoadValue.perSide(kg: 12, raw: "12each")
        let actual = RepTarget.perSide(left: 8, right: 10, raw: "8,10")
        XCTAssertEqual(AnalyticsMath.setVolume(load: load, actual: actual), 216) // 12 * (8+10)
    }

    func testVolume_excludedLoadKinds_returnNilNotZero() {
        let actual = RepTarget.fixed(value: 10, raw: "10")
        for load: LoadValue in [
            .bodyweight(raw: "bw"),
            .band(color: "purple", count: 1, raw: "Purple"),
            .machineStack(level: "Machine", raw: "Machine"),
            .pinLoad(desc: "1red1green", raw: "1red1green"),
            .unknown(raw: "/"),
        ] {
            XCTAssertNil(AnalyticsMath.setVolume(load: load, actual: actual), "\(load) must not contribute to volume")
        }
    }

    func testVolume_excludedActualKinds_returnNil() {
        let load = LoadValue.absolute(kg: 20, raw: "20")
        for actual: RepTarget in [
            .time(seconds: 30, raw: "30s"),
            .distance(meters: 500, raw: "500m"),
            .rounds(count: 3, raw: "3round"),
            .unknown(raw: ""),
        ] {
            XCTAssertNil(AnalyticsMath.setVolume(load: load, actual: actual), "\(actual) must not contribute to volume")
        }
    }

    func testVolume_ambiguousPerSideLoadFixedActual_isExcludedNotGuessed() {
        // perSide LOAD with a plain fixed rep count is ambiguous (is the
        // fixed count total or per-side?) -- must be excluded, not guessed.
        XCTAssertNil(AnalyticsMath.setVolume(load: .perSide(kg: 12, raw: "12each"), actual: .fixed(value: 10, raw: "10")))
    }

    // MARK: - Completed-reps metric

    func testSetReps_fixedAndPerSideAndRangeMidpoint() {
        XCTAssertEqual(AnalyticsMath.setReps(actual: .fixed(value: 8, raw: "8")), 8)
        XCTAssertEqual(AnalyticsMath.setReps(actual: .perSide(left: 10, right: 12, raw: "10,12")), 22)
        XCTAssertEqual(AnalyticsMath.setReps(actual: .range(low: 8, high: 12, raw: "8-12")), 10)
        XCTAssertTrue(AnalyticsMath.isRepsEstimated(actual: .range(low: 8, high: 12, raw: "8-12")))
        XCTAssertFalse(AnalyticsMath.isRepsEstimated(actual: .fixed(value: 8, raw: "8")))
    }

    func testSetReps_excludedKinds() {
        XCTAssertNil(AnalyticsMath.setReps(actual: .time(seconds: 30, raw: "30s")))
        XCTAssertNil(AnalyticsMath.setReps(actual: .distance(meters: 500, raw: "500m")))
        XCTAssertNil(AnalyticsMath.setReps(actual: .rounds(count: 3, raw: "3round")))
        XCTAssertNil(AnalyticsMath.setReps(actual: .unknown(raw: "")))
    }

    // MARK: - Time/distance/rounds metrics (2026-09-06 审查报告"适合当前范围的
    // 功能"第二批)

    func testSetDurationSeconds_onlyExtractsFromTimeActual() {
        XCTAssertEqual(AnalyticsMath.setDurationSeconds(actual: .time(seconds: 45, raw: "45s")), 45)
        XCTAssertNil(AnalyticsMath.setDurationSeconds(actual: .fixed(value: 8, raw: "8")))
        XCTAssertNil(AnalyticsMath.setDurationSeconds(actual: .distance(meters: 500, raw: "500m")))
        XCTAssertNil(AnalyticsMath.setDurationSeconds(actual: .rounds(count: 3, raw: "3round")))
    }

    func testSetDistanceMeters_onlyExtractsFromDistanceActual() {
        XCTAssertEqual(AnalyticsMath.setDistanceMeters(actual: .distance(meters: 500, raw: "500m")), 500)
        XCTAssertNil(AnalyticsMath.setDistanceMeters(actual: .time(seconds: 45, raw: "45s")))
        XCTAssertNil(AnalyticsMath.setDistanceMeters(actual: .fixed(value: 8, raw: "8")))
        XCTAssertNil(AnalyticsMath.setDistanceMeters(actual: .rounds(count: 3, raw: "3round")))
    }

    func testSetRoundsCount_onlyExtractsFromRoundsActual() {
        XCTAssertEqual(AnalyticsMath.setRoundsCount(actual: .rounds(count: 5, raw: "5round")), 5)
        XCTAssertNil(AnalyticsMath.setRoundsCount(actual: .time(seconds: 45, raw: "45s")))
        XCTAssertNil(AnalyticsMath.setRoundsCount(actual: .distance(meters: 500, raw: "500m")))
        XCTAssertNil(AnalyticsMath.setRoundsCount(actual: .fixed(value: 8, raw: "8")))
    }
}
