import SwiftUI
import GymLogKit

/// 训练界面顶部常驻的组间休息倒计时（2026-09-04）。
///
/// 交互按教练的原话设计：「点击一下就开始倒计时，时间到了会响铃提醒」——整条
/// 计时条本身就是那个按钮（开始 / 暂停 / 继续 / 结束后重来都走同一个
/// `toggle()`），右侧只挂两个次要控件：切换默认休息时长的预设胶囊、以及归零。
///
/// 视觉沿用 M9 之前那版被移除的 `RestTimerBar` 的规格（HANDOFF.md §2 计时器
/// 26/SemiBold 等宽数字 + §4.6 小主按钮），新增的是背后那层随剩余时间推进的
/// 进度填充，让教练不用读秒也能余光判断还剩多久。
struct RestTimerBar<Accessory: View>: View {
    @Bindable var timer: RestTimerModel
    /// 挂在第一行右端的附属控件（目前是心率芯片）。放进来而不是并排成两个
    /// 独立的条，是因为一行 402pt 塞不下"计时条 + 预设 + 重置 + 心率"——并排
    /// 会把整条顶栏撑到超出屏宽，连带把下方内容的页边距一起挤没。
    @ViewBuilder var accessory: Accessory

    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    var body: some View {
        VStack(spacing: 8) {
            Button(action: timer.toggle) {
                HStack(spacing: 10) {
                    Image(systemName: iconName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(timer.hasFinished ? DS.C.accent : DS.C.textLow)
                    Text(timer.displayText)
                        .font(DS.F.timer())
                        .monospacedDigit()
                        .foregroundStyle(DS.C.textHi)
                    Text(hintText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.C.textLow)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(hintText)
            .accessibilityValue(timer.displayText)
            .overlay(alignment: .trailing) { accessory }

            HStack(spacing: 6) {
                ForEach(RestTimerModel.presetSeconds, id: \.self) { seconds in
                    presetChip(seconds)
                }
                Spacer(minLength: 0)
                Button {
                    timer.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.C.textMid)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(timer.isIdle)
                .opacity(timer.isIdle ? 0.35 : 1)
                .accessibilityLabel(language.t("重置休息計時", "Reset rest timer"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(alignment: .leading) {
            // 进度填充画在 inset 底色之上、内容之下：GeometryReader 只在这一层，
            // 不参与前景排版，所以不会影响上面两行的自然高度。
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    DS.C.inset
                    Rectangle()
                        .fill(timer.hasFinished ? DS.C.accent.opacity(0.28) : DS.C.accentSoft)
                        .frame(width: geo.size.width * timer.progress)
                }
            }
            .animation(.linear(duration: 0.2), value: timer.progress)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    }

    private func presetChip(_ seconds: Int) -> some View {
        let isSelected = timer.totalSeconds == seconds
        return Button {
            timer.setTotal(seconds)
        } label: {
            Text("\(seconds)s")
                .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                .monospacedDigit()
                // 没有这两行，"30s" 会在窄胶囊里被折成上下两行的 "30" / "s"。
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(isSelected ? DS.C.onAccent : DS.C.textMid)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(isSelected ? DS.C.accent : DS.C.surface, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var iconName: String {
        if timer.hasFinished { return "bell.fill" }
        return timer.isRunning ? "pause.circle.fill" : "timer"
    }

    private var hintText: String {
        if timer.hasFinished { return language.t("休息結束", "Rest over") }
        if timer.isRunning { return language.t("休息中 · 點擊暫停", "Resting · tap to pause") }
        if timer.isIdle { return language.t("點擊開始休息", "Tap to start rest") }
        return language.t("已暫停 · 點擊繼續", "Paused · tap to resume")
    }
}

extension RestTimerBar where Accessory == EmptyView {
    init(timer: RestTimerModel) {
        self.init(timer: timer, accessory: { EmptyView() })
    }
}

#Preview {
    RestTimerBar(timer: RestTimerModel())
        .padding()
        .background(DS.C.canvas)
}
