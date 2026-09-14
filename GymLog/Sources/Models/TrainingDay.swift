import Foundation

/// A calendar-agnostic Gregorian (year, month, day) triple — the wire format
/// this app has always used for a training day: every `WorkoutSession.date`
/// is UTC midnight of some Gregorian y/m/d, regardless of where the coach
/// physically is or what calendar system their device is set to display.
///
/// 2026-09-07 审阅 B07: the previous single-direction `TrainingDayEncoding
/// .utcDay(from:)` had two independent bugs, both fixed by routing every
/// conversion through this type instead of ad hoc `Calendar.current` calls:
///
/// 1. No inverse. Every call site that needed to show an already-encoded
///    `session.date` back in a `DatePicker` (editing a past session's date,
///    re-opening a date-range filter) fed the raw UTC-midnight `Date`
///    straight into the picker. A `DatePicker` renders a `Date` in the
///    viewer's OWN time zone, so west of UTC in the evening (or east of UTC
///    before dawn) that UTC-midnight instant displays as the PREVIOUS local
///    day — and saving without touching anything then re-encodes that
///    shifted day, permanently losing a day. `from(utcMidnight:)` /
///    `localDate(timeZone:)` below round-trip correctly instead.
/// 2. `Calendar.current` is the user's PREFERRED calendar, not necessarily
///    Gregorian (Buddhist/Japanese/Islamic calendars are all valid iOS
///    Region settings). Extracting y/m/d with a non-Gregorian calendar and
///    then feeding those digits into a Gregorian UTC calendar — as the old
///    code did — silently reinterprets e.g. Buddhist year 2569 as if it
///    were Gregorian, producing a date centuries off. `fromLocalWallClock`
///    below always forces Gregorian for the extraction, independent of the
///    device's display-calendar preference.
public struct TrainingDay: Codable, Equatable, Hashable, Comparable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    private static func utcGregorianCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Decodes a persisted `session.date` (always UTC midnight of some
    /// Gregorian y/m/d) back into its (y, m, d). Always reads with an
    /// explicit Gregorian-UTC calendar, never `Calendar.current`/
    /// `TimeZone.current` — this must be the exact inverse of
    /// `utcMidnight` no matter the viewer's own settings.
    public static func from(utcMidnight date: Date) -> TrainingDay {
        let components = utcGregorianCalendar().dateComponents([.year, .month, .day], from: date)
        return TrainingDay(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
    }

    /// The persisted `session.date` representation: this y/m/d at UTC
    /// midnight, in the Gregorian calendar.
    public var utcMidnight: Date {
        Self.utcGregorianCalendar().date(from: DateComponents(year: year, month: month, day: day))
            ?? Date(timeIntervalSince1970: 0)
    }

    /// Extracts this y/m/d from a freshly-picked `Date` (e.g. straight out
    /// of a `DatePicker`, or `Date()`/"now") using the LOCAL wall clock,
    /// always in the Gregorian calendar — see the type doc comment's point
    /// 2 for why this must not be `Calendar.current`.
    public static func fromLocalWallClock(_ date: Date, timeZone: TimeZone = .current) -> TrainingDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return TrainingDay(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
    }

    /// A `Date` a `DatePicker` can display this day as, in `timeZone`. Local
    /// NOON, not midnight: a handful of time zones have historically
    /// transitioned DST at midnight, where local midnight itself can be a
    /// nonexistent or repeated wall-clock instant — noon is never on that
    /// edge, so this never needs a fallback/ambiguity rule to stay exact.
    public func localDate(timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        return calendar.date(from: components) ?? utcMidnight
    }

    public static func < (lhs: TrainingDay, rhs: TrainingDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}
