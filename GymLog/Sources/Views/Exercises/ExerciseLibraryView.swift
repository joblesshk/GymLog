import SwiftUI
import SwiftData
import GymLogKit

/// Exercise-library management — CONTRACT-UI.md §4.4. Mounted by
/// ContentView (M2-owned) on the 动作库 tab; type name and no-argument
/// initializer are frozen.
///
/// Merge is deliberately non-destructive: it only reassigns
/// `ExerciseEntry.exercise` (+ `exerciseIdRef`) from the source exercise to
/// the target. The source `Exercise` row itself is never deleted and no new
/// field is added to the frozen `Exercise` model (CONTRACT-UI.md §5.1 —
/// data-layer schema changes need main-control sign-off first), which is
/// exactly what makes the in-session "撤销" below trivially correct: it just
/// reassigns the same entries back.
struct ExerciseLibraryView: View {
    // CONTRACT-M4.md §1: shared across all clients by design (unlike 今天/
    // 历史/学员), so this is display-only identity, not a filter -- the
    // exercise list itself never changes with the current client.
    @Bindable var clientStore: CurrentClientStore
    let switchCoordinator: ClientSwitchCoordinator

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Exercise.canonicalName) private var exercises: [Exercise]
    @Query(sort: \Client.name) private var clients: [Client]

    @State private var searchText = ""
    @State private var filter: LibraryFilter = .all
    @State private var mergeSourceID: String?
    @State private var pendingMerge: PendingMerge?
    @State private var lastMergeUndo: MergeUndoRecord?
    @State private var mergeErrorMessage: String?
    @State private var pendingDeleteExercise: Exercise?
    @State private var operationErrorMessage: String?
    @State private var showingAddExercise = false
    // Bulk clear -- added for local testing of the Excel re-import flow
    // (does re-importing correctly repopulate the library from scratch),
    // same destructive-confirmation pattern as the single-exercise delete
    // below. Unlike history, the library is shared across all clients
    // (CONTRACT-UI.md §4.4 -- see this view's own doc comment), so this
    // clears every exercise in the app, not just the current client's.
    @State private var showingClearAllConfirmation = false

    // CONTRACT-M4.md §6.2: a sibling "组合模板" segment added alongside the
    // pre-existing "动作" segment. `mode` only switches which content the
    // Group below renders -- none of the exercises-mode state above (filter,
    // merge/undo, search) is touched by this addition.
    @State private var mode: LibraryMode = .exercises
    @Query(sort: \SessionTemplate.order) private var templates: [SessionTemplate]
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    enum LibraryMode: String, CaseIterable, Identifiable {
        case exercises, templates
        var id: String { rawValue }
        var label: String {
            switch self {
            case .exercises: return L("動作", "Exercises")
            case .templates: return L("組合模板", "Templates")
            }
        }
    }

    enum LibraryFilter: String, CaseIterable, Identifiable {
        case all, needsReview, lowerIsStronger
        // 2026-09-09「訓練體系」：教练要求动作库能分成「Gym 力量训练需要的
        // exercise」和「CrossFit 所有的 movements」两栏来看。兩者皆是的动作
        // （Deadlift、Thruster、Wall ball…）两栏都出现。
        case strength, crossfit
        var id: String { rawValue }
    }

    private func filterLabel(_ f: LibraryFilter) -> String {
        switch f {
        case .all: return language.t("全部", "All")
        case .needsReview: return language.t("待復核 (\(needsReviewCount))", "Needs Review (\(needsReviewCount))")
        case .lowerIsStronger: return language.t("越小越強 (\(lowerIsStrongerCount))", "Lower Is Stronger (\(lowerIsStrongerCount))")
        case .strength: return language.t("力量 (\(strengthCount))", "Strength (\(strengthCount))")
        case .crossfit: return "CrossFit (\(crossfitCount))"
        }
    }

    private var needsReviewCount: Int { exercises.filter { $0.needsReview }.count }
    private var lowerIsStrongerCount: Int { exercises.filter { $0.loadDirection == .lowerIsStronger }.count }
    private var strengthCount: Int { exercises.filter { $0.discipline.belongs(to: .strength) }.count }
    private var crossfitCount: Int { exercises.filter { $0.discipline.belongs(to: .crossfit) }.count }

    private var currentClient: Client? {
        clientStore.currentClient(in: clients)
    }

    private var filteredExercises: [Exercise] {
        var list = exercises
        switch filter {
        case .all: break
        case .needsReview: list = list.filter { $0.needsReview }
        case .lowerIsStronger: list = list.filter { $0.loadDirection == .lowerIsStronger }
        case .strength: list = list.filter { $0.discipline.belongs(to: .strength) }
        case .crossfit: list = list.filter { $0.discipline.belongs(to: .crossfit) }
        }
        if !searchText.isEmpty {
            list = list.filter { $0.matches(searchText: searchText) }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .exercises:
                    exerciseListContent
                case .templates:
                    TemplateLibraryView()
                }
            }
            .safeAreaInset(edge: .top) {
                modePicker
            }
            .scrollContentBackground(.hidden)
            .background(DS.C.canvas)
            .reserveFloatingTabBarSpace()
            .navigationTitle(mode == .exercises ? language.t("動作庫 (\(exercises.count))", "Exercises (\(exercises.count))") : language.t("組合模板 (\(templates.count))", "Templates (\(templates.count))"))
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if let client = currentClient {
                        ClientSwitcherButton(currentClient: client, coordinator: switchCoordinator)
                    }
                }
            }
        }
    }

    private var modePicker: some View {
        GymSegmentedControl(selection: $mode, options: LibraryMode.allCases, label: \.label)
            .padding(.horizontal, DS.Space.pageMargin)
            .padding(.vertical, 8)
            .background(DS.C.canvas)
    }

    /// The pre-existing "动作" segment (CONTRACT-UI.md §4.4) -- unchanged in
    /// content and behavior, only relocated from being the direct child of
    /// `NavigationStack` to being one arm of `mode`'s `switch`.
    /// `navigationTitle`/the `.principal` toolbar item moved up to the
    /// `NavigationStack` level above (identical effect, since this view was
    /// previously the stack's sole direct child anyway).
    private var exerciseListContent: some View {
        List {
            if let undo = lastMergeUndo {
                Section {
                    mergeUndoBanner(undo)
                        .listRowBackground(DS.C.surface)
                }
            }
            Section {
                ForEach(filteredExercises, id: \.id) { exercise in
                    NavigationLink {
                        ExerciseDetailEditView(
                            exerciseID: exercise.id,
                            onMergeRequested: { mergeSourceID = exercise.id }
                        )
                    } label: {
                        ExerciseRow(exercise: exercise)
                    }
                    .listRowBackground(DS.C.surface)
                    .listRowSeparatorTint(DS.C.hairlineSoft)
                }
                .onDelete { offsets in
                    if let index = offsets.first {
                        pendingDeleteExercise = filteredExercises[index]
                    }
                }
            } header: {
                if !filteredExercises.isEmpty {
                    Text(language.t("\(filteredExercises.count) 個動作", "\(filteredExercises.count) exercises"))
                        .sectionLabelStyle()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.C.canvas)
        .searchable(text: $searchText, prompt: language.t("搜索動作名或別名", "Search name or alias"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Picker(language.t("篩選", "Filter"), selection: $filter) {
                    ForEach(LibraryFilter.allCases) { f in
                        Text(filterLabel(f)).tag(f)
                    }
                }
                .pickerStyle(.menu)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive) {
                    showingClearAllConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.C.danger)
                }
                .disabled(exercises.isEmpty)
                .accessibilityLabel(language.t("清空動作庫", "Clear All Exercises"))
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingAddExercise = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.C.onAccent)
                        .frame(width: 32, height: 32)
                        .background(DS.C.accent, in: Circle())
                }
                .accessibilityLabel(language.t("新增動作", "Add Exercise"))
            }
        }
        .sheet(isPresented: $showingAddExercise) {
            AddExerciseSheet { name in
                createCustomExercise(name: name)
            }
        }
        .alert(
            language.t("確認刪除", "Confirm Delete"),
            isPresented: Binding(get: { pendingDeleteExercise != nil }, set: { if !$0 { pendingDeleteExercise = nil } }),
            presenting: pendingDeleteExercise
        ) { exercise in
            Button(language.t("取消", "Cancel"), role: .cancel) { pendingDeleteExercise = nil }
            Button(language.t("刪除", "Delete"), role: .destructive) { performDelete(exercise) }
        } message: { exercise in
            Text(deleteConfirmationMessage(exercise))
        }
        .alert(
            language.t("確認清空動作庫", "Confirm Clear All Exercises"),
            isPresented: $showingClearAllConfirmation
        ) {
            Button(language.t("取消", "Cancel"), role: .cancel) {}
            Button(language.t("清空全部 \(exercises.count) 個", "Clear All \(exercises.count)"), role: .destructive) { clearAllExercises() }
        } message: {
            Text(language.t(
                "確定刪除動作庫中全部 \(exercises.count) 個動作嗎？所有學員的歷史訓練記錄會保留，但都會顯示為「未識別動作」。此操作無法撤銷。",
                "Delete all \(exercises.count) exercises in the library? Every client's history stays intact, but all of it will show as unresolved exercises. This cannot be undone."
            ))
        }
        .alert(language.t("操作失敗", "Operation Failed"), isPresented: Binding(
            get: { operationErrorMessage != nil },
            set: { if !$0 { operationErrorMessage = nil } }
        )) {
            Button(language.t("好", "OK")) { operationErrorMessage = nil }
        } message: {
            Text(operationErrorMessage ?? "")
        }
        .sheet(isPresented: Binding(
            get: { mergeSourceID != nil },
            set: { if !$0 { mergeSourceID = nil } }
        )) {
            if let mergeSourceID, let source = exercises.first(where: { $0.id == mergeSourceID }) {
                MergeTargetPickerView(source: source, exercises: exercises) { target in
                    self.mergeSourceID = nil
                    pendingMerge = PendingMerge(sourceID: source.id, targetID: target.id)
                }
            }
        }
        .alert(language.t("確認合並", "Confirm Merge"), isPresented: Binding(
            get: { pendingMerge != nil },
            set: { if !$0 { pendingMerge = nil } }
        ), presenting: pendingMerge) { merge in
            Button(language.t("取消", "Cancel"), role: .cancel) { pendingMerge = nil }
            Button(language.t("確認合並", "Confirm Merge"), role: .destructive) { performMerge(merge) }
        } message: { merge in
            Text(mergeConfirmationMessage(merge))
        }
        .alert(language.t("合並失敗", "Merge Failed"), isPresented: Binding(
            get: { mergeErrorMessage != nil },
            set: { if !$0 { mergeErrorMessage = nil } }
        )) {
            Button(language.t("好", "OK")) { mergeErrorMessage = nil }
        } message: {
            Text(mergeErrorMessage ?? "")
        }
    }

    // MARK: - Merge

    private func distinctSessionCount(_ entries: [ExerciseEntry]) -> Int {
        Set(entries.compactMap { $0.block?.session?.id }).count
    }

    private func mergeConfirmationMessage(_ merge: PendingMerge) -> String {
        guard let source = exercises.first(where: { $0.id == merge.sourceID }),
              let target = exercises.first(where: { $0.id == merge.targetID }) else {
            return language.t("動作已不存在，無法合並。", "The exercise no longer exists and can't be merged.")
        }
        let entries = source.entries ?? []
        let sessionCount = distinctSessionCount(entries)
        return language.t(
            "將把「\(source.canonicalName)」的 \(entries.count) 條力量記錄（涉及 \(sessionCount) 次訓練課，另包含相關的組合模板與 WOD 記錄）歸入「\(target.canonicalName)」。\n\n此操作會立即改寫歷史歸屬（動作的原始名稱/重量/次數快照不受影響）；完成後可在本頁頂部「撤銷」，但離開本頁或重啟 App 後將無法自動撤銷，請確認無誤後再繼續。",
            "This will move \(entries.count) strength record(s) from \"\(source.canonicalName)\" (across \(sessionCount) sessions, plus any related templates and WOD records) into \"\(target.canonicalName)\".\n\nThis rewrites history immediately (the original recorded name/weight/reps snapshots are untouched). You can \"Undo\" at the top of this page right after, but it can no longer be undone automatically once you leave this page or restart the app — please confirm before continuing."
        )
    }

    /// 2026-09-10：改走 `ExerciseReferenceRedirectionService`——这个按钮原来
    /// 是一套独立实现，只重定向了 `ExerciseEntry`，从没碰过
    /// `TemplateExerciseSlot.exerciseID`（B04 修的是 `SeedImporter` 那一条
    /// 路径，这个按钮从一开始就没接上），也没碰过 WOD 处方/成绩里的
    /// `exerciseID`。现在两条路径共用同一个实现，行为和覆盖范围一致。
    private func performMerge(_ merge: PendingMerge) {
        pendingMerge = nil
        guard let source = exercises.first(where: { $0.id == merge.sourceID }),
              let target = exercises.first(where: { $0.id == merge.targetID }) else {
            mergeErrorMessage = language.t("動作已不存在，合並已取消。", "The exercise no longer exists; merge cancelled.")
            return
        }
        let affectedEntries = source.entries ?? []
        let sessionCount = distinctSessionCount(affectedEntries)
        do {
            let (summary, undo) = try ExerciseReferenceRedirectionService.redirect(from: source, to: target, in: modelContext)
            try modelContext.save()
            lastMergeUndo = MergeUndoRecord(sourceID: source.id, undo: undo, summary: summary, sessionCount: sessionCount)
        } catch {
            // The service only mutates in-memory model objects and never
            // deletes anything itself -- rolling back the context discards
            // every reassignment this call made (entries, template slots,
            // WOD payloads/prescriptions) as one unit, so a save failure
            // never leaves a partial redirect behind.
            modelContext.rollback()
            mergeErrorMessage = language.t("保存失敗：\(error.localizedDescription)", "Save failed: \(error.localizedDescription)")
        }
    }

    private func undoLastMerge() {
        guard let record = lastMergeUndo else { return }
        guard let source = exercises.first(where: { $0.id == record.sourceID }) else {
            mergeErrorMessage = language.t("原動作已不存在，無法撤銷。", "The original exercise no longer exists and can't be undone.")
            lastMergeUndo = nil
            return
        }
        ExerciseReferenceRedirectionService.undo(record.undo, source: source, in: modelContext)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            mergeErrorMessage = language.t("撤銷保存失敗：\(error.localizedDescription)", "Undo save failed: \(error.localizedDescription)")
        }
        lastMergeUndo = nil
    }

    // MARK: - Delete

    /// `Exercise.entries` is `deleteRule: .nullify` (see `Exercise.swift`),
    /// so deleting an `Exercise` never touches historical `WorkoutSession`/
    /// `SetLog` data -- it only nullifies `ExerciseEntry.exercise` on any
    /// entries that referenced it (they keep `exerciseRaw`/`exerciseIdRef`
    /// and render as an unresolved reference, same as `SessionDetailView`
    /// already handles for any other unresolved `exercise == nil` case).
    /// The confirmation message says so explicitly since "删除动作" sounds
    /// more destructive to training history than it actually is.
    private func deleteConfirmationMessage(_ exercise: Exercise) -> String {
        let entries = exercise.entries ?? []
        guard !entries.isEmpty else {
            return language.t("確定刪除「\(exercise.canonicalName)」嗎？此操作無法撤銷。", "Delete \"\(exercise.canonicalName)\"? This cannot be undone.")
        }
        let sessionCount = distinctSessionCount(entries)
        return language.t(
            "「\(exercise.canonicalName)」在 \(entries.count) 條記錄（\(sessionCount) 次訓練課）中被引用。刪除後這些記錄會保留，但會顯示為「未識別動作」。此操作無法撤銷。",
            "\"\(exercise.canonicalName)\" is referenced by \(entries.count) record(s) across \(sessionCount) session(s). Those records will remain but show as an unresolved exercise. This cannot be undone."
        )
    }

    private func performDelete(_ exercise: Exercise) {
        pendingDeleteExercise = nil
        modelContext.delete(exercise)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            operationErrorMessage = language.t("刪除失敗：\(error.localizedDescription)", "Delete failed: \(error.localizedDescription)")
        }
    }

    /// Same `.nullify` cascade as `performDelete` above, just for every
    /// exercise in the (client-shared) library at once -- no history is
    /// lost, `ExerciseEntry.exercise` on every affected entry just goes
    /// `nil` and renders as unresolved.
    private func clearAllExercises() {
        for exercise in exercises {
            modelContext.delete(exercise)
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            operationErrorMessage = language.t("清空失敗：\(error.localizedDescription)", "Clear failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Add custom exercise

    /// Sibling of `ExercisePickerSheet.createAndSelect` -- that flow
    /// creates-and-selects from inside a session entry (and, since
    /// 2026-09-04, lets the coach pick the classification right there); this
    /// one just adds to the library without selecting anything, for
    /// exercises the coach wants available ahead of time rather than typed
    /// in mid-entry. It still leaves the classification unset, which is why
    /// it flags `needsReview`.
    private func createCustomExercise(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let exercise = Exercise(
            id: "ex-local-\(UUID().uuidString.prefix(8))",
            canonicalName: trimmed,
            aliases: [],
            movementPattern: .unknown,
            equipment: .other,
            loadDirection: .higherIsStronger,
            isUnilateral: false,
            occurrenceCount: 0,
            needsReview: true,
            reviewReason: language.t("教練在動作庫中手動新增，未經分類確認", "Manually added in the exercise library, not yet classified")
        )
        modelContext.insert(exercise)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            operationErrorMessage = language.t("新增失敗：\(error.localizedDescription)", "Create failed: \(error.localizedDescription)")
        }
    }

    @ViewBuilder
    private func mergeUndoBanner(_ undo: MergeUndoRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(language.t(
                    "已合並 \(undo.summary.entryCount) 條記錄（\(undo.sessionCount) 次訓練課\(mergeUndoExtraCoverageSuffix(undo.summary, zh: true))）",
                    "Merged \(undo.summary.entryCount) record(s) (\(undo.sessionCount) sessions\(mergeUndoExtraCoverageSuffix(undo.summary, zh: false)))"
                ))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.C.textHi)
                Text(language.t("如為誤操作可立即撤銷", "You can undo immediately if this was a mistake"))
                    .font(.system(size: 11))
                    .foregroundStyle(DS.C.textLow)
            }
            Spacer()
            Button(language.t("撤銷", "Undo")) { undoLastMerge() }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(DS.C.accent)
        }
    }

    /// Only mentions template/WOD counts when they're non-zero -- most
    /// merges only ever touch strength entries, and a permanent "0 個模板、
    /// 0 個 WOD" suffix would just be noise on every single undo banner.
    private func mergeUndoExtraCoverageSuffix(_ summary: ExerciseReferenceRedirectionService.Summary, zh: Bool) -> String {
        var parts: [String] = []
        if summary.templateSlotCount > 0 {
            parts.append(zh ? "\(summary.templateSlotCount) 個模板欄位" : "\(summary.templateSlotCount) template slot(s)")
        }
        let wodCount = summary.wodPayloadCount + summary.wodPrescriptionCount
        if wodCount > 0 {
            parts.append(zh ? "\(wodCount) 個 WOD 記錄" : "\(wodCount) WOD record(s)")
        }
        guard !parts.isEmpty else { return "" }
        return zh ? "、" + parts.joined(separator: "、") : ", " + parts.joined(separator: ", ")
    }
}

