import SwiftUI
import SwiftData
import Charts
import GymLogKit

// MARK: - Environment seam for the query page's date-range pre-filter
//
// ExerciseQueryView (CONTRACT-UI.md §4.3) needs to hand this view an
// optional starting date range without touching the frozen initializer
// (CONTRACT-UI.md §2: `init(clientID:exerciseID:)` is exactly what M2
// depends on). An environment value lets the query page seed an internal,
// user-adjustable filter instead. Internal (not private) so both files in
// this directory can use it; nothing outside the GymLog app target needs it.
struct ExerciseHistoryInitialDateRangeKey: EnvironmentKey {
    static let defaultValue: ClosedRange<Date>? = nil
}

extension EnvironmentValues {
    var exerciseHistoryInitialDateRange: ClosedRange<Date>? {
        get { self[ExerciseHistoryInitialDateRangeKey.self] }
        set { self[ExerciseHistoryInitialDateRangeKey.self] = newValue }
    }
}

/// Single-exercise history for one client — the M3 deliverable behind
/// 工程规划 §4.3 and the seam defined in CONTRACT-UI.md §2.
///
/// Type name and initializer signature are frozen: M2 embeds this as a
/// sheet from the entry row's expand button. All analytics math is
/// delegated to `Sources/Analytics/**` (AnalyticsMath / ExerciseHistoryPoint
/// / ExerciseHistoryAnalyzer / ChartMetric) — this file is presentation only.
struct ExerciseHistoryView: View {
    let clientID: String
    let exerciseID: String

    @Environment(\.exerciseHistoryInitialDateRange) private var initialDateRange

    // Fetched unfiltered and filtered in Swift (not via #Predicate): the
    // filter spans three optional-relationship hops
    // (entry -> block -> session -> client), which is well within reach for
    // 742 entries in memory but a poor fit for SwiftData's predicate
    // translator across that many optional hops. See VERIFICATION-M3.md.
    @Query private var allEntries: [ExerciseEntry]
    @Query private var allExercises: [Exercise]

    @State private var metric: ChartMetric = .maxLoad
    // Set once the exercise's recordingMetric is known (see `onAppear`) --
    // guarded so a later `onAppear` (e.g. returning from background) can't
    // stomp on a metric the coach already picked by hand.
    @State private var hasSetDefaultMetric = false
    // Rule ⑤: isInferred defaults to INCLUDED. All 2372 migrated SetLogs are
    // isInferred = true; defaulting this to false would make every chart in
    // the app empty on first launch.
    @State private var includeInferred: Bool = true
    @State private var dateRange: ClosedRange<Date>?
    @State private var showingDateRangeEditor = false
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    init(clientID: String, exerciseID: String) {
        self.clientID = clientID
        self.exerciseID = exerciseID
    }

    private var exercise: Exercise? {
        allExercises.first { $0.id == exerciseID }
    }

    private var direction: LoadDirection {
        exercise?.loadDirection ?? .higherIsStronger
    }

    private var relevantEntries: [ExerciseEntry] {
        allEntries.filter {
            $0.exercise?.id == exerciseID && $0.block?.session?.client?.id == clientID
        }
    }

    // Perf fix: this used to be a computed `var`, so `ExerciseHistoryAnalyzer
    // .points()` -- which JSON-decodes every contributing SetLog's
    // load/target/actual -- reran on EVERY body evaluation, and `body` reads
    // it (via `points`) in ~12 places (header, PR card, chart, caption,
    // every detail-list row) -- roughly a dozen full re-decodes of this
    // exercise's entire history per single render pass, for a popular
    // exercise like Bench press (195 sets) worth of redundant work on every
    // toggle tap. Cached in `@State`, refreshed only when its real
    // dependency (`includeInferred`) or the underlying data actually
    // changes -- not on every body pass.
    @State private var allPoints: [ExerciseHistoryPoint] = []

    private func refreshPoints() {
        allPoints = ExerciseHistoryAnalyzer.points(from: relevantEntries, loadDirection: direction, includeInferred: includeInferred)
    }

