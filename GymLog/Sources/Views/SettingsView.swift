import SwiftUI
import SwiftData
import GymLogKit

/// 外观（主题）与语言切换。
struct SettingsView: View {
    @Bindable var clientStore: CurrentClientStore
    let switchCoordinator: ClientSwitchCoordinator

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Client.name) private var clients: [Client]
    @Query(sort: \Exercise.canonicalName) private var allExercises: [Exercise]
    @AppStorage("appTheme") private var theme: AppTheme = .system
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    // 完整备份与恢复（2026-09-06 审查报告"适合当前范围的功能"第一批）。
    @State private var exportedBackupURL: URL?
    @State private var backupExportErrorMessage: String?
    @State private var showingBackupRestoreFlow = false
    @State private var backupRestoreResultMessage: String?
    @State private var backupRestoreErrorMessage: String?

    // P2 (2026-09-11)：教练学员互传的「從文件匯入」兜底入口——某个第三方
    // 渠道不能直接打开附件（触发 `.onOpenURL`）时仍可用。
    @State private var showingExchangeImportFlow = false
    @State private var exchangePasteRequest: ExchangePasteSheetRequest?
    @State private var exchangeImportResultMessage: String?
    @State private var exchangeImportErrorMessage: String?

    private var currentClient: Client? {
        clientStore.currentClient(in: clients)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(AppTheme.allCases, id: \.self) { option in
                        Button {
                            theme = option
                        } label: {
                            HStack {
                                Text(option.label)
                                    .font(.system(size: 15, weight: theme == option ? .semibold : .medium))
                                    .foregroundStyle(DS.C.textHi)
                                Spacer()
                                if theme == option {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 17, weight: .medium))
                                        .foregroundStyle(DS.C.accent)
                                }
                            }
                        }
                        .listRowBackground(DS.C.surface)
                    }
                    ThemePreviewRow(selected: theme)
                        .listRowBackground(DS.C.surface)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                } header: {
                    Text(language.t("外觀", "Appearance"))
                        .sectionLabelStyle()
                }

                Section {
                    ForEach(AppLanguage.allCases) { option in
                        Button {
                            language = option
                        } label: {
                            HStack {
                                Text(option.label)
                                    .font(.system(size: 15, weight: language == option ? .semibold : .medium))
                                    .foregroundStyle(DS.C.textHi)
                                Spacer()
                                if language == option {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 17, weight: .medium))
                                        .foregroundStyle(DS.C.accent)
                                }
                            }
                        }
                        .listRowBackground(DS.C.surface)
                    }
                } header: {
                    Text(language.t("語言", "Language"))
                        .sectionLabelStyle()
                }

                Section {
                    Button {
                        exportBackup()
                    } label: {
                        Label(language.t("導出完整備份", "Export Full Backup"), systemImage: "square.and.arrow.up")
                    }
                    .listRowBackground(DS.C.surface)

                    Button {
                        showingBackupRestoreFlow = true
                    } label: {
                        Label(language.t("從備份恢復", "Restore from Backup"), systemImage: "square.and.arrow.down")
                    }
                    .listRowBackground(DS.C.surface)
                } header: {
                    Text(language.t("備份與恢復", "Backup & Restore"))
                        .sectionLabelStyle()
                } footer: {
                    Text(language.t(
                        "一份備份文件包含全部學員、體測、訓練記錄、動作庫及模板，可用於換機恢復。恢復不會刪除本機現有資料，只會新增或按 ID 更新。",
                        "One backup file contains every client, body metric, training record, exercise library entry, and template — restore it after switching devices. Restoring never deletes existing local data; it only adds or updates by ID."
                    ))
                    .foregroundStyle(DS.C.textLow)
                }

                Section {
                    Button {
                        showingExchangeImportFlow = true
                    } label: {
                        Label(language.t("從文件匯入分享的計劃/結果", "Import a Shared Plan/Results"), systemImage: "square.and.arrow.down.on.square")
                    }
                    .listRowBackground(DS.C.surface)
                    .accessibilityIdentifier("exchange-import-from-file-button")
                    Button {
                        exchangePasteRequest = ExchangePasteSheetRequest()
                    } label: {
                        Label(language.t("貼上分享文字", "Paste Shared Text"), systemImage: "doc.on.clipboard")
                    }
                    .listRowBackground(DS.C.surface)
                    .accessibilityIdentifier("exchange-paste-button")
                } header: {
                    Text(language.t("教練學員互傳", "Coach/Student Exchange"))
                        .sectionLabelStyle()
                } footer: {
                    Text(language.t(
                        "打開對方 AirDrop 或訊息傳來的 .gymlogshare、JSON 或純文字檔案通常會直接彈出匯入預覽；這裡是手動選擇檔案的備用入口。",
                        "Opening a .gymlogshare, JSON, or plain-text file someone AirDropped or messaged you usually opens the import preview directly — this is a manual fallback for picking a file yourself."
                    ))
                    .foregroundStyle(DS.C.textLow)
                }

                Section {
                    LabeledContent {
                        Text(AppVersion.displayString)
                            .font(.system(size: 15, weight: .medium).monospacedDigit())
                            .foregroundStyle(DS.C.textLow)
                            .textSelection(.enabled)
                    } label: {
                        Text(language.t("版本", "Version"))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(DS.C.textHi)
                    }
                    .listRowBackground(DS.C.surface)
                } header: {
                    Text(language.t("關於", "About"))
                        .sectionLabelStyle()
                } footer: {
                    Text(language.t(
                        "括號中是構建號。回報問題時附上這一行，可以確認裝的是哪一版。",
                        "The number in brackets is the build. Quote this line when reporting a problem so the exact build is known."
                    ))
                    .foregroundStyle(DS.C.textLow)
                }

                // 2026-09-13：雲端語音刻意放在設置頁最後一個 Section——它是
                // 純參考用途、使用頻率最低的內容，排在這裡不會把上面既有的
                // 「備份與恢復」「教練學員互傳」「關於」等操作入口往下擠出
                // List 首屏渲染範圍（SwiftUI List 在真機/模擬器上對超出首屏
                // 的行有懶加載行為，XCUITest 的 `waitForExistence` 不會自動
                // 先滾動）。
                Section {
                    NavigationLink("雲端語音設定", destination: CloudVoiceSettingsView())
                } header: {
                    Text(language.t("雲端語音", "Cloud Voice"))
                        .sectionLabelStyle()
                } footer: {
                    Text(language.t(
                        "設定語音識別與指令理解服務。密鑰保存在本機鑰匙串。",
                        "Configure cloud speech and command services. Credentials stay in the local Keychain."
                    ))
                    .font(.caption)
                    .foregroundStyle(DS.C.textLow)
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.C.canvas)
            .reserveFloatingTabBarSpace()
            .navigationTitle(language.t("設置", "Settings"))
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if let client = currentClient {
                        ClientSwitcherButton(currentClient: client, coordinator: switchCoordinator)
                    }
                }
            }
            .sheet(isPresented: Binding(get: { exportedBackupURL != nil }, set: { if !$0 { exportedBackupURL = nil } })) {
                if let exportedBackupURL {
                    ActivityShareSheet(activityItems: [exportedBackupURL])
                }
            }
            .sheet(isPresented: $showingBackupRestoreFlow) {
                BackupRestoreFlow { status in
                    switch status {
                    case .success(let result):
                        var message = language.t(
                            "已恢復 \(result.clientsWritten) 位學員 · \(result.sessionsWritten) 個課次 · \(result.exercisesWritten) 個動作 · \(result.templatesWritten) 個模板",
                            "Restored \(result.clientsWritten) client(s) · \(result.sessionsWritten) session(s) · \(result.exercisesWritten) exercise(s) · \(result.templatesWritten) template(s)"
                        )
                        // 2026-09-07 审阅 B06: skipped-due-to-conflict counts
                        // must stay visible in the final result, not just the
                        // pre-commit preview -- otherwise "恢复完成" reads as
                        // if everything in the file was restored.
                        if result.sessionsSkippedDueToOwnershipConflict > 0 || result.otherEntitiesSkippedDueToOwnershipConflict > 0 {
                            message += language.t(
                                "\n因歸屬衝突跳過：\(result.sessionsSkippedDueToOwnershipConflict) 個課次、\(result.otherEntitiesSkippedDueToOwnershipConflict) 項其他記錄。",
                                "\nSkipped due to ownership conflicts: \(result.sessionsSkippedDueToOwnershipConflict) session(s), \(result.otherEntitiesSkippedDueToOwnershipConflict) other record(s)."
                            )
                        }
                        backupRestoreResultMessage = message
                    case .failure(let message):
                        backupRestoreErrorMessage = message
                    }
                }
            }
            .alert(language.t("導出失敗", "Export Failed"), isPresented: Binding(get: { backupExportErrorMessage != nil }, set: { if !$0 { backupExportErrorMessage = nil } })) {
                Button(language.t("好", "OK"), role: .cancel) {}
            } message: {
                Text(backupExportErrorMessage ?? "")
            }
            .alert(language.t("恢復完成", "Restore Complete"), isPresented: Binding(get: { backupRestoreResultMessage != nil }, set: { if !$0 { backupRestoreResultMessage = nil } })) {
                Button(language.t("好", "OK"), role: .cancel) {}
            } message: {
                Text(backupRestoreResultMessage ?? "")
            }
            .alert(language.t("恢復失敗", "Restore Failed"), isPresented: Binding(get: { backupRestoreErrorMessage != nil }, set: { if !$0 { backupRestoreErrorMessage = nil } })) {
                Button(language.t("好", "OK"), role: .cancel) {}
            } message: {
                Text(backupRestoreErrorMessage ?? "")
            }
            .sheet(isPresented: $showingExchangeImportFlow) {
                ExchangeImportFlow(allowsTextFiles: true) { status in
                    switch status {
                    case .success(let result):
                        var message = language.t(
                            "已匯入 \(result.sessionsWritten) 個課次",
                            "Imported \(result.sessionsWritten) session(s)"
                        )
                        if result.exercisesCreated > 0 {
                            message += language.t("，新建 \(result.exercisesCreated) 個動作", ", created \(result.exercisesCreated) exercise(s)")
                        }
                        if result.sessionsSkippedIdempotent > 0 {
                            message += language.t("\n\(result.sessionsSkippedIdempotent) 個課次已匯入過，已跳過", "\n\(result.sessionsSkippedIdempotent) session(s) already imported, skipped")
                        }
                        if result.sessionsSkippedContentChanged > 0 {
                            message += language.t("\n\(result.sessionsSkippedContentChanged) 個課次內容有更新，保留本機版本", "\n\(result.sessionsSkippedContentChanged) session(s) had updated content — local version kept")
                        }
                        exchangeImportResultMessage = message
                    case .failure(let message):
                        exchangeImportErrorMessage = message
                    case .cancelled:
                        break
                    }
                }
            }
            .sheet(item: $exchangePasteRequest) { _ in
                ExchangePasteSheet { status in
                    handleExchangeStatus(status)
                }
            }
            .alert(language.t("匯入完成", "Import Complete"), isPresented: Binding(get: { exchangeImportResultMessage != nil }, set: { if !$0 { exchangeImportResultMessage = nil } })) {
                Button(language.t("好", "OK"), role: .cancel) {}
            } message: {
                Text(exchangeImportResultMessage ?? "")
            }
            .alert(language.t("匯入失敗", "Import Failed"), isPresented: Binding(get: { exchangeImportErrorMessage != nil }, set: { if !$0 { exchangeImportErrorMessage = nil } })) {
                Button(language.t("好", "OK"), role: .cancel) {}
            } message: {
                Text(exchangeImportErrorMessage ?? "")
            }
        }
    }

    private func exportBackup() {
        do {
            exportedBackupURL = try BackupExporter.writeTempFile(from: modelContext)
        } catch {
            backupExportErrorMessage = error.localizedDescription
        }
    }

    private func handleExchangeStatus(_ status: ExchangeImportFlow.Status) {
        switch status {
        case .success(let result):
            var message = language.t("已匯入 \(result.sessionsWritten) 個課次", "Imported \(result.sessionsWritten) session(s)")
            if result.exercisesCreated > 0 { message += language.t("，新建 \(result.exercisesCreated) 個動作", ", created \(result.exercisesCreated) exercise(s)") }
            if result.sessionsSkippedIdempotent > 0 { message += language.t("\n\(result.sessionsSkippedIdempotent) 個課次已匯入過，已跳過", "\n\(result.sessionsSkippedIdempotent) session(s) already imported, skipped") }
            if result.sessionsSkippedContentChanged > 0 { message += language.t("\n\(result.sessionsSkippedContentChanged) 個課次內容有更新，保留本機版本", "\n\(result.sessionsSkippedContentChanged) session(s) had updated content — local version kept") }
            exchangeImportResultMessage = message
        case .failure(let message): exchangeImportErrorMessage = message
        case .cancelled: break
        }
    }
}

