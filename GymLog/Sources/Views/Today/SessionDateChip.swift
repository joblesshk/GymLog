import SwiftUI
import GymLogKit

/// GymLog 改版設計 §問題一：課次日期不再是與訓練內容同權重的獨立卡片行，
/// 而是收進頂部導航行、與學員切換 pill 同排靠右。「今天」（最常見狀態）
/// 進一步弱化成純圖示＋文字、無底色；只有設成非今天的日期才顯示醒目一些
/// 的 inset 膠囊。點擊行為不變——彈出日期選擇器，決定這節課歸檔到哪一天。
struct SessionDateChip: View {
    @Binding var date: Date
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant
    @State private var showingPicker = false

    private var isToday: Bool { Calendar.current.isDateInToday(date) }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    var body: some View {
        Button {
            showingPicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                Text(isToday ? language.t("今天", "Today") : dateText)
                    .font(DS.F.subtitle)
                    .fontWeight(isToday ? .semibold : .bold)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(isToday ? DS.C.textLow : DS.C.textMid)
            .padding(.horizontal, isToday ? 4 : 10)
            .padding(.vertical, 6)
            .background(isToday ? Color.clear : DS.C.inset, in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(minWidth: DS.Size.minHit, minHeight: DS.Size.minHit)
        .contentShape(Rectangle())
        // 2026-09-16 修正：這顆 chip 掛在導航行、貼著螢幕邊緣，`.popover` 在
        // iPhone 上即使加了 `.presentationCompactAdaptation(.popover)` 也會
        // 被系統依錨點位置裁切，只露出日曆的一角。改用鋪滿寬度的 `.sheet`
        // （中等高度 detent），不再受錨點位置影響，日曆完整可見。
        .sheet(isPresented: $showingPicker) {
            NavigationStack {
                DatePicker("", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding()
                    .navigationTitle(language.t("課次日期", "Session Date"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(language.t("完成", "Done")) { showingPicker = false }
                        }
                    }
            }
            .presentationDetents([.medium])
        }
        .accessibilityLabel(language.t("課次日期", "Session date"))
        .accessibilityValue(isToday ? language.t("今天", "Today") : dateText)
    }
}
