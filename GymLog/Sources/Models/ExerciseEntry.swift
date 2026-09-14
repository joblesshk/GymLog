import Foundation
import SwiftData

/// CONTRACT.md §6. One exercise within a block.
@Model
public final class ExerciseEntry {
    public var order: Int
    /// Raw `exerciseId` string reference from the JSON; kept alongside the
    /// resolved relationship below so a dangling/unresolvable reference is
    /// still visible for debugging rather than silently disappearing.
    public var exerciseIdRef: String
    /// Original split-out exercise name fragment (CONTRACT.md §6, never
    /// dropped).
    public var exerciseRaw: String
    public var plannedSets: Int

    public var exercise: Exercise?
    public var block: SessionBlock?

    @Relationship(deleteRule: .cascade, inverse: \SetLog.entry)
    public var sets: [SetLog]? = []

    public init(order: Int, exerciseIdRef: String, exerciseRaw: String, plannedSets: Int, exercise: Exercise? = nil) {
        self.order = order
        self.exerciseIdRef = exerciseIdRef
        self.exerciseRaw = exerciseRaw
        self.plannedSets = plannedSets
        self.exercise = exercise
    }

    public var orderedSets: [SetLog] {
        (sets ?? []).sorted { $0.setIndex < $1.setIndex }
    }

    /// Display name: prefer the resolved canonical name, fall back to the
    /// raw fragment if the exercise reference couldn't be resolved.
    public var displayName: String {
        exercise?.canonicalName ?? exerciseRaw
    }
}
