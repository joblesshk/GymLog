import Foundation
import Observation

/// CONTRACT-M5.md §3.3: one "Round" -- a genuinely different weight/rep
/// attempt within the same exercise on the same day (the coach's own
/// example: bench press Round 1 = 2 sets @ 30kg, Round 2 = 3 sets @ 45kg,
/// Round 3 = 2 sets @ 40kg). Replaces M4's `SetDraft`/per-set-editing
/// subsystem entirely -- there is no separate per-set override layer
/// anymore, only Rounds.
///
/// `targetQuantity`/`actualQuantity` are plain `Int`s, never `RepTarget`s --
/// only the unit each is in comes from a `RepTarget` case (see
/// `RepTargetToRoundQuantity`/`recordingMetric` below), not the shape.
///
/// CONTRACT-M9.md: M5 originally collapsed 目标/实际 into one shared number
/// for new entries ("为什么 reps 是 Int 不是 RepTarget", `CONTRACT-M5.md
/// §3.3.2`). The coach later asked for that reversed -- 目标 (what's planned)
/// and 实际 (what actually happened) are independently editable again, same
/// as `SetLog.target`/`SetLog.actual` always were at the model layer; only
/// the M5/M8 entry UI had ever merged them.
///
/// CONTRACT-M8.md: what unit these are actually in (reps / seconds / meters
/// / rounds) is not carried on `RoundDraft` itself -- it's whatever the
/// owning `EntryDraft.exercise.recordingMetric` says.
public struct RoundDraft: Identifiable, Equatable {
    public let id: UUID
    public var setsCount: Int
    public var load: LoadValue
    public var targetQuantity: Int
    public var actualQuantity: Int { didSet { actualRecorded = true } }
    public var actualRecorded: Bool

    public init(id: UUID = UUID(), setsCount: Int, load: LoadValue, targetQuantity: Int, actualQuantity: Int, actualRecorded: Bool = true) {
        self.id = id
        self.setsCount = setsCount
        self.load = load
        self.targetQuantity = targetQuantity
        self.actualQuantity = actualQuantity
        self.actualRecorded = actualRecorded
    }
}

/// CONTRACT-M5.md §3.3.2 (extended by CONTRACT-M8.md): converts a historical
/// `RepTarget` into the single exact integer a new `RoundDraft.quantity`
/// requires. Every call site that seeds a Round's quantity from historical
/// data (new-entry prefill, 复制上次课次, 从模板新建) routes through this so
/// the rounding rule is applied once and identically everywhere, per the
/// contract's explicit "不要在不同入口用不同规则" requirement.
///
/// `metric` is the exercise's own `recordingMetric` classification -- the
/// source of truth for which unit `quantity` should end up in, independent
/// of whatever kind the historical `target` happens to carry (an exercise
/// can be reclassified after being logged, or its history can be `.unknown`).
/// When `target`'s kind matches `metric`, the exact historical value passes
/// through (or, for `.reps`, the existing `.range`/`.perSide` midpoint-
/// rounding rule, unchanged from before M8). When it doesn't match, there is
/// no unit-correct number to extract, so this falls back to a sensible
/// per-metric default instead of pretending every mismatch means "10".
public enum RepTargetToRoundQuantity {
    public static func quantity(from target: RepTarget, metric: RecordingMetric) -> Int {
        switch (metric, target) {
        case (.time, .time(let seconds, _)):
            return seconds
        case (.distance, .distance(let meters, _)):
            return meters
        case (.rounds, .rounds(let count, _)):
            return count
        case (.reps, .fixed(let value, _)), (.unknown, .fixed(let value, _)):
            return value
        case (.reps, .range(let low, let high, _)), (.unknown, .range(let low, let high, _)):
            return Int((Double(low + high) / 2).rounded())
        case (.reps, .perSide(let left, let right, _)), (.unknown, .perSide(let left, let right, _)):
            return Int((Double(left + right) / 2).rounded())
        default:
            return defaultQuantity(for: metric)
        }
    }

    /// Per-metric fallback used both above (target/metric mismatch) and by
    /// `EntryDraft`'s empty-rounds-array bootstrap case.
    public static func defaultQuantity(for metric: RecordingMetric) -> Int {
        switch metric {
        case .time: return 30
        case .distance: return 200
        case .rounds: return 3
        case .reps, .unknown: return 10
        }
    }
}

