import Foundation

/// One chartable/listable occurrence of an exercise for one client — one
/// `ExerciseEntry` (a single appearance of the exercise in one session's
/// block), with its sets pre-aggregated per CONTRACT-UI.md §4.2. Deliberately
/// a plain value type with no SwiftData reference held, so it survives
/// across `@Query` invalidations and is trivially usable in Swift Charts.
public struct ExerciseHistoryPoint: Identifiable, Hashable {
    public let id: String
    public let date: Date
    public let sessionID: String
    public let sourceSheet: String
    public let sourceRow: Int
    public let blockNote: String?
    /// True iff EVERY contributing set is `isInferred`. All 2372 migrated
    /// SetLogs are `isInferred = true`, so this is true for effectively all
    /// history until M2 entries accumulate.
    public let isInferred: Bool
    public let anyInferred: Bool
    public let sets: [SetSummary]

    public struct SetSummary: Hashable {
        public let setIndex: Int
        public let load: LoadValue
        public let target: RepTarget
        public let actual: RepTarget
        public let isInferred: Bool
    }

    // Metric values — nil means "not computable for this entry", per
    // §4.2's per-branch rules. Never a substituted zero or estimate that
    // isn't explicitly flagged.
    public let maxLoadKg: Double?
    public let bestEstimated1RM: Double?
    public let volumeKg: Double?
    public let volumeExcludedSetCount: Int
    public let volumeEstimated: Bool
    public let completedReps: Double?
    public let repsExcludedSetCount: Int
    public let repsEstimated: Bool
    /// Longest single set's hold time this occurrence, for `.time`-metric
    /// exercises (e.g. plank) — nil for anything else. 2026-09-06 审查报告
    /// "适合当前范围的功能"第二批: 趋势指标此前只覆盖重量/次数，时间/距离/
    /// 轮次类动作（录入早已支持这些类型）没有对应的趋势可看。
    public let bestDurationSeconds: Double?
    /// Longest single set's distance this occurrence, for `.distance`-metric
    /// exercises (e.g. rowing).
    public let bestDistanceMeters: Double?
    /// Most rounds completed in a single set this occurrence, for
    /// `.rounds`-metric exercises (e.g. an AMRAP-style carry/circuit).
    public let bestRoundsCount: Double?

    /// True iff any contributing set's load is `.perSide` — used by the UI
    /// to decide whether the weight axis needs a "单侧 kg" annotation.
    public let anyPerSideLoad: Bool
}

/// Builds `ExerciseHistoryPoint`s from raw model objects and derives PR /
/// aggregate summaries. The single seam between SwiftData models and the
/// pure `AnalyticsMath` functions above.
public enum ExerciseHistoryAnalyzer {

