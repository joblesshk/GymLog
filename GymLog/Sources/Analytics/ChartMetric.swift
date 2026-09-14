import Foundation

/// The switchable trend-chart metrics, CONTRACT-UI.md §4.1: 最大重量 / 估算
/// 1RM / 单次训练容量 / 完成次数, extended (2026-09-06 审查报告"适合当前范围的
/// 功能"第二批) with the three metrics matching `RecordingMetric.time`/
/// `.distance`/`.rounds` — 录入流程早就支持这些类型（plank 计时、划船计距离、
/// 农夫行走计轮次），但趋势页此前只有重量/次数相关指标可选，这几类动作的进度
/// 没有对应的曲线可看。
public enum ChartMetric: String, CaseIterable, Identifiable, Hashable {
    case maxLoad
    case estimated1RM
    case volume
    case completedReps
    case completedDuration
    case completedDistance
    case completedRounds

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .maxLoad: return L("最大重量", "Max Load")
        case .estimated1RM: return L("估算1RM", "Est. 1RM")
        case .volume: return L("單次容量", "Volume")
        case .completedReps: return L("完成次數", "Completed Reps")
        case .completedDuration: return L("最長時長", "Longest Hold")
        case .completedDistance: return L("最遠距離", "Longest Distance")
        case .completedRounds: return L("最多輪次", "Most Rounds")
        }
    }

    /// Which metrics make sense to offer for a given exercise, based on its
    /// `recordingMetric`. `maxLoad`/`estimated1RM`/`volume` depend only on
    /// `LoadValue` (present regardless of recording type — even a `.time`
    /// exercise can carry a weighted plank's load) so they stay available
    /// across the board and simply show "no comparable data" when empty,
    /// same as they always have. The four completed-QUANTITY metrics are
    /// each tied to exactly one `RecordingMetric`, since a value in the
    /// wrong unit (e.g. "完成次數" for a timed plank) is never populated —
    /// showing it would just be a permanently-empty picker option.
    public func isRelevant(for recordingMetric: RecordingMetric) -> Bool {
        switch self {
        case .maxLoad, .estimated1RM, .volume:
            return true
        case .completedReps:
            return recordingMetric == .reps || recordingMetric == .unknown
        case .completedDuration:
            return recordingMetric == .time
        case .completedDistance:
            return recordingMetric == .distance
        case .completedRounds:
            return recordingMetric == .rounds
        }
    }

    /// The metric that best matches an exercise's own recording type,
    /// picked as the chart's initial selection instead of always defaulting
    /// to `.maxLoad` (which is simply empty for a bodyweight-timed exercise).
    public static func defaultMetric(for recordingMetric: RecordingMetric) -> ChartMetric {
        switch recordingMetric {
        case .reps, .unknown: return .maxLoad
        case .time: return .completedDuration
        case .distance: return .completedDistance
        case .rounds: return .completedRounds
        }
    }

    /// nil when this metric has no computable value for the given point —
    /// callers must skip the point for this metric, never plot a zero.
    public func value(for point: ExerciseHistoryPoint) -> Double? {
        switch self {
        case .maxLoad: return point.maxLoadKg
        case .estimated1RM: return point.bestEstimated1RM
        case .volume: return point.volumeKg
        case .completedReps: return point.completedReps
        case .completedDuration: return point.bestDurationSeconds
        case .completedDistance: return point.bestDistanceMeters
        case .completedRounds: return point.bestRoundsCount
        }
    }

    /// Axis/unit label. `.maxLoad` on a `.lowerIsStronger` exercise gets an
    /// explicit direction annotation — CONTRACT-UI.md §4.2 rule ① requires
    /// either a reversed axis or an explicit label; this UI uses the
    /// explicit-label form plus color-coded deltas (see
    /// `ExerciseHistoryView`), which is lower-risk than attempting to flip
    /// Swift Charts' continuous value-axis direction.
    public func unitLabel(direction: LoadDirection) -> String {
        switch self {
        case .maxLoad:
            return direction.isInverted ? L("kg（輔助配重，越小越強）", "kg (assisted, lower is stronger)") : "kg"
        case .estimated1RM:
            return L("kg（估算）", "kg (est.)")
        case .volume:
            return L("kg·次", "kg·reps")
        case .completedReps:
            return L("次", "reps")
        case .completedDuration:
            return L("秒", "sec")
        case .completedDistance:
            return L("公尺", "m")
        case .completedRounds:
            return L("輪", "rounds")
        }
    }

    /// Whether a bigger number on THIS metric's own already-normalized
    /// scale means improvement. Only `.maxLoad` carries the raw
    /// direction inversion (rule ①) — every other metric (1RM/volume/
    /// completed-reps, and the three completed-quantity metrics below) is
    /// always "more is better" once computed.
    public func isImprovement(_ candidate: Double, over previous: Double, direction: LoadDirection) -> Bool {
        switch self {
        case .maxLoad:
            return AnalyticsMath.isImprovement(candidate: candidate, overBest: previous, direction: direction)
        case .estimated1RM, .volume, .completedReps, .completedDuration, .completedDistance, .completedRounds:
            return candidate > previous
        }
    }
}
