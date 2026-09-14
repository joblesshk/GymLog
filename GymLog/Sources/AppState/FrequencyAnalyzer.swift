import Foundation
import SwiftData

/// CONTRACT-UI.md §3.1 -- frequency-driven ordering for the two-column
/// exercise wheel's 「常用」 category, its per-category right column, and the
/// 次数目标 preset reordering. All three read the same underlying signal
/// (a client's session history) so they live together in one place.
public enum FrequencyAnalyzer {

    /// 「常用」 (CONTRACT-UI.md §3.1): the client's most recent 8 sessions,
    /// exercises ranked by occurrence count within that window (descending),
    /// top 20; if fewer than 20 distinct exercises appear in that window,
    /// pad with the client's all-time frequency (excluding exercises already
    /// included), also descending.
    public static func frequentExercises(clientID: String, in context: ModelContext, limit: Int = 20) -> [Exercise] {
        let sessions = clientSessions(clientID: clientID, in: context) // already date-descending
        let recentWindow = Array(sessions.prefix(8))

        let recentCounts = usageCounts(sessions: recentWindow)
        var result = recentCounts.keys
            .sorted { lhs, rhs in
                let (lc, rc) = (recentCounts[lhs]!.count, recentCounts[rhs]!.count)
                return lc != rc ? lc > rc : lhs < rhs
            }
            .prefix(limit)
            .compactMap { recentCounts[$0]?.exercise }

        if result.count < limit {
            let allTimeCounts = usageCounts(sessions: sessions)
            let alreadyIncluded = Set(result.map(\.id))
            let additional = allTimeCounts.keys
                .filter { !alreadyIncluded.contains($0) }
                .sorted { lhs, rhs in
                    let (lc, rc) = (allTimeCounts[lhs]!.count, allTimeCounts[rhs]!.count)
                    return lc != rc ? lc > rc : lhs < rhs
                }
                .prefix(limit - result.count)
                .compactMap { allTimeCounts[$0]?.exercise }
            result.append(contentsOf: additional)
        }
        return result
    }

    /// Right-column ordering for a given `MovementPattern` category
    /// (CONTRACT-UI.md §3.1): exercises the client has used, ranked by their
    /// usage count for this client (descending); exercises the client has
    /// never used, appended after, ranked by global `occurrenceCount`
    /// (descending).
    public static func exercises(
        in pattern: MovementPattern,
        allExercises: [Exercise],
        clientID: String,
        in context: ModelContext
    ) -> [Exercise] {
        let sessions = clientSessions(clientID: clientID, in: context)
        let counts = usageCounts(sessions: sessions)
        let inCategory = allExercises.filter { $0.movementPattern == pattern }

        let used = inCategory
            .filter { counts[$0.id] != nil }
            .sorted { counts[$0.id]!.count > counts[$1.id]!.count }
        let unused = inCategory
            .filter { counts[$0.id] == nil }
            .sorted { $0.occurrenceCount > $1.occurrenceCount }
        return used + unused
    }

    /// The `MovementPattern` categories to show in the left column: all 7
    /// non-`unknown` patterns, plus `unknown` itself only if at least one
    /// exercise in the library is actually classified `unknown`
    /// (CONTRACT-UI.md §3.1: "`unknown` 分类仅在存在此类动作时显示").
    public static func visibleCategories(allExercises: [Exercise]) -> [MovementPattern] {
        var categories = MovementPattern.allCases.filter { $0 != .unknown }
        if allExercises.contains(where: { $0.movementPattern == .unknown }) {
            categories.append(.unknown)
        }
        return categories
    }

    // MARK: - RepTarget preset reordering (CONTRACT-UI.md §3.1)

