import Foundation

/// 課次卡片「總量／最大」的彙總（GymLog 改版設計 §6：「練得多重」）。只走
/// `.strength`/`.skill` 區塊的 `SetLog`——WOD 的計分方式不是 kg×reps，不算進
/// 來。最大重量只比較外加負重，排除輔助重量（含舊資料以 absolute 儲存的
/// 輔助重量）。不同動作的輔助程度不可混入同一個最大值；課次排序不影響結果。
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
                    // Legacy numeric loads on assistance exercises mean assistance;
                    // an explicitly selected added load retains its own meaning.
                    let isLegacyAssistance = direction.isInverted && !set.load.hasExplicitLoadMode
                    if !isLegacyAssistance,
                       let kg = AnalyticsMath.comparableKg(set.load, direction: .higherIsStronger) {
                        maxLoad = max(maxLoad ?? kg, kg)
                    }
                }
            }
        }
        return SessionSummaryMetrics(totalVolumeKg: totalVolume, maxLoadKg: maxLoad)
    }
}
