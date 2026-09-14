import Foundation
import Observation

/// 组间休息倒计时（2026-09-04 教练要求恢复）。
///
/// 历史：CONTRACT-UI.md §3.5 原本就有休息计时器，M9 v2 时教练要求整体移除
/// （CONTRACT-M9.md §6），本轮按新需求重新引入——放在训练界面顶部、点一下就
/// 开始、时间到会响铃。响铃本身是 UI 层的事（见 `RestTimerAlarm`），这里只
/// 负责倒计时逻辑，通过 `onFinish` 回调把"到点了"这件事交出去。
///
/// 与被移除的旧实现的关键区别：旧版本每秒 `remainingSeconds -= 1`，一旦 App
/// 被切到后台、锁屏、或主线程卡顿，计时就会漂移甚至停住。这里改成记录一个
/// 墙钟 deadline，每次 tick 都从 deadline 反推剩余秒数，所以中途切走再切回来
/// 读数依然是对的（`sync()` 也可以在回到前台时被显式调用一次）。
///
/// 纯逻辑、无 SwiftUI/AVFoundation 依赖，因此放在 GymLogKit 里可以直接单测；
/// `now` 是注入的，测试不需要真的等待。
@MainActor
@Observable
public final class RestTimerModel {
    /// 顶部计时条上的快捷预设。60 秒是教练指定的默认值。
    public static let presetSeconds = [30, 45, 60, 90]
    public static let defaultSeconds = 60

    /// 本轮倒计时的总长（秒）。
    public private(set) var totalSeconds: Int
    /// 剩余秒数，永远 >= 0。
    public private(set) var remainingSeconds: Int
    public private(set) var isRunning = false
    /// 倒计时刚刚走到 0（任何 `start()`/`reset()`/`setTotal(_:)` 都会清掉），
    /// 用于让计时条在响铃后短暂显示"休息結束"。
    public private(set) var hasFinished = false

    /// 走到 0 时调用一次。由 UI 层挂上响铃 + 触感。
    public var onFinish: (() -> Void)?

    /// 倒计时开始时带着本轮的墙钟到点时间调用，停表（暂停/重置/走完）时带 `nil`
    /// 调用。UI 层用它排一条到点的本地通知（`RestTimerNotificationScheduler`）。
    ///
    /// 为什么不能只靠 `onFinish`：`onFinish` 由下面那个 200ms 的 `Task` 触发，
    /// App 被切到后台或锁屏时这个 Task 会被系统挂起，到点那一刻没有任何代码在
    /// 跑——而「休息一分钟时把手机放下」恰恰是最常见的用法。到点提醒必须提前交
    /// 给系统排程，不能等自己醒过来再补。
    public var onScheduleChange: ((Date?) -> Void)?

    /// 本轮倒计时的墙钟到点时间，`nil` 表示没在跑。对外只读，供 UI 层核对
    /// 「刚才排的那条通知说的还是这一轮吗」（见 `onScheduleChange`）。
    public private(set) var deadline: Date?
    private let now: () -> Date
    private var ticker: Task<Void, Never>?

    public init(totalSeconds: Int = RestTimerModel.defaultSeconds, now: @escaping () -> Date = Date.init) {
        let clamped = max(1, totalSeconds)
        self.totalSeconds = clamped
        self.remainingSeconds = clamped
        self.now = now
    }

    // MARK: - Derived display state

    /// `m:ss`，等宽数字下不会跳动。
    public var displayText: String {
        let clamped = max(0, remainingSeconds)
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }

    /// 已经休息掉的比例，0...1，用于计时条的进度填充。
    public var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        let done = Double(totalSeconds - max(0, remainingSeconds)) / Double(totalSeconds)
        return min(1, max(0, done))
    }

    /// 还没开始、也没有暂停在半途——即"点一下就从头开始"的状态。
    public var isIdle: Bool {
        !isRunning && remainingSeconds == totalSeconds
    }

    // MARK: - Controls

    /// 教练要的"点一下就开始"：空闲→开始，运行中→暂停，暂停中→继续，
    /// 已结束→重新从头开始。整条计时条只绑这一个动作。
    public func toggle() {
        if isRunning {
            pause()
        } else if hasFinished || remainingSeconds <= 0 {
            reset()
            start()
        } else {
            start()
        }
    }

    /// 从当前剩余秒数开始跑（剩余为 0 时按整轮重来）。
    public func start() {
        let seconds = remainingSeconds > 0 ? remainingSeconds : totalSeconds
        hasFinished = false
        remainingSeconds = seconds
        let deadline = now().addingTimeInterval(TimeInterval(seconds))
        self.deadline = deadline
        isRunning = true
        startTicker()
        onScheduleChange?(deadline)
    }

    public func pause() {
        guard isRunning else { return }
        sync()          // 先把剩余秒数落到当前真实值，再停表
        stopTicker()
        isRunning = false
        deadline = nil
        onScheduleChange?(nil)
    }

    public func reset() {
        stopTicker()
        isRunning = false
        deadline = nil
        hasFinished = false
        remainingSeconds = totalSeconds
        onScheduleChange?(nil)
    }

    /// 切换预设时长。总是回到"未开始"状态，避免出现"总长 90s 但剩余 120s"
    /// 这种进度条算出负数的自相矛盾状态。
    public func setTotal(_ seconds: Int) {
        totalSeconds = max(1, seconds)
        reset()
    }

    /// 按墙钟 deadline 重算剩余秒数。tick 每次调用；App 回到前台时也应该调
    /// 一次，这样后台经过的时间同样会被算进去。
    public func sync() {
        guard isRunning, let deadline else { return }
        let left = Int(deadline.timeIntervalSince(now()).rounded(.up))
        if left <= 0 {
            remainingSeconds = 0
            isRunning = false
            self.deadline = nil
            stopTicker()
            hasFinished = true
            // 已经到点了，排好的那条通知要么刚被系统投递、要么正要投递；这里
            // 主动撤掉是为了「回到前台时才补算出结束」的那种情况——那条通知早已
            // 投递完毕，撤销是无害的空操作，而顺序上先撤再响铃，能保证任何路径
            // 下都不会出现「响铃之后又弹一条通知」。
            onScheduleChange?(nil)
            onFinish?()
        } else {
            remainingSeconds = left
        }
    }

    // MARK: - Ticker

    /// 200ms 而不是 1s：显示的整秒数由 `sync()` 从 deadline 算出，高频 tick
    /// 只是为了让读数换秒的时刻贴近真实时间，不会累积误差。
    private func startTicker() {
        stopTicker()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, !Task.isCancelled else { return }
                self.sync()
                if !self.isRunning { return }
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}