// MARK: - Supporting types

private struct PendingMerge: Identifiable {
    let sourceID: String
    let targetID: String
    var id: String { "\(sourceID)->\(targetID)" }
}

private struct MergeUndoRecord {
    let sourceID: String
    let undo: ExerciseReferenceRedirectionService.UndoToken
    let summary: ExerciseReferenceRedirectionService.Summary
    let sessionCount: Int
}

private struct ExerciseRow: View {
    let exercise: Exercise

    /// 只在不是纯力量时才写出来：库里 148/240 是纯力量动作，每行都缀一个
    /// 「力量」等于什么都没说。
    private var disciplineSuffix: String {
        exercise.discipline == .strength ? "" : " · \(exercise.discipline.displayName)"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(exercise.displayName)
                    .font(DS.F.cardTitle)
                    .foregroundStyle(DS.C.textHi)
                Text(L(
                    "\(exercise.movementPattern.displayName) · \(exercise.equipment.displayName)\(disciplineSuffix) · 出現 \(exercise.occurrenceCount) 次",
                    "\(exercise.movementPattern.displayName) · \(exercise.equipment.displayName)\(disciplineSuffix) · \(exercise.occurrenceCount)×"
                ))
                    .font(DS.F.subtitle)
                    .foregroundStyle(DS.C.textLow)
                if !exercise.notes.isEmpty {
                    Text(exercise.notes)
                        .font(.caption)
                        .foregroundStyle(DS.C.textLow)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if exercise.loadDirection == .lowerIsStronger {
                    Text(L("越小越強", "Lower Is Stronger"))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(DS.C.inset, in: Capsule())
                        .foregroundStyle(DS.C.textMid)
                }
                if exercise.needsReview {
                    DataTagView(kind: .review)
                }
            }
        }
    }
}

