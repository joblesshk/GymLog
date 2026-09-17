import XCTest
@testable import GymLogKit

final class BodyMetricTrendSeriesTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }

    private func metric(
        _ id: String,
        day: Int,
        hour: Int = 0,
        weight: Double? = nil,
        fat: Double? = nil,
        muscle: Double? = nil
    ) -> BodyMetric {
        BodyMetric(
            id: id,
            date: date(day, hour: hour),
            weightKg: weight,
            bodyFatPercent: fat,
            skeletalMuscleKg: muscle
        )
    }

    func testUnorderedEightRecordsSelectsLatestSixAndIndexesAscending() {
        let records = [
            metric("d", day: 4), metric("h", day: 8), metric("b", day: 2),
            metric("f", day: 6), metric("a", day: 1), metric("g", day: 7),
            metric("c", day: 3), metric("e", day: 5)
        ]

        let points = BodyMetricTrendSeries.points(from: records)

        XCTAssertEqual(points.map(\.id), ["c", "d", "e", "f", "g", "h"])
        XCTAssertEqual(points.map(\.index), Array(0..<6))
        XCTAssertEqual(points.map(\.date), (3...8).map { date($0) })
    }

    func testUnevenDatesAndSameDayRecordsUseOneDiscreteIndexAxis() {
        let records = [
            metric("later", day: 20),
            metric("same-day-b", day: 10, hour: 12),
            metric("same-day-a", day: 10, hour: 8),
            metric("early", day: 1)
        ]

        let points = BodyMetricTrendSeries.points(from: records)

        XCTAssertEqual(points.map(\.id), ["early", "same-day-a", "same-day-b", "later"])
        XCTAssertEqual(points.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(points.map(\.date), [date(1), date(10, hour: 8), date(10, hour: 12), date(20)])
    }

    func testNilValueDoesNotPullOlderRecordIntoLatestSixWindow() {
        let records = [
            metric("old", day: 1, fat: 18),
            metric("two", day: 2, fat: 19),
            metric("three", day: 3),
            metric("four", day: 4, fat: 20),
            metric("five", day: 5),
            metric("six", day: 6, fat: 21),
            metric("seven", day: 7, fat: 22)
        ]

        let points = BodyMetricTrendSeries.points(from: records)

        XCTAssertEqual(points.map(\.id), ["two", "three", "four", "five", "six", "seven"])
        XCTAssertEqual(points.map(\.bodyFatPercent), [19, nil, 20, nil, 21, 22])
        XCTAssertFalse(points.contains { $0.id == "old" })
    }

    func testZeroOneAndTwoRecordsKeepExpectedSlots() {
        XCTAssertTrue(BodyMetricTrendSeries.points(from: []).isEmpty)

        let one = BodyMetricTrendSeries.points(from: [metric("one", day: 1, weight: 70)])
        XCTAssertEqual(one.map(\.index), [0])
        XCTAssertEqual(one.map(\.weightKg), [70])

        let two = BodyMetricTrendSeries.points(from: [metric("two", day: 20), metric("one", day: 1)])
        XCTAssertEqual(two.map(\.index), [0, 1])
        XCTAssertEqual(two.map(\.id), ["one", "two"])
    }

    func testSameValuesRemainPresentAtDistinctIndices() {
        let points = BodyMetricTrendSeries.points(from: [
            metric("b", day: 2, weight: 70, fat: 20, muscle: 30),
            metric("a", day: 1, weight: 70, fat: 20, muscle: 30),
            metric("c", day: 3, weight: 70, fat: 20, muscle: 30)
        ])

        XCTAssertEqual(points.map(\.index), [0, 1, 2])
        XCTAssertEqual(points.map(\.weightKg), [70, 70, 70])
        XCTAssertEqual(points.map(\.bodyFatPercent), [20, 20, 20])
        XCTAssertEqual(points.map(\.skeletalMuscleKg), [30, 30, 30])
    }
}
