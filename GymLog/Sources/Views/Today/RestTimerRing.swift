import SwiftUI
import UIKit
import GymLogKit

/// 组间休息倒计时：角落小圆环常驻 + 点击展开浮层（2026-09-15 设计改版）。
///
/// 取代原先占整行的 `RestTimerBar`／线性填充膠囊 `RestTimerPill`——线性填充在
/// 44pt 高的窄条里幾乎看不出進度。改成 32pt 小圓環常駐在標題列，餘光就能看出
/// 剩餘比例；需要精確讀秒、暫停或改時長時，點一下展開成 168pt 的浮層圓環，
/// 再點「收合」或 3 秒無操作自動收回——記錄組數的卡片區不會被常駐的大圓環
/// 擠掉首屏。
///
/// 一顆計時器只有一份 `RestTimerModel`，這裡只是換皮＋加一個「展開/收合」的
/// 純 UI 狀態，沿用既有的 `toggle()/start()/setTotal()/reset()` 控制邏輯。
struct RestTimerHeaderRow<Accessory: View>: View {
    @Bindable var timer: RestTimerModel
    /// 掛在同一列尾端的附屬控件（目前是心率膠囊）——與舊版 `RestTimerBar` 的
    /// `accessory` 用途相同，保留同樣的呼叫方式以縮小 `TodayView` 的改動面。
    @ViewBuilder var accessory: Accessory

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if !isExpanded {
                    RestTimerCornerPill(timer: timer, onTap: handleCornerTap)
                }
                Spacer(minLength: 0)
                accessory
            }
            if isExpanded {
                RestTimerExpandedCard(timer: timer, onCollapse: { isExpanded = false })
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.94, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(
            reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.82),
            value: isExpanded
        )
        // 计时器一旦走完，浮层没有意义再挡着——自动收回，露出下面的「休息結束」
        // 小圆环，教练点一下就能直接开始下一轮。
        .onChange(of: timer.hasFinished) { _, finished in
            if finished { isExpanded = false }
        }
    }

    /// 角落圆环的点击语义：閒置＝直接開始（教練要的「點一下就開始」，不因為
    /// 改了外觀就多一次確認）；運行中／暫停＝展開浮層看細節或暫停；已結束＝
    /// 直接重新開始下一輪（同 `toggle()` 舊語意），不需要先展開。
    private func handleCornerTap() {
        if timer.isIdle {
            timer.start()
        } else if timer.hasFinished {
            timer.toggle()
        } else {
            isExpanded = true
        }
    }
}

extension RestTimerHeaderRow where Accessory == EmptyView {
    init(timer: RestTimerModel) {
        self.init(timer: timer, accessory: { EmptyView() })
    }
}

// MARK: - Ring visual (shared between 32pt corner and 168pt expanded card)

/// 環形進度：track 用 `hairline`，剩餘比例用 `trim` 畫出來，連續遞減（綁
/// `timer.progress` 的 `.linear(duration:0.2)`，配合 model 200ms 一次的
/// `sync()`，視覺上不會有「每秒跳格」的頓挫）。`centerContent` 只有閒置
/// （提示圖示）與結束（鈴鐺）兩態需要，運行中／暫停時環中央是空的——數字
/// 另外擺在環外側。
private struct RestRingVisual<Center: View>: View {
    let timer: RestTimerModel
    let diameter: CGFloat
    let lineWidth: CGFloat
    @ViewBuilder var centerContent: Center

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isFinalCountdown: Bool {
        timer.isRunning && timer.remainingSeconds > 0 && timer.remainingSeconds <= 5
    }

    private var remainingFraction: CGFloat {
        CGFloat(max(0, min(1, 1 - timer.progress)))
    }

    private var arcColor: Color {
        if isFinalCountdown { return DS.C.accent }
        return timer.isRunning ? DS.C.accent : DS.C.textLow
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(timer.hasFinished ? DS.C.onAccent.opacity(0.9) : DS.C.hairline, lineWidth: lineWidth)
            if !timer.hasFinished && !timer.isIdle {
                Circle()
                    .trim(from: 0, to: remainingFraction)
                    .stroke(arcColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .linear(duration: 0.2), value: timer.progress)
            }
            centerContent
        }
        .frame(width: diameter, height: diameter)
    }
}

extension RestRingVisual where Center == EmptyView {
    init(timer: RestTimerModel, diameter: CGFloat, lineWidth: CGFloat) {
        self.init(timer: timer, diameter: diameter, lineWidth: lineWidth, centerContent: { EmptyView() })
    }
}