private struct ExchangePasteSheetRequest: Identifiable {
    let id = UUID()
}

private struct ExchangePasteSheet: View {
    private enum Stage {
        case editing
        case importing(String)
    }

    let onComplete: (ExchangeImportFlow.Status) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant
    @State private var text = ""
    @State private var stage: Stage = .editing

    var body: some View {
        Group {
            switch stage {
            case .editing:
                NavigationStack {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(language.t(
                            "可貼上 GymLog 聊天分享文字，或直接貼上舊版摘要。系統會先解析並顯示預覽，確認後才寫入。",
                            "Paste a GymLog chat message or a supported older summary. GymLog will preview it before anything is saved."
                        ))
                        .font(.footnote)
                        .foregroundStyle(DS.C.textLow)
                        TextEditor(text: $text)
                            .font(.system(.body, design: .monospaced))
                            .padding(8)
                            .background(DS.C.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .accessibilityIdentifier("exchange-paste-text-editor")
                        Button {
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            stage = .importing(trimmed)
                        } label: {
                            Label(language.t("解析並預覽", "Parse and Preview"), systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.gymPrimary)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("exchange-paste-parse-button")
                        Spacer()
                    }
                    .padding(16)
                    .background(DS.C.canvas)
                    .navigationTitle(language.t("貼上分享文字", "Paste Shared Text"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(language.t("取消", "Cancel")) { dismiss() }
                        }
                    }
                }
            case .importing(let text):
                ExchangeImportFlow(initialText: text, onComplete: onComplete)
            }
        }
    }
}

/// 主题缩略预览卡（HANDOFF.md §5）：标题条 + 药丸 + accent 条的抽象示意，
/// 分别以浅色/深色渲染，当前选中的一张加 2px accent 边框。
private struct ThemePreviewRow: View {
    let selected: AppTheme

    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    var body: some View {
        HStack(spacing: 10) {
            ThemePreviewCard(
                scheme: .light,
                isSelected: selected == .light,
                accessibilityName: language.t("淺色外觀預覽", "Light appearance preview")
            )
            ThemePreviewCard(
                scheme: .dark,
                isSelected: selected == .dark,
                accessibilityName: language.t("深色外觀預覽", "Dark appearance preview")
            )
        }
    }
}

private struct ThemePreviewCard: View {
    let scheme: ColorScheme
    let isSelected: Bool
    let accessibilityName: String

    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    private var bg: Color { scheme == .dark ? Color(hex: "#181C21") : Color(hex: "#FFFFFF") }
    private var canvas: Color { scheme == .dark ? Color(hex: "#0E1013") : Color(hex: "#F6F2EA") }
    private var line: Color { scheme == .dark ? Color(hex: "#2C333A") : Color(hex: "#E7E0D3") }
    private var text: Color { scheme == .dark ? Color(hex: "#F4F6F3") : Color(hex: "#1A2B25") }
    private var accent: Color { scheme == .dark ? Color(hex: "#C7ED3E") : Color(hex: "#C05A2E") }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(text)
                .frame(width: 34, height: 6)
            Capsule()
                .fill(bg)
                .overlay(Capsule().stroke(line, lineWidth: 1))
                .frame(width: 48, height: 12)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accent)
                .frame(width: 40, height: 4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? DS.C.accent : line, lineWidth: isSelected ? 2 : 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(isSelected ? language.t("已選取", "Selected") : language.t("未選取", "Not selected"))
    }
}

private extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: h).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
