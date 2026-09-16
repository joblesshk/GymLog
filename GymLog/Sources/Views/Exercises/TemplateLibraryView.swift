import SwiftUI
import SwiftData
import GymLogKit

/// CONTRACT-M4.md §6.2's "组合模板" segment content, mounted inside
/// `ExerciseLibraryView`'s existing `NavigationStack` (not its own stack --
/// see that file's `mode` switch). Global, not client-scoped, matching
/// `SessionTemplate`'s shape in CONTRACT-M4.md §3.
struct TemplateLibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SessionTemplate.order) private var allTemplates: [SessionTemplate]

    @State private var showingNewTemplateSheet = false
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    // 2026-09-17：這個分段只顯示一般多動作訓練模板——Superset 模板、WOD 模板
    // 各自有自己的分段（見 `SupersetTemplateLibraryView`/`WODTemplateLibraryView`
    // 及 `SessionTemplate.isSupersetOnly`/`isWODOnly`），三個模板庫互不重疊。
    private var templates: [SessionTemplate] {
        allTemplates.filter { !$0.isSupersetOnly && !$0.isWODOnly }
    }

    var body: some View {
        List {
            if templates.isEmpty {
                ContentUnavailableView(
                    language.t("暫無組合模板", "No Templates"),
                    systemImage: "square.stack.3d.up.slash",
                    description: Text(language.t("點擊右上角「+」創建第一個訓練組合模板", "Tap \"+\" in the top right to create your first template"))
                )
            } else {
                Section {
                    ForEach(templates, id: \.id) { template in
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
                    Text(language.t("\(templates.count) 個模板", "\(templates.count) templates"))
                        .sectionLabelStyle()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.C.canvas)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingNewTemplateSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.C.onAccent)
                        .frame(width: 32, height: 32)
                        .background(DS.C.accent, in: Circle())
                }
            }
        }
        .sheet(isPresented: $showingNewTemplateSheet) {
            NewTemplateNameSheet { name in
                createTemplate(name: name)
            }
        }
    }

    private func createTemplate(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // 用 `allTemplates`（不是這個分段篩選後的 `templates`）算下一個 order，
        // 避免跟 Superset/WOD 模板的 order 撞號。
        let newOrder = (allTemplates.map(\.order).max() ?? -1) + 1
        let template = SessionTemplate(
            id: "tpl-\(UUID().uuidString.prefix(8))",
            name: trimmed.isEmpty ? language.t("新組合模板", "New Template") : trimmed,
            templateNote: nil,
            order: newOrder
        )
        modelContext.insert(template)
        try? modelContext.save()
    }

    private func deleteTemplates(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(templates[index])
        }
        try? modelContext.save()
        TemplateReorder.reindex(templates.enumerated().filter { !offsets.contains($0.offset) }.map(\.element))
        try? modelContext.save()
    }
}

/// Row shared by `TemplateLibraryView` (edit entry point) and
/// `SessionTemplatePickerView` (read-only selection, CONTRACT-M4.md §5).
struct TemplateSummaryRow: View {
    let template: SessionTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(template.name)
                .font(DS.F.cardTitle)
                .foregroundStyle(DS.C.textHi)
            // CONTRACT-M4.md §3: explicitly a rough heuristic -- always
            // shown as "约 X 分钟", never a bare/precise-looking number.
            Text(L("\(template.orderedBlocks.count) 個塊 約 \(template.estimatedMinutes) 分鐘", "\(template.orderedBlocks.count) blocks ~\(template.estimatedMinutes) min"))
                .font(DS.F.subtitle)
                .foregroundStyle(DS.C.textLow)
            if let note = template.templateNote, !note.isEmpty {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.C.textMid)
                    .lineLimit(1)
            }
        }
    }
}

private struct NewTemplateNameSheet: View {
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    var body: some View {
        NavigationStack {
            Form {
                TextField(language.t("模板名稱，如「全身力量 A」", "Template name, e.g. \"Full Body A\""), text: $name)
            }
            .scrollContentBackground(.hidden)
            .background(DS.C.canvas)
            .font(DS.F.listRow)
            .foregroundStyle(DS.C.textHi)
            .navigationTitle(language.t("新建組合模板", "New Template"))
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

/// Pure, unit-testable reordering helper shared by block and slot reorder
/// callbacks -- kept independent of any specific `@Model` type via a small
/// protocol so `M4B*` tests can exercise the reindexing logic without
/// standing up a SwiftData context.
protocol OrderIndexed: AnyObject {
    var order: Int { get set }
}

extension SessionTemplate: OrderIndexed {}
extension TemplateBlock: OrderIndexed {}
extension TemplateExerciseSlot: OrderIndexed {}

enum TemplateReorder {
    /// Reassigns `.order` to `0..<count` following the given array's
    /// current sequence -- used both after a drag-reorder (`onMove`) and
    /// after a deletion (to close the gap left behind).
    static func reindex<T: OrderIndexed>(_ items: [T]) {
        for (index, item) in items.enumerated() {
            item.order = index
        }
    }

    /// Computes the reordered array for an `onMove` callback without
    /// touching any model object -- lets the reindexing math be tested in
    /// isolation from SwiftData.
    static func moved<T>(_ items: [T], from source: IndexSet, to destination: Int) -> [T] {
        var copy = items
        copy.move(fromOffsets: source, toOffset: destination)
        return copy
    }
}
