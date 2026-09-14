import Foundation
import GymLogKit

enum SessionDateFormat {
    // One cached formatter per language (not per call) -- History lists 100+
    // sessions, so re-constructing a `DateFormatter` on every row's render
    // would be wasteful. `display`/`displayWithWeekday` just pick between
    // the two, so a language switch still takes effect immediately.
    private static let displayZh: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.timeZone = TimeZone(identifier: "UTC") // dates are stored as UTC-midnight calendar days
        f.dateFormat = "yyyy年M月d日"
        return f
    }()

    private static let displayEn: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    private static let displayWithWeekdayZh: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hant_TW")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy年M月d日 EEEE"
        return f
    }()

    private static let displayWithWeekdayEn: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMM d, yyyy (EEEE)"
        return f
    }()

    static var display: DateFormatter {
        LanguageContext.current == .zhHant ? displayZh : displayEn
    }

    static var displayWithWeekday: DateFormatter {
        LanguageContext.current == .zhHant ? displayWithWeekdayZh : displayWithWeekdayEn
    }
}

/// Single place that converts a `Date` picked in the user's local calendar
/// (from a `DatePicker`, or "now") into the project's training-day encoding:
/// the local year/month/day, re-encoded at UTC midnight. Every place that
/// saves or filters by training date must go through this — using the raw
/// `Date` (which still carries local wall-clock time) against UTC-midnight
/// session dates is what produced the 2026-09-06 审查报告 #1 (new sessions
/// saved a day early west of UTC in the evening / east of UTC before dawn)
/// and #4 (range filters dropping the boundary day) bugs.
///
/// Both directions are just thin wrappers over `TrainingDay` (GymLogKit) now
/// — see that type's doc comment for why the old `Calendar.current`-based
/// implementation was wrong in two independent ways (2026-09-07 审阅 B07).
enum TrainingDayEncoding {
    static func utcDay(from date: Date) -> Date {
        TrainingDay.fromLocalWallClock(date).utcMidnight
    }

    static func isoDateString(from date: Date) -> String {
        let day = TrainingDay.fromLocalWallClock(date)
        return String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }

    /// Inverse of `utcDay`: turns an already-encoded UTC-midnight
    /// `session.date` back into a `Date` a local `DatePicker` can display —
    /// and, if the coach doesn't touch it, re-save through `utcDay` without
    /// drifting to a different day. Every call site that initializes picker
    /// state from a value that has already been through `utcDay` (editing
    /// an existing session's date, re-opening a previously-applied date
    /// range) MUST go through this rather than using that stored `Date`
    /// directly — see `TrainingDay`'s doc comment point 1.
    static func localDisplayDate(from utcDay: Date) -> Date {
        TrainingDay.from(utcMidnight: utcDay).localDate()
    }
}
