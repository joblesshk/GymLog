import Foundation

/// M3 analytics core — CONTRACT-UI.md §4.2. Pure, deterministic functions
/// with no SwiftUI/SwiftData dependency, so every branch is directly
/// unit-testable and there is exactly one place each rule can be gotten
/// right or wrong. Every UI file (ExerciseHistoryView, ExerciseQueryView)
/// MUST route through these functions rather than re-deriving any of §4.2's
/// rules locally — that duplication is exactly how "individually simple,
/// collectively easy to violate" rules go wrong in practice.
public enum AnalyticsMath {

    // MARK: - Rule ② — estimated 1RM

    /// Epley formula. Does NOT itself enforce CONTRACT-UI.md §4.2 rule ②'s
    /// eligibility conditions — `estimatedOneRepMax(load:actual:)` below is
    /// the safe, contract-enforcing entry point every call site must use.
    public static func epley(weightKg: Double, reps: Int) -> Double {
        weightKg * (1 + Double(reps) / 30)
    }

    /// Rule ②: estimated 1RM only when `load` is `.absolute` AND `actual` is
    /// `.fixed(r)` with `1...12`. Every other combination — range actuals,
    /// `.perSide` loads, bodyweight/band/assisted/machineStack/pinLoad/sled,
    /// time/distance/rounds actuals — returns nil. Callers must treat nil as
    /// "no point", never substitute a fallback.
    ///
    /// Rule ① is also enforced defensively by callers passing `loadDirection`
    /// and refusing to call this at all for `.lowerIsStronger` exercises
    /// (see `ExerciseHistoryAnalyzer`) — this function additionally can
    /// never produce a 1RM for an assisted-style load, because `.assisted`
    /// is not `.absolute`, so the two rules are structurally redundant here
    /// by construction, not just by convention.
    public static func estimatedOneRepMax(load: LoadValue, actual: RepTarget) -> Double? {
        guard case .absolute(let kg, _) = load else { return nil }
        guard case .fixed(let reps, _) = actual, (1...12).contains(reps) else { return nil }
        return epley(weightKg: kg, reps: reps)
    }

    // MARK: - Rule ④ — volume

    /// Volume contribution of one set, per CONTRACT-UI.md §4.2 rule ④'s
    /// table (as amended — see the `.absolute` + `.perSide` case below).
    /// Returns nil when the combination is not defined as contributing to
    /// volume; callers MUST treat nil as "excluded" and surface the count,
    /// never silently drop it or treat it as zero.
    ///
    /// Amendment (post-review correction, ~194 real SetLogs affected):
    /// `.absolute(kg)` load + `.perSide(left,right)` actual reps IS
    /// countable as `kg × (left + right)` — e.g. `Leg extension SL` at a
    /// single absolute pin weight, reps counted per leg because the machine
    /// is worked one leg at a time. This is NOT the same situation as rule
    /// ③ (which forbids doubling a `.perSide` LOAD) — here the load is a
    /// single absolute number and both legs' reps are genuine completed
    /// reps at that load, so summing them is correct, not a doubling error.
    public static func setVolume(load: LoadValue, actual: RepTarget) -> Double? {
        switch (load, actual) {
        case (.absolute(let kg, _), .fixed(let reps, _)):
            return kg * Double(reps)
        case (.absolute(let kg, _), .range(let low, let high, _)):
            // "用 actual；actual 也是区间则取中值并标为估算" — midpoint;
            // `isVolumeEstimated` mirrors this so the UI can flag it.
            let mid = Double(low + high) / 2
            return kg * mid
        case (.absolute(let kg, _), .perSide(let left, let right, _)):
            return kg * Double(left + right)
        case (.perSide(let kg, _), .perSide(let left, let right, _)):
            return kg * Double(left + right)
        default:
            // Includes: bodyweight/band/machineStack/pinLoad/sled/unknown
            // loads; time/distance/rounds/unknown actuals; and any other
            // load×actual combination not explicitly whitelisted above
            // (e.g. `.perSide` load + `.fixed` actual — ambiguous whether
            // the fixed count is total or per-side, so "算不了就不算").
            return nil
        }
    }

    /// True iff `setVolume` computed its result from a range-actual
    /// midpoint (the one case in the table that is an estimate, not exact).
    public static func isVolumeEstimated(load: LoadValue, actual: RepTarget) -> Bool {
        if case .absolute = load, case .range = actual { return true }
        return false
    }

    // MARK: - Rule ③ — comparable load, never doubling `.perSide`