    private var points: [ExerciseHistoryPoint] {
        guard let range = dateRange else { return allPoints }
        return allPoints.filter { range.contains($0.date) }
    }

    /// PR flag for every currently-visible point, keyed by point id.
    /// Computed once per body pass and shared by the chart and the detail
    /// list — before this, `isPR`/`detailRow` each independently recomputed
    /// `points` (re-filtering `allPoints` by `dateRange`), recomputed a full
    /// `ExerciseHistoryAnalyzer.prFlags` PR scan, AND ran
    /// `points.firstIndex(where:)`
    /// (another O(n) scan) for EVERY one of the n visible points, an O(n²)
    /// cost over the visible history (2026-09-06 审查报告"运行效率"#1).
    private var prFlagsByPointID: [String: Bool] {
        let currentPoints = points
        let flags = ExerciseHistoryAnalyzer.prFlags(points: currentPoints, direction: direction)
        var byID: [String: Bool] = [:]
        byID.reserveCapacity(currentPoints.count)
        for (point, flag) in zip(currentPoints, flags) {
            byID[point.id] = flag
        }
        return byID
    }

    private var currentPR: (value: Double, point: ExerciseHistoryPoint)? {
        ExerciseHistoryAnalyzer.currentPR(points: points, direction: direction)
    }