    /// One point per `ExerciseEntry`, sorted ascending by session date.
    /// `includeInferred = false` drops individual SETS whose `isInferred`
    /// is true (rule ⑤: defaults to `true`, i.e. included); an entry left
    /// with zero sets after filtering is dropped from the result entirely,
    /// not shown as an empty point.
    public static func points(
        from entries: [ExerciseEntry],
        loadDirection: LoadDirection,
        includeInferred: Bool
    ) -> [ExerciseHistoryPoint] {
        var results: [(blockOrder: Int, entryOrder: Int, point: ExerciseHistoryPoint)] = []

        for entry in entries {
            guard let block = entry.block, let session = block.session else { continue }
            let allSets = entry.orderedSets
            let sets = includeInferred ? allSets : allSets.filter { !$0.isInferred }
            guard !sets.isEmpty else { continue }

            var maxLoad: Double?
            var best1RM: Double?
            var volume: Double = 0
            var volumeCount = 0
            var volumeExcluded = 0
            var volumeEstimated = false
            var reps: Double = 0
            var repsCount = 0
            var repsExcluded = 0
            var repsEstimated = false
            var bestDuration: Double?
            var bestDistance: Double?
            var bestRounds: Double?
            var anyPerSide = false

            for set in sets {
                if case .perSide = set.load { anyPerSide = true }

                // 2026-09-07 审阅 B03: a failed/not-recorded attempt (actual
                // reps/time/distance/rounds of 0) must never contribute a
                // comparable load, even though the LOAD value itself (what
                // was attempted) is fully known — otherwise a missed 150kg
                // lift registers as a 150kg PR.
                if AnalyticsMath.isEffectiveCompletion(actual: set.actual),
                   let kg = AnalyticsMath.comparableKg(set.load) {
                    maxLoad = maxLoad.map { AnalyticsMath.betterValue($0, kg, direction: loadDirection) } ?? kg
                }

                // Rule ① enforced here, structurally redundant with rule ②'s
                // own `.absolute`-only check for this dataset (assisted
                // loads are never `.absolute`) but kept explicit as a
                // defensive guard, not relied on implicitly.
                if !loadDirection.isInverted,
                   let oneRM = AnalyticsMath.estimatedOneRepMax(load: set.load, actual: set.actual) {
                    best1RM = max(best1RM ?? oneRM, oneRM)
                }

                if let v = AnalyticsMath.setVolume(load: set.load, actual: set.actual) {
                    volume += v
                    volumeCount += 1
                    if AnalyticsMath.isVolumeEstimated(load: set.load, actual: set.actual) {
                        volumeEstimated = true
                    }
                } else {
                    volumeExcluded += 1
                }

                if let r = AnalyticsMath.setReps(actual: set.actual) {
                    reps += r
                    repsCount += 1
                    if AnalyticsMath.isRepsEstimated(actual: set.actual) { repsEstimated = true }
                } else {
                    repsExcluded += 1
                }

                // Best-single-set figure for time/distance/rounds metrics —
                // same "longest/most in one set this session" philosophy as
                // `maxLoad` above, not a sum across sets.
                if let seconds = AnalyticsMath.setDurationSeconds(actual: set.actual) {
                    bestDuration = max(bestDuration ?? seconds, seconds)
                }
                if let meters = AnalyticsMath.setDistanceMeters(actual: set.actual) {
                    bestDistance = max(bestDistance ?? meters, meters)
                }
                if let rounds = AnalyticsMath.setRoundsCount(actual: set.actual) {
                    bestRounds = max(bestRounds ?? rounds, rounds)
                }
            }

            let summaries = sets.map {
                ExerciseHistoryPoint.SetSummary(
                    setIndex: $0.setIndex, load: $0.load, target: $0.target,
                    actual: $0.actual, isInferred: $0.isInferred
                )
            }

            let point = ExerciseHistoryPoint(
                // entry.order only counts within its own block (starts at 0
                // in each), so two blocks in the same session that both
                // include this exercise once each produced the same
                // "session.id#entry.order" id and collided (2026-09-06
                // 审查报告 #3). A block has no id of its own — CONTRACT.md
                // identifies it by (session.id, order) — so the composite
                // (session, block.order, entry.order) is what's actually
                // unique.
                id: "\(session.id)#\(block.order)#\(entry.order)",
                date: session.date,
                sessionID: session.id,
                sourceSheet: session.sourceSheet,
                sourceRow: session.sourceRow,
                blockNote: entry.block?.note,
                isInferred: sets.allSatisfy { $0.isInferred },
                anyInferred: sets.contains { $0.isInferred },
                sets: summaries,
                maxLoadKg: maxLoad,
                bestEstimated1RM: best1RM,
                volumeKg: volumeCount > 0 ? volume : nil,
                volumeExcludedSetCount: volumeExcluded,
                volumeEstimated: volumeEstimated,
                completedReps: repsCount > 0 ? reps : nil,
                repsExcludedSetCount: repsExcluded,
                repsEstimated: repsEstimated,
                bestDurationSeconds: bestDuration,
                bestDistanceMeters: bestDistance,
                bestRoundsCount: bestRounds,
                anyPerSideLoad: anyPerSide
            )
            results.append((blockOrder: block.order, entryOrder: entry.order, point: point))
        }

        // Same-day, same-session occurrences (e.g. two blocks that each
        // include this exercise once) sort by block order then entry order,
        // so the display order is deterministic regardless of the input
        // array's fetch order (2026-09-06 审查报告 #3).
        return results.sorted { lhs, rhs in
            if lhs.point.date != rhs.point.date { return lhs.point.date < rhs.point.date }
            if lhs.blockOrder != rhs.blockOrder { return lhs.blockOrder < rhs.blockOrder }
            return lhs.entryOrder < rhs.entryOrder
        }.map(\.point)
    }

    /// PR tracking over the `maxLoadKg` series (rule ⑤), respecting
    /// `loadDirection`. Returns, per point in chronological order, whether
    /// that point set a NEW running best — a strict improvement only
    /// ("同值不算破纪录"), never merely equal to the prior best.
    public static func prFlags(points: [ExerciseHistoryPoint], direction: LoadDirection) -> [Bool] {
        var flags: [Bool] = []
        var best: Double?
        for p in points {
            guard let v = p.maxLoadKg else { flags.append(false); continue }
            if let b = best {
                if AnalyticsMath.isImprovement(candidate: v, overBest: b, direction: direction) {
                    flags.append(true)
                    best = v
                } else {
                    flags.append(false)
                }
            } else {
                flags.append(true)
                best = v
            }
        }
        return flags
    }

    /// The current (i.e. final/best-to-date) PR value and the point that
    /// set it, or nil if no point in the series has a comparable load.
    public static func currentPR(points: [ExerciseHistoryPoint], direction: LoadDirection) -> (value: Double, point: ExerciseHistoryPoint)? {
        var best: (value: Double, point: ExerciseHistoryPoint)?
        for p in points {
            guard let v = p.maxLoadKg else { continue }
            if let b = best {
                if AnalyticsMath.isImprovement(candidate: v, overBest: b.value, direction: direction) {
                    best = (v, p)
                }
            } else {
                best = (v, p)
            }
        }
        return best
    }

    /// Volume rollup across a set of points (e.g. everything currently
    /// shown), for the "另有 N 组无法计入容量" requirement (rule ④). The
    /// total is the sum of only the countable portion; it must never be
    /// presented as if it were the session/query's complete volume without
    /// the accompanying excluded count.
    public static func volumeSummary(points: [ExerciseHistoryPoint]) -> (total: Double, excludedSetCount: Int, anyEstimated: Bool) {
        var total: Double = 0
        var excluded = 0
        var estimated = false
        for p in points {
            if let v = p.volumeKg { total += v }
            excluded += p.volumeExcludedSetCount
            if p.volumeEstimated { estimated = true }
        }
        return (total, excluded, estimated)
    }
}
