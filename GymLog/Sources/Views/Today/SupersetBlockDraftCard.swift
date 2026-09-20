import SwiftUI
import SwiftData
import GymLogKit

/// P1 (2026-09-11)：一個 Superset（A1→A2→A3 依序完成一輪、再統一休息）在
/// 今天頁的專用卡片。取代 `BlockDraftCard` 對 `blockType == .superset` 的
/// 通用渲染——原來的通用卡片只把每個成員各自的 `EntryRowView` 疊起來，沒有
/// A1/A2 標識、沒有「輪次」概念、也沒有組間休息的觸發入口。
///
/// 不需要新的 SwiftData schema：「Superset 的第 N 輪」＝「每個成員的第 N 個
/// `RoundDraft`（`setsCount` 固定為 1）」，「加一輪」＝對每個成員各呼叫一次
/// 既有的 `EntryDraft.addRound()`；成員之間允許輪數不齊（各自的 `rounds`
/// 陣列本來就是獨立的），不齊時每個成員自己的「補上第 N 輪」用全新預設值
/// 補，絕不覆製其他成員或其他輪次的數值。替換某個成員的動作沿用 P0 修好的
/// `EntryDraft.setExercise(_:)`，記錄單位不同時同樣不會把舊數字挪用到新
/// 單位下。
struct SupersetBlockDraftCard: View {
    @Bindable var block: BlockDraft
    let clientID: String
    let bandColorIndex: [String: [String]]
    let canMoveUp: Bool
    let canMoveDown: Bool
    var onMove: (Int) -> Void
    /// 拆回 N 個獨立 `.single` block——資料/順序原樣保留，只是這一步涉及
    /// `draft.blocks` 陣列本身的結構調整，必須交給持有那個陣列的 TodayView。
    var onDissolve: () -> Void
    var onDelete: () -> Void
    /// 全部成員的熱量估算合計（`≈N kcal`），資料不足時為 nil 不顯示。
    var energyText: String? = nil
    /// 「本輪結束・開始休息」：接到 TodayView 既有的共享 `RestTimerModel`
    /// （`{ seconds in restTimer.setTotal(seconds); restTimer.start() }`，
    /// 與 `RestTimerHeaderRow` 自己開始計時的方式完全一致），本卡片不另外持有一
    /// 份計時器狀態。
    var onStartRest: (Int) -> Void

    @Query(sort: \Exercise.canonicalName) private var allExercises: [Exercise]
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    @State private var showingAddMemberPicker = false
    @State private var memberPickerTarget: MemberPickerTarget?
    @State private var showingDeleteConfirmation = false
    @State private var showingRemoveLastRoundConfirmation = false
    @State private var showingRestPicker = false

    private struct MemberPickerTarget: Identifiable {
        let memberID: UUID
        var id: UUID { memberID }
    }

