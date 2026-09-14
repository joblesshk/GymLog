import SwiftUI
import SwiftData
import GymLogKit

/// 历史课次编辑及补录日期（2026-09-06 审查报告"适合当前范围的功能"第二批）:
/// "修正输错的重量、次数、训练日期，不必整节删除重录"。
///
/// 2026-09-07 审阅 B01 (代码确认): the previous implementation wrote every
/// keystroke straight into the live `SetLog` -- `set.load =`/`set.target =`/
/// `set.actual =` inside each `Binding`'s setter. "Cancel" only called
/// `dismiss()`; it never undid those writes. Since `SetLog` is a SwiftData
/// reference type, the mutated values stayed live in `modelContext` after a
/// cancel, and ANY subsequent `modelContext.save()` -- triggered by
/// completely unrelated work elsewhere in the app -- would silently
/// persist them. Editing 50→60 then tapping Cancel left the in-memory
/// object at 60 forever, until something else happened to save.
///
/// Fixed by editing a plain value-type draft (`SetEditDraft`) per set,
/// applying nothing to the model until "保存" is tapped and every edited
/// set validates. Cancel / swipe-to-dismiss touches only `@State`, so it is
/// unconditionally a zero-write no-op -- there is no code path left that
/// can persist an edit without going through `save()`.
///
/// Editable set shapes: weight (`.absolute` load) plus `.fixed`/`.time`/
/// `.distance`/`.rounds`/`.perSide` targets -- covering reps, seconds,
/// meters, generic "rounds", and per-side rep pairs, not just the original
/// plain-reps case. Every other `LoadValue`/`RepTarget` kind (bodyweight/
/// band/machine-stack/pin-load/sled loads; `.range` targets) stays
/// read-only -- a full editor for those needs the same per-metric wheel
/// machinery `Sources/Views/Wheels/**` already has for NEW entries, which
/// is a materially bigger lift than "fix a mistyped number".
///
/// No special integration with the Excel-import conflict guard is needed:
/// `XLSXHistoryImporter.importDigest(forExisting:)` already recomputes its
/// digest from every block/entry/set's current load/target/actual (and the
/// session's own date/notes) every time an import runs. Editing any of
/// those fields here, without touching `session.importDigest`/
/// `sourceDigest` (this view never does), makes the next reimport's
/// recomputed digest diverge from the stored one automatically -- exactly
/// the existing `.conflicted` path, not a new mechanism.
struct SessionEditSheet: View {
    let session: WorkoutSession

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var editedDate: Date
    @State private var drafts: [PersistentIdentifier: SetEditDraft]
    @State private var saveErrorMessage: String?

    init(session: WorkoutSession) {
        self.session = session
        // `session.date` is already UTC-midnight-encoded; decode back to a
        // local display date before handing to the DatePicker (2026-09-07
        // 审阅 B07 -- see TrainingDayEncoding.localDisplayDate's doc comment).
        _editedDate = State(initialValue: TrainingDayEncoding.localDisplayDate(from: session.date))

        var built: [PersistentIdentifier: SetEditDraft] = [:]
        for block in session.orderedBlocks {
            for entry in block.orderedEntries {
                for set in entry.orderedSets {
                    built[set.persistentModelID] = SetEditDraft(set: set)
                }
            }
        }
        _drafts = State(initialValue: built)
    }

    private var hasValidationError: Bool {
        drafts.values.contains { $0.isEditable && $0.validationError != nil }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DatePicker(L("訓練日期", "Training Date"), selection: $editedDate, displayedComponents: .date)
                } header: {
                    Text(L("日期", "Date")).sectionLabelStyle()
                } footer: {
                    Text(L(
                        "原始日期文本「\(session.dateRaw)」不會被改動，僅供對照。",
                        "The original date text \u{201C}\(session.dateRaw)\u{201D} is kept as-is for reference, not changed."
                    ))
                }

