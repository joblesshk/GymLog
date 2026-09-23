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
    /// 2026-09-16：「今天」新增「從 Superset 模板添加」時復用同一顆
    /// picker，只是把清單篩成 `isSupersetOnly` 的模板 -- 預設不篩選，不影響
    /// 既有「從模板新建」呼叫端的行為。
    var filter: (SessionTemplate) -> Bool = { _ in true }
    var titleOverride: (zh: String, en: String)?
    var emptyStateOverride: (title: (zh: String, en: String), description: (zh: String, en: String))?
    /// 2026-09-17：「先從模板選、模板裡沒有再手動加」——非 nil 時在清單最下面
    /// （以及空清單時）都會多一顆按鈕，點擊後關掉這個 picker 並呼叫這個
    /// closure，交給呼叫端接手既有的手動選動作流程（`exercisePickerTarget`）。
    var onManualFallback: (() -> Void)?
    var manualFallbackLabel: (zh: String, en: String)?

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SessionTemplate.order) private var allTemplates: [SessionTemplate]
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    init(
        onSelect: @escaping (SessionTemplate) -> Void,
        filter: @escaping (SessionTemplate) -> Bool = { _ in true },
        titleOverride: (zh: String, en: String)? = nil,
        emptyStateOverride: (title: (zh: String, en: String), description: (zh: String, en: String))? = nil,
        onManualFallback: (() -> Void)? = nil,
        manualFallbackLabel: (zh: String, en: String)? = nil
    ) {
        self.onSelect = onSelect
        self.filter = filter
        self.titleOverride = titleOverride
        self.emptyStateOverride = emptyStateOverride
        self.onManualFallback = onManualFallback
        self.manualFallbackLabel = manualFallbackLabel
    }

    private var templates: [SessionTemplate] {
        allTemplates.filter(filter)
    }

    var body: some View {
        NavigationStack {
            List {
                if templates.isEmpty {
                    ContentUnavailableView(
                        language.t(emptyStateOverride?.title.zh ?? "暫無組合模板", emptyStateOverride?.title.en ?? "No Templates"),
                        systemImage: "square.stack.3d.up.slash",
                        description: Text(language.t(emptyStateOverride?.description.zh ?? "請先在「動作庫」的「組合模板」分段中創建", emptyStateOverride?.description.en ?? "Please create one under \"Exercises\" › \"Templates\" first"))
                    )
                    if let onManualFallback {
                        manualFallbackButton(onManualFallback)
                    }
                } else {
                    Section {
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
                    if let onManualFallback {
                        Section {
                            manualFallbackButton(onManualFallback)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.C.canvas)
            .navigationTitle(language.t(titleOverride?.zh ?? "選擇組合模板", titleOverride?.en ?? "Select Template"))
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

    @ViewBuilder
    private func manualFallbackButton(_ action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            action()
        } label: {
            Text(language.t(manualFallbackLabel?.zh ?? "找不到想要的？改為手動選擇動作", manualFallbackLabel?.en ?? "Can't find what you want? Pick exercises manually"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.C.accent)
        }
        .accessibilityIdentifier("template-picker-manual-fallback")
        .listRowBackground(DS.C.surface)
    }
}