/// Edit form for one exercise. Looked up by id (not held as a direct
/// reference) so it stays valid across a merge elsewhere invalidating the
/// `@Query` snapshot the caller held.
private struct ExerciseDetailEditView: View {
    let exerciseID: String
    let onMergeRequested: () -> Void

    @Query private var exercises: [Exercise]
    @State private var showingInvertedWarning = false

    init(exerciseID: String, onMergeRequested: @escaping () -> Void) {
        self.exerciseID = exerciseID
        self.onMergeRequested = onMergeRequested
    }

    private var exercise: Exercise? {
        exercises.first { $0.id == exerciseID }
    }

    var body: some View {
        if let exercise {
            EditForm(exercise: exercise, onMergeRequested: onMergeRequested)
        } else {
            ContentUnavailableView(L("動作已不存在", "Exercise No Longer Exists"), systemImage: "questionmark.circle")
        }
    }
}

private struct EditForm: View {
    @Bindable var exercise: Exercise
    let onMergeRequested: () -> Void
    @State private var showingInvertedWarning = false
    @State private var showingDeleteConfirmation = false
    @State private var deleteErrorMessage: String?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private var deleteConfirmationMessage: String {
        let entries = exercise.entries ?? []
        guard !entries.isEmpty else {
            return L("確定刪除「\(exercise.canonicalName)」嗎？此操作無法撤銷。", "Delete \"\(exercise.canonicalName)\"? This cannot be undone.")
        }
        let sessionCount = Set(entries.compactMap { $0.block?.session?.id }).count
        return L(
            "「\(exercise.canonicalName)」在 \(entries.count) 條記錄（\(sessionCount) 次訓練課）中被引用。刪除後這些記錄會保留，但會顯示為「未識別動作」。此操作無法撤銷。",
            "\"\(exercise.canonicalName)\" is referenced by \(entries.count) record(s) across \(sessionCount) session(s). Those records will remain but show as an unresolved exercise. This cannot be undone."
        )
    }

