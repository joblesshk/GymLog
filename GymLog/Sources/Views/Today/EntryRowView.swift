import SwiftUI
import SwiftData
import GymLogKit

/// One exercise entry in the active session draft.
///
/// CONTRACT-M5.md §3.2/§3.3 replaces M4's "wheels always expanded + 逐组编辑
/// toggle" layout entirely: every selectable value (动作/组数/重量/次数) is now
/// plain tappable text that opens a `.sheet` and collapses back on 完成, and
/// the old flat setsCount/repTarget/load trio + per-set override subsystem
/// is gone, replaced by the Round table (`RoundTableView` below) --
/// `EntryDraft.rounds`, 1-4 genuinely different weight/rep attempts within
/// this exercise on the same day (the coach's own bench-press example: 2
/// sets @ 30kg, then 3 sets @ 45kg, then 2 sets @ 40kg). The chart-icon
/// button still opens the M3 `ExerciseHistoryView` seam (CONTRACT-UI.md §2)
/// as a sheet.
///
/// Visual spec: HANDOFF.md §4.2/§4.3.
struct EntryRowView: View {
    @Bindable var draft: EntryDraft
    let clientID: String
    // Perf fix (kept from M2/M4, still relevant): these used to be computed
    // independently by every row (a full-table SwiftData fetch + decode-
    // every-set scan each), re-run on every SwiftUI body evaluation.
    // `TodayView` computes both ONCE per appearance/client-change and hands
    // the *result* down here.
    let repTargetPresets: [RepTargetPreset]
    let bandColorIndex: [String: [String]]
    /// 该动作所在训练块的默认休息秒数，并入副标题显示（HANDOFF.md §4.3）。纯信息
    /// 展示 -- 组间休息倒计时功能已按教练要求整体移除，这里不再是可点击按钮。
    var restSeconds: Int?
    /// 该动作的热量估算（`≈N kcal`），并入副标题末尾；数据不足时为 nil 不显示。
    var energyText: String? = nil
    var onDelete: () -> Void

    @Query(sort: \Exercise.canonicalName) private var allExercises: [Exercise]

    @State private var showHistory = false
    @State private var exercisePickerPresentation: ExercisePickerPresentation?
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    /// 2026-09-11 P0 崩溃修复：单一 `.sheet(item:)` 是这一行「修改動作」的唯一
    /// 弹窗入口——滚轮/搜索是同一個 sheet 的两种內容，不是兩層疊起来的獨立
    /// sheet（根因與修复說明見 `ExercisePickerWheel.onRequestSearch`）。
    private enum ExercisePickerPresentation: Identifiable {
        case wheel
        case search
        var id: Self { self }
    }

    private var loadKind: LoadWheelKind {
        let colors = bandColorIndex[draft.exercise.id] ?? []
        return LoadWheelResolver.kind(for: draft.exercise, historicalBandColors: colors)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            RoundTableView(draft: draft, loadKind: loadKind)
        }
        .padding(.top, 12)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .gymCard()
        .sheet(isPresented: $showHistory) {
            NavigationStack {
                ExerciseHistoryView(clientID: clientID, exerciseID: draft.exercise.id)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(language.t("關閉", "Close")) { showHistory = false }
                        }
                    }
            }
        }
        .sheet(item: $exercisePickerPresentation) { presentation in
            switch presentation {
            case .wheel:
                PickerSheet(title: language.t("選擇動作", "Select Exercise")) {
                    ExercisePickerWheel(
                        exercise: Binding(
                            get: { draft.exercise },
                            set: { draft.setExercise($0) }
                        ),
                        clientID: clientID,
                        onRequestSearch: { exercisePickerPresentation = .search }
                    )
                }
            case .search:
                ExercisePickerSheet(allExercises: allExercises, clientID: clientID) { picked in
                    draft.setExercise(picked)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            MovementPatternBadge(pattern: draft.exercise.movementPattern)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Button {
                    exercisePickerPresentation = .wheel
                } label: {
                    // 2026-09-16 改回原版樣式：中文名 + 括號英文名同一行、同字
                    // 級（`Exercise.displayName`，已經按 appLanguage 決定誰在
                    // 前面），不再是「中文主行、英文降級副行」的堆疊版型。
                    Text(draft.exercise.displayName)
                        .font(DS.F.cardTitle)
                        .foregroundStyle(DS.C.textHi)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("entry-exercise-name")
                .accessibilityLabel(draft.exercise.displayName)

                summaryLine
            }

            Spacer()

            Button {
                showHistory = true
            } label: {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 17))
                    .foregroundStyle(DS.C.textLow)
            }
            .accessibilityLabel(language.t("查看歷史", "View history"))

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 16))
                    .foregroundStyle(DS.C.danger)
            }
            .accessibilityLabel(language.t("刪除", "Delete"))
        }
    }

    private var roundWord: String {
        language.t(
            draft.rounds.count == 1 ? "1 個 Round" : "\(draft.rounds.count) 個 Round",
            draft.rounds.count == 1 ? "1 Round" : "\(draft.rounds.count) Rounds"
        )
    }

    private var summaryLine: some View {
        Group {
            Text(([language.t("\(roundWord) · 共 \(draft.plannedSets) 組", "\(roundWord) · \(draft.plannedSets) sets")]
                + [restSeconds.map { language.t("休息 \($0)s", "Rest \($0)s") }, energyText].compactMap { $0 })
                .joined(separator: " · "))
                .accessibilityIdentifier("entry-summary-line")
        }
        .font(DS.F.subtitle)
        .foregroundStyle(DS.C.textLow)
    }
}

