import SwiftUI
import SwiftData
import GymLogKit

/// 2026-09-16「Superset 模板」-- `ExerciseLibraryView`裡新增的第三個
/// segment，跟 `TemplateLibraryView`("組合模板") 平行，共用同一張
/// `SessionTemplate` 表，只是篩選出 `isSupersetOnly` 的那些（見
/// `SessionTemplate.isSupersetOnly` 的說明）。編輯畫面直接復用既有的
/// `TemplateEditorView`（它的 block-type picker本來就支援 `.superset`），
/// 這裡不需要另外做一套編輯器。
struct SupersetTemplateLibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SessionTemplate.order) private var allTemplates: [SessionTemplate]

    @State private var showingNewSupersetSheet = false
    @State private var navigateToTemplateID: String?
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    private var supersetTemplates: [SessionTemplate] {
        allTemplates.filter { $0.isSupersetOnly }
    }

    var body: some View {
        List {
            if supersetTemplates.isEmpty {
                ContentUnavailableView(
                    language.t("暫無 Superset 模板", "No Superset Templates"),
                    systemImage: "square.on.square",
                    description: Text(language.t("點擊右上角「+」創建第一個 Superset 模板，之後在「今天」添加 Superset 時可直接選用", "Tap \"+\" in the top right to create your first superset template — pick it directly next time you add a superset in Today"))
                )
            } else {
                Section {
                    ForEach(supersetTemplates, id: \.id) { template in
                        NavigationLink {
                            TemplateEditorView(templateID: template.id)
                        } label: {
                            TemplateSummaryRow(template: template)
                        }
                        .listRowBackground(DS.C.surface)
                        .listRowSeparatorTint(DS.C.hairlineSoft)
                    }
                    .onDelete(perform: deleteTemplates)
                } header: {
                    Text(language.t("\(supersetTemplates.count) 個 Superset 模板", "\(supersetTemplates.count) superset templates"))
                        .sectionLabelStyle()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.C.canvas)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingNewSupersetSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.C.onAccent)
                        .frame(width: 32, height: 32)
                        .background(DS.C.accent, in: Circle())
                }
            }
        }
        .sheet(isPresented: $showingNewSupersetSheet) {
            NewSupersetTemplateNameSheet { name in
                let newID = createSupersetTemplate(name: name)
                navigateToTemplateID = newID
            }
        }
        .navigationDestination(item: $navigateToTemplateID) { templateID in
            TemplateEditorView(templateID: templateID)
        }
    }

    /// 跟 `TemplateLibraryView.createTemplate` 不同：這裡除了建立
    /// `SessionTemplate`，還立刻建立一個空的 `.superset` `TemplateBlock`，
    /// 讓教練建立完直接進到編輯畫面加兩個動作，不用自己先去「新增區塊」再
    /// 手動把類型改成 Superset。
    private func createSupersetTemplate(name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newOrder = (allTemplates.map(\.order).max() ?? -1) + 1
        let templateID = "tpl-\(UUID().uuidString.prefix(8))"
        let template = SessionTemplate(
            id: templateID,
            name: trimmed.isEmpty ? language.t("新 Superset 模板", "New Superset Template") : trimmed,
            templateNote: nil,
            order: newOrder
        )
        modelContext.insert(template)
        let block = TemplateBlock(id: "\(templateID)-block0", order: 0, blockType: .superset, restSeconds: 75)
        block.template = template
        modelContext.insert(block)
        try? modelContext.save()
        return templateID
    }

    private func deleteTemplates(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(supersetTemplates[index])
        }
        try? modelContext.save()
    }
}

private struct NewSupersetTemplateNameSheet: View {
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(language.t("模板名稱，如「壺鈴擺盪 + 爬行」", "Template name, e.g. \"KB Swing + Bear Crawl\""), text: $name)
                } footer: {
                    Text(language.t("建立後會直接進入編輯畫面，請在裡面加入這組 Superset 的兩個動作。", "You'll land in the editor right after — add the two exercises for this superset there."))
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.C.canvas)
            .font(DS.F.listRow)
            .foregroundStyle(DS.C.textHi)
            .navigationTitle(language.t("新建 Superset 模板", "New Superset Template"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("取消", "Cancel")) { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.C.textHi)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.t("創建", "Create")) {
                        onCreate(name)
                        dismiss()
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.C.accent)
                }
            }
        }
    }
}
