import Foundation

/// What makes two `WODPrescription`s "the same workout, unchanged" for the
/// purpose of deciding whether a save should bump `revision` -- 下一轮交接
/// 要求的"可比性字段"清单：动作及顺序、各轮数量与单位、负重、动作标准、時限、
/// 間歇配置、計分方式，逐字段列在这里而不是散落在调用点，方便以后审计"这个
/// 字段算不算可比性"这件事只有一个答案。
///
/// Deliberately built as plain `Equatable` structs of already-normalized
/// `String`/`Int`/`Double` values rather than a hash -- comparing two
/// snapshots with `==` is exactly as deterministic as a stable hash would be
/// (no dependency on Swift's per-process-randomized `Hasher`), and skips the
/// entire "which hash algorithm" question. `raw` display text (e.g. a
/// `LoadValue`'s formatted string) is intentionally excluded: re-typing the
/// same 20kg as "20" vs "20.0" must never look like a different prescription
/// (呼应"标题和备注等不影响运动处方的字段不应意外打断比较" -- the same
/// principle extends to display-only text inside comparability fields).
extension WODPrescription {
    public struct ComparabilitySnapshot: Equatable {
        public struct Movement: Equatable {
            let exerciseKey: String
            let quantityKey: String
            let loadKey: String?
            let equipmentCount: Int?
            let heightCm: Double?
            let standard: String
        }
        public struct Round: Equatable {
            let movements: [Movement]
        }
        let format: WODFormat
        let timeCapSeconds: Int?
        let intervalSeconds: Int?
        let restSeconds: Int?
        let intervalCount: Int?
        let scoringRule: WODScoringRule
        let rounds: [Round]
    }

    /// Identity key for a movement: prefers `exerciseID` (stable across an
    /// exercise-library merge redirect -- redirecting an id must NOT look
    /// like "a different movement", see `ExerciseReferenceRedirectionService`)
    /// and falls back to the name snapshot only for a hand-typed movement
    /// with no library entry.
    private static func movementKey(_ movement: WODMovementPrescription) -> ComparabilitySnapshot.Movement {
        let exerciseKey = movement.exerciseID.map { "id:\($0)" } ?? "name:\(movement.exerciseNameSnapshot)"
        return ComparabilitySnapshot.Movement(
            exerciseKey: exerciseKey,
            quantityKey: quantityKey(movement.quantity),
            loadKey: movement.load.map(loadKey),
            equipmentCount: movement.equipmentCount,
            heightCm: movement.heightCm,
            standard: (movement.standard ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func quantityKey(_ quantity: WorkoutQuantity) -> String {
        switch quantity {
        case .reps(let v, _): return "reps:\(v)"
        case .seconds(let v, _): return "seconds:\(v)"
        case .meters(let v, _): return "meters:\(v)"
        case .machineCalories(let v, _): return "machineCalories:\(v)"
        case .unknown: return "unknown"
        }
    }

    private static func loadKey(_ load: LoadValue) -> String {
        switch load {
        case .absolute(let kg, _): return "absolute:\(kg)"
        case .perSide(let kg, _): return "perSide:\(kg)"
        case .bodyweight: return "bodyweight"
        case .assisted(let kg, _): return "assisted:\(kg)"
        case .band(let color, let count, _): return "band:\(color):\(count)"
        case .machineStack(let level, _): return "machineStack:\(level)"
        case .pinLoad(let desc, _): return "pinLoad:\(desc)"
        case .sled(let kg, _): return "sled:\(kg)"
        case .unknown: return "unknown"
        }
    }

    /// Not: `id`/`revision` (identity/version themselves), `name`/
    /// `standardNotes` (titles/source notes -- explicitly called out as
    /// "不影响运动处方"), `schemaVersion`, or any `stepID` (an internal
    /// bookkeeping key, not part of what was prescribed).
    public var comparabilitySnapshot: ComparabilitySnapshot {
        ComparabilitySnapshot(
            format: format,
            timeCapSeconds: timeCapSeconds,
            intervalSeconds: intervalSeconds,
            restSeconds: restSeconds,
            intervalCount: intervalCount,
            scoringRule: scoringRule,
            rounds: rounds.map { round in
                ComparabilitySnapshot.Round(movements: round.movements.map(Self.movementKey))
            }
        )
    }

    /// True iff `other` prescribes the exact same workout (same
    /// comparability fields) regardless of `id`/`revision`/`name`/
    /// `standardNotes`. Used to decide whether re-saving an edited WOD block
    /// should bump `revision` (differs) or keep it (identical) --
    /// see `WODBlockDraft.resolveIdentity()`.
    public func isComparablyEquivalent(to other: WODPrescription) -> Bool {
        comparabilitySnapshot == other.comparabilitySnapshot
    }
}

extension WODPrescription {
    /// Movement names across ALL rounds, deduplicated by movement identity
    /// (same rule as `comparabilitySnapshot`'s `exerciseKey`) while
    /// preserving first-appearance order -- e.g. 21-15-9's three rounds share
    /// the same two movements, so this returns those two names once, not six
    /// repeats. Replaces the old "`rounds.first?.movements` only" pattern
    /// that silently dropped every round past the first in CSV/summary
    /// exports once multi-round prescriptions became possible.
    public var uniqueMovementNames: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for round in rounds {
            for movement in round.movements {
                let key = movement.exerciseID.map { "id:\($0)" } ?? "name:\(movement.exerciseNameSnapshot)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                names.append(movement.exerciseNameSnapshot)
            }
        }
        return names
    }
}
