import Foundation

/// A body-composition measurement positioned on the trend chart's discrete
/// measurement axis. The index is deliberately independent of elapsed time:
/// each selected measurement gets one evenly spaced slot, including records
/// whose selected metric is nil.
public struct BodyMetricTrendPoint: Identifiable, Equatable {
    public let id: String
    public let date: Date
    public let index: Int
    public let weightKg: Double?
    public let bodyFatPercent: Double?
    public let skeletalMuscleKg: Double?

    public init(index: Int, metric: BodyMetric) {
        self.id = metric.id
        self.date = metric.date
        self.index = index
        self.weightKg = metric.weightKg
        self.bodyFatPercent = metric.bodyFatPercent
        self.skeletalMuscleKg = metric.skeletalMuscleKg
    }
}

/// Selects and positions the records used by the body-composition trend.
///
/// Selection happens before any metric-specific nil filtering. This is
/// material: a missing body-fat value in one of the latest `defaultLimit`
/// records must leave a gap in the body-fat line, rather than pulling an
/// older record outside that window into that metric's chart.
public enum BodyMetricTrendSeries {
    /// Widened from 6 to 12 measurements so the trend chart reflects a
    /// longer history when enough records exist.
    public static let defaultLimit = 12

    /// A deterministic ascending order for both the history list and trend
    /// selection. `id` breaks same-day ties so repeated measurements on one
    /// date retain distinct, predictable positions.
    public static func sorted(_ metrics: [BodyMetric]) -> [BodyMetric] {
        metrics.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id < $1.id
        }
    }

    /// The viewport is limited, not the underlying history. Missing values
    /// and same-day measurements retain their own selectable slots.
    public static func allPoints(from metrics: [BodyMetric]) -> [BodyMetricTrendPoint] {
        sorted(metrics).enumerated().map { BodyMetricTrendPoint(index: $0.offset, metric: $0.element) }
    }

    public static func point(at position: Double, in points: [BodyMetricTrendPoint]) -> BodyMetricTrendPoint? {
        guard position.isFinite, !points.isEmpty,
              position >= -0.5, position <= Double(points.count) - 0.5 else { return nil }
        let index = min(max(Int(position.rounded()), 0), points.count - 1)
        return points[index]
    }

    /// Returns the latest `limit` records in ascending chronological order,
    /// with a continuous index from zero. A non-positive limit produces no
    /// points and never falls back to the full history.
    public static func points(from metrics: [BodyMetric], limit: Int = defaultLimit) -> [BodyMetricTrendPoint] {
        guard limit > 0 else { return [] }
        let ordered = sorted(metrics)
        let selected = ordered.count > limit ? Array(ordered.suffix(limit)) : ordered
        return selected.enumerated().map { BodyMetricTrendPoint(index: $0.offset, metric: $0.element) }
    }
}