/// In-memory (never-yet-saved) representation of one exercise entry being
/// built in the "今天" entry flow. Nothing here touches `ModelContext` --
/// it only becomes real `ExerciseEntry`/`SetLog` rows when the coach taps
/// 保存 (see `EntryDraft.resolvedSets()` and the save path in
/// `Sources/Views/Today/TodayView.swift`).
@MainActor
@Observable
public final class EntryDraft: Identifiable {
    /// CONTRACT-M5.md §3.3.2: "最多 4 个" / "至少保留 1 个".
    public static let maxRounds = 4
    public static let minRounds = 1

    public let id: UUID
    public var exercise: Exercise
    /// 1...4 Rounds, in display/save order. Never empty -- the initializer
    /// guarantees at least one Round, and `removeRound` refuses to drop the
    /// last one.
    public var rounds: [RoundDraft]
    public var restSeconds: Int?
    /// The unit every Round's `targetQuantity`/`actualQuantity` is in,
    /// captured ONCE at construction time from `exercise.recordingMetric`
    /// and never re-read from `exercise` afterward.
    ///
    /// 2026-09-07 审阅 B02 (实验确认): `resolvedSets()` used to read
    /// `exercise.recordingMetric` live on every call. `Exercise` is a
    /// SwiftData reference type the coach can reclassify at any time (动作库
    /// -> 编辑 -> 記錄單位) independently of any draft holding a reference to
    /// it, and a saved-to-disk draft snapshot resolves against whatever the
    /// library says AT RESTORE TIME, not when the Round's numbers were
    /// actually entered. Reproduced: a 500m row Round, snapshotted, then the
    /// exercise reclassified reps -- restoring it turned "500 meters" into
    /// "500 reps" with no unit conversion, silently. Capturing the metric
    /// once here means `exercise.recordingMetric` only ever supplies the
    /// DEFAULT for a Round created fresh from now on; it can never
    /// retroactively reinterpret a quantity someone already typed in.
    public private(set) var recordingMetric: RecordingMetric

    public init(
        id: UUID = UUID(),
        exercise: Exercise,
        rounds: [RoundDraft],
        restSeconds: Int? = nil,
        recordingMetric: RecordingMetric? = nil
    ) {
        self.id = id
        self.exercise = exercise
        let metric = recordingMetric ?? exercise.recordingMetric
        self.recordingMetric = metric
        self.rounds = rounds.isEmpty
            ? [RoundDraft(
                setsCount: 3, load: PrefillResolver.defaultLoad(for: exercise.equipment),
                targetQuantity: RepTargetToRoundQuantity.defaultQuantity(for: metric),
                actualQuantity: RepTargetToRoundQuantity.defaultQuantity(for: metric), actualRecorded: false
            )]
            : rounds
        self.restSeconds = restSeconds
    }

    /// Convenience for the common case (new entry / copy-last-session /
    /// template consumption): a single starting Round.
    public convenience init(
        id: UUID = UUID(),
        exercise: Exercise,
        setsCount: Int,
        load: LoadValue,
        targetQuantity: Int,
        actualQuantity: Int,
        restSeconds: Int? = nil,
        recordingMetric: RecordingMetric? = nil,
        actualRecorded: Bool = true
    ) {
        self.init(
            id: id,
            exercise: exercise,
            rounds: [RoundDraft(setsCount: setsCount, load: load, targetQuantity: targetQuantity, actualQuantity: actualQuantity, actualRecorded: actualRecorded)],
            restSeconds: restSeconds,
            recordingMetric: recordingMetric
        )
    }

