import SwiftUI
import GymLogKit

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
