import Foundation
import GymLogKit

/// "距今时长" formatting shared by the history detail list and the query
/// page. Kept separate from (and not editing) `DateFormatting.swift`, which
/// is shared-read-only per CONTRACT-UI.md §1.
enum RelativeTime {
    static func string(from date: Date, to now: Date = Date()) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days < 0 { return L("未來", "in the future") }
        if days == 0 { return L("今天", "today") }
        if days == 1 { return L("昨天", "yesterday") }
        if days < 7 { return L("\(days)天前", "\(days)d ago") }
        if days < 30 { return L("\(days / 7)週前", "\(days / 7)w ago") }
        if days < 365 { return L("\(days / 30)個月前", "\(days / 30)mo ago") }
        return L("\(days / 365)年前", "\(days / 365)y ago")
    }
}
