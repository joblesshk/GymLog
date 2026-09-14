import Foundation

/// PR tracking across WOD attempts -- the WOD counterpart to
/// `ExerciseHistoryAnalyzer`'s strength-PR logic, but deliberately NOT the
/// same algorithm: a WOD's "better" depends on its `WODScoringRule`, and
/// two attempts only compare at all when they're genuinely the same
/// prescription (工程审阅 §5.3: "PR只比较同处方revision、评分规则、实际标准/
/// 负重/器械等兼容组...同名不等于同版本").
public enum WODPRAnalyzer {
    public struct Entry: Equatable {
        public let date: Date
        public let payload: WODPayload

        public init(date: Date, payload: WODPayload) {
            self.date = date
            self.payload = payload
        }
    }

    /// What makes two attempts comparable: same prescription identity AND
    /// revision (editing a template bumps the revision, so an old result
    /// never silently compares against a changed plan), same scoring rule,
    /// and same Rx/Scaled/custom variant (工程审阅 §5.3: "Scaled不能自動破Rx
    /// 記錄"). Equipment/load/height substitutions are handled by requiring
    /// BOTH sides to have no `actualMovements` override at all (see
    /// `groupKey(for:)`) -- rather than trying to compare substitution
    /// details field-by-field, a modified attempt simply opts out of
    /// automatic comparison entirely and is shown standalone (工程审阅:
    /// "器械替換後提供並列回看，默認不連成同一條PR曲線").
    public struct GroupKey: Hashable {
        public let prescriptionID: String
        public let revision: Int
        public let scoringRule: WODScoringRule
        public let variant: WODVariant
    }

    /// A comparable score for one attempt. Deliberately NOT a single `Double`
    /// -- `roundsAndReps` used to be encoded as `rounds + partial/100_000`,
    /// a float-scaling hack that (a) silently breaks once partial progress
    /// exceeds the scale factor and (b) reads as "make up a conversion rate"
    /// which nothing in the domain actually defines. Comparing "5 rounds + 3
    /// reps" vs "5 rounds + 12 reps" as two separate integers (rounds first,
    /// then partial) is both exact and matches how a coach actually reads
    /// AMRAP scores.
    ///
    /// `.quantity` carries its `WorkoutQuantity` unit tag alongside the
    /// value so `isImprovement` can refuse to compare, say, a rowing meters
    /// total against a calorie total that ended up in the same group by
    /// accident (should not happen given `GroupKey`/`revision` isolation,
    /// but "不要直接取数组第一项当作通用总成绩" -- 不假设兼容, always verify).
    public enum Score: Equatable {
        case time(Int)
        case roundsAndReps(rounds: Int, partial: Int)
        case quantity(unit: String, value: Int)
    }

    /// `nil` when this attempt can't participate in automatic comparison at
    /// all: a substituted-equipment/load/movement attempt, or one whose
    /// variant is `.unknown` (no declared Rx/Scaled/custom to group by).
    public static func groupKey(for entry: Entry) -> GroupKey? {
        guard entry.payload.result.actualMovements.isEmpty else { return nil }
        guard entry.payload.result.variant != .unknown else { return nil }
        return GroupKey(
            prescriptionID: entry.payload.prescription.id,
            revision: entry.payload.prescription.revision,
            scoringRule: entry.payload.prescription.scoringRule,
            variant: entry.payload.result.variant
        )
    }

    private static func quantityUnitTag(_ quantity: WorkoutQuantity) -> String? {
        switch quantity {
        case .reps: return "reps"
        case .seconds: return "seconds"
        case .meters: return "meters"
        case .machineCalories: return "machineCalories"
        case .unknown: return nil
        }
    }

    /// Sum of `typedTotals`, but ONLY when every entry shares the same unit
    /// -- "总量和间歇成绩必须保留单位，只有单位和计分定义兼容时才比较". A
    /// result that mixes units within itself (e.g. a rowing+wall-ball
    /// interval keeping separate meters and reps totals, per
    /// `WODResult.typedTotals`'s own doc comment) has no single well-defined
    /// "total" and is not comparable -- this is a real, expected shape (not
    /// a data error), so returning `nil` here is the conservative-but-common
    /// case, not an edge case.
    private static func totalQuantityScore(_ result: WODResult) -> Score? {
        guard let first = result.typedTotals.first, let unit = quantityUnitTag(first) else { return nil }
        var sum = 0
        for quantity in result.typedTotals {
            guard quantityUnitTag(quantity) == unit, let value = quantity.value else { return nil }
            sum += value
        }
        return .quantity(unit: unit, value: sum)
    }

    /// The worst (minimum) interval's completed quantity -- classic Tabata
    /// scoring. Same unit-safety rule as `totalQuantityScore`: intervals
    /// recorded in mixed units have no well-defined single "worst" number
    /// and are not comparable.
    private static func worstIntervalScore(_ result: WODResult) -> Score? {
        let quantities = result.intervalResults.compactMap(\.completedQuantity)
        guard let first = quantities.first, let unit = quantityUnitTag(first) else { return nil }
        var worst: Int?
        for quantity in quantities {
            guard quantityUnitTag(quantity) == unit, let value = quantity.value else { return nil }
            worst = worst.map { Swift.min($0, value) } ?? value
        }
        return worst.map { .quantity(unit: unit, value: $0) }
    }

