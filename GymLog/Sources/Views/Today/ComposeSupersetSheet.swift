import SwiftUI
import GymLogKit

/// P1 (2026-09-11)：「從現有動作多選『組成 Superset』」——今天頁已經錄好的
/// 幾個獨立 `.single` 動作，事後選 2+ 個合併成一個 Superset block。獨立的
/// 選取面板而不是在卡片列表上疊一層「選取模式」：後者需要改
/// `BlockDraftCard` 的渲染邏輯（勾選框覆蓋層），前者是一個全新、自帶狀態的
/// `List`，不動任何既有卡片代碼，風險小很多。
///
/// 只列出 `sectionKind == .strength && blockType == .single && entries.count
/// == 1` 的 block——WOD、已經是 Superset/遞減組/循環組的塊不能被隱式並進來
/// （CONTRACT 2026-09-11 P1 §4.1：「跨 WOD 或已有其他組合的成員不隱式合
/// 併」）。
struct ComposeSupersetSheet: View {
    let eligibleBlocks: [BlockDraft]
    var onCompose: (Set<UUID>) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant
    @State private var selection: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(eligibleBlocks) { block in
                        Button {
                            toggle(block.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(block.entries.first?.exercise.displayName ?? "")
                                        .font(DS.F.listRow)
                                        .foregroundStyle(DS.C.textHi)
                                }
                                Spacer()
                                Image(systemName: selection.contains(block.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selection.contains(block.id) ? DS.C.accent : DS.C.textLow)
                            }
                        }
                        .listRowBackground(DS.C.surface)
                        .accessibilityIdentifier("compose-row-\(block.id.uuidString)")
                    }
                } header: {
                    Text(language.t("選 2 個以上的動作，組成一個 Superset", "Select 2 or more exercises to combine into a Superset"))
                        .sectionLabelStyle()
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.C.canvas)
            .navigationTitle(language.t("組成 Superset", "Combine into Superset"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("取消", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.t("組成（\(selection.count)）", "Combine (\(selection.count))")) {
                        onCompose(selection)
                        dismiss()
                    }
                    .disabled(selection.count < 2)
                    .accessibilityIdentifier("compose-confirm-button")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }
}
