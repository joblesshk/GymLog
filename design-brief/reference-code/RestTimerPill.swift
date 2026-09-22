import SwiftUI
import GymLogKit

/// 训练界面左上角的组间休息计时胶囊（2026-09-15 教练要求：计时器不该常驻占一整块）。
///
/// 点一下开始 / 暂停 / 继续（结束后再点重新开始），长按弹出 30/45/60/90 秒预设
/// 和归零——`Menu(primaryAction:)` 正好是「点击执行、长按出菜单」这组系统手势。
/// 胶囊底色随剩余时间推进填充，结束时整颗变成强调色，余光就能看出状态。
struct RestTimerPill: View {
    @Bindable var timer: RestTimerModel

    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    var body: some View {
        Menu {
            ForEach(RestTimerModel.presetSeconds, id: \.self) { seconds in
                Button {
                    timer.setTotal(seconds)
                } label: {
                    if timer.totalSeconds == seconds {
                        Label("\(seconds)s", systemImage: "checkmark")
                    } else {
                        Text("\(seconds)s")
                    }
                }
            }
            Divider()
            Button {
                timer.reset()
            } label: {
                Label(language.t("重置休息計時", "Reset rest timer"), systemImage: "arrow.counterclockwise")
            }
            .disabled(timer.isIdle)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(timer.hasFinished ? DS.C.onAccent : (timer.isRunning ? DS.C.accent : DS.C.textLow))
                Text(timer.displayText)
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(timer.hasFinished ? DS.C.onAccent : DS.C.textHi)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        timer.hasFinished ? DS.C.accent : DS.C.inset
                        if !timer.hasFinished {
                            Rectangle()
                                .fill(DS.C.accentSoft)
                                .frame(width: geo.size.width * timer.progress)
                        }
                    }
                }
                .animation(.linear(duration: 0.2), value: timer.progress)
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
        } primaryAction: {
            timer.toggle()
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .accessibilityIdentifier("rest-timer-pill")
        .accessibilityLabel(hintText)
        .accessibilityValue(timer.displayText)
        .accessibilityHint(language.t("長按選擇休息時長", "Long-press to choose the rest length"))
    }

    private var iconName: String {
        if timer.hasFinished { return "bell.fill" }
        return timer.isRunning ? "pause.fill" : "timer"
    }

    private var hintText: String {
        if timer.hasFinished { return language.t("休息結束", "Rest over") }
        if timer.isRunning { return language.t("休息中，點擊暫停", "Resting, tap to pause") }
        if timer.isIdle { return language.t("點擊開始休息", "Tap to start rest") }
        return language.t("已暫停，點擊繼續", "Paused, tap to resume")
    }
}

#Preview {
    RestTimerPill(timer: RestTimerModel())
        .padding()
        .background(DS.C.canvas)
}
