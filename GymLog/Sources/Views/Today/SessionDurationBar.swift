import SwiftUI
import GymLogKit

/// CONTRACT-M5.md §3.1: session-duration control shown at the top of the
/// active-session view. Deliberately just a `Stepper` --
/// the contract is explicit this is "独立的、简单的数值输入，不要过度设计",
/// not a fourth wheel-style component alongside 动作/组数/重量/次数.
/// Visual spec: HANDOFF.md §4.7 (stepper) + §2 (时长值 22/SemiBold).
struct SessionDurationBar: View {
    @Binding var minutes: Int
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    var body: some View {
        HStack {
            Image(systemName: "clock")
                .foregroundStyle(DS.C.textLow)
            Text(language.t("訓練時長：", "Duration:"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DS.C.textHi)
            Text("\(minutes)")
                .font(DS.F.durationValue())
                .monospacedDigit()
                .foregroundStyle(DS.C.textHi)
            Text(language.t("分鐘", "min"))
                .font(DS.F.durationUnit)
                .foregroundStyle(DS.C.textLow)
            Spacer()
            GymStepper(value: $minutes, range: 15...240, step: 5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DS.C.inset, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    }
}

/// 课次日期（2026-09-09）。原本「今天」录的课永远落在今天，日期只能事后在
/// 歷史的编辑面板里改；把这节课的日期直接放在录入界面上，一是补录昨天的课不
/// 用再绕一圈，二是从歷史打开旧课次继续编辑时，教练看到的日期就是那一天，而
/// 不是误以为自己在改今天。
struct SessionDateBar: View {
    @Binding var date: Date
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    var body: some View {
        HStack {
            Image(systemName: "calendar")
                .foregroundStyle(DS.C.textLow)
            Text(language.t("課次日期", "Date"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DS.C.textHi)
            Spacer()
            DatePicker("", selection: $date, displayedComponents: .date)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DS.C.inset, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    }
}

/// 两格步进器（HANDOFF.md §4.7）：34×34 两格，外框 1px hairline 圆角 12，
/// 中间 1px 分隔，符号 17pt textMid。
struct GymStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        HStack(spacing: 0) {
            button(systemImage: "minus") { value = max(range.lowerBound, value - step) }
            Rectangle()
                .fill(DS.C.hairline)
                .frame(width: 1, height: 34)
            button(systemImage: "plus") { value = min(range.upperBound, value + step) }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DS.C.hairline, lineWidth: 1)
        )
    }

    private func button(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17))
                .foregroundStyle(DS.C.textMid)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    SessionDurationBar(minutes: .constant(60))
        .padding()
}
