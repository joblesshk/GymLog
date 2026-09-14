import SwiftUI
import SwiftData
import GymLogKit

/// CONTRACT-M4.md §6.2: editing a single `SessionTemplate` -- reorder
/// exercises via drag, add/remove blocks, set each block's set count / rep
/// target / rest seconds, and show `estimatedMinutes` live while building.
///
/// Looked up by id (not held as a direct reference), same reasoning as
/// `ExerciseDetailEditView` in `ExerciseLibraryView.swift`: stays valid if a
/// delete elsewhere invalidates the `@Query` snapshot the caller held.
struct TemplateEditorView: View {
    let templateID: String

    @Query private var templates: [SessionTemplate]
    @Query(sort: \Exercise.canonicalName) private var allExercises: [Exercise]

    init(templateID: String) {
        self.templateID = templateID
    }

    private var template: SessionTemplate? {
        templates.first { $0.id == templateID }
    }

    var body: some View {
        if let template {
            TemplateEditorForm(template: template, allExercises: allExercises)
        } else {
            ContentUnavailableView(L("模板已不存在", "Template No Longer Exists"), systemImage: "questionmark.circle")
        }
    }
}

private struct TemplateEditorForm: View {
    @Bindable var template: SessionTemplate
    let allExercises: [Exercise]

