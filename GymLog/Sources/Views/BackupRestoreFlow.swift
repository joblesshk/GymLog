import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import GymLogKit

/// 完整备份与恢复的恢复一侧（2026-09-06 审查报告"适合当前范围的功能"第一批）：
/// 选文件 → 解析并校验 → 预览（新增/更新分别多少）→ 确认恢复。镜像
/// `ExcelImportFlow` 的选文件→解析→预览→提交流程结构，但恢复覆盖全部学员/
/// 动作库/模板（不像 Excel 导入那样限定到当前选中的学员），所以放在「設置」而
/// 不是「歷史」里。
struct BackupRestoreFlow: View {
    let onComplete: (Status) -> Void

    enum Status {
        case success(BackupImporter.RestoreResult)
        case failure(String)
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    @State private var showingFilePicker = true
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var parsedFile: BackupFile?
    @State private var previewResult: BackupImporter.PreviewResult?
    @State private var showingPreview = false

    /// Generous multiple of a realistic backup's size (a few hundred KB even
    /// with thousands of sessions) -- same "too big means wrong file, not a
    /// legitimately large export" reasoning as `ExcelImportFlow`'s own cap.
    private static let maxFileSize = 50_000_000

    var body: some View {
        Color.clear
            .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [UTType(filenameExtension: "json") ?? .json]) { result in
                handleFileSelection(result)
            }
            .overlay {
                if isProcessing {
                    ProgressView(language.t("解析中…", "Parsing…"))
                        .padding(16)
                        .background(DS.C.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .sheet(isPresented: $showingPreview, onDismiss: { dismiss() }) {
                if let parsedFile, let previewResult {
                    BackupRestorePreviewSheet(
                        file: parsedFile,
                        preview: previewResult,
                        onConfirm: { commitRestore(parsedFile) },
                        onCancel: { dismiss() }
                    )
                }
            }
            .alert(language.t("恢復失敗", "Restore Failed"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { let wasShowing = errorMessage != nil; errorMessage = nil; if wasShowing { dismiss() } } }
            )) {
                Button(language.t("好", "OK"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func handleFileSelection(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let url):
            guard url.pathExtension.lowercased() == "json" else {
                errorMessage = language.t("請選擇備份 .json 檔案。", "Please choose a backup .json file.")
                return
            }
            let didStartScope = url.startAccessingSecurityScopedResource()
            isProcessing = true
            Task.detached(priority: .userInitiated) {
                defer { if didStartScope { url.stopAccessingSecurityScopedResource() } }
                do {
                    // 2026-09-07 审阅 B10: check the file's size BEFORE
                    // reading its bytes -- the old code read the entire
                    // file into memory first and only rejected it
                    // afterward, so the size check bought no actual memory
                    // protection against a genuinely huge file.
                    let fileSizeValues = try? url.resourceValues(forKeys: [.fileSizeKey])
                    guard let fileSize = fileSizeValues?.fileSize, fileSize < Self.maxFileSize else {
                        await MainActor.run {
                            isProcessing = false
                            errorMessage = language.t("檔案過大，請確認選擇的是正確的備份檔案。", "File too large — please check you selected the right backup file.")
                        }
                        return
                    }
                    let data = try Data(contentsOf: url)
                    let file = try BackupImporter.parse(data)
                    await MainActor.run {
                        isProcessing = false
                        computePreview(file)
                    }
                } catch {
                    await MainActor.run {
                        isProcessing = false
                        errorMessage = Self.describe(error, language: language)
                    }
                }
            }
        }
    }

    private func computePreview(_ file: BackupFile) {
        do {
            let preview = try BackupImporter.preview(file, in: modelContext)
            parsedFile = file
            previewResult = preview
            showingPreview = true
        } catch {
            errorMessage = Self.describe(error, language: language)
        }
    }

    private func commitRestore(_ file: BackupFile) {
        do {
            let result = try BackupImporter.restore(file, into: modelContext)
            onComplete(.success(result))
        } catch {
            onComplete(.failure(Self.describe(error, language: language)))
        }
    }

    private static func describe(_ error: Error, language: AppLanguage) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return language.t("這個檔案看起來不是有效的備份檔案。", "This file doesn't look like a valid backup file.")
    }
}

/// 恢复前的确认预览：按报告要求（"恢复应有格式版本、恢复预览、完整性检查和往返
/// 验证"）明确列出会新增/更新多少条数据，教练确认后才真正写入。
private struct BackupRestorePreviewSheet: View {
    let file: BackupFile
    let preview: BackupImporter.PreviewResult
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(language.t("備份時間", "Backed up at")) {
                        Text(SessionDateFormat.displayWithWeekday.string(from: file.generatedAt))
                    }
                    LabeledContent(language.t("格式版本", "Format version")) {
                        Text("\(file.schemaVersion)")
                    }
                }
                Section {
                    previewRow(language.t("學員", "Clients"), new: preview.newClients, updated: preview.updatedClients)
                    previewRow(language.t("訓練課次", "Sessions"), new: preview.newSessions, updated: preview.updatedSessions)
                    previewRow(language.t("動作庫", "Exercises"), new: preview.newExercises, updated: preview.updatedExercises)
                    previewRow(language.t("模板", "Templates"), new: preview.newTemplates, updated: preview.updatedTemplates)
                } header: {
                    Text(language.t("將會寫入", "Will write"))
                } footer: {
                    Text(language.t(
                        "「更新」指這份備份裡的資料會覆蓋本機上同一 ID 的既有記錄；本機獨有、不在備份裡的資料不會被刪除。",
                        "\"Updated\" means this backup's data will overwrite the existing local record with the same ID; local-only data not in this backup is never deleted."
                    ))
                    .font(.caption)
                    .foregroundStyle(DS.C.textLow)
                }
                // 2026-09-07 审阅 B06: a session whose id already exists
                // locally under a DIFFERENT client than the backup declares
                // is never silently restored -- it's held back and reported
                // here instead. Resolving a specific conflict (choosing to
                // adopt the backup's ownership) isn't wired up in this pass;
                // for now the safe default is "don't touch it".
                if !preview.ownershipConflicts.isEmpty {
                    Section {
                        ForEach(preview.ownershipConflicts, id: \.sessionID) { conflict in
                            Text(conflict.sessionID)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(DS.C.textMid)
                        }
                    } header: {
                        Text(language.t("歸屬衝突，將不會恢復", "Ownership conflicts — will not be restored"))
                    } footer: {
                        Text(language.t(
                            "以上訓練課次在本機屬於另一位學員，備份卻聲稱屬於不同學員。為避免記錯人，這些課次不會被恢復，本機資料保持不變。",
                            "These sessions belong to a different client locally than what the backup declares. To avoid misattribution, they will not be restored — the local records are left untouched."
                        ))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.C.canvas)
            .navigationTitle(language.t("確認恢復", "Confirm Restore"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("取消", "Cancel"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.t("恢復", "Restore"), action: onConfirm)
                        .font(.system(size: 15, weight: .semibold))
                }
            }
        }
    }

    @ViewBuilder
    private func previewRow(_ label: String, new: Int, updated: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(language.t("新增 \(new) · 更新 \(updated)", "\(new) new · \(updated) updated"))
                .foregroundStyle(DS.C.textLow)
                .font(.system(size: 13))
        }
    }
}
