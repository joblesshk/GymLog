import SwiftUI
import GymLogKit

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