                ForEach(session.orderedBlocks, id: \.persistentModelID) { block in
                    Section {
                        ForEach(block.orderedEntries, id: \.persistentModelID) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(DS.C.textHi)
                                ForEach(entry.orderedSets, id: \.persistentModelID) { set in
                                    EditableSetRow(setIndex: set.setIndex, draft: draftBinding(for: set))
                                    if set.persistentModelID != entry.orderedSets.last?.persistentModelID {
                                        Divider().overlay(DS.C.hairlineSoft)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text(block.blockType.displayName).sectionLabelStyle()
                    }
                    .listRowBackground(DS.C.surface)
                }

                Section {
                    Text(L(
                        "手動修改後，下次導入同名 Excel 課次會被判定為衝突並跳過，不會覆蓋這次修改。",
                        "After a manual edit, re-importing the same Excel session will be flagged as a conflict and skipped, never silently overwriting this edit."
                    ))
                    .font(.caption)
                    .foregroundStyle(DS.C.textLow)
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.C.canvas)
            .navigationTitle(L("編輯課次", "Edit Session"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Zero-write by construction: only touches @State.
                    Button(L("取消", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("保存", "Save")) { save() }
                        .font(.system(size: 15, weight: .semibold))
                        .disabled(hasValidationError)
                }
            }
            .alert(L("保存失敗", "Save Failed"), isPresented: Binding(get: { saveErrorMessage != nil }, set: { if !$0 { saveErrorMessage = nil } })) {
                Button(L("好", "OK"), role: .cancel) {}
            } message: {
                Text(saveErrorMessage ?? "")
            }
        }
        // A modal sheet's swipe-to-dismiss / tap-outside-to-dismiss never
        // calls the Cancel button's action -- but since neither this
        // gesture nor Cancel ever touch `modelContext`, both are equally
        // zero-write. No `.interactiveDismissDisabled`/`onDisappear` guard
        // is needed to make that true.
    }

    private func draftBinding(for set: SetLog) -> Binding<SetEditDraft> {
        Binding(
            get: { drafts[set.persistentModelID] ?? SetEditDraft(set: set) },
            set: { drafts[set.persistentModelID] = $0 }
        )
    }

    /// Validates every editable draft, then applies all of them plus the
    /// date in one pass, then a single `context.save()` -- the "确认后统一
    /// 校验提交" requirement. Nothing here touches the model before every
    /// draft has already validated clean, so a failed `context.save()`'s
    /// `rollback()` only ever reverts what THIS call just applied.
    private func save() {
        guard !hasValidationError else { return }

        session.date = TrainingDayEncoding.utcDay(from: editedDate)
        for block in session.orderedBlocks {
            for entry in block.orderedEntries {
                for set in entry.orderedSets {
                    guard let draft = drafts[set.persistentModelID], draft.isEditable else { continue }
                    draft.apply(to: set)
                }
            }
        }
        do {
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            saveErrorMessage = error.localizedDescription
        }
    }
}

/// One editable set row. Falls back to the same read-only rendering
/// `SessionDetailView.SetRow` uses whenever `draft.isEditable` is false.
private struct EditableSetRow: View {
    let setIndex: Int
    @Binding var draft: SetEditDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(L("第\(setIndex + 1)組", "Set \(setIndex + 1)"))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(DS.C.textMid)
                    .frame(width: 46, alignment: .leading)

                if draft.isEditable {
                    editableFields
                } else {
                    Text(L("此類型暫不支援行內編輯", "Not inline-editable for this type"))
                        .font(.system(size: 12))
                        .foregroundStyle(DS.C.textLow)
                }
            }
            if let error = draft.validationError, draft.isEditable {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.C.danger)
                    .padding(.leading, 54)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var editableFields: some View {
        HStack(spacing: 10) {
            if draft.isWeightEditable {
                labeledField(L("重量(kg)", "Weight(kg)"), text: Binding(
                    get: { draft.kgText ?? "" },
                    set: { draft.kgText = $0 }
                ), keyboard: .decimalPad)
            }
            switch draft.kind {
            case .fixed:
                labeledField(L("目標(次)", "Target(reps)"), text: $draft.targetPrimaryText, keyboard: .numberPad)
                labeledField(L("完成(次)", "Actual(reps)"), text: $draft.actualPrimaryText, keyboard: .numberPad)
            case .time:
                labeledField(L("目標(秒)", "Target(sec)"), text: $draft.targetPrimaryText, keyboard: .numberPad)
                labeledField(L("完成(秒)", "Actual(sec)"), text: $draft.actualPrimaryText, keyboard: .numberPad)
            case .distance:
                labeledField(L("目標(米)", "Target(m)"), text: $draft.targetPrimaryText, keyboard: .numberPad)
                labeledField(L("完成(米)", "Actual(m)"), text: $draft.actualPrimaryText, keyboard: .numberPad)
            case .rounds:
                labeledField(L("目標(輪)", "Target(rounds)"), text: $draft.targetPrimaryText, keyboard: .numberPad)
                labeledField(L("完成(輪)", "Actual(rounds)"), text: $draft.actualPrimaryText, keyboard: .numberPad)
            case .perSide:
                labeledField(L("目標左", "Target L"), text: $draft.targetPrimaryText, keyboard: .numberPad)
                labeledField(L("目標右", "Target R"), text: Binding(
                    get: { draft.targetSecondaryText ?? "" },
                    set: { draft.targetSecondaryText = $0 }
                ), keyboard: .numberPad)
                labeledField(L("完成左", "Actual L"), text: $draft.actualPrimaryText, keyboard: .numberPad)
                labeledField(L("完成右", "Actual R"), text: Binding(
                    get: { draft.actualSecondaryText ?? "" },
                    set: { draft.actualSecondaryText = $0 }
                ), keyboard: .numberPad)
            case .unsupported:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func labeledField(_ label: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(DS.C.textLow)
            TextField("", text: text)
                .keyboardType(keyboard)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DS.C.textHi)
        }
    }
}