    /// A numeric, direction-comparable kg figure for the "max/min load"
    /// chart metric and PR tracking. `.perSide` yields the PER-SIDE kg
    /// as-is — rule ③: never doubled to a "total". Returns nil for
    /// bodyweight/band/machineStack/pinLoad/unknown, which carry no
    /// comparable numeric weight.
    public static func comparableKg(_ load: LoadValue) -> Double? {
        switch load {
        case .absolute(let kg, _): return kg
        case .perSide(let kg, _): return kg
        case .assisted(let kg, _): return kg
        case .sled(let kg, _): return kg
        case .bodyweight, .band, .machineStack, .pinLoad, .unknown:
            return nil
        }
    }

    // MARK: - Effective completion (2026-09-07 审阅 B03)

    /// True iff `actual` represents a genuinely completed attempt, never
    /// merely "some value was recorded". An `actual` of zero — a missed
    /// lift, a failed CrossFit attempt, a set stopped before any rep landed
    /// — must never be treated as if the prescribed weight/time/distance
    /// was actually achieved. Each `RepTarget` kind uses its own
    /// zero-is-failure rule; `.range`/`.perSide` are considered completed
    /// whenever either side is positive, since a genuine range/per-side
    /// target is never legitimately all-zero on both ends.
    ///
    /// This gates `maxLoadKg` (and therefore every PR derived from it) in
    /// `ExerciseHistoryAnalyzer.points` — a `.absolute(150)` load paired
    /// with `.fixed(0)` actual must never register 150kg as lifted, let
    /// alone as a new PR. Separate from `setReps`/`setVolume`/`isRepsEstimated`
    /// above: those already correctly compute 0 reps / 0kg volume for a
    /// zero actual (which is arithmetically correct — nothing to fix
    /// there), this is specifically about "was there a comparable load
    /// achieved at all this set".
    public static func isEffectiveCompletion(actual: RepTarget) -> Bool {
        switch actual {
        case .fixed(let value, _): return value > 0
        case .range(let low, let high, _): return low > 0 || high > 0
        case .perSide(let left, let right, _): return left > 0 || right > 0
        case .time(let seconds, _): return seconds > 0
        case .distance(let meters, _): return meters > 0
        case .rounds(let count, _): return count > 0
        case .unknown: return false
        }
    }

    // MARK: - Completed-reps metric

    /// Completed-reps figure for one set. Mirrors volume's "definable
    /// branches only" discipline: `.fixed`/`.perSide` are exact, `.range`
    /// contributes its midpoint (flagged via `isRepsEstimated`), and
    /// time/distance/rounds/unknown are excluded (not zero).
    public static func setReps(actual: RepTarget) -> Double? {
        switch actual {
        case .fixed(let value, _): return Double(value)
        case .perSide(let left, let right, _): return Double(left + right)
        case .range(let low, let high, _): return Double(low + high) / 2
        case .time, .distance, .rounds, .unknown:
            return nil
        }
    }

    public static func isRepsEstimated(actual: RepTarget) -> Bool {
        if case .range = actual { return true }
        return false
    }

    // MARK: - Time/distance/rounds metrics (2026-09-06 审查报告"适合当前范围的
    // 功能"第二批: 录入早就支持这三类 recordingMetric，趋势页此前却只能看重量/
    // 次数——`ExerciseHistoryAnalyzer.points` 取这三者里每次训练最好的一组，
    // 与 `comparableKg` 对 maxLoad 的"当次最佳单组"口径一致，不是把各组相加。)

    /// 0 seconds/meters/rounds is excluded, not just "not `.time`/etc" — a
    /// recorded zero is a failed/not-attempted set for these metrics too
    /// (2026-09-07 审阅 B03), not a legitimate "best single set" figure.
    public static func setDurationSeconds(actual: RepTarget) -> Double? {
        guard case .time(let seconds, _) = actual, seconds > 0 else { return nil }
        return Double(seconds)
    }

    public static func setDistanceMeters(actual: RepTarget) -> Double? {
        guard case .distance(let meters, _) = actual, meters > 0 else { return nil }
        return Double(meters)
    }

    public static func setRoundsCount(actual: RepTarget) -> Double? {
        guard case .rounds(let count, _) = actual, count > 0 else { return nil }
        return Double(count)
    }

    // MARK: - Rule ① — direction-aware comparison

    /// Is `candidate` a strict improvement over `currentBest`, given
    /// `direction`? The single choke point for rule ①'s inversion — no
    /// other file may independently decide "bigger number = better".
    public static func isImprovement(candidate: Double, overBest currentBest: Double, direction: LoadDirection) -> Bool {
        direction.isInverted ? candidate < currentBest : candidate > currentBest
    }

    /// Direction-aware "which of these two is the better/PR value".
    public static func betterValue(_ a: Double, _ b: Double, direction: LoadDirection) -> Double {
        direction.isInverted ? min(a, b) : max(a, b)
    }
}