    /// Swaps which exercise this entry refers to -- the "修改動作" picker
    /// flow (2026-09-11 P0 fix). Existing bug this closes: the picker used
    /// to write straight into `exercise` while `recordingMetric` stayed
    /// frozen at whatever it was captured as in `init` (the B02 fix above),
    /// so a Round's raw quantity kept its OLD meaning even after switching
    /// to an exercise recorded in a different unit -- e.g. a 500m row's
    /// Round, after swapping to a reps exercise, saved as `.distance(meters:
    /// 500)` under the new exercise (`resolvedSets()` still used the stale
    /// `recordingMetric`), while the UI displayed the same "500" reinterpreted
    /// live as "500 次" (`RoundTableView` reads `exercise.recordingMetric`
    /// directly) -- two different, both-wrong readings of the same number,
    /// neither reflecting what the coach actually typed. Routing every
    /// exercise swap through this method keeps `recordingMetric` and
    /// `exercise` changing together, atomically, same as `init` -- never an
    /// ambient live read -- so `resolvedSets()` stays correct.
    ///
    /// A same-metric swap (the common case, e.g. 槓鈴卧推 -> 啞鈴卧推) keeps
    /// every Round byte-for-byte, identical to a plain `exercise =` write. A
    /// metric change keeps each Round's `setsCount` (still meaningful for
    /// any exercise) but resets load/目標/實際 to the new metric's defaults
    /// -- the old raw number is never carried over and reinterpreted under a
    /// different unit.
    public func setExercise(_ newExercise: Exercise) {
        let newMetric = newExercise.recordingMetric
        guard newMetric != recordingMetric else {
            exercise = newExercise
            return
        }
        let fallback = RepTargetToRoundQuantity.defaultQuantity(for: newMetric)
        rounds = rounds.map {
            RoundDraft(
                id: $0.id,
                setsCount: $0.setsCount,
                load: PrefillResolver.defaultLoad(for: newExercise.equipment),
                targetQuantity: fallback,
                actualQuantity: fallback,
                actualRecorded: $0.actualRecorded
            )
        }
        recordingMetric = newMetric
        exercise = newExercise
    }

    public var canAddRound: Bool { rounds.count < Self.maxRounds }
    public var canRemoveRound: Bool { rounds.count > Self.minRounds }

    /// Appends a new Round seeded from the last Round's values (the coach's
    /// next attempt usually starts from where the previous one left off,
    /// then gets adjusted) -- no-op once `maxRounds` is reached. 目标/实际 are
    /// copied independently, not synced to each other.
    public func addRound() {
        guard canAddRound else { return }
        let seed = rounds.last
        let fallback = RepTargetToRoundQuantity.defaultQuantity(for: recordingMetric)
        rounds.append(RoundDraft(
            setsCount: seed?.setsCount ?? 3,
            load: seed?.load ?? PrefillResolver.defaultLoad(for: exercise.equipment),
            targetQuantity: seed?.targetQuantity ?? fallback,
            actualQuantity: seed?.actualQuantity ?? fallback,
            actualRecorded: false
        ))
    }

    /// Removes one Round by id -- no-op if only one Round remains (an entry
    /// must always have at least one Round of data).
    public func removeRound(id: UUID) {
        guard canRemoveRound else { return }
        rounds.removeAll { $0.id == id }
    }

    /// P3/M3a (2026-09-12): splits whichever `RoundDraft` currently covers
    /// physical set `physicalSetIndex` (1-based, across the WHOLE entry, in
    /// the same order `resolvedSets()` expands rounds into) into up to 3
    /// pieces -- [before, exactly this one set, after] -- so a voice command
    /// like "把第二組實際次數改為八次" can give ONE physical set an
    /// independently different value from the others that used to share its
    /// Round's single (load, target, actual) triple. `setsCount` is
    /// conserved across the split (sum unchanged); every OTHER physical
    /// set's own (load, target, actual) is byte-for-byte identical before
    /// and after -- splitting alone, with no further mutation, must never
    /// change what `resolvedSets()` returns.
    ///
    /// The returned id always identifies a `RoundDraft` with `setsCount ==
    /// 1` that owns exactly `physicalSetIndex`'s slot. That single-set piece
    /// keeps the ORIGINAL Round's id (not the `before`/`after` pieces) -- a
    /// caller that just split in order to immediately mutate that one set
    /// gets a stable id with no extra lookup.
    ///
    /// No-op (returns the covering Round's own id unchanged) if it already
    /// has `setsCount == 1`. Returns `nil` -- mutating nothing -- if
    /// `physicalSetIndex` is out of range (`< 1` or `> plannedSets`).
    @discardableResult
    public func splitRound(atPhysicalSetIndex physicalSetIndex: Int) -> UUID? {
        guard physicalSetIndex >= 1 else { return nil }
        var consumed = 0
        for (index, round) in rounds.enumerated() {
            let nextConsumed = consumed + round.setsCount
            guard physicalSetIndex <= nextConsumed else {
                consumed = nextConsumed
                continue
            }
            guard round.setsCount > 1 else { return round.id }
            let offsetWithinRound = physicalSetIndex - consumed - 1
            var pieces: [RoundDraft] = []
            if offsetWithinRound > 0 {
                pieces.append(RoundDraft(setsCount: offsetWithinRound, load: round.load, targetQuantity: round.targetQuantity, actualQuantity: round.actualQuantity, actualRecorded: round.actualRecorded))
            }
            pieces.append(RoundDraft(id: round.id, setsCount: 1, load: round.load, targetQuantity: round.targetQuantity, actualQuantity: round.actualQuantity, actualRecorded: round.actualRecorded))
            let afterCount = round.setsCount - offsetWithinRound - 1
            if afterCount > 0 {
                pieces.append(RoundDraft(setsCount: afterCount, load: round.load, targetQuantity: round.targetQuantity, actualQuantity: round.actualQuantity, actualRecorded: round.actualRecorded))
            }
            rounds.replaceSubrange(index...index, with: pieces)
            return round.id
        }
        return nil
    }

