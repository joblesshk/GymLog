import XCTest
@testable import GymLogKit

/// `RestTimerModel` -- 2026-09-04 恢复的组间休息倒计时。
///
/// 全部用注入的假时钟驱动，没有一个用例需要真的等待；重点覆盖的是旧实现
/// （每秒 `remainingSeconds -= 1`）做不到的那件事：**倒计时按墙钟走**，App 被
/// 切走 / 主线程卡住的那段时间照样算进休息里。
@MainActor
final class RestTimerModelTests: XCTestCase {

    /// 可以被用例任意拨动的假时钟。
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { now += seconds }
        var provider: () -> Date { { [unowned self] in self.now } }
    }

    private func makeTimer(_ seconds: Int = 60) -> (RestTimerModel, Clock) {
        let clock = Clock()
        return (RestTimerModel(totalSeconds: seconds, now: clock.provider), clock)
    }

    // MARK: - 初始状态

    func testStartsIdleAtFullDuration() {
        let (timer, _) = makeTimer(60)
        XCTAssertEqual(timer.totalSeconds, 60)
        XCTAssertEqual(timer.remainingSeconds, 60)
        XCTAssertFalse(timer.isRunning)
        XCTAssertTrue(timer.isIdle)
        XCTAssertEqual(timer.displayText, "1:00")
        XCTAssertEqual(timer.progress, 0)
    }

    func testDefaultIsSixtySecondsAsTheCoachAsked() {
        XCTAssertEqual(RestTimerModel.defaultSeconds, 60)
        XCTAssertEqual(RestTimerModel(now: Date.init).totalSeconds, 60)
    }

    func testRejectsNonPositiveDurations() {
        let (timer, _) = makeTimer(0)
        XCTAssertEqual(timer.totalSeconds, 1)
        timer.setTotal(-30)
        XCTAssertEqual(timer.totalSeconds, 1)
    }

    // MARK: - 按墙钟倒数

    func testCountsDownAgainstWallClockNotTickCount() {
        let (timer, clock) = makeTimer(60)
        timer.start()

        clock.advance(10)
        timer.sync()
        XCTAssertEqual(timer.remainingSeconds, 50)

        // 这就是旧实现会漂移的场景：中间没有任何 tick 发生（App 在后台 / 主线
        // 程被占住），一次 sync 必须把整段时间都补上，而不是只减 1 秒。
        clock.advance(35)
        timer.sync()
        XCTAssertEqual(timer.remainingSeconds, 15)
        XCTAssertTrue(timer.isRunning)
    }

    func testDisplayTextAndProgressTrackRemainingTime() {
        let (timer, clock) = makeTimer(120)
        timer.start()
        clock.advance(30)
        timer.sync()

        XCTAssertEqual(timer.displayText, "1:30")
        XCTAssertEqual(timer.progress, 0.25, accuracy: 0.0001)
    }

    // MARK: - 到点

    func testFiresOnFinishExactlyOnceWhenTimeRunsOut() {
        let (timer, clock) = makeTimer(60)
        var ringCount = 0
        timer.onFinish = { ringCount += 1 }

        timer.start()
        clock.advance(59)
        timer.sync()
        XCTAssertEqual(ringCount, 0, "还剩 1 秒时不该响")

        clock.advance(1)
        timer.sync()
        XCTAssertEqual(ringCount, 1)
        XCTAssertEqual(timer.remainingSeconds, 0)
        XCTAssertFalse(timer.isRunning)
        XCTAssertTrue(timer.hasFinished)
        XCTAssertEqual(timer.progress, 1)

        // 已经停表了，后续 sync 不该再响第二次。
        clock.advance(30)
        timer.sync()
        timer.sync()
        XCTAssertEqual(ringCount, 1)
    }

    /// 教练在休息中间切走去接了个电话，回来时早就过点了——必须补响，而不是
    /// 显示成"还剩 -70 秒"或者停在半路。
    func testOvershootingTheDeadlineWhileBackgroundedStillRings() {
        let (timer, clock) = makeTimer(60)
        var rang = false
        timer.onFinish = { rang = true }

        timer.start()
        clock.advance(130)
        timer.sync()

        XCTAssertTrue(rang)
        XCTAssertEqual(timer.remainingSeconds, 0, "剩余秒数永远不该变成负数")
        XCTAssertEqual(timer.displayText, "0:00")
    }

    // MARK: - 暂停 / 继续 / 重置

    func testPauseFreezesRemainingTimeAndResumeContinuesFromThere() {
        let (timer, clock) = makeTimer(60)
        timer.start()

        clock.advance(20)
        timer.pause()
        XCTAssertEqual(timer.remainingSeconds, 40)
        XCTAssertFalse(timer.isRunning)

        // 暂停期间流逝的时间不算进休息。
        clock.advance(300)
        XCTAssertEqual(timer.remainingSeconds, 40)

        timer.start()
        clock.advance(15)
        timer.sync()
        XCTAssertEqual(timer.remainingSeconds, 25)
    }

    func testResetReturnsToFullDurationAndClearsFinishedFlag() {
        let (timer, clock) = makeTimer(60)
        timer.start()
        clock.advance(90)
        timer.sync()
        XCTAssertTrue(timer.hasFinished)

        timer.reset()
        XCTAssertEqual(timer.remainingSeconds, 60)
        XCTAssertFalse(timer.isRunning)
        XCTAssertFalse(timer.hasFinished)
        XCTAssertTrue(timer.isIdle)
    }

    // MARK: - toggle（整条计时条唯一的动作）

    func testToggleStartsThenPausesThenResumes() {
        let (timer, clock) = makeTimer(60)

        timer.toggle()
        XCTAssertTrue(timer.isRunning)

        clock.advance(10)
        timer.toggle()
        XCTAssertFalse(timer.isRunning)
        XCTAssertEqual(timer.remainingSeconds, 50)

        timer.toggle()
        XCTAssertTrue(timer.isRunning)
    }

    /// 响完铃之后再点一下，应该是"重新休息一轮"，而不是卡在 0:00。
    func testToggleAfterFinishRestartsAFullRound() {
        let (timer, clock) = makeTimer(60)
        timer.start()
        clock.advance(60)
        timer.sync()
        XCTAssertTrue(timer.hasFinished)

        timer.toggle()
        XCTAssertTrue(timer.isRunning)
        XCTAssertFalse(timer.hasFinished)
        XCTAssertEqual(timer.remainingSeconds, 60)
    }

    // MARK: - 预设

    func testPresetsIncludeTheCoachesSixtySecondDefault() {
        XCTAssertTrue(RestTimerModel.presetSeconds.contains(RestTimerModel.defaultSeconds))
        XCTAssertEqual(RestTimerModel.presetSeconds, RestTimerModel.presetSeconds.sorted())
    }

    /// 切预设时必须一并把剩余秒数拉回去：否则会留下"总长 30s / 剩余 60s"这种
    /// 让 `progress` 算出负数的状态。
    func testSwitchingPresetResetsToTheNewDuration() {
        let (timer, clock) = makeTimer(60)
        timer.start()
        clock.advance(45)
        timer.sync()
        XCTAssertEqual(timer.remainingSeconds, 15)

        timer.setTotal(30)
        XCTAssertEqual(timer.totalSeconds, 30)
        XCTAssertEqual(timer.remainingSeconds, 30)
        XCTAssertFalse(timer.isRunning)
        XCTAssertEqual(timer.progress, 0)
    }

    // MARK: - 到点提醒的排程回调（2026-09-09）

    /// 教练的反馈是「到期只显示，不响」。前台响铃走的是 `onFinish`，但 App 被
    /// 切到后台时那条 200ms 的 tick 会被系统挂起，到点那一刻根本没有代码在跑。
    /// 所以开始倒计时的瞬间就必须把到点时刻交出去，让调用方提前排一条本地通知
    /// ——这几个用例锁的就是「什么时候交、交的是哪个时刻、什么时候撤」。
    func testStartHandsOutTheWallClockDeadlineForABackgroundAlert() {
        let (timer, clock) = makeTimer(60)
        var scheduled: [Date?] = []
        timer.onScheduleChange = { scheduled.append($0) }

        timer.start()
        XCTAssertEqual(scheduled.count, 1)
        XCTAssertEqual(scheduled.first ?? nil, clock.now.addingTimeInterval(60))
        XCTAssertEqual(timer.deadline, clock.now.addingTimeInterval(60))
    }

    /// 暂停后剩下的是 40 秒，继续时排的通知必须是「从现在起 40 秒」，不是原来
    /// 那个已经过时的到点时刻。
    func testResumingReschedulesFromTheRemainingTimeNotTheOriginalDeadline() {
        let (timer, clock) = makeTimer(60)
        var scheduled: [Date?] = []
        timer.onScheduleChange = { scheduled.append($0) }

        timer.start()
        clock.advance(20)
        timer.sync()
        timer.pause()
        XCTAssertEqual(scheduled.last ?? nil, nil, "暂停必须撤掉已排的提醒")

        clock.advance(300)   // 教练去接了个电话
        timer.start()
        XCTAssertEqual(scheduled.last ?? nil, clock.now.addingTimeInterval(40))
    }

    /// 重置、切预设、以及倒计时真的走完，都要把排好的提醒撤掉——尤其是最后
    /// 一种：走完时那条通知要么刚投递、要么正要投递，不撤的话「响铃之后又弹
    /// 一条通知」就会同时发生。
    func testStoppingInAnyWayCancelsTheScheduledAlert() {
        let (timer, clock) = makeTimer(60)
        var scheduled: [Date?] = []
        timer.onScheduleChange = { scheduled.append($0) }

        timer.start()
        timer.reset()
        XCTAssertEqual(scheduled.last ?? nil, nil)

        timer.start()
        timer.setTotal(30)
        XCTAssertEqual(scheduled.last ?? nil, nil)

        timer.start()
        clock.advance(30)
        timer.sync()
        XCTAssertTrue(timer.hasFinished)
        XCTAssertEqual(scheduled.last ?? nil, nil)
    }
}