    var body: some View {
        Group {
            if let exercise {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(exercise)
                        prSummaryCard
                        controls
                        chartSection
                        Divider()
                        detailList
                    }
                    .padding()
                }
                .background(DS.C.canvas)
            } else {
                ContentUnavailableView(
                    language.t("動作未找到", "Exercise Not Found"),
                    systemImage: "questionmark.circle",
                    description: Text(language.t("exerciseID=\(exerciseID) 在動作庫中不存在", "exerciseID=\(exerciseID) not found in exercise library"))
                )
            }
        }
        .navigationTitle(exercise?.displayName ?? language.t("單項歷史", "Exercise History"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if dateRange == nil, let initialDateRange {
                dateRange = initialDateRange
            }
            refreshPoints()
            if !hasSetDefaultMetric, let exercise {
                hasSetDefaultMetric = true
                metric = ChartMetric.defaultMetric(for: exercise.recordingMetric)
            }
        }
        .onChange(of: includeInferred) {
            refreshPoints()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ exercise: Exercise) -> some View {
        HStack(spacing: 8) {
            Text(exercise.movementPattern.displayName)
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.secondary.opacity(0.15), in: Capsule())
            Text(exercise.equipment.displayName)
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.secondary.opacity(0.15), in: Capsule())
            if direction.isInverted {
                Label(language.t("輔助類·越小越強", "Assisted · Lower Is Stronger"), systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(DS.C.inset, in: Capsule())
                    .foregroundStyle(DS.C.textMid)
            }
            Spacer()
        }
    }

    // MARK: - PR summary

    @ViewBuilder
    private var prSummaryCard: some View {
        if let pr = currentPR {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.t("歷史最佳（重量）", "Best Ever (Weight)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(weightText(pr.value))
                        .font(.title3.bold())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(SessionDateFormat.display.string(from: pr.point.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    lastDeltaBadge
                }
            }
            .padding(12)
            .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        } else {
            Text(language.t("暫無可比較的重量數據", "No comparable weight data yet"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// "较上次" delta on the weight (maxLoadKg) series specifically — rule
    /// ①'s own example ("较上次 -5kg 应呈现为进步") is phrased in terms of
    /// weight, so this badge always reflects the weight series regardless
    /// of which chart metric is currently selected.
    @ViewBuilder
    private var lastDeltaBadge: some View {
        let weightPoints = points.compactMap { p -> (Date, Double)? in
            guard let v = p.maxLoadKg else { return nil }
            return (p.date, v)
        }
        if weightPoints.count >= 2 {
            let last = weightPoints[weightPoints.count - 1].1
            let prev = weightPoints[weightPoints.count - 2].1
            let delta = last - prev
            let improved = AnalyticsMath.isImprovement(candidate: last, overBest: prev, direction: direction)
            let same = delta == 0
            Text(deltaText(delta))
                .font(.caption.bold())
                .foregroundStyle(same ? Color.secondary : (improved ? Color.green : Color.red))
        }
    }

    private func deltaText(_ delta: Double) -> String {
        let sign = delta > 0 ? "+" : ""
        return language.t("較上次 \(sign)\(formatKg(delta))kg", "\(sign)\(formatKg(delta))kg vs last")
    }

    private func weightText(_ kg: Double) -> String {
        "\(formatKg(kg))kg"
    }

    private func formatKg(_ kg: Double) -> String {
        if kg == kg.rounded() { return String(format: "%.0f", kg) }
        return String(format: "%.1f", kg)
    }

    // MARK: - Controls

    /// The metric picker only offers metrics that can actually be
    /// non-empty for this exercise's `recordingMetric` — a reps-based
    /// exercise never shows "最長時長"/"最遠距離"/"最多輪次", and a timed
    /// exercise never shows "完成次數" (2026-09-06 审查报告"适合当前范围的
    /// 功能"第二批).
    private var relevantMetrics: [ChartMetric] {
        let recordingMetric = exercise?.recordingMetric ?? .unknown
        return ChartMetric.allCases.filter { $0.isRelevant(for: recordingMetric) }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(language.t("指標", "Metric"), selection: $metric) {
                ForEach(relevantMetrics) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Toggle(language.t("包含推斷數據（遷移記錄）", "Include Inferred Data (migrated)"), isOn: $includeInferred)
                    .font(.caption)
                Spacer()
            }

            dateRangeControl
        }
    }

    @ViewBuilder
    private var dateRangeControl: some View {
        HStack {
            Button {
                showingDateRangeEditor = true
            } label: {
                Label(dateRangeSummary, systemImage: "calendar")
                    .font(.caption)
            }
            if dateRange != nil {
                Button(language.t("清除", "Clear")) { dateRange = nil }
                    .font(.caption)
            }
        }
        .sheet(isPresented: $showingDateRangeEditor) {
            DateRangeEditorSheet(
                initialRange: dateRange ?? defaultEditableRange,
                onApply: { dateRange = $0 },
                onClear: { dateRange = nil }
            )
        }
    }

    /// Both bounds are UTC-midnight-encoded (same representation as
    /// `dateRange`/`session.date`), never a raw "now"/wall-clock instant —
    /// `DateRangeEditorSheet` decodes both ends back to a local display
    /// date at its own boundary (2026-09-07 审阅 B07), so whatever it's
    /// handed here must already be in the encoded form or that decode step
    /// would double-convert it.
    private var defaultEditableRange: ClosedRange<Date> {
        let today = TrainingDayEncoding.utcDay(from: Date())
        let earliest = allPoints.map(\.date).min() ?? today
        return earliest...today
    }

    private var dateRangeSummary: String {
        guard let range = dateRange else { return language.t("全部時間範圍", "All Time") }
        let f = SessionDateFormat.display
        return "\(f.string(from: range.lowerBound)) – \(f.string(from: range.upperBound))"
    }

    // MARK: - Chart

    @ViewBuilder
    private var chartSection: some View {
        let chartable = points.compactMap { p -> (ExerciseHistoryPoint, Double)? in
            guard let v = metric.value(for: p) else { return nil }
            return (p, v)
        }
        let prByID = prFlagsByPointID

        if chartable.isEmpty {
            emptyMetricNote
                .frame(maxWidth: .infinity, minHeight: 120)
                .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Chart {
                    ForEach(chartable, id: \.0.id) { point, value in
                        LineMark(
                            x: .value(language.t("日期", "Date"), point.date),
                            y: .value(metric.displayName, value)
                        )
                        .foregroundStyle(.blue.opacity(0.6))

                        PointMark(
                            x: .value(language.t("日期", "Date"), point.date),
                            y: .value(metric.displayName, value)
                        )
                        .symbol(point.anyInferred ? .circle : .square)
                        .symbolSize(isPR(point, in: prByID) ? 140 : 50)
                        .foregroundStyle(isPR(point, in: prByID) ? .orange : .blue)
                    }
                }
                .chartYAxisLabel { Text(metric.unitLabel(direction: direction)) }
                .frame(height: 220)

                metricCaption(chartable: chartable)

                if metric == .volume {
                    volumeExclusionNote
                }
            }
        }
    }

    private func isPR(_ point: ExerciseHistoryPoint, in prFlagsByID: [String: Bool]) -> Bool {
        guard metric == .maxLoad else { return false }
        return prFlagsByID[point.id] ?? false
    }

    @ViewBuilder
    private var emptyMetricNote: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.xyaxis.line")
                .foregroundStyle(.secondary)
            Text(emptyMetricMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private var emptyMetricMessage: String {
        switch metric {
        case .maxLoad:
            return language.t("該動作沒有可比較的重量數值（自重 / 彈力帶 / 器械配重檔等類型不產生數值曲線）", "This exercise has no comparable weight values (bodyweight/band/machine-stack types don't produce a numeric curve)")
        case .estimated1RM:
            if direction.isInverted {
                return language.t("輔助類動作（越小越強）不計算估算1RM", "Assisted exercises (lower is stronger) don't compute estimated 1RM")
            }
            return language.t("暫無滿足條件的記錄 — 僅當同一組為絕對重量且實際完成為 1–12 次固定次數時才計算估算1RM", "No qualifying records yet — estimated 1RM only applies to absolute-weight sets with 1–12 fixed completed reps")
        case .volume:
            return language.t("該動作不參與容量統計（自重 / 彈力帶 / 器械配重檔 / 時間 / 距離 / 輪次類不計入）", "This exercise isn't counted in volume stats (bodyweight/band/machine-stack/time/distance/rounds types are excluded)")
        case .completedReps:
            return language.t("暫無可計入的次數記錄（時間 / 距離 / 輪次類不計入完成次數）", "No countable rep records yet (time/distance/rounds types aren't counted as completed reps)")
        case .completedDuration:
            return language.t("暫無時長記錄", "No hold-time records yet")
        case .completedDistance:
            return language.t("暫無距離記錄", "No distance records yet")
        case .completedRounds:
            return language.t("暫無輪次記錄", "No rounds records yet")
        }
    }

    @ViewBuilder
    private func metricCaption(chartable: [(ExerciseHistoryPoint, Double)]) -> some View {
        if chartable.count >= 2 {
            let last = chartable[chartable.count - 1].1
            let prev = chartable[chartable.count - 2].1
            let delta = last - prev
            let improved = metric.isImprovement(last, over: prev, direction: direction)
            let same = delta == 0
            HStack(spacing: 4) {
                Text(language.t("\(metric.displayName) 較上次：", "\(metric.displayName) vs last:"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(delta > 0 ? "+" : "")\(formatKg(delta))")
                    .font(.caption2.bold())
                    .foregroundStyle(same ? Color.secondary : (improved ? Color.green : Color.red))
            }
        }
    }

    @ViewBuilder
    private var volumeExclusionNote: some View {
        let summary = ExerciseHistoryAnalyzer.volumeSummary(points: points)
        if summary.excludedSetCount > 0 {
            Text(language.t(
                "另有 \(summary.excludedSetCount) 組無法計入容量" + (summary.anyEstimated ? "（含區間實際次數取中值估算的部分）" : ""),
                "\(summary.excludedSetCount) more set(s) not counted in volume" + (summary.anyEstimated ? " (includes range-estimated midpoints)" : "")
            ))
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Detail list

    @ViewBuilder
    private var detailList: some View {
        let currentPoints = points
        let prByID = prFlagsByPointID
        VStack(alignment: .leading, spacing: 4) {
            Text(language.t("訓練明細（\(currentPoints.count)）", "Details (\(currentPoints.count))"))
                .font(.headline)
            if currentPoints.isEmpty {
                Text(language.t("暫無記錄", "No records yet"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // LazyVStack, not VStack: a popular exercise can have hundreds
                // of history rows, and this whole section already lives
                // inside the screen's outer `ScrollView` — only the rows
                // actually scrolled into view need to be built (2026-09-06
                // 审查报告"运行效率"#3).
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(currentPoints.reversed().enumerated()), id: \.element.id) { _, point in
                        detailRow(point, isPRRow: prByID[point.id] ?? false)
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func detailRow(_ point: ExerciseHistoryPoint, isPRRow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(SessionDateFormat.display.string(from: point.date))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(DS.C.textHi)
                Text(RelativeTime.string(from: point.date))
                    .font(.system(size: 12))
                    .foregroundStyle(DS.C.textLow)
                if isPRRow {
                    Text("PR")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(DS.C.accent, in: Capsule())
                        .foregroundStyle(DS.C.onAccent)
                }
                if point.anyInferred {
                    DataTagView(kind: .inferred)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Text(language.t("\(point.sets.count)組 × \(aggregatedTargetText(point))", "\(point.sets.count) sets × \(aggregatedTargetText(point))"))
                    .font(.system(size: 12))
                    .foregroundStyle(DS.C.textHi)
                Text(aggregatedLoadText(point))
                    .font(.system(size: 12))
                    .foregroundStyle(DS.C.textLow)
            }
            Text(language.t("完成：\(aggregatedActualText(point))", "Actual: \(aggregatedActualText(point))"))
                .font(.system(size: 12))
                .foregroundStyle(DS.C.textLow)

            if let note = point.blockNote, !note.isEmpty {
                Text(language.t("備註：\(note)", "Note: \(note)"))
                    .font(.system(size: 11))
                    .foregroundStyle(DS.C.textLow)
            }
        }
        .padding(.vertical, 4)
    }

    private func uniqueOrdered(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for v in values where !seen.contains(v) {
            seen.insert(v)
            result.append(v)
        }
        return result
    }

    private func aggregatedTargetText(_ point: ExerciseHistoryPoint) -> String {
        uniqueOrdered(point.sets.map { $0.target.displayText }).joined(separator: "/")
    }

    private func aggregatedLoadText(_ point: ExerciseHistoryPoint) -> String {
        uniqueOrdered(point.sets.map { $0.load.displayText }).joined(separator: "/")
    }

    private func aggregatedActualText(_ point: ExerciseHistoryPoint) -> String {
        point.sets.map { $0.actual.displayText }.joined(separator: " / ")
    }
}

/// Minimal date-range picker sheet used by the "选时间范围" control here and
/// reachable from ExerciseQueryView's pre-filter.
private struct DateRangeEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date
    let onApply: (ClosedRange<Date>) -> Void
    let onClear: () -> Void
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    init(initialRange: ClosedRange<Date>, onApply: @escaping (ClosedRange<Date>) -> Void, onClear: @escaping () -> Void) {
        // `initialRange`'s bounds are always UTC-midnight-encoded (see
        // `defaultEditableRange`/`onApply` below) -- decode back to a local
        // display date before handing to the pickers, same reasoning as
        // SessionEditSheet (2026-09-07 审阅 B07).
        _start = State(initialValue: TrainingDayEncoding.localDisplayDate(from: initialRange.lowerBound))
        _end = State(initialValue: TrainingDayEncoding.localDisplayDate(from: initialRange.upperBound))
        self.onApply = onApply
        self.onClear = onClear
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(language.t("起始日期", "Start Date"), selection: $start, displayedComponents: .date)
                DatePicker(language.t("結束日期", "End Date"), selection: $end, displayedComponents: .date)
                Button(language.t("清除範圍（顯示全部）", "Clear Range (Show All)"), role: .destructive) {
                    onClear()
                    dismiss()
                }
            }
            .navigationTitle(language.t("選擇時間範圍", "Select Date Range"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("取消", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.t("應用", "Apply")) {
                        // 转换为训练日期编码（UTC 零点）后再取范围，避免遗漏边界
                        // 当天（2026-09-06 审查报告 #4），与 ExerciseQueryView 的
                        // 换算方式一致。
                        let lo = TrainingDayEncoding.utcDay(from: start)
                        let hi = TrainingDayEncoding.utcDay(from: end)
                        onApply(min(lo, hi)...max(lo, hi))
                        dismiss()
                    }
                }
            }
        }
    }
}
