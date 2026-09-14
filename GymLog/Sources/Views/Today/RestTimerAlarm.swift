import AVFoundation
import UIKit

/// 休息倒计时走完时的响铃 + 触感。
///
/// 为什么不用 `AudioServicesPlaySystemSound`（旧代码里最省事的写法）：系统提示
/// 音走的是铃声通道，手机拨到静音档就只剩震动——而健身房里手机长期静音是常态，
/// 教练要的"响铃提醒"就废了。这里改用 `.playback` 类别播一段自带音频：该类别
/// 明确忽略静音开关，配上 `.mixWithOthers + .duckOthers` 又能在教练放着音乐时
/// 把音乐压低而不是打断。
enum RestTimerAlarm {
    private static var player: AVAudioPlayer?
    /// 长期持有而不是每次现造：`UIImpactFeedbackGenerator` 要先 `prepare()` 把
    /// Taptic Engine 唤醒，触感才会真的出来；创建后立刻 `impactOccurred()` 的
    /// 写法（旧实现）经常一点感觉都没有——而教练的反馈正是「只是显示到期」。
    private static let haptics = UIImpactFeedbackGenerator(style: .heavy)

    /// 提前唤醒触感引擎。倒计时开始时调一次即可；不调也能响，只是第一下可能被
    /// 吞掉。
    static func prepare() {
        haptics.prepare()
    }

    static func ring() {
        vibrate()
        playSound()
    }

    /// 三下重震，间隔 0.45s。一下 `.success` 那种轻两声在健身房里（手机放在
    /// 地上、口袋里，周围有音乐）基本感知不到，这是教练要「铃声或者震动」的
    /// 直接原因。
    private static func vibrate() {
        for index in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.45) {
                haptics.impactOccurred(intensity: 1)
                haptics.prepare()
            }
        }
    }

    private static func playSound() {
        guard let url = Bundle.main.url(forResource: "rest_timer_alarm", withExtension: "wav") else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = 1
            player.prepareToPlay()
            player.play()
            // 强引用留住，否则 player 出作用域就被释放、声音直接被掐断。
            self.player = player
            // 播完把 session 交还出去，音乐才会从 duck 状态恢复原音量。
            DispatchQueue.main.asyncAfter(deadline: .now() + player.duration + 0.2) {
                try? session.setActive(false, options: [.notifyOthersOnDeactivation])
                if self.player === player { self.player = nil }
            }
        } catch {
            // 响铃失败不该影响记录训练：降级成只有触感，并留下痕迹而不是静默吞掉。
            print("[GymLog] Rest timer alarm failed: \(error.localizedDescription)")
        }
    }
}
