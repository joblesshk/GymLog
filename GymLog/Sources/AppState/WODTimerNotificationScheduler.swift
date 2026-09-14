import Foundation
import UserNotifications

/// Schedules/cancels local notifications for WOD timer phase boundaries so
/// a coach who backgrounds the app (checking a client's profile, answering
/// a call) still gets an alert when a phase/interval/cap ends.
///
/// Explicitly NOT a guarantee: delivery depends on the user's OS-level
/// notification permission and Focus/silent-mode settings exactly like any
/// other app's local notifications, and this type makes no attempt to work
/// around either -- 工程审阅与CrossFit适配方案.md §7: "不為計時偽造後台音頻，
/// 不承諾無權限/靜音時保證響鈴". Real-device verification of actual delivery
/// while backgrounded/locked/on silent is listed as an explicit open item
/// (`CONTRACT-M10.md`), not claimed here.
public enum WODTimerNotificationScheduler {
    private static let identifierPrefix = "org.example.gymlog.wod-timer-phase-"

    /// Current permission state, checked before scheduling anything -- a
    /// caller should surface `false` to the coach as "these alerts won't
    /// fire, but the on-screen timer still works" rather than silently
    /// scheduling requests the OS will just drop.
    public static func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined, .denied: return false
        @unknown default: return false
        }
    }

    /// Requests permission if not already decided. The OS only prompts once
    /// per install; a prior denial returns `false` here too (the coach must
    /// re-enable it in Settings, same as any other app).
    @discardableResult
    public static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    /// Schedules exactly one notification per REMAINING phase boundary,
    /// starting from `firstPhaseDeadline` (the current phase's own
    /// deadline -- pass `WODTimerModel`'s own tracked value, not "now",
    /// so a mid-phase start/resume schedules the right countdown for the
    /// phase actually in progress) through the end of `phases[fromIndex...]`.
    /// Never schedules for a boundary already in the past -- "不... 補播
    /// 所有漏掉的提醒" applies to notifications exactly as much as it does
    /// to `WODTimerModel.sync()`'s own bookkeeping. Always cancels any
    /// previously-scheduled phase notifications first, so pausing and
    /// restarting a timer never leaves stale duplicates queued.
    public static func schedulePhaseNotifications(phases: [WODTimerPhase], fromIndex: Int, firstPhaseDeadline: Date) {
        cancelAll()
        guard fromIndex < phases.count else { return }
        var deadline = firstPhaseDeadline
        let center = UNUserNotificationCenter.current()
        for index in fromIndex..<phases.count {
            defer { deadline = deadline.addingTimeInterval(TimeInterval(phases[index].durationSeconds)) }
            let interval = deadline.timeIntervalSinceNow
            guard interval > 0 else { continue }
            let content = UNMutableNotificationContent()
            content.title = L("WOD 計時", "WOD Timer")
            content.body = index + 1 < phases.count
                ? L("「\(phases[index].label)」結束", "\"\(phases[index].label)\" finished")
                : L("WOD 時間到", "WOD time is up")
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(identifier: "\(identifierPrefix)\(index)", content: content, trigger: trigger)
            center.add(request)
        }
    }

    /// A single notification at `deadline` -- used for AMRAP/For-Time's
    /// one-phase case and for a manual "time cap reached" alert.
    public static func scheduleSingle(title: String, body: String, at deadline: Date) {
        cancelAll()
        let interval = deadline.timeIntervalSinceNow
        guard interval > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: "\(identifierPrefix)0", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    public static func cancelAll() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
            guard !ids.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
}