/// 最後 5 秒的閃爍（`ringflash`：opacity 1↔0.45，每 0.5s 一次）。「減少動態
/// 效果」開啟時完全不閃，只靠顏色轉 accent + 文字提示。
private struct FinalCountdownPulse: ViewModifier {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(isActive && !reduceMotion && dimmed ? 0.45 : 1)
            .onChange(of: isActive) { _, active in
                guard !reduceMotion else { return }
                if active {
                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                        dimmed = true
                    }
                } else {
                    dimmed = false
                }
            }
    }
}

extension View {
    fileprivate func finalCountdownPulse(_ isActive: Bool) -> some View {
        modifier(FinalCountdownPulse(isActive: isActive))
    }
}

/// 最後 5 秒每秒一次的輕觸感——鬧鈴本身（`RestTimerAlarm`）已經有一套三連震
/// 動的重觸感，這裡刻意用 `.light` 區分「快到了」與「到了」兩種提醒強度。
private enum FinalCountdownHaptic {
    private static let generator = UIImpactFeedbackGenerator(style: .light)

    static func prepare() { generator.prepare() }

    static func fire() {
        generator.impactOccurred()
        generator.prepare()
    }
}

// MARK: - Corner pill (collapsed)

/// 32pt 小圓環常駐在標題列，取代舊版的 SF Symbol 圖示。長按沿用
/// `Menu(primaryAction:)`：點一下走 `onTap`（開始 / 展開 / 重新開始），長按
/// 彈出時長預設與重置——與改版前完全相同的手勢，教練不用重新學。
private struct RestTimerCornerPill: View {
    @Bindable var timer: RestTimerModel
    let onTap: () -> Void

    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var finishBounce = false

    private var isFinalCountdown: Bool {
        timer.isRunning && timer.remainingSeconds > 0 && timer.remainingSeconds <= 5
    }

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
            HStack(spacing: 9) {
                RestRingVisual(timer: timer, diameter: 32, lineWidth: 4) {
                    if timer.isIdle {
                        Image(systemName: "timer")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.C.textLow)
                    } else if timer.hasFinished {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.C.onAccent)
                    }
                }
                if timer.hasFinished {
                    Text(language.t("休息結束", "Rest over"))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(DS.C.onAccent)
                        .lineLimit(1)
                        .fixedSize()
                } else {
                    HStack(spacing: 6) {
                        Text(timer.displayText)
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundStyle(isFinalCountdown ? DS.C.accent : DS.C.textHi)
                            .lineLimit(1)
                            .fixedSize()
                        if !timer.isRunning && !timer.isIdle {
                            // 暫停中：一個小三角形取代文字，跟角落圓環一樣輕量。
                            Image(systemName: "play.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(DS.C.textLow)
                        }
                    }
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .padding(.vertical, 5)
            .frame(height: 44)
            .background(pillBackground, in: Capsule())
            .finalCountdownPulse(isFinalCountdown)
            .contentShape(Capsule())
            .scaleEffect(finishBounce ? 1.04 : 1)
        } primaryAction: {
            onTap()
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .accessibilityIdentifier("rest-timer-ring")
        .accessibilityLabel(hintText)
        .accessibilityValue(timer.hasFinished ? language.t("休息結束", "Rest over") : timer.displayText)
        .accessibilityHint(language.t("長按選擇休息時長", "Long-press to choose the rest length"))
        // 結束瞬間整環填滿 accent 的同時彈一下（1→1.04→1，0.28s），呼應鬧鈴；
        // 減少動態效果時只靠顏色 + 響鈴 + 文字，不做縮放。
        .onChange(of: timer.hasFinished) { _, finished in
            guard finished, !reduceMotion else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.6)) { finishBounce = true }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.6).delay(0.15)) { finishBounce = false }
        }
        .onAppear { FinalCountdownHaptic.prepare() }
        .onChange(of: timer.remainingSeconds) { _, newValue in
            if timer.isRunning, newValue > 0, newValue <= 5 {
                FinalCountdownHaptic.fire()
            }
        }
    }

    private var pillBackground: Color {
        if timer.hasFinished { return DS.C.accent }
        if isFinalCountdown { return DS.C.accentSoft }
        return DS.C.inset
    }

    private var hintText: String {
        if timer.hasFinished { return language.t("休息結束，點擊開始下一輪", "Rest over, tap to start the next one") }
        if timer.isRunning { return language.t("休息中，點擊展開", "Resting, tap to expand") }
        if timer.isIdle { return language.t("點擊開始休息", "Tap to start rest") }
        return language.t("已暫停，點擊展開", "Paused, tap to expand")
    }
}

