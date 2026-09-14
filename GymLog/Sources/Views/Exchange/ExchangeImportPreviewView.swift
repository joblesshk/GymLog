import SwiftUI
import GymLogKit

/// §5.2 分享預覽: 學員、日期、課次數、包含欄位；§5.3 學員映射（已有明確映射
/// 自動預選，仍顯示歸屬，允許改選/新建）；衝突摘要用本輪確認過的簡化版——
/// 一行"N 條因內容更新被跳過，保留本地版本"，不做字段級對比/替換/另存
/// 選擇器。
struct ExchangeImportPreviewView: View {
    let package: ExchangePackage
    let preview: ExchangeImporter.PreviewResult
    let clients: [Client]
    /// Called with the resolved target `Client.id` once the coach confirms
    /// -- a brand-new client is inserted (and saved) by this view itself
    /// before calling, so the id passed here always already exists.
    var onConfirm: (String) -> Void
    var onCancel: () -> Void

    @Environment(\.modelContext) private var modelContext
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    @State private var selectedClientID: String?
    @State private var showingNewClientField = false
    @State private var newClientName = ""
    @State private var clientCreationError: String?

    private var payloadKindLabel: String {
        package.payloadKind == .plan ? language.t("今天計劃", "Today's Plan") : language.t("歷史結果", "History Results")
    }

    private var canConfirm: Bool {
        showingNewClientField ? !newClientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : selectedClientID != nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(language.t("來自學員", "From client")) {
                        Text(package.client.displayName)
                    }
                    LabeledContent(language.t("內容", "Contents")) {
                        Text(payloadKindLabel)
                    }
                    LabeledContent(language.t("課次數", "Sessions")) {
                        Text("\(package.sessions.count)")
                    }
                    LabeledContent(language.t("格式版本", "Format version")) {
                        Text("\(package.formatVersion)")
                    }
                } header: {
                    Text(language.t("這個檔案裡有什麼", "What's in this file"))
                }

                Section {
                    previewCountRow(language.t("新增課次", "New sessions"), count: preview.newCount)
                    if preview.idempotentCount > 0 {
                        previewCountRow(language.t("已匯入過，將跳過", "Already imported, will skip"), count: preview.idempotentCount)
                    }
                    if preview.contentChangedCount > 0 {
                        previewCountRow(language.t("內容有更新，保留本地版本", "Content updated, local version kept"), count: preview.contentChangedCount)
                    }
                    if preview.willCreateExerciseCount > 0 {
                        previewCountRow(language.t("將新建動作", "Exercises to create"), count: preview.willCreateExerciseCount)
                    }
                } header: {
                    Text(language.t("匯入預覽", "Import preview"))
                } footer: {
                    if preview.contentChangedCount > 0 {
                        Text(language.t(
                            "「內容有更新」的課次本機已有較舊版本、對方這次的內容不完全一樣——本輪一律保留本機版本，不會被覆蓋。",
                            "Sessions marked \"content updated\" already exist locally with different content — this version always keeps the local copy; it will not be overwritten."
                        ))
                        .font(.caption)
                        .foregroundStyle(DS.C.textLow)
                    }
                }

                Section {
                    if showingNewClientField {
                        TextField(language.t("學員姓名", "Client name"), text: $newClientName)
                        Button(language.t("改為選擇既有學員", "Choose an existing client instead")) {
                            showingNewClientField = false
                        }
                        .font(.system(size: 13))
                    } else {
                        Picker(language.t("匯入到哪位學員", "Import to which client"), selection: $selectedClientID) {
                            Text(language.t("請選擇", "Choose one")).tag(String?.none)
                            ForEach(clients) { client in
                                Text(client.displayName).tag(String?.some(client.id))
                            }
                        }
                        Button(language.t("新建學員", "New client")) {
                            showingNewClientField = true
                        }
                        .font(.system(size: 13))
                    }
                } header: {
                    Text(language.t("歸屬學員", "Assign to client"))
                } footer: {
                    if preview.mappedLocalClientID != nil {
                        Text(language.t(
                            "已根據先前的匯入記憶，自動選中對應的本機學員。",
                            "Pre-selected based on a mapping remembered from a previous import."
                        ))
                        .font(.caption)
                        .foregroundStyle(DS.C.textLow)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.C.canvas)
            .navigationTitle(language.t("確認匯入", "Confirm Import"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("取消", "Cancel"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.t("匯入", "Import"), action: confirm)
                        .font(.system(size: 15, weight: .semibold))
                        .disabled(!canConfirm)
                }
            }
            .alert(language.t("無法建立學員", "Couldn't Create Client"), isPresented: Binding(
                get: { clientCreationError != nil }, set: { if !$0 { clientCreationError = nil } }
            )) {
                Button(language.t("好", "OK"), role: .cancel) {}
            } message: {
                Text(clientCreationError ?? "")
            }
        }
        .onAppear {
            selectedClientID = preview.mappedLocalClientID
        }
    }

    @ViewBuilder
    private func previewCountRow(_ label: String, count: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(count)")
                .foregroundStyle(DS.C.textLow)
                .font(.system(size: 13, weight: .medium))
        }
    }

    private func confirm() {
        if showingNewClientField {
            let trimmed = newClientName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let client = Client(id: "cl-exchange-\(UUID().uuidString)", name: trimmed)
            modelContext.insert(client)
            do {
                try modelContext.save()
                onConfirm(client.id)
            } catch {
                modelContext.rollback()
                clientCreationError = error.localizedDescription
            }
        } else if let selectedClientID {
            onConfirm(selectedClientID)
        }
    }
}
