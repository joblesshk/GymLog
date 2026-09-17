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

                if package.originInstallationID == "gymlog-legacy-summary" {
                    Section {
                        Label(language.t(
                            "這是舊版課後摘要。只按明確顯示的單位讀取實績；計劃、熱身／放鬆、訓練塊備註及其他缺失欄位不會補造，目標會保留為待核對。請核對後再匯入。",
                            "This is an older session summary. Only explicitly unit-labeled results are read; missing plans, notes, and other fields are not invented, and targets remain marked for review. Check the preview before importing."
                        ), systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(DS.C.review)
                    }
                }

                Section {
                    ForEach(package.sessions, id: \.recordID) { session in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(language.t("訓練日 \(session.trainingLocalDate)", "Training date \(session.trainingLocalDate)"))
                                    .font(.system(size: 15, weight: .semibold))
                                Spacer()
                                Text(language.t("第 \(session.weekNumber) 週", "Week \(session.weekNumber)"))
                                    .font(.caption)
                                    .foregroundStyle(DS.C.textLow)
                            }
                            ForEach(session.blocks.sorted(by: { $0.order < $1.order }), id: \.order) { block in
                                if block.sectionKind == .wod {
                                    wodPreview(block)
                                }
                                ForEach(block.entries.sorted(by: { $0.order < $1.order }), id: \.order) { entry in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.exerciseRef.canonicalName)
                                            .font(.system(size: 14, weight: .medium))
                                            .accessibilityIdentifier("exchange-preview-exercise-\(entry.exerciseRef.canonicalName)")
                                        ForEach(entry.sets.sorted(by: { $0.setIndex < $1.setIndex }), id: \.setIndex) { set in
                                            valueRow(set: set, label: language.t("目標", "Target"), quantity: set.target)
                                            if package.payloadKind == .results {
                                                valueRow(
                                                    set: set,
                                                    label: language.t("實績", "Actual"),
                                                    quantity: set.actual ?? .unknown(raw: language.t("未記錄", "Not recorded"))
                                                )
                                            }
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("exchange-preview-session-\(session.recordID)")
                    }
                } header: {
                    Text(language.t("內容核對", "Review Contents"))
                } footer: {
                    Text(language.t("這裡只讀顯示即將匯入的日期、動作和數值。", "Read-only preview of the dates, exercises, and values that will be imported."))
                        .font(.caption)
                        .foregroundStyle(DS.C.textLow)
                }

                Section {
                    previewCountRow(language.t("新增課次", "New sessions"), count: preview.newCount)
                    if preview.idempotentCount > 0 {
                        previewCountRow(language.t("已匯入過，將跳過", "Already imported, will skip"), count: preview.idempotentCount)
                            .accessibilityIdentifier("exchange-preview-idempotent-count")
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
                            .accessibilityIdentifier("exchange-preview-client-name-field")
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
                        .accessibilityIdentifier("exchange-preview-new-client-button")
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
                        .accessibilityIdentifier("exchange-preview-cancel-button")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.t("匯入", "Import"), action: confirm)
                        .font(.system(size: 15, weight: .semibold))
                        .disabled(!canConfirm)
                        .accessibilityIdentifier("exchange-preview-confirm-button")
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

    private func valueRow(set: ExchangeSetDTO, label: String, quantity: RepTarget) -> some View {
        HStack(spacing: 5) {
            Text(set.load.displayText)
            Text("×")
                .foregroundStyle(DS.C.textLow)
            Text(quantity.displayText)
            Spacer()
            Text(label)
                .font(.caption2)
                .foregroundStyle(DS.C.textLow)
        }
        .font(.system(size: 13))
    }

    @ViewBuilder
    private func wodPreview(_ block: ExchangeBlockDTO) -> some View {
        if let raw = block.wodPayloadRawJSON,
           let data = raw.data(using: .utf8),
           let payload = try? JSONDecoder().decode(WODPayload.self, from: data) {
            VStack(alignment: .leading, spacing: 2) {
                Text(language.t("WOD", "WOD"))
                    .font(.caption)
                    .foregroundStyle(DS.C.review)
                let lines = WODSummaryFormatter.detailLines(payload)
                ForEach(lines.indices, id: \.self) { index in
                    Text(lines[index])
                        .font(.caption)
                        .foregroundStyle(DS.C.textHi)
                }
            }
        } else {
            Text(language.t("WOD（處方內容無法在此版本核對）", "WOD (prescription cannot be previewed by this version)"))
                .font(.caption)
                .foregroundStyle(DS.C.review)
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
