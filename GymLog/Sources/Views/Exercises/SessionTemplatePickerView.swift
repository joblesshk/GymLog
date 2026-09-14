import SwiftUI
import SwiftData
import GymLogKit

/// Template picker for "从模板新建" -- CONTRACT-M4.md §5, the frozen seam.
///
/// Type name and initializer signature are frozen: M4-A's `SessionStartView`
/// presents this as a sheet and depends on nothing else about it. Read-only
/// selection -- creation/editing lives in `ExerciseLibraryView`'s "组合模板"
/// segment (`TemplateLibraryView`/`TemplateEditorView`), not here.
struct SessionTemplatePickerView: View {
    let onSelect: (SessionTemplate) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SessionTemplate.order) private var templates: [SessionTemplate]
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    init(onSelect: @escaping (SessionTemplate) -> Void) {
        self.onSelect = onSelect
    }

    var body: some View {
        NavigationStack {
            List {
                if templates.isEmpty {
                    ContentUnavailableView(
                        language.t("暫無組合模板", "No Templates"),
                        systemImage: "square.stack.3d.up.slash",
                        description: Text(language.t("請先在「動作庫」的「組合模板」分段中創建", "Please create one under \"Exercises\" › \"Templates\" first"))
                    )
                } else {
                    ForEach(templates, id: \.id) { template in
                        Button {
                            onSelect(template)
                            dismiss()
                        } label: {
                            TemplateSummaryRow(template: template)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(DS.C.surface)
                        .listRowSeparatorTint(DS.C.hairlineSoft)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.C.canvas)
            .navigationTitle(language.t("選擇組合模板", "Select Template"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("取消", "Cancel")) { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.C.textHi)
                }
            }
        }
    }
}