    private var maxRoundCount: Int {
        block.entries.map(\.rounds.count).max() ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.cardGap) {
            header
            ForEach(Array(block.entries.enumerated()), id: \.element.id) { index, entry in
                memberSection(entry, index: index)
                if index < block.entries.count - 1 {
                    Divider().overlay(DS.C.hairlineSoft)
                }
            }
            footer
        }
        .padding(.top, 12)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .gymCard()
        .sheet(isPresented: $showingAddMemberPicker) {
            ExercisePickerSheet(allExercises: allExercises, clientID: clientID) { exercise in
                addMember(exercise)
            }
        }
        .sheet(item: $memberPickerTarget) { target in
            ExercisePickerSheet(allExercises: allExercises, clientID: clientID) { exercise in
                replaceMember(id: target.memberID, with: exercise)
            }
        }
        .sheet(isPresented: $showingRestPicker) {
            PickerSheet(title: language.t("組間休息", "Rest Between Rounds")) {
                QuantityWheel(
                    value: Binding(get: { block.restSeconds ?? 60 }, set: { block.restSeconds = $0 }),
                    range: 0...300, step: 5
                ) { language.t("\($0) 秒", "\($0)s") }
            }
        }
        .confirmationDialog(
            language.t("刪除這個超級組？", "Delete this superset?"),
            isPresented: $showingDeleteConfirmation, titleVisibility: .visible
        ) {
            Button(language.t("刪除", "Delete"), role: .destructive) { onDelete() }
            Button(language.t("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(language.t(
                "這是最後一個動作，刪除後整個超級組會一併移除。",
                "This is the last exercise — removing it deletes the whole superset."
            ))
        }
        .confirmationDialog(
            language.t("刪除第 \(maxRoundCount) 輪？", "Delete round \(maxRoundCount)?"),
            isPresented: $showingRemoveLastRoundConfirmation, titleVisibility: .visible
        ) {
            Button(language.t("刪除", "Delete"), role: .destructive) { confirmRemoveLastRound() }
            Button(language.t("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(language.t(
                "會從每個動作裡移除第 \(maxRoundCount) 輪已記錄的重量/目標/實際。",
                "Removes round \(maxRoundCount)'s load/target/actual from every exercise in this superset."
            ))
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                headerChip(language.t("超級組", "Superset"))
                Menu {
                    ForEach(BlockType.allCases.filter { $0 != .unknown && $0 != .single }, id: \.self) { type in
                        Button {
                            block.blockType = type
                        } label: {
                            if block.blockType == type {
                                Label(type.displayName, systemImage: "checkmark")
                            } else {
                                Text(type.displayName)
                            }
                        }
                    }
                } label: {
                    headerChip(block.blockType.displayName)
                }

                Spacer(minLength: 0)

                Menu {
                    Button {
                        showingAddMemberPicker = true
                    } label: {
                        Label(language.t("加入動作", "Add Exercise"), systemImage: "plus")
                    }
                    Button {
                        onDissolve()
                    } label: {
                        Label(language.t("解散為獨立動作", "Dissolve to Separate Exercises"), systemImage: "square.split.2x1")
                    }
                    Button {
                        onMove(-1)
                    } label: {
                        Label(language.t("上移", "Move Up"), systemImage: "arrow.up")
                    }
                    .disabled(!canMoveUp)
                    Button {
                        onMove(1)
                    } label: {
                        Label(language.t("下移", "Move Down"), systemImage: "arrow.down")
                    }
                    .disabled(!canMoveDown)
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label(language.t("刪除這一塊", "Delete Block"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(DS.C.textMid)
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("superset-menu-button")
            }

            HStack(spacing: 12) {
                Text(language.t("共 \(maxRoundCount) 輪", "\(maxRoundCount) rounds"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.C.textMid)
                Button {
                    showingRestPicker = true
                } label: {
                    Text(language.t("輪間休息 \(block.restSeconds ?? 60)s", "Rest \(block.restSeconds ?? 60)s"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.C.accent)
                }
                if let energyText {
                    Text(energyText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.C.textLow)
                }
            }
        }
    }

    private func headerChip(_ title: String) -> some View {
        HStack(spacing: 3) {
            Text(title)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
        }
        .font(DS.F.dataLabel)
        .foregroundStyle(DS.C.textMid)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(DS.C.inset, in: Capsule())
    }

    // MARK: - Member sections

    private func memberSection(_ entry: EntryDraft, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("A\(index + 1)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(DS.C.accent)
                    .frame(minWidth: 22, alignment: .leading)
                Button {
                    memberPickerTarget = MemberPickerTarget(memberID: entry.id)
                } label: {
                    Text(entry.exercise.displayName)
                        .font(DS.F.cardTitle)
                        .foregroundStyle(DS.C.textHi)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("superset-member-name-\(index)")
                Spacer()
                if block.entries.count > 1 {
                    Button {
                        moveMember(entry.id, by: -1)
                    } label: {
                        Image(systemName: "chevron.up").font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.C.textLow)
                    .disabled(index == 0)
                    Button {
                        moveMember(entry.id, by: 1)
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.C.textLow)
                    .disabled(index == block.entries.count - 1)
                }
                Button(role: .destructive) {
                    removeMember(entry.id)
                } label: {
                    Image(systemName: "trash").font(.system(size: 12))
                }
                .accessibilityIdentifier("superset-remove-member-\(index)")
                .buttonStyle(.plain)
                .foregroundStyle(DS.C.danger)
                .accessibilityLabel(language.t("刪除 A\(index + 1)", "Delete A\(index + 1)"))
            }
            memberRoundRows(entry)
        }
    }

    private func memberRoundRows(_ entry: EntryDraft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(entry.rounds.enumerated()), id: \.element.id) { index, round in
                let roundID = round.id
                SupersetMemberRoundRow(
                    roundIndex: index,
                    round: Binding(
                        get: { entry.rounds.first(where: { $0.id == roundID }) ?? round },
                        set: { newValue in
                            if let idx = entry.rounds.firstIndex(where: { $0.id == roundID }) {
                                entry.rounds[idx] = newValue
                            }
                        }
                    ),
                    loadKind: loadKind(for: entry),
                    metric: entry.recordingMetric
                )
            }
            if entry.rounds.count < maxRoundCount {
                Button {
                    entry.addRound()
                } label: {
                    Label(
                        language.t("補上第 \(entry.rounds.count + 1) 輪", "Fill In Round \(entry.rounds.count + 1)"),
                        systemImage: "plus.circle"
                    )
                    .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.C.textLow)
            }
        }
        .padding(.leading, 30)
    }

    private func loadKind(for entry: EntryDraft) -> LoadWheelKind {
        let colors = bandColorIndex[entry.exercise.id] ?? []
        return LoadWheelResolver.kind(for: entry.exercise, historicalBandColors: colors)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                showingAddMemberPicker = true
            } label: {
                Label(language.t("加入動作", "Add Exercise"), systemImage: "plus.circle")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.C.accent)
            .accessibilityIdentifier("superset-add-member-button")

            Button {
                addRoundToAllMembers()
            } label: {
                Label(language.t("加一輪", "Add Round"), systemImage: "square.stack.3d.up.badge.plus")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.C.accent)
            .disabled(!block.entries.contains { $0.canAddRound })
            .accessibilityIdentifier("superset-add-round-button")

            if maxRoundCount > 1 {
                Button(role: .destructive) {
                    showingRemoveLastRoundConfirmation = true
                } label: {
                    Label(language.t("刪除最後一輪", "Delete Last Round"), systemImage: "minus.circle")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.C.danger)
            }

            Spacer(minLength: 0)

            Button {
                onStartRest(block.restSeconds ?? 60)
            } label: {
                Label(language.t("本輪結束・開始休息", "End Round · Rest"), systemImage: "timer")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.C.textHi)
        }
        .padding(.top, 4)
    }

    // MARK: - Member management

    // P3/M3a (2026-09-12): the actual mutation logic for every method below
    // moved into `TodayDraftMutationService` (`GymLogKit`) so the voice
    // command service can call the SAME implementation -- these stay as
    // thin forwarding calls so every button/confirmation-dialog trigger in
    // this file is untouched.

    private func addMember(_ exercise: Exercise) {
        TodayDraftMutationService.addMember(exercise, to: block)
    }

    private func replaceMember(id: UUID, with exercise: Exercise) {
        TodayDraftMutationService.replaceExercise(id, in: block, with: exercise)
    }

    private func removeMember(_ id: UUID) {
        if TodayDraftMutationService.removeMember(id, from: block) == .needsWholeBlockDeleteConfirmation {
            showingDeleteConfirmation = true
        }
    }

    private func moveMember(_ id: UUID, by offset: Int) {
        TodayDraftMutationService.moveMember(id, in: block, by: offset)
    }

    // MARK: - Round sync

    private func addRoundToAllMembers() {
        TodayDraftMutationService.addRoundToAllMembers(block)
    }

    private func confirmRemoveLastRound() {
        TodayDraftMutationService.removeLastRoundFromAllMembers(block)
    }
}

