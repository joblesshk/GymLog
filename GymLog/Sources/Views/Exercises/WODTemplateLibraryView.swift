import SwiftUI
import SwiftData
import GymLogKit

/// 2026-09-17「WOD 模板」-- `ExerciseLibraryView` 裡第四個 segment，跟
/// `TemplateLibraryView`("組合模板")、`SupersetTemplateLibraryView"("Superset
/// 模板") 平行，同樣共用 `SessionTemplate` 表，只是篩選出 `isWODOnly` 的那些
/// （見 `SessionTemplate.isWODOnly`）。種子資料是 14 個網上最知名的 CrossFit
/// 基準 WOD（Fran/Grace/Helen/…/Murph/DT/Jackie），見
/// `Resources/template_seed.json`。
///
/// 跟 `SupersetTemplateLibraryView` 不同的地方：這裡沒有「+」新建入口。自訂
/// 一支 WOD（處方的輪次/動作/形式/計分規則）需要一整套 WOD 編輯 UI，
/// `TemplateEditorView` 現有的區塊編輯器只認識動作 slot，不認識 WOD 處方
/// ——教練目前若想要自訂 WOD 模板，仍然是在「今天」用既有的
/// `WODBlockDraftCard` 現場編（本次需求只要求把網上知名的 WOD 放進庫裡，
/// 沒有要求新建自訂 WOD 模板的編輯器，所以這裡刻意不做半套）。
struct WODTemplateLibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SessionTemplate.order) private var allTemplates: [SessionTemplate]
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    private var wodTemplates: [SessionTemplate] {
        allTemplates.filter { $0.isWODOnly }
    }

    var body: some View {
        List {
            if wodTemplates.isEmpty {
                ContentUnavailableView(
                    language.t("暫無 WOD 模板", "No WOD Templates"),
                    systemImage: "flame",
                    description: Text(language.t("知名的 CrossFit 基準 WOD 會顯示在這裡", "Well-known CrossFit benchmark WODs will appear here"))
                )
            } else {
                Section {
                    ForEach(wodTemplates, id: \.id) { template in
                        NavigationLink {
                            WODTemplateDetailView(template: template)
                        } label: {
                            WODTemplateSummaryRow(template: template)
                        }
                        .listRowBackground(DS.C.surface)
                        .listRowSeparatorTint(DS.C.hairlineSoft)
                    }
                    .onDelete(perform: deleteTemplates)
                } header: {
                    Text(language.t("\(wodTemplates.count) 個 WOD 模板", "\(wodTemplates.count) WOD templates"))
                        .sectionLabelStyle()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.C.canvas)
    }

    private func deleteTemplates(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(wodTemplates[index])
        }
        try? modelContext.save()
    }
}

private struct WODTemplateSummaryRow: View {
    let template: SessionTemplate
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    private var prescription: WODPrescription? {
        template.orderedBlocks.first?.wodPrescription
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(template.name)
                .font(DS.F.cardTitle)
                .foregroundStyle(DS.C.textHi)
            if let prescription {
                Text(WODTemplateFormatting.summaryLine(prescription, language: language))
                    .font(DS.F.subtitle)
                    .foregroundStyle(DS.C.textLow)
            }
            if let note = template.templateNote, !note.isEmpty {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.C.textMid)
                    .lineLimit(2)
            }
        }
    }
}

/// 唯讀詳情頁——只顯示處方內容（形式、計時上限、每輪動作/次數/重量、計分
/// 規則、標準備註），不提供編輯，理由見本檔案頂部說明。
private struct WODTemplateDetailView: View {
    let template: SessionTemplate
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    private var prescription: WODPrescription? {
        template.orderedBlocks.first?.wodPrescription
    }

    var body: some View {
        List {
            if let prescription {
                Section {
                    LabeledContent(language.t("形式", "Format"), value: prescription.format.displayName)
                    if let cap = prescription.timeCapSeconds {
                        LabeledContent(language.t("時間上限", "Time Cap"), value: WODTemplateFormatting.formatSeconds(cap))
                    }
                    LabeledContent(language.t("計分方式", "Scoring"), value: WODTemplateFormatting.scoringDisplayName(prescription.scoringRule, language: language))
                }
                .listRowBackground(DS.C.surface)

                ForEach(prescription.rounds, id: \.roundIndex) { round in
                    Section {
                        ForEach(round.movements, id: \.stepID) { movement in
                            HStack {
                                Text(movement.exerciseNameSnapshot)
                                    .font(DS.F.listRow)
                                    .foregroundStyle(DS.C.textHi)
                                Spacer()
                                Text(WODTemplateFormatting.movementDetail(movement))
                                    .font(.system(size: 13))
                                    .foregroundStyle(DS.C.textLow)
                            }
                            .listRowBackground(DS.C.surface)
                        }
                    } header: {
                        if prescription.rounds.count > 1 {
                            Text(language.t("第 \(round.roundIndex + 1) 輪", "Round \(round.roundIndex + 1)"))
                                .sectionLabelStyle()
                        }
                    }
                }

                if let notes = prescription.standardNotes, !notes.isEmpty {
                    Section {
                        Text(notes)
                            .font(.system(size: 13))
                            .foregroundStyle(DS.C.textMid)
                    } header: {
                        Text(language.t("標準備註", "Standard Notes"))
                            .sectionLabelStyle()
                    }
                    .listRowBackground(DS.C.surface)
                }
            } else {
                ContentUnavailableView(
                    language.t("此模板沒有可顯示的 WOD 處方", "This template has no displayable WOD prescription"),
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.C.canvas)
        .navigationTitle(template.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum WODTemplateFormatting {
    static func summaryLine(_ prescription: WODPrescription, language: AppLanguage) -> String {
        var parts = [prescription.format.displayName]
        if let cap = prescription.timeCapSeconds {
            parts.append(formatSeconds(cap))
        }
        let movementCount = Set(prescription.rounds.flatMap { $0.movements.map(\.exerciseNameSnapshot) }).count
        parts.append(language.t("\(movementCount) 個動作", "\(movementCount) movements"))
        return parts.joined(separator: " · ")
    }

    static func scoringDisplayName(_ rule: WODScoringRule, language: AppLanguage) -> String {
        switch rule {
        case .completionTime: return language.t("計時完成", "Completion Time")
        case .roundsAndReps: return language.t("輪數＋次數", "Rounds + Reps")
        case .totalQuantity: return language.t("總量", "Total Quantity")
        case .worstInterval: return language.t("最差一輪", "Worst Interval")
        case .manual: return language.t("手動記錄", "Manual")
        case .unknown: return language.t("未知", "Unknown")
        }
    }

    static func movementDetail(_ movement: WODMovementPrescription) -> String {
        var text = movement.quantity.displayText
        if let load = movement.load {
            text += " · \(load.raw)"
        }
        if let standard = movement.standard, !standard.isEmpty {
            text += " · \(standard)"
        }
        return text
    }

    static func formatSeconds(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remaining = seconds % 60
        return remaining == 0 ? "\(minutes) min" : "\(minutes):\(String(format: "%02d", remaining))"
    }
}
