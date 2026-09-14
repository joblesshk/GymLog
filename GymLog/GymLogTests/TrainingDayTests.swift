import XCTest
@testable import GymLogKit

/// 2026-09-07 审阅 B07: UTC-midnight training days must decode back to a
/// local display date without drifting, in negative-offset (New York),
/// positive-offset (Hong Kong), and DST-transitioning time zones, and the
/// Gregorian y/m/d extraction must never be contaminated by a non-Gregorian
/// device calendar (Buddhist year 2569 for Gregorian 2026, etc).
final class TrainingDayTests: XCTestCase {
    private let hongKong = TimeZone(identifier: "Asia/Hong_Kong")!
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let utc = TimeZone(identifier: "UTC")!

    // MARK: - The exact regression the audit reproduced

    func testUTCMidnightDecodesToSameLocalDayInNewYorkEvening() {
        // Stored session.date: 2026-09-07T00:00:00Z. In New York (UTC-4 in
        // September, EDT) that instant is 2026-09-06 20:00 local -- the OLD
        // code (feeding the raw Date straight into a DatePicker) showed and
        // re-saved this as September 6th. The decoded display date must
        // read September 7th.
        let stored = isoInstant("2026-09-07T00:00:00Z")
        let day = TrainingDay.from(utcMidnight: stored)
        XCTAssertEqual(day, TrainingDay(year: 2026, month: 9, day: 7))

        let displayed = day.localDate(timeZone: newYork)
        let redecoded = TrainingDay.fromLocalWallClock(displayed, timeZone: newYork)
        XCTAssertEqual(redecoded, day, "round-tripping through the New York display date must not drift the day")
    }

    func testHongKongMorningRoundTrips() {
        let stored = isoInstant("2026-01-15T00:00:00Z")
        let day = TrainingDay.from(utcMidnight: stored)
        let displayed = day.localDate(timeZone: hongKong)
        XCTAssertEqual(TrainingDay.fromLocalWallClock(displayed, timeZone: hongKong), day)
    }

    // MARK: - Repeated open/save must never drift (no-op edit)

    func testRepeatedOpenAndSaveNeverDriftsInNewYork() {
        var current = TrainingDay(year: 2026, month: 3, day: 10).utcMidnight
        for _ in 0..<5 {
            let displayed = TrainingDay.from(utcMidnight: current).localDate(timeZone: newYork)
            current = TrainingDay.fromLocalWallClock(displayed, timeZone: newYork).utcMidnight
        }
        XCTAssertEqual(TrainingDay.from(utcMidnight: current), TrainingDay(year: 2026, month: 3, day: 10))
    }

    // MARK: - DST transitions

    func testSpringForwardDSTBoundaryInNewYork() {
        // 2026-03-08 is the US spring-forward date (2am -> 3am).
        let day = TrainingDay(year: 2026, month: 3, day: 8)
        let displayed = day.localDate(timeZone: newYork)
        XCTAssertEqual(TrainingDay.fromLocalWallClock(displayed, timeZone: newYork), day)
    }

    func testFallBackDSTBoundaryInNewYork() {
        // 2026-11-01 is the US fall-back date.
        let day = TrainingDay(year: 2026, month: 11, day: 1)
        let displayed = day.localDate(timeZone: newYork)
        XCTAssertEqual(TrainingDay.fromLocalWallClock(displayed, timeZone: newYork), day)
    }

    // MARK: - Cross month/year boundary

    func testYearBoundaryRoundTrips() {
        let day = TrainingDay(year: 2026, month: 12, day: 31)
        let displayed = day.localDate(timeZone: newYork)
        XCTAssertEqual(TrainingDay.fromLocalWallClock(displayed, timeZone: newYork), day)

        let dayAfter = TrainingDay(year: 2027, month: 1, day: 1)
        let displayedAfter = dayAfter.localDate(timeZone: hongKong)
        XCTAssertEqual(TrainingDay.fromLocalWallClock(displayedAfter, timeZone: hongKong), dayAfter)
    }

    // MARK: - Non-Gregorian device calendar must not contaminate extraction

    func testFromLocalWallClockIgnoresNonGregorianCurrentCalendarPreference() {
        // Regardless of what calendar `Calendar.current` prefers to DISPLAY
        // in, `fromLocalWallClock` must always extract Gregorian y/m/d.
        // Simulate by comparing against components extracted with an
        // explicit Buddhist calendar over the same instant/time zone --
        // the two must disagree (proving the Buddhist path would have been
        // wrong), while `fromLocalWallClock` must match the Gregorian one.
        let instant = TrainingDay(year: 2026, month: 9, day: 7).localDate(timeZone: hongKong)

        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = hongKong
        let buddhistComponents = buddhist.dateComponents([.year, .month, .day], from: instant)
        XCTAssertNotEqual(buddhistComponents.year, 2026, "sanity check: Buddhist year must differ from Gregorian for this to be a meaningful test")

        let extracted = TrainingDay.fromLocalWallClock(instant, timeZone: hongKong)
        XCTAssertEqual(extracted, TrainingDay(year: 2026, month: 9, day: 7))
    }

    func testUtcMidnightExtractionIsAlwaysGregorianRegardlessOfCalendarUsedToBuildTheInstant() {
        // A UTC-midnight instant built directly (not through TrainingDay)
        // must still decode to the expected Gregorian y/m/d via `from`.
        let stored = isoInstant("2026-06-15T00:00:00Z")
        XCTAssertEqual(TrainingDay.from(utcMidnight: stored), TrainingDay(year: 2026, month: 6, day: 15))
    }

    // MARK: - Comparable

    func testComparable() {
        XCTAssertLessThan(TrainingDay(year: 2026, month: 1, day: 1), TrainingDay(year: 2026, month: 1, day: 2))
        XCTAssertLessThan(TrainingDay(year: 2025, month: 12, day: 31), TrainingDay(year: 2026, month: 1, day: 1))
    }

    // MARK: - Helpers

    private func isoInstant(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)!
    }
}