/// 一輪的重量/目標/實際三格——`RoundRow`（`EntryRowView.swift`）的精簡版，
/// 同一套「單一 `.sheet(item:)`、按 id 找 Binding」防禦模式（同檔案
/// `RoundTableView` 的註解裡那個真實崩潰修復的理由在這裡同樣成立：`index`
/// 只在渲染這一輪的當下有效，SwiftUI 仍可能在陣列已經變化後才呼叫這個
/// Binding 的 get/set）。Superset 場景下 `setsCount` 固定為 1（一輪＝一
/// 組），所以不需要「組數」欄——這正是它跟 `RoundRow` 唯一的結構性差異。
private struct SupersetMemberRoundRow: View {
    let roundIndex: Int
    @Binding var round: RoundDraft
    let loadKind: LoadWheelKind
    let metric: RecordingMetric

    private enum Field: Identifiable { case load, target, actual
        var id: Self { self }
    }
    @State private var editingField: Field?
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    private func quantityCellText(_ quantity: Int) -> (number: String, unit: String) {
        switch metric {
        case .time: return (RepTarget.formatSeconds(quantity), "")
        case .distance: return ("\(quantity)", language.t("米", "m"))
        case .rounds: return ("\(quantity)", language.t("輪", "rounds"))
        case .reps, .unknown: return ("\(quantity)", language.t("次", "reps"))
        }
    }

