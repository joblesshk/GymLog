import SwiftUI
import GymLogKit

/// 「從歷史記錄選擇」的挑選頁（2026-09-16）——複製任一天歷史課次的完整
/// 結構（所有區塊、動作與逐輪細節）作為今天的起點，不限於最近一次。只列
/// 這位學員已經**結束**的課次——進行中的課次還不是一份完整的範本，教練要
/// 複製的是練完的那一次，跟 `TodayView.mostRecentSession` 的既有過濾規則
/// 一致。選中後把 `WorkoutSession` 交給呼叫端（`TodayView.startFromCopy`），
/// 這裡本身不碰 `draft`，也不做任何複製邏輯。
struct SessionCopyPickerView: View {
    let client: Client
    let onSelect: (WorkoutSession) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    private var sessions: [WorkoutSession] {
        (client.sessions ?? []).filter { !$0.isInProgress }.sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            List {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        language.t("暫無歷史課次", "No Past Sessions"),
                        systemImage: "clock.arrow.circlepath",
                        description: Text(language.t("這位學員還沒有已結束的訓練課次可以複製", "This client has no finished sessions to copy yet"))
                    )
                } else {
                    ForEach(sessions, id: \.id) { session in
                        Button {
                            onSelect(session)
                            dismiss()
                        } label: {
                            SessionCopyRow(session: session)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(DS.C.surface)
                        .listRowSeparatorTint(DS.C.hairlineSoft)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.C.canvas)
            .navigationTitle(language.t("選擇要複製的課次", "Choose a Session to Copy"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("取消", "Cancel")) { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.C.textHi)
                }
            }
        }
    }
}

private struct SessionCopyRow: View {
    let session: WorkoutSession
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    private var exerciseSummaryText: String {
        let strengthNames = session.orderedBlocks
            .filter { $0.sectionKind != .wod }
            .flatMap(\.orderedEntries)
            .compactMap { $0.exercise?.displayName }
        let wodNames = session.orderedBlocks
            .filter { $0.sectionKind == .wod }
            .compactMap { $0.wodPayload?.prescription.name }
            .filter { !$0.isEmpty }
        let allNames = strengthNames + wodNames
        guard !allNames.isEmpty else { return language.t("（無動作）", "(no exercises)") }
        let shown = Array(allNames.prefix(3))
        let extra = allNames.count - shown.count
        let joined = shown.joined(separator: " · ")
        return extra > 0 ? "\(joined) · +\(extra)" : joined
    }

    private var weekdayText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .zhHant ? "zh_Hant" : "en_US")
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: session.date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(SessionDateFormat.display.string(from: session.date))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(DS.C.textHi)
                Text(weekdayText)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.C.textLow)
                Spacer()
                Text(language.t("第 \(session.weekNumber) 週", "Week \(session.weekNumber)"))
                    .font(.system(size: 11))
                    .foregroundStyle(DS.C.textLow)
            }
            Text(exerciseSummaryText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.C.textMid)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 4)
    }
}
