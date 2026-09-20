import SwiftUI
import Charts
import GymLogKit

/// Keep the full measurement history in the chart and show twelve slots at
/// a time. A tap selects a record; horizontal drags remain chart scrolling.
struct BodyMetricTrendCard: View {
    let metrics: [BodyMetric]
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant
    @State private var metric: BodyMetricTrend = .weight
    @State private var selectedID: String?
    @State private var scrollPosition: Double = 0

    private var series: [BodyMetricTrendPoint] { BodyMetricTrendSeries.allPoints(from: metrics) }
    private var selected: BodyMetricTrendPoint? {
        series.first { $0.id == selectedID } ?? series.last
    }
    private var unit: String { metric == .bodyFat ? "%" : "kg" }
    private var latestPosition: Double { max(-0.5, Double(series.count - BodyMetricTrendSeries.defaultLimit) - 0.5) }
    private var firstVisibleIndex: Int { min(max(0, Int((scrollPosition + 0.5).rounded())), max(0, series.count - 1)) }
    private var visiblePoints: [BodyMetricTrendPoint] {
        Array(series.dropFirst(firstVisibleIndex).prefix(BodyMetricTrendSeries.defaultLimit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(windowTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityIdentifier("body-metric-window-label")
                Spacer()
                Text(unit).font(.system(size: 11)).foregroundStyle(DS.C.textMid)
                    .accessibilityIdentifier("body-metric-axis-unit")
            }
            GymSegmentedControl(selection: $metric, options: BodyMetricTrend.allCases, label: { $0.label })
            if !series.isEmpty {
                chart
                HStack {
                    Text(language.t("點選量測查看數據", "Tap a measurement for details"))
                    Spacer()
                    if series.count > BodyMetricTrendSeries.defaultLimit {
                        Text(language.t("左右滑動查看歷史", "Swipe for history"))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(DS.C.textMid)
                if let selected { details(selected) }
                if !series.contains(where: { metric.value(of: $0)?.isFinite == true }) {
                    Text(language.t("此指標暫無數據", "No data for this metric yet"))
                        .font(.system(size: 12)).foregroundStyle(DS.C.textMid)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gymCard()
        .padding(.horizontal, DS.Space.pageMargin)
        .onAppear { scrollPosition = latestPosition }
        .onChange(of: series.map(\.id)) { _, _ in
            // New measurements open at the latest window; deleted selections
            // fall back to the newest surviving record by stable identity.
            scrollPosition = latestPosition
            if !series.contains(where: { $0.id == selectedID }) { selectedID = nil }
        }
    }

    private var windowTitle: String {
        if firstVisibleIndex >= max(0, series.count - BodyMetricTrendSeries.defaultLimit) {
            return language.t("最近 \(min(series.count, BodyMetricTrendSeries.defaultLimit)) 次量測", "Latest \(min(series.count, BodyMetricTrendSeries.defaultLimit)) measurements")
        }
        return language.t("第 \(firstVisibleIndex + 1)–\(firstVisibleIndex + visiblePoints.count) 次 · 共 \(series.count) 次", "\(firstVisibleIndex + 1)–\(firstVisibleIndex + visiblePoints.count) of \(series.count) measurements")
    }

    private var yDomain: ClosedRange<Double> {
        // The visible window controls the vertical scale so old outliers do
        // not flatten the default recent view. Empty/equal ranges stay valid.
        let values = visiblePoints.compactMap { metric.value(of: $0) }.filter(\.isFinite)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let padding = max((high - low) * 0.15, 0.5)
        return (low - padding)...(high + padding)
    }

    private var segments: [Int: Int] {
        var result: [Int: Int] = [:]
        var segment = 0
        for point in series {
            if metric.value(of: point)?.isFinite == true { result[point.index] = segment }
            else { segment += 1 }
        }
        return result
    }

    private var chart: some View {
        let segments = segments
        return Chart {
            ForEach(series) { point in
                if let value = metric.value(of: point), value.isFinite {
                    LineMark(x: .value("measurement", Double(point.index)), y: .value("value", value),
                             series: .value("segment", segments[point.index] ?? point.index))
                        .foregroundStyle(DS.C.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineJoin: .round))
                    PointMark(x: .value("measurement", Double(point.index)), y: .value("value", value))
                        .symbolSize(point.id == selected?.id ? 65 : 25)
                        .foregroundStyle(DS.C.accent)
                        .accessibilityLabel(point.date.formatted(date: .numeric, time: .omitted))
                        .accessibilityValue("\(value.formatted()) \(unit)")
                }
            }
            if let selected {
                RuleMark(x: .value("measurement", Double(selected.index)))
                    .foregroundStyle(DS.C.textLow.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: -0.5...max(0.5, Double(series.count) - 0.5))
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: Double(min(max(series.count, 1), BodyMetricTrendSeries.defaultLimit)))
        .chartScrollPosition(x: $scrollPosition)
        .chartXAxis {
            AxisMarks(values: series.map { Double($0.index) }) { value in
                AxisGridLine().foregroundStyle(DS.C.inset)
                if let index = value.as(Int.self), series.indices.contains(index) {
                    AxisValueLabel(anchor: .top) {
                        Text(series[index].date.formatted(.dateTime.day()) + "\n" + series[index].date.formatted(.dateTime.month(.abbreviated)))
                            .font(.system(size: 9))
                            .multilineTextAlignment(.center)
                            .fixedSize()
                            .foregroundStyle(DS.C.textMid)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(DS.C.inset)
                AxisTick()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(number.formatted(.number.precision(.fractionLength(0...1))))
                            .foregroundStyle(DS.C.textMid)
                    }
                }
            }
        }
        .chartGesture { proxy in
            SpatialTapGesture().onEnded { event in
                if let position = proxy.value(atX: event.location.x, as: Double.self),
                   let point = BodyMetricTrendSeries.point(at: position, in: series) {
                    selectedID = point.id
                }
            }
        }
        .frame(height: 180)
        .accessibilityIdentifier("body-metric-trend-chart")
    }

    private func details(_ point: BodyMetricTrendPoint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language.t("量測 · ", "Measurement · ") + point.date.formatted(date: .numeric,
                time: series.filter { Calendar.current.isDate($0.date, inSameDayAs: point.date) }.count > 1 ? .shortened : .omitted))
                .font(.system(size: 13, weight: .semibold))
                .accessibilityIdentifier("body-metric-selected-date")
            HStack {
                detail(language.t("體重", "Weight"), value: point.weightKg, unit: "kg", id: "weight")
                detail(language.t("體脂率", "Body Fat"), value: point.bodyFatPercent, unit: "%", id: "fat")
                detail(language.t("骨骼肌", "Muscle"), value: point.skeletalMuscleKg, unit: "kg", id: "muscle")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.C.inset, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("body-metric-selected-\(point.id)")
    }

    private func detail(_ title: String, value: Double?, unit: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(DS.C.textMid)
            Text(value.flatMap { $0.isFinite ? "\($0.formatted(.number.precision(.fractionLength(1)))) \(unit)" : nil } ?? "—")
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
                .accessibilityIdentifier("body-metric-selected-\(id)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
