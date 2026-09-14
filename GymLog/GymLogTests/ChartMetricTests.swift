import XCTest
@testable import GymLogKit

/// 时间/距离/轮次类动作趋势（2026-09-06 审查报告"适合当前范围的功能"第二批）：
/// which `ChartMetric`s are offered per `RecordingMetric`, and which one is
/// picked as the default, so a coach viewing a plank/rowing/carry never
/// lands on a permanently-empty "最大重量" chart by default and never sees
/// a picker option that can't possibly have data for that exercise type.
final class ChartMetricTests: XCTestCase {

    func testRepsExercise_onlyOffersWeightAndRepMetrics() {
        let relevant = ChartMetric.allCases.filter { $0.isRelevant(for: .reps) }
        XCTAssertEqual(Set(relevant), [.maxLoad, .estimated1RM, .volume, .completedReps])
    }

    func testTimeExercise_offersWeightMetricsAndDurationOnly() {
        let relevant = ChartMetric.allCases.filter { $0.isRelevant(for: .time) }
        XCTAssertEqual(Set(relevant), [.maxLoad, .estimated1RM, .volume, .completedDuration])
    }

    func testDistanceExercise_offersWeightMetricsAndDistanceOnly() {
        let relevant = ChartMetric.allCases.filter { $0.isRelevant(for: .distance) }
        XCTAssertEqual(Set(relevant), [.maxLoad, .estimated1RM, .volume, .completedDistance])
    }

    func testRoundsExercise_offersWeightMetricsAndRoundsOnly() {
        let relevant = ChartMetric.allCases.filter { $0.isRelevant(for: .rounds) }
        XCTAssertEqual(Set(relevant), [.maxLoad, .estimated1RM, .volume, .completedRounds])
    }

    func testUnknownRecordingMetric_fallsBackToRepsBehavior() {
        // A legacy/migrated exercise with no confirmed recordingMetric
        // (defaults to `.reps` at the model layer, but `.unknown` is the
        // classification enums' own generic fallback) must not lose access
        // to the reps metric it most likely needs.
        XCTAssertTrue(ChartMetric.completedReps.isRelevant(for: .unknown))
        XCTAssertFalse(ChartMetric.completedDuration.isRelevant(for: .unknown))
    }

    func testDefaultMetric_matchesEachRecordingMetric() {
        XCTAssertEqual(ChartMetric.defaultMetric(for: .reps), .maxLoad)
        XCTAssertEqual(ChartMetric.defaultMetric(for: .unknown), .maxLoad)
        XCTAssertEqual(ChartMetric.defaultMetric(for: .time), .completedDuration)
        XCTAssertEqual(ChartMetric.defaultMetric(for: .distance), .completedDistance)
        XCTAssertEqual(ChartMetric.defaultMetric(for: .rounds), .completedRounds)
    }

    func testDefaultMetric_isAlwaysAmongTheRelevantSetForThatType() {
        for recordingMetric in RecordingMetric.allCases {
            let d = ChartMetric.defaultMetric(for: recordingMetric)
            XCTAssertTrue(d.isRelevant(for: recordingMetric), "\(d) must be a relevant option for \(recordingMetric), or the picker's initial selection wouldn't even appear in its own list.")
        }
    }
}