    private func deleteExercise() {
        modelContext.delete(exercise)
        do {
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            deleteErrorMessage = L("刪除失敗：\(error.localizedDescription)", "Delete failed: \(error.localizedDescription)")
        }
    }

    var body: some View {
        Form {
            Section(L("規範名", "Canonical Name")) {
                TextField(L("規範名（英文）", "Canonical Name (English)"), text: $exercise.canonicalName)
                TextField(L("中文名", "Chinese Name"), text: $exercise.nameZh)
                TextField(L("動作說明（50字以內）", "Description (50 characters or fewer)"), text: $exercise.notes)
                if !exercise.aliases.isEmpty {
                    Text(L("別名：\(exercise.aliases.joined(separator: "、"))", "Aliases: \(exercise.aliases.joined(separator: ", "))"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L("分類", "Category")) {
                Picker(L("動作模式", "Movement Pattern"), selection: $exercise.movementPattern) {
                    ForEach(MovementPattern.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                Picker(L("器械", "Equipment"), selection: $exercise.equipment) {
                    ForEach(Equipment.allCases) { e in
                        Text(e.displayName).tag(e)
                    }
                }
                Picker(L("記錄方式", "Recorded By"), selection: $exercise.recordingMetric) {
                    ForEach(RecordingMetric.allCases.filter { $0 != .unknown }) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                // 2026-09-09：决定这个动作出现在选动作面板的「力量」还是
                // 「CrossFit」筛选里。两边都用（Deadlift、Thruster、Wall ball
                // 之类）就选「兩者皆是」。
                Picker(L("訓練體系", "Discipline"), selection: $exercise.discipline) {
                    ForEach(ExerciseDiscipline.allCases) { d in
                        Text(d.displayName).tag(d)
                    }
                }
                Toggle(L("單側動作 (isUnilateral)", "Unilateral (isUnilateral)"), isOn: $exercise.isUnilateral)
            }

            Section {
                Picker(L("負重方向", "Load Direction"), selection: Binding(
                    get: { exercise.loadDirection },
                    set: { newValue in
                        if newValue == .lowerIsStronger {
                            showingInvertedWarning = true
                        }
                        exercise.loadDirection = newValue
                    }
                )) {
                    Text(L("越大越強（默認）", "Higher Is Stronger (default)")).tag(LoadDirection.higherIsStronger)
                    Text(L("越小越強（輔助配重類）", "Lower Is Stronger (assisted)")).tag(LoadDirection.lowerIsStronger)
                }
                if exercise.loadDirection == .lowerIsStronger {
                    Label(L("此動作按「數值越小越強」計算 PR 與趨勢方向，標錯代價最大，請務必確認屬於輔助類動作（如 assisted dip/chin up）。", "This exercise computes PR/trend direction as \"lower is stronger\" — mislabeling this is the costliest mistake, so please confirm it's truly an assisted exercise (e.g. assisted dip/chin up)."), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(DS.C.danger)
                }
            } header: {
                Text(L("負重方向 (loadDirection)", "Load Direction (loadDirection)"))
            }

            Section(L("待復核", "Needs Review")) {
                Toggle("needsReview", isOn: $exercise.needsReview)
                if let reason = exercise.reviewReason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button(L("合並到其他動作…", "Merge into Another Exercise…")) {
                    onMergeRequested()
                }
                .foregroundStyle(DS.C.accent)
            } footer: {
                Text(L("合並會把該動作的全部訓練記錄改記到目標動作名下，需二次確認，且可在本次會話中撤銷。", "Merging reassigns all of this exercise's training records to the target exercise. This needs a second confirmation and can be undone within this session."))
            }

            Section {
                Button(L("刪除該動作", "Delete This Exercise"), role: .destructive) {
                    showingDeleteConfirmation = true
                }
                .foregroundStyle(DS.C.danger)
            }
        }
        .font(DS.F.listRow)
        .foregroundStyle(DS.C.textHi)
        .navigationTitle(exercise.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .alert(L("確認：該動作數值越小越強？", "Confirm: lower is stronger for this exercise?"), isPresented: $showingInvertedWarning) {
            Button(L("確認", "Confirm"), role: .destructive) {}
            Button(L("取消", "Cancel"), role: .cancel) {
                exercise.loadDirection = .higherIsStronger
            }
        } message: {
            Text(L("誤標會讓所有相關趨勢圖與 PR 方向完全顛倒。僅輔助配重類動作（如 Dips w/assist、Chin up w/assist）應設為此項。", "Mislabeling this flips every related trend chart and PR direction. Only assisted exercises (e.g. Dips w/assist, Chin up w/assist) should use this."))
        }
        .alert(L("確認刪除", "Confirm Delete"), isPresented: $showingDeleteConfirmation) {
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("刪除", "Delete"), role: .destructive) { deleteExercise() }
        } message: {
            Text(deleteConfirmationMessage)
        }
        .alert(L("刪除失敗", "Delete Failed"), isPresented: Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )) {
            Button(L("好", "OK")) { deleteErrorMessage = nil }
        } message: {
            Text(deleteErrorMessage ?? "")
        }
    }
}

/// Target picker for merge — excludes the source exercise itself.
private struct MergeTargetPickerView: View {
    let source: Exercise
    let exercises: [Exercise]
    let onSelect: (Exercise) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var candidates: [Exercise] {
        let list = exercises.filter { $0.id != source.id }
        guard !searchText.isEmpty else { return list }
        return list.filter { $0.matches(searchText: searchText) }
    }

    var body: some View {
        NavigationStack {
            List(candidates, id: \.id) { candidate in
                Button {
                    onSelect(candidate)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.canonicalName)
                            .font(DS.F.listRow)
                            .foregroundStyle(DS.C.textHi)
                        Text(L("\(candidate.movementPattern.displayName) · 出現 \(candidate.occurrenceCount) 次", "\(candidate.movementPattern.displayName) · \(candidate.occurrenceCount)×"))
                            .font(DS.F.subtitle)
                            .foregroundStyle(DS.C.textLow)
                    }
                }
                .listRowBackground(DS.C.surface)
            }
            .scrollContentBackground(.hidden)
            .background(DS.C.canvas)
            .searchable(text: $searchText, prompt: L("搜索合並目標", "Search merge target"))
            .navigationTitle(L("合並「\(source.canonicalName)」到…", "Merge \"\(source.canonicalName)\" Into…"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消", "Cancel")) { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.C.textHi)
                }
            }
        }
    }
}

/// New-custom-exercise entry point mounted directly from the library (as
/// opposed to `ExercisePickerSheet`'s `NewExerciseSheet`, which
/// creates-and-selects mid-entry) -- for exercises the coach wants in the
/// library ahead of time, not typed in during a session.
private struct AddExerciseSheet: View {
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    var body: some View {
        NavigationStack {
            Form {
                TextField(language.t("動作名稱", "Exercise name"), text: $name)
            }
            .scrollContentBackground(.hidden)
            .background(DS.C.canvas)
            .font(DS.F.listRow)
            .foregroundStyle(DS.C.textHi)
            .navigationTitle(language.t("新增動作", "New Exercise"))
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
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