    @Environment(\.modelContext) private var modelContext
    @State private var showingExerciseSearchForBlockID: String?
    @State private var editingSlotID: String?
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    var body: some View {
        List {
            Section {
                TextField(language.t("模板名稱", "Template Name"), text: $template.name)
                TextField(language.t("備註（可選）", "Note (optional)"), text: Binding(
                    get: { template.templateNote ?? "" },
                    set: { template.templateNote = $0.isEmpty ? nil : $0 }
                ))
                HStack {
                    Text(language.t("預計時長", "Estimated Duration"))
                        .foregroundStyle(DS.C.textHi)
                    Spacer()
                    // CONTRACT-M4.md §3: a rough fit-check heuristic, not a
                    // stopwatch -- must never be displayed as a bare/precise
                    // number.
                    Text(language.t("約 \(template.estimatedMinutes) 分鐘", "~\(template.estimatedMinutes) min"))
                        .foregroundStyle(DS.C.textLow)
                }
            } header: {
                Text(language.t("模板信息", "Template Info")).sectionLabelStyle()
            }
            .listRowBackground(DS.C.surface)

            ForEach(template.orderedBlocks, id: \.id) { block in
                blockSection(block)
            }
            .onMove(perform: moveBlocks)

            Section {
                Button {
                    addBlock()
                } label: {
                    Text(language.t("添加塊", "Add Block"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.C.accent)
                }
                .listRowBackground(DS.C.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.C.canvas)
        .font(DS.F.listRow)
        .foregroundStyle(DS.C.textHi)
        .navigationTitle(template.name.isEmpty ? language.t("組合模板", "Template") : template.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
        }
        .sheet(isPresented: Binding(
            get: { showingExerciseSearchForBlockID != nil },
            set: { if !$0 { showingExerciseSearchForBlockID = nil } }
        )) {
            if let blockID = showingExerciseSearchForBlockID,
               let block = template.orderedBlocks.first(where: { $0.id == blockID }) {
                ExercisePickerSheet(allExercises: allExercises) { exercise in
                    addSlot(exercise: exercise, to: block)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { editingSlotID != nil },
            set: { if !$0 { editingSlotID = nil } }
        )) {
            if let slotID = editingSlotID, let slot = findSlot(slotID) {
                TemplateSlotRepTargetSheet(slot: slot)
            }
        }
    }

    // MARK: - Block section

    @ViewBuilder
    private func blockSection(_ block: TemplateBlock) -> some View {
        Section {
            Picker(language.t("類型", "Type"), selection: Binding(
                get: { block.blockType },
                set: { block.blockType = $0 }
            )) {
                ForEach([BlockType.single, .superset, .dropset, .circuit], id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }

            Stepper(
                language.t("組間休息 \(block.restSeconds) 秒", "Rest \(block.restSeconds)s"),
                value: Binding(
                    get: { block.restSeconds },
                    set: { block.restSeconds = max(0, $0) }
                ),
                in: 0...600,
                step: 15
            )

            ForEach(block.orderedSlots, id: \.id) { slot in
                slotRow(slot)
            }
            .onDelete { offsets in deleteSlots(offsets, in: block) }
            .onMove { from, to in moveSlots(in: block, from: from, to: to) }

            Button {
                showingExerciseSearchForBlockID = block.id
            } label: {
                Text(language.t("添加動作", "Add Exercise"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.C.accent)
            }

            Button(language.t("刪除此塊", "Delete This Block")) {
                deleteBlock(block)
            }
            .foregroundStyle(DS.C.danger)
        } header: {
            Text(language.t("第 \(block.order + 1) 塊 · \(block.blockType.displayName)", "Block \(block.order + 1) · \(block.blockType.displayName)"))
                .sectionLabelStyle()
        } footer: {
            if block.orderedSlots.isEmpty {
                Text(language.t("此塊暫無動作", "This block has no exercises yet"))
                    .foregroundStyle(DS.C.textLow)
            }
        }
        .listRowBackground(DS.C.surface)
    }

    @ViewBuilder
    private func slotRow(_ slot: TemplateExerciseSlot) -> some View {
        HStack {
            Button {
                editingSlotID = slot.id
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(exerciseName(for: slot.exerciseID))
                        .font(DS.F.listRow)
                        .foregroundStyle(DS.C.textHi)
                    Text(language.t("\(slot.defaultSets) 組 · \(slot.defaultRepTarget.displayText) · 點擊設置次數目標", "\(slot.defaultSets) sets · \(slot.defaultRepTarget.displayText) · tap to set reps target"))
                        .font(DS.F.subtitle)
                        .foregroundStyle(DS.C.textLow)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Stepper(
                language.t("\(slot.defaultSets) 組", "\(slot.defaultSets) sets"),
                value: Binding(
                    get: { slot.defaultSets },
                    set: { slot.defaultSets = max(1, min(10, $0)) }
                ),
                in: 1...10
            )
            .labelsHidden()
            .fixedSize()
        }
    }

    private func exerciseName(for exerciseID: String) -> String {
        allExercises.first { $0.id == exerciseID }?.displayName ?? language.t("未知動作", "Unknown Exercise")
    }

    private func findSlot(_ id: String) -> TemplateExerciseSlot? {
        template.orderedBlocks.flatMap { $0.orderedSlots }.first { $0.id == id }
    }

    // MARK: - Mutations

    private func addBlock() {
        let block = TemplateBlock(
            id: "tb-\(UUID().uuidString.prefix(8))",
            order: template.orderedBlocks.count,
            blockType: .single,
            restSeconds: 60
        )
        block.template = template
        modelContext.insert(block)
        try? modelContext.save()
    }

    private func deleteBlock(_ block: TemplateBlock) {
        modelContext.delete(block)
        try? modelContext.save()
        TemplateReorder.reindex(template.orderedBlocks.filter { $0.id != block.id })
        try? modelContext.save()
    }

    private func moveBlocks(from source: IndexSet, to destination: Int) {
        let reordered = TemplateReorder.moved(template.orderedBlocks, from: source, to: destination)
        TemplateReorder.reindex(reordered)
        try? modelContext.save()
    }

    private func addSlot(exercise: Exercise, to block: TemplateBlock) {
        let slot = TemplateExerciseSlot(
            id: "tes-\(UUID().uuidString.prefix(8))",
            order: block.orderedSlots.count,
            exerciseID: exercise.id,
            defaultSets: 3,
            defaultRepTarget: .fixed(value: 10, raw: "10")
        )
        slot.block = block
        modelContext.insert(slot)
        try? modelContext.save()
    }

    private func deleteSlots(_ offsets: IndexSet, in block: TemplateBlock) {
        let slots = block.orderedSlots
        for index in offsets {
            modelContext.delete(slots[index])
        }
        try? modelContext.save()
        TemplateReorder.reindex(block.orderedSlots.enumerated().filter { !offsets.contains($0.offset) }.map(\.element))
        try? modelContext.save()
    }

    private func moveSlots(in block: TemplateBlock, from source: IndexSet, to destination: Int) {
        let reordered = TemplateReorder.moved(block.orderedSlots, from: source, to: destination)
        TemplateReorder.reindex(reordered)
        try? modelContext.save()
    }
}

/// Rep-target editing for one slot's `defaultSets`' partner field --
/// deliberately reuses the existing `RepTargetWheel` component (M2/M4-A
/// owned, `Sources/Views/Wheels/**`) rather than a new input UI, matching
/// CONTRACT-M4.md's "复用既有组件，不新造一套次数输入 UI" discipline applied
/// to template editing too.
private struct TemplateSlotRepTargetSheet: View {
    @Bindable var slot: TemplateExerciseSlot
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    var body: some View {
        NavigationStack {
            VStack {
                RepTargetWheel(
                    target: $slot.defaultRepTarget,
                    presets: FrequencyAnalyzer.baseRepTargetPresets + [FrequencyAnalyzer.customPreset]
                )
                .frame(height: 160)
                .padding(.top, 20)
                Spacer()
            }
            .navigationTitle(language.t("設置次數目標", "Set Reps Target"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.t("完成", "Done")) { dismiss() }
                }
            }
        }
    }
}