// MARK: - Expanded overlay card

/// 展開後的 168pt 圓環卡片：暫停/繼續為主按鈕，旁邊一顆歸零；下方是時長
/// 預設。3 秒無操作或再點「收合」即自動收回——教練調完就該回去看動作卡片，
/// 不該一直佔著首屏。
struct RestTimerExpandedCard: View {
    @Bindable var timer: RestTimerModel
    let onCollapse: () -> Void

    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant
    @State private var autoCollapseTask: Task<Void, Never>?

    private var isFinalCountdown: Bool {
        timer.isRunning && timer.remainingSeconds > 0 && timer.remainingSeconds <= 5
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(language.t("組間休息 · REST", "REST"))
                    .sectionLabelStyle()
                Spacer()
                Button(action: onCollapse) {
                    HStack(spacing: 3) {
                        Text(language.t("收合", "Collapse"))
                        Image(systemName: "chevron.up")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.C.accent)
                }
                .buttonStyle(.plain)
            }

            RestRingVisual(timer: timer, diameter: 168, lineWidth: 7) {
                if timer.hasFinished {
                    Text(language.t("休息結束", "Rest over"))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(DS.C.onAccent)
                } else {
                    VStack(spacing: 6) {
                        Text("\(max(0, timer.remainingSeconds))")
                            .font(.system(size: 54, weight: .semibold, design: .monospaced))
                            .foregroundStyle(isFinalCountdown ? DS.C.accent : DS.C.textHi)
                            .tracking(-1)
                        Text(language.t("秒 · 共 \(timer.totalSeconds)s", "sec · of \(timer.totalSeconds)s"))
                            .font(.system(size: 12))
                            .foregroundStyle(DS.C.textLow)
                    }
                }
            }
            .finalCountdownPulse(isFinalCountdown)
            .padding(.vertical, 6)

            HStack(spacing: 8) {
                Button {
                    timer.toggle()
                    scheduleAutoCollapse()
                } label: {
                    Label(
                        timer.isRunning
                            ? language.t("暫停", "Pause")
                            : (timer.hasFinished ? language.t("重新開始", "Restart") : language.t("繼續", "Resume")),
                        systemImage: timer.isRunning ? "pause.fill" : "play.fill"
                    )
                }
                .buttonStyle(.gymPrimary)

                Button {
                    timer.reset()
                    scheduleAutoCollapse()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.C.textMid)
                }
                .buttonStyle(.gymSecondary)
                .frame(width: DS.Size.buttonHeight)
                .disabled(timer.isIdle)
                .opacity(timer.isIdle ? 0.4 : 1)
                .accessibilityLabel(language.t("重置休息計時", "Reset rest timer"))
            }

            HStack(spacing: 6) {
                ForEach(RestTimerModel.presetSeconds, id: \.self) { seconds in
                    presetChip(seconds)
                }
            }
        }
        .padding(.horizontal, DS.Space.cardPadding)
        .padding(.vertical, DS.Space.cardPadding)
        .gymCard()
        .shadow(color: DS.C.textHi.opacity(0.1), radius: 16, y: 8)
        .onAppear { scheduleAutoCollapse() }
        .onDisappear { autoCollapseTask?.cancel() }
    }

    private func presetChip(_ seconds: Int) -> some View {
        let isSelected = timer.totalSeconds == seconds
        return Button {
            timer.setTotal(seconds)
            scheduleAutoCollapse()
        } label: {
            Text("\(seconds)s")
                .font(.system(size: 14, weight: isSelected ? .bold : .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(isSelected ? DS.C.accent : DS.C.textMid)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(isSelected ? DS.C.surface : DS.C.inset, in: RoundedRectangle(cornerRadius: DS.Radius.stepper, style: .continuous))
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: DS.Radius.stepper, style: .continuous)
                            .stroke(DS.C.accent, lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    /// 3 秒無操作自動收回；每次在卡片裡按了按鈕都重新計時。
    private func scheduleAutoCollapse() {
        autoCollapseTask?.cancel()
        autoCollapseTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            onCollapse()
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        RestTimerHeaderRow(timer: {
            let t = RestTimerModel()
            t.start()
            return t
        }())
        RestTimerHeaderRow(timer: RestTimerModel())
    }
    .padding()
    .background(DS.C.canvas)
}