    /// `ExerciseEntry.plannedSets` = sum of all Rounds' `setsCount`
    /// (CONTRACT-M5.md §3.3.2).
    public var plannedSets: Int {
        rounds.reduce(0) { $0 + $1.setsCount }
    }

    /// The sets this entry will actually write on save, in Round order:
    /// Round 1's sets first, then Round 2's, etc. -- the caller assigns
    /// gapless `setIndex` via `.enumerated()` over this array, so Round 1
    /// occupies `0..<n1`, Round 2 occupies `n1..<n1+n2`, and so on, matching
    /// CONTRACT-M5.md §3.3.2's expansion rule exactly.
    public func resolvedSets() -> [(load: LoadValue, target: RepTarget, actual: RepTarget)] {
        let metric = recordingMetric
        return rounds.flatMap { round -> [(load: LoadValue, target: RepTarget, actual: RepTarget)] in
            let target = Self.repTarget(quantity: round.targetQuantity, metric: metric)
            let actual: RepTarget = round.actualRecorded ? Self.repTarget(quantity: round.actualQuantity, metric: metric) : .unknown(raw: "")
            return (0..<round.setsCount).map { _ in (round.load, target, actual) }
        }
    }

    /// CONTRACT-M8.md: wraps a Round's raw `quantity` back into the
    /// `RepTarget` case matching the exercise's `recordingMetric`, so a
    /// plank's Round is persisted as `.time(seconds:)` and a farmer walk's as
    /// `.rounds(count:)`, not unconditionally `.fixed` (reps) the way every
    /// exercise was persisted before M8.
    private static func repTarget(quantity: Int, metric: RecordingMetric) -> RepTarget {
        switch metric {
        case .time: return .time(seconds: quantity, raw: "\(quantity)")
        case .distance: return .distance(meters: quantity, raw: "\(quantity)m")
        case .rounds: return .rounds(count: quantity, raw: "\(quantity)round")
        case .reps, .unknown: return .fixed(value: quantity, raw: "\(quantity)")
        }
    }
}

/// In-memory grouping of one or more `EntryDraft`s -- mirrors `SessionBlock`
/// (CONTRACT.md §6) so a copied-from-last-session superset stays one block,
/// not two independent entries (CONTRACT-UI.md §3.5: "带出上一次课的完整块结构").
@MainActor
@Observable
public final class BlockDraft: Identifiable {
    public let id: UUID
    public var blockType: BlockType
    public var restSeconds: Int?
    public var entries: [EntryDraft]
    /// 2026-09-07 M1/M2 CrossFit extension. `.strength` (with `wodDraft ==
    /// nil`) is every pre-CrossFit block's shape, unchanged. A `.wod` block
    /// carries its authoring/recording state in `wodDraft` instead of
    /// `entries` (which stays empty for it) -- see `WODBlockDraft`.
    public var sectionKind: SectionKind
    public var wodDraft: WODBlockDraft?

    public init(
        id: UUID = UUID(), blockType: BlockType = .single, restSeconds: Int? = nil, entries: [EntryDraft] = [],
        sectionKind: SectionKind = .strength, wodDraft: WODBlockDraft? = nil
    ) {
        self.id = id
        self.blockType = blockType
        self.restSeconds = restSeconds
        self.entries = entries
        self.sectionKind = sectionKind
        self.wodDraft = wodDraft
    }
}
