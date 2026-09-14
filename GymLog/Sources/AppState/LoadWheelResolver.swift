import Foundation
import SwiftData

/// CONTRACT-UI.md §3.3 -- which wheel content the 重量 slot shows, driven by
/// `Exercise.equipment` / `loadDirection`, with a `.band` exercise's actual
/// color set pulled from its own history (there is no fixed color enum in
/// CONTRACT.md §7.6 -- `LoadValue.band.color` is a free string).
public enum LoadWheelKind: Equatable {
    /// Absolute kg, 2.5kg steps, 2.5-200kg (CONTRACT-UI.md §3.1).
    case absolute
    /// Per-side kg, same range/step, labeled "单侧".
    case perSide
    /// Assisted kg -- same range/step, but "数值越小越强" (CONTRACT-UI.md §3.3).
    case assisted
    /// Colors observed historically for this exercise (frequency order);
    /// falls back to a fixed common-color set if this exercise has no prior
    /// band-load history at all.
    case band(colors: [String])
    /// Bodyweight exercises: defaults to "自重" (no added weight) but stays
    /// interactive so added weight (e.g. a plate held during a plank, a
    /// weighted dip belt) can still be dialed in. Amends CONTRACT-UI.md
    /// §3.3's original "隐藏重量滚轮" row -- that fully hid the wheel even
    /// though real history (e.g. "plank" @ 12kg) already recorded added
    /// weight against `.bodyweight` exercises, which the hidden wheel could
    /// then never re-select on a later entry.
    case bodyweightPlus
}

public enum LoadWheelResolver {
    /// Common resistance-band color/thickness names, used only as a
    /// fallback when an exercise has `equipment == .band` but no prior
    /// recorded `LoadValue.band` to derive an observed color set from (e.g.
    /// a brand-new exercise).
    public static let fallbackBandColors = ["black", "blue", "green", "red", "purple", "yellow"]

    /// CONTRACT-UI.md §3.3's dispatch table. `loadDirection == .lowerIsStronger`
    /// is checked first since it's the highest-stakes classification (辅助类
    /// 动作) and is orthogonal to `equipment`.
    public static func kind(for exercise: Exercise, historicalBandColors: [String]) -> LoadWheelKind {
        if exercise.loadDirection == .lowerIsStronger {
            return .assisted
        }
        switch exercise.equipment {
        case .bodyweight:
            return .bodyweightPlus
        case .band:
            return .band(colors: historicalBandColors.isEmpty ? fallbackBandColors : historicalBandColors)
        default:
            return exercise.isUnilateral ? .perSide : .absolute
        }
    }

    /// Distinct `LoadValue.band` colors ever recorded for this exercise
    /// (any client), most-frequent first. Ties fall back to first-seen
    /// order for determinism.
    public static func historicalBandColors(forExerciseID exerciseID: String, in context: ModelContext) -> [String] {
        let descriptor = FetchDescriptor<ExerciseEntry>()
        let entries = (try? context.fetch(descriptor)) ?? []
        return historicalBandColors(forExerciseID: exerciseID, entries: entries)
    }

    /// Same result as the `context`-based overload above, but computed from
    /// an already-fetched entry list instead of running its own
    /// `context.fetch`. Perf fix (see EntryRowView.swift / TodayView.swift):
    /// the `context`-based overload was being called once per visible entry
    /// row -- N rows meant N full-table fetches. Callers that already have
    /// (or can share) a fetched `[ExerciseEntry]` should use this instead;
    /// `bandColorIndex(entries:)` below is the preferred way to get that for
    /// *every* exercise in a single pass rather than one call per exercise.
    public static func historicalBandColors(forExerciseID exerciseID: String, entries: [ExerciseEntry]) -> [String] {
        var counts: [String: Int] = [:]
        var firstSeenOrder: [String] = []
        for entry in entries where entry.exercise?.id == exerciseID {
            for set in entry.orderedSets {
                if case .band(let color, _, _) = set.load {
                    let key = color.lowercased()
                    if counts[key] == nil { firstSeenOrder.append(key) }
                    counts[key, default: 0] += 1
                }
            }
        }
        return rank(firstSeenOrder, by: counts)
    }

    /// Builds the historical-band-color list for *every* exercise that has
    /// ever recorded a `.band` load, in one pass over `entries` -- O(entries)
    /// total instead of O(exercises × entries) from calling the single-
    /// exercise function once per exercise. This is what `TodayView` uses to
    /// precompute the whole table once per appearance; each `EntryRowView`
    /// then does an O(1) dictionary lookup instead of any scan at all.
    public static func bandColorIndex(entries: [ExerciseEntry]) -> [String: [String]] {
        var countsByExercise: [String: [String: Int]] = [:]
        var orderByExercise: [String: [String]] = [:]
        for entry in entries {
            guard let exerciseID = entry.exercise?.id else { continue }
            for set in entry.orderedSets {
                if case .band(let color, _, _) = set.load {
                    let key = color.lowercased()
                    if countsByExercise[exerciseID]?[key] == nil {
                        orderByExercise[exerciseID, default: []].append(key)
                    }
                    countsByExercise[exerciseID, default: [:]][key, default: 0] += 1
                }
            }
        }
        var result: [String: [String]] = [:]
        for (exerciseID, order) in orderByExercise {
            result[exerciseID] = rank(order, by: countsByExercise[exerciseID] ?? [:])
        }
        return result
    }

    /// Shared frequency-desc / first-seen-tiebreak ordering, used by both
    /// the single-exercise and all-exercises paths above.
    private static func rank(_ firstSeenOrder: [String], by counts: [String: Int]) -> [String] {
        firstSeenOrder.sorted { lhs, rhs in
            let (lc, rc) = (counts[lhs] ?? 0, counts[rhs] ?? 0)
            return lc != rc ? lc > rc : firstSeenOrder.firstIndex(of: lhs)! < firstSeenOrder.firstIndex(of: rhs)!
        }
    }
}
