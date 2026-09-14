import Foundation
import SwiftData

/// CONTRACT-UI.md §3.2 -- the M2 acceptance criterion. Opening an entry row
/// must prefill 组数/次数目标/重量 from "该学员该动作最近一次的记录", searched
/// across the client's full session history.
///
/// The lookup walks `WorkoutSession -> SessionBlock -> ExerciseEntry ->
/// SetLog`, in reverse date order, and inspects **every** entry in **every**
/// block -- including multi-entry (superset/dropset/circuit) blocks -- so an
/// exercise that has only ever been logged inside a superset is still found.
/// This is deliberately not a query that only looks at single-entry blocks;
/// CONTRACT-UI.md's own risk callout is exactly about this case being missed.
public enum PrefillResolver {
    public struct Prefill: Equatable {
        public let sets: Int
        /// CONTRACT-M9.md: 目标 and 实际 are read from the historical set's
        /// own `target`/`actual` independently -- they're only ever equal by
        /// coincidence, not by construction.
        public let targetRepTarget: RepTarget
        public let actualRepTarget: RepTarget
        public let load: LoadValue
        public let sourceSessionDate: Date
    }

    /// Default values used when the client has no prior record of this
    /// exercise at all (CONTRACT-UI.md §3.2: "查无历史时用默认值（3 组 / `10` /
    /// 20kg）").
    public static let defaultSets = 3
    public static let defaultRepTarget = RepTarget.fixed(value: 10, raw: "10")
    public static let defaultLoad = LoadValue.absolute(kg: 20, raw: "20")

    /// Equipment-aware variant of `defaultLoad`: a never-before-recorded
    /// `.bodyweight` exercise should prefill at "自重" (no added weight),
    /// not the generic 20kg default -- that generic default predates the
    /// `.bodyweightPlus` wheel (`LoadWheelResolver.swift`) and was only ever
    /// meant for weighted equipment.
    public static func defaultLoad(for equipment: Equipment) -> LoadValue {
        equipment == .bodyweight ? .bodyweight(raw: "BW") : defaultLoad
    }

    /// Finds the client's most recent recorded set of `exerciseID`, across
    /// all of their sessions (all block types), and returns the values to
    /// prefill the four wheels with. `nil` if the client has never recorded
    /// this exercise.
    public static func lastRecord(clientID: String, exerciseID: String, in context: ModelContext) -> Prefill? {
        // Fetched unfiltered-by-predicate and sorted/filtered in Swift:
        // SwiftData's #Predicate macro has known trouble with optional
        // to-one relationship chains (`session.client?.id`), and at the
        // real dataset's scale (124 sessions) an in-memory pass over
        // already-materialized model objects costs nothing worth
        // optimizing prematurely for.
        let descriptor = FetchDescriptor<WorkoutSession>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        guard let sessions = try? context.fetch(descriptor) else { return nil }

        for session in sessions where session.client?.id == clientID {
            for block in session.orderedBlocks {
                for entry in block.orderedEntries where entry.exercise?.id == exerciseID {
                    let sets = entry.orderedSets
                    guard let firstSet = sets.first else { continue }
                    return Prefill(
                        sets: entry.plannedSets > 0 ? entry.plannedSets : sets.count,
                        targetRepTarget: firstSet.target,
                        actualRepTarget: firstSet.actual,
                        load: firstSet.load,
                        sourceSessionDate: session.date
                    )
                }
            }
        }
        return nil
    }

    /// Convenience wrapper returning always-usable prefill values (falls
    /// back to the documented defaults instead of `nil`).
    public static func resolvedPrefill(clientID: String, exerciseID: String, equipment: Equipment = .other, in context: ModelContext) -> Prefill {
        lastRecord(clientID: clientID, exerciseID: exerciseID, in: context)
            ?? Prefill(sets: defaultSets, targetRepTarget: defaultRepTarget, actualRepTarget: defaultRepTarget, load: defaultLoad(for: equipment), sourceSessionDate: .distantPast)
    }
}
