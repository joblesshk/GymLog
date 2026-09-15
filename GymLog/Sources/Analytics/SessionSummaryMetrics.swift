import Foundation

/// 課次卡片「總量／最大」的彙總（GymLog 改版設計 §6：「練得多重」）。只走
/// `.strength`/`.skill` 區塊的 `SetLog`——WOD 的計分方式不是 kg×reps，不算進
/// 來。完全複用 `AnalyticsMath` 既有的 volume/comparableKg/isEffectiveCompletion
/// 規則，不重新定義任何一條判斷；「最大」的口徑（未完成的組不計入、
/// direction-aware 比較）與 `ExerciseHistoryPoint.maxLoadKg` 完全一致，只是
/// 從「單一動作跨課次」換成「單一課次跨全部動作」。
public struct SessionSummaryMetrics {
    /// 全課次總訓練量（kg）。沒有任何一組可定義 volume 時為 nil，不是 0——
    /// 0 表示「算出來就是零」，nil 表示「這堂課沒有可加總的數據」。
    public let totalVolumeKg: Double?
    /// 全課次單組最大重量（kg）。同樣：無可比較數值時為 nil。
    public let maxLoadKg: Double?

    public static func compute(for session: WorkoutSession) -> SessionSummaryMetrics {
        var totalVolume: Double?
        var maxLoad: Double?

        for block in session.orderedBlocks {
            guard block.sectionKind != .wod else { continue }
            for entry in block.orderedEntries {
                let direction = entry.exercise?.loadDirection ?? .higherIsStronger
                for set in entry.orderedSets {
                    guard AnalyticsMath.isEffectiveCompletion(actual: set.actual) else { continue }
                    if let volume = AnalyticsMath.setVolume(load: set.load, actual: set.actual) {
                        totalVolume = (totalVolume ?? 0) + volume
                    }
                    if let kg = AnalyticsMath.comparableKg(set.load) {
                        maxLoad = maxLoad.map { AnalyticsMath.betterValue($0, kg, direction: direction) } ?? kg
                    }
                }
            }
        }
        return SessionSummaryMetrics(totalVolumeKg: totalVolume, maxLoadKg: maxLoad)
    }
}