/// CONTRACT-M9.md v2: five columns (ROUND/組數/重量/目標/實際, plus an
/// optional 删除 button) on ONE row again -- the v1 two-row layout was
/// functionally fine but visually poor per direct coach feedback ("依然保持
/// 一行"). Getting five columns onto one ~374pt-wide card without SwiftUI's
/// default equal-width `.flexible()` grid columns starving 重量 (the one
/// column with realistically longer text, e.g. "輔助 30kg") requires
/// deliberately UNEQUAL column widths -- `RoundColumnLayout` computes them
/// from the real available width via `GeometryReader`, shared identically by
/// the header row and every `RoundRow` so columns line up. Every editable
/// cell still follows §3.2's tap-to-open-sheet rule; 组数 reuses
/// `SetsCountWheel`, 重量 reuses `LoadWheel`, 目標/實際 both dispatch to the
/// same metric-driven wheel (`RepsCountWheel`/`TimeQuantityWheel`/
/// `QuantityWheel`, CONTRACT-M8.md), just bound to different Round fields.
private struct RoundTableView: View {
    @Bindable var draft: EntryDraft
    let loadKind: LoadWheelKind
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    // R02 (2026-09-16): must read the frozen `draft.recordingMetric`, not
    // `draft.exercise.recordingMetric` live -- `Exercise` is a SwiftData
    // reference type the coach can reclassify (動作庫 -> 編輯 -> 記錄單位) at
    // any time, independently of any draft/history entry already pointing
    // at it. Reading it live here reintroduces exactly the bug
    // `EntryDraft`'s own `recordingMetric` capture (see its doc comment,
    // "2026-09-07 审阅 B02") exists to prevent: a saved 500m row entry, after
    // the exercise gets reclassified to reps, showing/editing as "500 次"
    // here even though `SessionDraftLoader`/`resolvedSets()` still correctly
    // treat it as meters.
    private var metric: RecordingMetric { draft.recordingMetric }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let layout = RoundColumnLayout(totalWidth: geo.size.width, canDelete: draft.canRemoveRound)
                HStack(spacing: layout.spacing) {
                    // No header label here -- "ROUND"/"輪次" doesn't fit this
                    // column's ~22pt width at any readable size, and every
                    // data row's own "R1"/"R2" label already makes the
                    // column's meaning self-evident.
                    Color.clear
                        .frame(width: layout.roundWidth, height: 1)
                    Text(language.t("組數", "SETS")).roundHeaderStyle(alignment: .center).frame(width: layout.setsWidth)
                    Text(language.t("重量", "LOAD")).roundHeaderStyle(alignment: .center).frame(width: layout.loadWidth)
                    Text(language.t("目標", "TARGET")).roundHeaderStyle(alignment: .center).frame(width: layout.targetWidth)
                    Text(language.t("實際", "ACTUAL")).roundHeaderStyle(alignment: .center).frame(width: layout.actualWidth)
                    if draft.canRemoveRound {
                        Color.clear.frame(width: layout.deleteWidth, height: 1)
                    }
                }
            }
            .frame(height: 13)

            ForEach(Array(draft.rounds.enumerated()), id: \.element.id) { index, round in
                // Bound by `round.id`, looked up fresh on every get/set,
                // NOT by the captured `index`. This is a real, confirmed
                // crash fix, not defensive styling: `index` is only valid
                // for the render pass that created this closure, but
                // SwiftUI can still invoke a `RoundRow`'s Binding
                // get/set during its own removal transition/diffing,
                // after `draft.rounds` has already shrunk -- at that point
                // the old `index` is out of range and `draft.rounds[index]`
                // traps (confirmed via a real crash log: `Array.
                // _checkSubscript` inside this exact closure). Looking up
                // by id instead degrades gracefully (falls back to the
                // last-known snapshot / no-ops) if the round is already
                // gone, instead of crashing.
                let roundID = round.id
                RoundRow(
                    index: index,
                    round: Binding(
                        get: { draft.rounds.first(where: { $0.id == roundID }) ?? round },
                        set: { newValue in
                            if let idx = draft.rounds.firstIndex(where: { $0.id == roundID }) {
                                draft.rounds[idx] = newValue
                            }
                        }
                    ),
                    loadKind: loadKind,
                    metric: metric,
                    canDelete: draft.canRemoveRound,
                    onDelete: { draft.removeRound(id: roundID) }
                )
            }
        }

        if draft.canAddRound {
            Button {
                draft.addRound()
            } label: {
                Label(language.t("添加 Round", "Add Round"), systemImage: "plus.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.C.accent)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
        }
    }
}

