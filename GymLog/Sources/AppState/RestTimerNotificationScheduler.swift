import Foundation
import UserNotifications

/// 组间休息倒计时到点时的本地通知（2026-09-09 教练反馈：「一分钟休息的倒计时
/// 到期之后，应该有一个铃声或者震动作为提示，不能只是显示到期」）。
///
/// 为什么光有 `RestTimerAlarm` 不够：那条路径挂在 `RestTimerModel.onFinish`
/// 上，而 `onFinish` 由一个 `Task` 里的 200ms tick 触发——App 一旦被切到后台
/// 或锁屏（教练把手机放下休息一分钟，正是最典型的情形），这个 Task 会被系统挂
/// 起，到点那一刻没有任何代码在跑，回到前台时 `sync()` 才补算出「已经结束」，
/// 于是屏幕上只剩「休息結束」四个字，铃声和震动都错过了。本地通知是由系统在
/// 到点时刻投递的，与 App 是否在跑无关，所以补的正是这一段。
///
/// 和 `WODTimerNotificationScheduler` 分开而不是复用它：那个类型的 `cancelAll()`
/// 按自己的前缀一把清空，休息计时和 WOD 计时可以同时挂着（教练在一个 WOD 的
/// 间歇里按休息计时），共用前缀会让任何一方的取消误伤另一方。授权检查复用它
/// 的静态方法，不重复实现。
///
/// 同样不做的事（沿用 WODTimerNotificationScheduler 的立场）：不伪造后台音频、
/// 不承诺无通知权限或勿扰模式下一定响。权限被拒时调用方会在计时条下方显示一行
/// 说明，而不是静默排一个系统必然丢弃的请求。
public enum RestTimerNotificationScheduler {
    private static let identifier = "org.example.gymlog.rest-timer-finished"

    /// 排一条在 `deadline` 投递的通知，覆盖上一条（休息计时同一时间只有一个）。
    /// `deadline` 已过则什么也不做——`WODTimerNotificationScheduler` 的「不补播
    /// 漏掉的提醒」规则在这里同样适用。
    public static func schedule(at deadline: Date, totalSeconds: Int) {
        cancel()
        let interval = deadline.timeIntervalSinceNow
        guard interval > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = L("組間休息", "Rest Timer")
        content.body = L("\(totalSeconds) 秒休息結束，開始下一組", "\(totalSeconds)s rest is over — next set")
        content.sound = .default
        // App 在前台时不会重复响：这个 App 没有实现 UNUserNotificationCenterDelegate，
        // 而 iOS 默认就不向前台 App 投递通知，于是前台走 RestTimerAlarm、后台走
        // 这条通知，两条路径天然互斥。
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    public static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
