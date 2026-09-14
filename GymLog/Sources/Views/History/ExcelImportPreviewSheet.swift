import SwiftUI
import GymLogKit

/// CONTRACT-M7.md §3.10: shown before commit, using the SAME
/// `XLSXHistoryImporter.importSessions(preview: true)` counts the actual
/// commit will produce -- never a separately-estimated number.
struct ExcelImportPreviewSheet: View {
    let fileName: String
    let clientName: String
    /// `true` when this import created a brand-new client (the workbook's
    /// `Info` sheet named someone not already in the app) rather than
    /// writing into an existing one.
    let isNewClient: Bool
    let sheetNames: [String]
    let sessionCount: Int
    let dateRangeText: String?
    let result: XLSXHistoryImporter.ImportResult
    /// Exercises the workbook referenced that weren't already in the
    /// library and were auto-created (always flagged for review) rather
    /// than asking the coach to confirm each one.
    let newExerciseCount: Int
    let exercisesNeedingReview: Int
    let sessionsNeedingReview: Int
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(language.t("檔案", "File")) { Text(fileName).foregroundStyle(DS.C.textLow) }
                    // Largest, most prominent field on the screen -- this is
                    // CONTRACT-M7.md §9.2's front line of defense against
                    // importing into the wrong client's history.
                    VStack(alignment: .leading, spacing: 2) {
                        Text(language.t("學員", "Client"))
                            .font(DS.F.subtitle)
                            .foregroundStyle(DS.C.textLow)
                        HStack(spacing: 6) {
                            Text(clientName)
                                .font(DS.F.pageTitle)
                                .foregroundStyle(DS.C.textHi)
                            if isNewClient {
                                Text(language.t("新建", "New"))
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(DS.C.accent.opacity(0.15), in: Capsule())
                                    .foregroundStyle(DS.C.accent)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    if isNewClient {
                        Text(language.t(
                            "Excel 裡的學員姓名和目前選擇的學員不同，將新建這位學員並把資料導入到 TA 名下。",
                            "The workbook's client name doesn't match the one currently selected — a new client will be created and this data imported under them."
                        ))
                        .font(.system(size: 12))
                        .foregroundStyle(DS.C.textLow)
                    }
                    LabeledContent(language.t("工作表", "Sheets")) { Text(sheetNames.joined(separator: "、")).foregroundStyle(DS.C.textLow) }
                    if let dateRangeText {
                        LabeledContent(language.t("課次", "Sessions")) {
                            Text(language.t("\(sessionCount) 節（\(dateRangeText)）", "\(sessionCount) (\(dateRangeText))"))
                                .foregroundStyle(DS.C.textLow)
                        }
                    } else {
                        LabeledContent(language.t("課次", "Sessions")) { Text("\(sessionCount)").foregroundStyle(DS.C.textLow) }
                    }
                }

                if result.possiblyWrongClient {
                    Section {
                        Label(
                            language.t(
                                "這個檔案的大部分課次已經在其他學員名下，確定要導入到「\(clientName)」嗎？",
                                "Most sessions in this file already exist under a different client. Import to \"\(clientName)\" anyway?"
                            ),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(DS.C.danger)
                    }
                    .listRowBackground(DS.C.surface)
                }

                Section {
                    statRow(language.t("新增課次", "New Sessions"), result.newSessions, tint: DS.C.accent)
                    statRow(language.t("已存在", "Unchanged"), result.existingSessions, tint: DS.C.textLow)
                    statRow(language.t("已更新", "Updated"), result.updatedSessions, tint: DS.C.accent)
                    statRow(language.t("衝突", "Conflicts"), result.conflictedSessions, tint: result.conflictedSessions > 0 ? DS.C.danger : DS.C.textLow)
                    if newExerciseCount > 0 {
                        statRow(language.t("新增動作", "New Exercises"), newExerciseCount, tint: DS.C.accent)
                    }
                } header: {
                    Text(language.t("導入結果預覽", "Import Preview")).sectionLabelStyle()
                } footer: {
                    if newExerciseCount > 0 {
                        Text(language.t(
                            "動作庫裡沒有的動作名稱會自動新建（標記待復核），不需要逐項確認。",
                            "Exercise names not already in the library are created automatically (flagged for review) — no per-item confirmation needed."
                        ))
                    }
                }

                if exercisesNeedingReview > 0 || sessionsNeedingReview > 0 {
                    Section {
                        if exercisesNeedingReview > 0 {
                            statRow(language.t("待複核動作", "Exercises to Review"), exercisesNeedingReview, tint: DS.C.textLow)
                        }
                        if sessionsNeedingReview > 0 {
                            statRow(language.t("待複核課次", "Sessions to Review"), sessionsNeedingReview, tint: DS.C.textLow)
                        }
                    } footer: {
                        Text(language.t(
                            "這些項目已正常導入，僅標記供之後複核（如日期笔误、動作分類不確定等）。",
                            "These already imported normally -- they're only flagged for later review (e.g. a data-entry date slip, uncertain exercise classification)."
                        ))
                    }
                }

                if result.conflictedSessions > 0 {
                    Section {
                        Text(language.t(
                            "衝突課次在 App 裡和 Excel 裡都被修改過，本次將跳過，不會覆蓋你在 App 裡的修改。",
                            "Conflicted sessions were edited both in the app and in Excel -- they'll be skipped, your in-app edits are safe."
                        ))
                        .foregroundStyle(DS.C.textLow)
                    }
                    .listRowBackground(DS.C.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.C.canvas)
            .navigationTitle(language.t("導入預覽", "Import Preview"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("取消", "Cancel")) { dismiss() }
                        .foregroundStyle(DS.C.textHi)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.t("確認導入", "Import")) {
                        onConfirm()
                        dismiss()
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.C.accent)
                }
            }
        }
    }

    @ViewBuilder
    private func statRow(_ label: String, _ value: Int, tint: Color) -> some View {
        LabeledContent(label) {
            Text("\(value)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}