/// CONTRACT-M9.md v2, ratios updated by GymLog 改版設計 §3: 重量與實際是現場
/// 最常改的兩個值，改版前四欄一樣寬（除了本來就寬的重量），現在實際也跟著
/// 放大——0.85 / 1.5 / 0.9 / 1.15，四者相加仍是 4.4 整除，算法不變。重量仍是
/// 最寬的一欄：最長的常見文字是「輔助 30kg」/「紫帶 x2」。
private struct RoundColumnLayout {
    let roundWidth: CGFloat
    let setsWidth: CGFloat
    let loadWidth: CGFloat
    let targetWidth: CGFloat
    let actualWidth: CGFloat
    let deleteWidth: CGFloat
    let spacing: CGFloat = 5

    init(totalWidth: CGFloat, canDelete: Bool) {
        roundWidth = 22
        deleteWidth = canDelete ? 20 : 0
        let gapCount: CGFloat = canDelete ? 5 : 4
        let remaining = max(0, totalWidth - roundWidth - deleteWidth - spacing * gapCount)
        let unit = remaining / 4.4
        setsWidth = unit * 0.85
        loadWidth = unit * 1.5
        targetWidth = unit * 0.9
        actualWidth = unit * 1.15
    }
}

private extension Text {
    func roundHeaderStyle(alignment: Alignment) -> some View {
        self
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(DS.C.textLow)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

/// One Round, one row: a read-only "R1" label (HANDOFF.md §4.2: shortened
/// from "Round 1" to reclaim horizontal space) plus four tap-to-open data
/// cells sized by `RoundColumnLayout` (CONTRACT-M9.md v2). Each cell opens
/// `PickerSheet` wrapping the field's own wheel and collapses back to plain
/// text on 完成 (CONTRACT-M5.md §3.2).
private struct RoundRow: View, Identifiable {
    let index: Int
    @Binding var round: RoundDraft
    let loadKind: LoadWheelKind
    let metric: RecordingMetric
    let canDelete: Bool
    var onDelete: () -> Void

    var id: UUID { round.id }

    private enum Field: Identifiable { case sets, load, target, actual
        var id: Self { self }
    }
    @State private var editingField: Field?
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    /// CONTRACT-M8.md: the quantity cell's number+unit formatting follows
    /// `metric` -- `.time` renders m:ss (no separate unit suffix, matching
    /// `RepTarget.time`'s own display convention), the others keep the
    /// existing number+unit split.
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

    /// R01 (2026-09-16): `round.target`/`.actual` are the real `RepTarget`
    /// now (`.range`/`.perSide` included for an untouched historical Round)
    /// -- these wheels can only show/edit one `Int`, so the binding reads
    /// via `RepTargetToRoundQuantity.quantity(from:metric:)` (lossy for
    /// `.range`/`.perSide`, same midpoint rule as always) and writes back
    /// through `repTarget(quantity:metric:)`. Only actually opening this
    /// sheet and changing the value narrows the stored `RepTarget` to
    /// `metric`'s simple shape -- merely displaying it never does.
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
        GeometryReader { geo in
            let layout = RoundColumnLayout(totalWidth: geo.size.width, canDelete: canDelete)
            let target = quantityCellText(RepTargetToRoundQuantity.quantity(from: round.target, metric: metric))
            let actual = round.actualRecorded ? quantityCellText(RepTargetToRoundQuantity.quantity(from: round.actual, metric: metric)) : (number: "—", unit: "")

            HStack(spacing: layout.spacing) {
                Text("R\(index + 1)")
                    .font(DS.F.roundTagCompact)
                    .foregroundStyle(DS.C.textMid)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: layout.roundWidth, alignment: .leading)

                dataCell(number: "\(round.setsCount)", unit: language.t("組", "x"), width: layout.setsWidth, kind: .sets) { editingField = .sets }
                loadCell(width: layout.loadWidth) { editingField = .load }
                dataCell(number: target.number, unit: target.unit, width: layout.targetWidth, kind: .target) { editingField = .target }
                if round.actualRecorded {
                    dataCell(number: actual.number, unit: actual.unit, width: layout.actualWidth, kind: .actual) { editingField = .actual }
                } else {
                    unrecordedActualCell(width: layout.actualWidth) { editingField = .actual }
                }

                if canDelete {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 15))
                            .foregroundStyle(DS.C.danger)
                    }
                    .buttonStyle(.plain)
                    .frame(width: layout.deleteWidth)
                    .accessibilityLabel(language.t("刪除 Round \(index + 1)", "Delete Round \(index + 1)"))
                }
            }
        }
        .frame(height: 46)
        .sheet(item: $editingField) { field in
            switch field {
            case .sets:
                PickerSheet(title: language.t("組數", "Sets")) {
                    SetsCountWheel(sets: $round.setsCount)
                }
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

    /// GymLog 改版設計 §3：重量與實際是現場最常改的兩個值，要比組數/目標更
    /// 突出；實際額外用 accent 描邊框住，跟「已記錄」的狀態綁在一起——描邊本
    /// 身就是「這是教練剛剛按進去的數字」的視覺提示，不用再讀顏色以外的東西。
    private enum RoundCellKind { case sets, target, actual }

    private func numberFont(_ kind: RoundCellKind) -> Font {
        switch kind {
        case .sets: return .system(size: 16, weight: .semibold)
        case .target: return .system(size: 14, weight: .medium)
        case .actual: return .system(size: 20, weight: .bold)
        }
    }

    private func numberColor(_ kind: RoundCellKind) -> Color {
        switch kind {
        case .sets: return DS.C.textHi
        case .target: return DS.C.textMid
        case .actual: return DS.C.accent
        }
    }

    @ViewBuilder
    private func dataCell(number: String, unit: String, width: CGFloat, kind: RoundCellKind, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(number)
                    .font(numberFont(kind))
                    .monospacedDigit()
                    .foregroundStyle(numberColor(kind))
                if !unit.isEmpty {
                    Text(unit)
                        .font(DS.F.dataUnitCompact)
                        .foregroundStyle(kind == .actual ? DS.C.accent : DS.C.textLow)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: width)
            .frame(height: 46)
            .background(kind == .actual ? DS.C.accentSoft : DS.C.inset, in: Capsule())
            .overlay {
                if kind == .actual {
                    Capsule().stroke(DS.C.accent, lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// 未記錄的「實際」：虛線 accent 描邊 + 「＋」，取代原本的純文字「—」——
    /// 一眼就能看出這一格「還沒填」而不是「填了個破折號」。
    private func unrecordedActualCell(width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.C.accent)
                .frame(width: width, height: 46)
                .background(DS.C.surface, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(DS.C.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language.t("記錄實際成績", "Record actual result"))
    }

    @ViewBuilder
    private func loadCell(width: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let numeric = round.load.numericDisplay {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(numeric.value)
                            .font(.system(size: 19, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(DS.C.textHi)
                        Text(numeric.unit)
                            .font(DS.F.dataUnitCompact)
                            .foregroundStyle(DS.C.textLow)
                    }
                } else {
                    Text(round.load.displayText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.C.textHi)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .frame(width: width)
            .frame(height: 46)
            .background(DS.C.inset, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("entry-load-button")
    }
}

extension LoadValue {
    /// Splits `displayText` into a numeric value + unit pair when the value
    /// is a plain number (e.g. "40kg" -> ("40", "kg")), for the 19/11
    /// number+unit baseline-aligned style (HANDOFF.md §4.2). Non-numeric
    /// values (e.g. "紫带") return nil and fall back to plain centered text.
    var numericDisplay: (value: String, unit: String)? {
        let text = displayText
        guard let firstNonDigit = text.firstIndex(where: { !($0.isNumber || $0 == ".") }) else {
            return text.isEmpty ? nil : (text, "")
        }
        let value = String(text[text.startIndex..<firstNonDigit])
        let unit = String(text[firstNonDigit...])
        guard !value.isEmpty else { return nil }
        return (value, unit)
    }
}