    /// One comparable score for one attempt, or `nil` when there's nothing
    /// comparable yet (not recorded, capped/stopped for a `.completionTime`
    /// rule -- a cap is explicitly NOT a finish time -- mixed-unit quantity
    /// data, or `.manual`/`.unknown` scoring, which never auto-compares).
    public static func comparableScore(_ payload: WODPayload) -> Score? {
        let result = payload.result
        guard result.status == .completed else { return nil }
        switch payload.prescription.scoringRule {
        case .completionTime:
            guard let elapsed = result.elapsedSeconds else { return nil }
            return .time(elapsed)
        case .roundsAndReps:
            guard let rounds = result.completedRounds else { return nil }
            return .roundsAndReps(rounds: rounds, partial: result.partialRoundQuantity?.value ?? 0)
        case .totalQuantity:
            return totalQuantityScore(result)
        case .worstInterval:
            return worstIntervalScore(result)
        case .manual, .unknown:
            return nil
        }
    }

    /// Whether `candidate` beats `best` -- the ONE place "For Time: smaller
    /// is better, AMRAP: more rounds then more partial progress, interval
    /// totals: bigger is better" gets decided. Ties are never improvements
    /// ("同值不算破紀錄"). A candidate/best pair with mismatched score
    /// shapes (different scoring rule, or -- defensively -- different
    /// quantity units) never compares as an improvement; callers keep the
    /// existing best rather than silently replacing it with an
    /// incomparable value.
    public static func isImprovement(candidate: Score, over best: Score, scoringRule: WODScoringRule) -> Bool {
        switch (candidate, best) {
        case (.time(let c), .time(let b)):
            return c < b
        case (.roundsAndReps(let cRounds, let cPartial), .roundsAndReps(let bRounds, let bPartial)):
            if cRounds != bRounds { return cRounds > bRounds }
            return cPartial > bPartial
        case (.quantity(let cUnit, let cValue), .quantity(let bUnit, let bValue)):
            guard cUnit == bUnit else { return false }
            return cValue > bValue
        default:
            return false
        }
    }

    /// Richer than a bare PR flag: distinguishes "this is the first-ever
    /// comparable attempt in its group" (a baseline, not yet a record broken
    /// against anything) from "this genuinely beat a prior best" -- "首次有效
    /// 成绩建议显示'首次成绩／基准'，后续真正改善才显示'新纪录'". `prFlags`
    /// below is kept as the pre-existing boolean-only convenience derived
    /// from this.
    public enum RecordStatus: Equatable {
        case none
        case first
        case improved
    }

    /// One status per entry (same order as `entries`, which the caller must
    /// pass in chronological order).
    public static func recordStatuses(entries: [Entry]) -> [RecordStatus] {
        var bestByGroup: [GroupKey: Score] = [:]
        var statuses: [RecordStatus] = []
        for entry in entries {
            guard let key = groupKey(for: entry), let score = comparableScore(entry.payload) else {
                statuses.append(.none)
                continue
            }
            if let best = bestByGroup[key] {
                if isImprovement(candidate: score, over: best, scoringRule: key.scoringRule) {
                    statuses.append(.improved)
                    bestByGroup[key] = score
                } else {
                    statuses.append(.none)
                }
            } else {
                statuses.append(.first)
                bestByGroup[key] = score
            }
        }
        return statuses
    }

    /// One flag per entry (same order as `entries`, which the caller must
    /// pass in chronological order), true iff that attempt set a NEW PR
    /// within its own comparable group -- true for BOTH a first-ever
    /// baseline and a later genuine improvement (`RecordStatus.first` or
    /// `.improved`); use `recordStatuses` directly when the UI needs to tell
    /// those two apart. An attempt outside any comparable group
    /// (`groupKey(for:) == nil`) or without a comparable score always flags
    /// `false` -- it's still shown in history, just never claims a PR.
    public static func prFlags(entries: [Entry]) -> [Bool] {
        recordStatuses(entries: entries).map { $0 != .none }
    }

    /// The current (best-to-date) score and the entry that set it, per
    /// comparable group present in `entries` -- lets a caller show "your PR
    /// for this WOD (Rx, rev 2)" without accidentally mixing it with a
    /// Scaled attempt or an older revision.
    public static func bestPerGroup(entries: [Entry]) -> [GroupKey: (value: Score, entry: Entry)] {
        var best: [GroupKey: (value: Score, entry: Entry)] = [:]
        for entry in entries {
            guard let key = groupKey(for: entry), let score = comparableScore(entry.payload) else { continue }
            if let current = best[key] {
                if isImprovement(candidate: score, over: current.value, scoringRule: key.scoringRule) {
                    best[key] = (score, entry)
                }
            } else {
                best[key] = (score, entry)
            }
        }
        return best
    }
}