    /// The 14 fixed presets plus 自定义…, in the contract's documented
    /// default order (CONTRACT-UI.md §3.1). Never edit these values --
    /// they're the frequency-analysis-derived set covering 96.7% of real
    /// data, fixed by the contract.
    public static let baseRepTargetPresets: [RepTargetPreset] = [
        .init(label: "10", target: .fixed(value: 10, raw: "10")),
        .init(label: "3-8", target: .range(low: 3, high: 8, raw: "3-8")),
        .init(label: "10-15", target: .range(low: 10, high: 15, raw: "10-15")),
        .init(label: "6-10", target: .range(low: 6, high: 10, raw: "6-10")),
        .init(label: "12", target: .fixed(value: 12, raw: "12")),
        .init(label: "8-12", target: .range(low: 8, high: 12, raw: "8-12")),
        .init(label: "8", target: .fixed(value: 8, raw: "8")),
        .init(label: "20", target: .fixed(value: 20, raw: "20")),
        .init(label: "3-5", target: .range(low: 3, high: 5, raw: "3-5")),
        .init(label: "15", target: .fixed(value: 15, raw: "15")),
        .init(label: "5", target: .fixed(value: 5, raw: "5")),
        .init(label: "5-8", target: .range(low: 5, high: 8, raw: "5-8")),
        .init(label: "16", target: .fixed(value: 16, raw: "16")),
        .init(label: "3", target: .fixed(value: 3, raw: "3")),
    ]
    // `static var` (computed), not `static let` -- a `let` would cache
    // whichever language was active on first access forever, even after the
    // coach switches language in Settings.
    public static var customPreset: RepTargetPreset { RepTargetPreset(label: L("自定義…", "Custom…"), target: nil) }

    /// Reorders `baseRepTargetPresets` by this client's actual usage
    /// frequency (descending), preserving the contract's original relative
    /// order for ties (Swift's `sorted` is a stable sort). 自定义… always
    /// stays last, never reordered into the ranked set.
    public static func repTargetPresetOrder(clientID: String, in context: ModelContext) -> [RepTargetPreset] {
        repTargetPresetOrder(clientSessions: clientSessions(clientID: clientID, in: context))
    }

    /// Same result as the `context`-based overload above, computed from an
    /// already-fetched session list instead of running its own
    /// `context.fetch`. Perf fix (see EntryRowView.swift / TodayView.swift):
    /// the `context`-based overload was being called once per visible entry
    /// row -- N rows meant N full-table fetches plus N re-scans of every set
    /// in the client's history. `TodayView` now fetches once per appearance
    /// and passes the *result* down; every row shares the same array.
    public static func repTargetPresetOrder(clientSessions sessions: [WorkoutSession]) -> [RepTargetPreset] {
        var counts: [String: Int] = [:] // keyed by preset label
        for session in sessions {
            for block in session.orderedBlocks {
                for entry in block.orderedEntries {
                    for set in entry.orderedSets {
                        if let match = baseRepTargetPresets.first(where: { $0.matches(set.target) }) {
                            counts[match.label, default: 0] += 1
                        }
                    }
                }
            }
        }
        let ranked = baseRepTargetPresets.sorted { (counts[$0.label] ?? 0) > (counts[$1.label] ?? 0) }
        return ranked + [customPreset]
    }

    // MARK: - Shared helpers

    private static func clientSessions(clientID: String, in context: ModelContext) -> [WorkoutSession] {
        let descriptor = FetchDescriptor<WorkoutSession>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        let all = (try? context.fetch(descriptor)) ?? []
        return all.filter { $0.client?.id == clientID }
    }

    private static func usageCounts(sessions: [WorkoutSession]) -> [String: (count: Int, exercise: Exercise)] {
        var counts: [String: (count: Int, exercise: Exercise)] = [:]
        for session in sessions {
            for block in session.orderedBlocks {
                for entry in block.orderedEntries {
                    guard let exercise = entry.exercise else { continue }
                    let existing = counts[exercise.id]?.count ?? 0
                    counts[exercise.id] = (existing + 1, exercise)
                }
            }
        }
        return counts
    }
}

/// One row in the 次数目标 wheel: either a concrete preset value, or the
/// 自定义… placeholder (`target == nil`).
public struct RepTargetPreset: Identifiable, Equatable {
    public var id: String { label }
    public let label: String
    public let target: RepTarget?

    public init(label: String, target: RepTarget?) {
        self.label = label
        self.target = target
    }

    /// Structural match (kind + values), ignoring `raw` text -- so a
    /// historical `RepTarget.fixed(value: 10, raw: "10 reps")` still counts
    /// toward the `"10"` preset.
    public func matches(_ other: RepTarget) -> Bool {
        guard let target else { return false }
        switch (target, other) {
        case (.fixed(let a, _), .fixed(let b, _)):
            return a == b
        case (.range(let aLow, let aHigh, _), .range(let bLow, let bHigh, _)):
            return aLow == bLow && aHigh == bHigh
        default:
            return false
        }
    }
}
