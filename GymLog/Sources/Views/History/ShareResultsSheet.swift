import SwiftUI
import GymLogKit

/// P2 (2026-09-11) §5.2：歷史頁「分享結果」單選/多選，首版限定同一學員（呼叫
/// 端已經按 `currentClient` 過濾好）、只列已結束課次（進行中的課次不是最終
/// 結果）。結構仿照 P1 `ComposeSupersetSheet.swift` 的 List + 勾選 + 確認
/// 模式。
struct ShareResultsSheet: View {
    let sessions: [WorkoutSession]
    var onShare: ([WorkoutSession]) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant
    @State private var selection: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(sessions) { session in
                        Button {
                            toggle(session.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(SessionDateFormat.display.string(from: session.date))
                                        .font(DS.F.listRow)
                                        .foregroundStyle(DS.C.textHi)
                                    Text(language.t("\(session.orderedBlocks.count) 個訓練塊", "\(session.orderedBlocks.count) block(s)"))
                                        .font(DS.F.subtitle)
                                        .foregroundStyle(DS.C.textLow)
                                }
                                Spacer()
                                Image(systemName: selection.contains(session.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selection.contains(session.id) ? DS.C.accent : DS.C.textLow)
                            }
                        }
                        .listRowBackground(DS.C.surface)
                        .accessibilityIdentifier("share-results-row-\(session.id)")
                    }
                } header: {
                    Text(language.t("選擇要分享的課次", "Select sessions to share"))
                        .sectionLabelStyle()
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.C.canvas)
            .navigationTitle(language.t("分享結果", "Share Results"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("取消", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.t("分享（\(selection.count)）", "Share (\(selection.count))")) {
                        onShare(sessions.filter { selection.contains($0.id) })
                        dismiss()
                    }
                    .disabled(selection.isEmpty)
                    .accessibilityIdentifier("share-results-confirm-button")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }
}