    private func quantityFieldTitle(isTarget: Bool) -> String {
        switch (isTarget, metric) {
        case (true, .time): return language.t("目標時間", "Target Time")
        case (true, .distance): return language.t("目標距離", "Target Distance")
        case (true, .rounds): return language.t("目標輪次", "Target Rounds")
        case (true, .reps), (true, .unknown): return language.t("目標次數", "Target Reps")
        case (false, .time): return language.t("實際時間", "Actual Time")
        case (false, .distance): return language.t("實際距離", "Actual Distance")
        case (false, .rounds): return language.t("實際輪次", "Actual Rounds")
        case (false, .reps), (false, .unknown): return language.t("實際次數", "Actual Reps")
        }
    }

    // R01 (2026-09-16): same rationale as EntryRowView.RoundRow's identical
    // pair -- `round.target`/`.actual` are the real `RepTarget` now, these
    // wheels can only show/edit one `Int`.
    private var targetQuantityBinding: Binding<Int> {
        Binding(
            get: { RepTargetToRoundQuantity.quantity(from: round.target, metric: metric) },
            set: { round.target = RepTargetToRoundQuantity.repTarget(quantity: $0, metric: metric) }
        )
    }

    private var actualQuantityBinding: Binding<Int> {
        Binding(
            get: { RepTargetToRoundQuantity.quantity(from: round.actual, metric: metric) },
            set: { round.actual = RepTargetToRoundQuantity.repTarget(quantity: $0, metric: metric) }
        )
    }

    var body: some View {
        let target = quantityCellText(RepTargetToRoundQuantity.quantity(from: round.target, metric: metric))
        let actual = round.actualRecorded ? quantityCellText(RepTargetToRoundQuantity.quantity(from: round.actual, metric: metric)) : (number: "—", unit: "")

        HStack(spacing: 6) {
            Text("R\(roundIndex + 1)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.C.textMid)
                .frame(width: 24, alignment: .leading)

            cell(round.load.displayText, width: 74) { editingField = .load }
            cell("\(target.number)\(target.unit)", width: 64) { editingField = .target }
            cell("\(actual.number)\(actual.unit)", width: 64) { editingField = .actual }
            Spacer(minLength: 0)
        }
        .sheet(item: $editingField) { field in
            switch field {
            case .load:
                PickerSheet(title: language.t("重量", "Load"), contentHeight: 270) {
                    LoadWheel(load: $round.load, kind: loadKind)
                }
            case .target:
                PickerSheet(title: quantityFieldTitle(isTarget: true)) {
                    quantityWheel(targetQuantityBinding)
                }
            case .actual:
                PickerSheet(title: quantityFieldTitle(isTarget: false)) {
                    VStack {
                        quantityWheel(actualQuantityBinding)
                        Button(language.t("記錄此數值", "Record this value")) { round.actualRecorded = true; editingField = nil }
                        Button(language.t("清除實際成績", "Clear result")) { round.actualRecorded = false; editingField = nil }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func quantityWheel(_ binding: Binding<Int>) -> some View {
        switch metric {
        case .time:
            TimeQuantityWheel(seconds: binding)
        case .distance:
            QuantityWheel(value: binding, range: 50...50000, step: 50) { language.t("\($0) 米", "\($0) m") }
        case .rounds:
            QuantityWheel(value: binding, range: 1...30, step: 1) { language.t("\($0) 輪", "\($0) rounds") }
        case .reps, .unknown:
            RepsCountWheel(reps: binding)
        }
    }

    private func cell(_ text: String, width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(DS.C.textHi)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: width, height: 30)
                .background(DS.C.inset, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
