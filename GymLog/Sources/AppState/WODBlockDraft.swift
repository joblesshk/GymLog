import Foundation
import Observation

/// Which `WorkoutQuantity` case a movement's quantity is in -- draft-side
/// enum so the UI has something `Picker`-friendly (`WorkoutQuantity` itself
/// carries its value inline, awkward for a segmented control).
public enum WorkoutQuantityKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case reps, seconds, meters, machineCalories

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .reps: return L("次數", "Reps")
        case .seconds: return L("秒", "Seconds")
        case .meters: return L("公尺", "Meters")
        case .machineCalories: return L("卡（器械顯示）", "Calories (machine)")
        }
    }

    /// 单位胶囊上用的短名。`displayName` 里「卡（器械顯示）」/「Calories
    /// (machine)」那种长度放不进动作行的一格，早先就是它把整行挤到换行的
    /// （2026-09-09 教练截图：`Reps` 被折成上下两行的 `Rep` / `s`）。菜单展开
    /// 后仍然用完整的 `displayName`，说明不丢。
    public var shortName: String {
        switch self {
        case .reps: return L("次", "reps")
        case .seconds: return L("秒", "sec")
        case .meters: return L("公尺", "m")
        case .machineCalories: return L("卡", "cal")
        }
    }

    /// `WorkoutQuantity`'s discriminator, independent of its value -- used
    /// to read back which kind a persisted quantity was recorded in without
    /// re-deriving it from the exercise library's CURRENT classification
    /// (same "unit comes from the record, not today's library state" rule
    /// `SessionDraftLoader.recordingMetric(for:fallback:)` already applies
    /// to strength entries). `nil` for `.unknown` (nothing recorded).
    public static func of(_ quantity: WorkoutQuantity) -> WorkoutQuantityKind? {
        switch quantity {
        case .reps: return .reps
        case .seconds: return .seconds
        case .meters: return .meters
        case .machineCalories: return .machineCalories
        case .unknown: return nil
        }
    }

    fileprivate func makeQuantity(_ value: Int) -> WorkoutQuantity {
        switch self {
        case .reps: return .reps(value, raw: "\(value)")
        case .seconds: return .seconds(value, raw: "\(value)")
        case .meters: return .meters(value, raw: "\(value)")
        case .machineCalories: return .machineCalories(value, raw: "\(value)")
        }
    }
}

/// One movement row while authoring a WOD prescription -- the in-progress,
/// never-yet-saved mirror of `WODMovementPrescription`, same "plain
/// @Observable class, converted to the real Codable type only at save time"
/// shape `EntryDraft`/`RoundDraft` already use for strength entries.
@MainActor
@Observable
public final class WODMovementDraft: Identifiable {
    public let id: UUID
    /// Set when picked from the exercise library; `nil` for a hand-typed
    /// movement name not in the library (a coach can WOD-record "Assault
    /// Bike Sprints" without first adding it as a formal Exercise).
    public var exercise: Exercise?
    /// Always the source of truth for display/snapshot -- populated from
    /// `exercise.canonicalName` when a library exercise is picked, editable
    /// afterward, and the ONLY thing `resolvedPrescription` reads (mirrors
    /// `WODMovementPrescription.exerciseNameSnapshot`'s "must resolve
    /// independent of the library staying unchanged" rule).
    public var nameText: String
    public var quantityKind: WorkoutQuantityKind
    public var quantityValue: Int
    public var loadKg: Double?
    /// Free-text movement standard/variant note (e.g. "chest-to-bar", "24in
    /// box") -- part of `WODMovementPrescription.standard`, and part of the
    /// comparability fields two attempts must match on to be treated as the
    /// same WOD (see `WODPrescription.comparabilitySnapshot`).
    public var standard: String

    public init(
        id: UUID = UUID(), exercise: Exercise? = nil, nameText: String = "",
        quantityKind: WorkoutQuantityKind = .reps, quantityValue: Int = 10,
        loadKg: Double? = nil, standard: String = ""
    ) {
        self.id = id
        self.exercise = exercise
        self.nameText = nameText.isEmpty ? (exercise?.canonicalName ?? "") : nameText
        self.quantityKind = quantityKind
        self.quantityValue = quantityValue
        self.loadKg = loadKg
        self.standard = standard
    }

    /// Selecting an exercise from the library sets `nameText` (still freely
    /// editable afterward) and defaults the quantity kind to the exercise's
    /// own `recordingMetric`, same "library classification only supplies the
    /// default" rule `EntryDraft.recordingMetric` established for strength
    /// entries (2026-09-07 审阅 B02).
    ///
    /// 2026-09-09：名称改成**总是**覆盖，原本只在 `nameText` 为空时才填。旧行
    /// 为在旧版面下无所谓（选动作的入口是最左边一个不起眼的图标，基本只在空行
    /// 上用）；新版面把「選動作」做成了显眼的按钮，教练打了半个名字发现库里有、
    /// 于是去点它，是完全正常的操作——这时留着那半个词才是错的。
    public func applyExercise(_ exercise: Exercise) {
        self.exercise = exercise
        nameText = exercise.canonicalName
        switch exercise.recordingMetric {
        case .time: quantityKind = .seconds
        case .distance: quantityKind = .meters
        case .reps, .rounds, .unknown: quantityKind = .reps
        }
    }

    public var resolvedQuantity: WorkoutQuantity {
        quantityKind.makeQuantity(quantityValue)
    }

    public func resolvedPrescription(stepID: String) -> WODMovementPrescription {
        WODMovementPrescription(
            stepID: stepID,
            exerciseID: exercise?.id,
            exerciseNameSnapshot: nameText,
            quantity: resolvedQuantity,
            load: loadKg.map { .absolute(kg: $0, raw: Self.formatKg($0)) },
            standard: standard.isEmpty ? nil : standard
        )
    }

    private static func formatKg(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    /// Builds an editable draft from a saved `WODMovementPrescription` --
    /// see `WODBlockDraft.fromPrescription`'s doc comment for the "copy
    /// last session"/retest use case this serves.
    public static func fromPrescription(_ prescription: WODMovementPrescription, exercises: [Exercise]) -> WODMovementDraft {
        let exercise = prescription.exerciseID.flatMap { id in exercises.first(where: { $0.id == id }) }
        let kind = WorkoutQuantityKind.of(prescription.quantity) ?? .reps
        let value = prescription.quantity.value ?? 0
        var loadKg: Double?
        if case .absolute(let kg, _) = prescription.load { loadKg = kg }
        return WODMovementDraft(
            exercise: exercise, nameText: prescription.exerciseNameSnapshot, quantityKind: kind,
            quantityValue: value, loadKg: loadKg, standard: prescription.standard ?? ""
        )
    }
}

/// One "round" of movements while authoring/editing a WOD prescription --
/// e.g. 21-15-9 is three `WODRoundDraft`s sharing the same movements at
/// different quantities. The counterpart to `WODRoundPrescription`, same
/// "editable class, converted to the real value type at save time" split
/// every other draft type in this file uses.
@MainActor
@Observable
public final class WODRoundDraft: Identifiable {
    public let id: UUID
    public var movements: [WODMovementDraft]

    public init(id: UUID = UUID(), movements: [WODMovementDraft] = []) {
        self.id = id
        self.movements = movements.isEmpty ? [WODMovementDraft()] : movements
    }
}

/// In-progress WOD block being authored/recorded in "今天" -- the WOD
/// counterpart to `EntryDraft`/`BlockDraft`. Nothing here touches
/// `ModelContext`; it only becomes a real `SessionBlock.wodPayload` on save
/// (`resolvedPrescription`/`resolvedResult`, mirrored by
/// `TodayView.save(client:)`).
@MainActor
@Observable
public final class WODBlockDraft: Identifiable {
    public let id: UUID
    public var name: String
    public var format: WODFormat
    /// AMRAP duration, or For Time's optional cap, in seconds.
    public var timeCapSeconds: Int?
    /// EMOM/interval: work-interval length, in seconds.
    public var intervalSeconds: Int?
    /// Interval: rest between work periods, in seconds.
    public var restSeconds: Int?
    /// EMOM/interval: total number of intervals.
    public var intervalCount: Int?
    /// Ordered rounds -- most WODs have exactly one (the round template
    /// simply repeats, e.g. an AMRAP, or executes once, e.g. a plain For
    /// Time); a 21-15-9-style prescription has one `WODRoundDraft` per
    /// distinct rep scheme, each independently editable (加/刪/調整順序,
    /// never a single "总轮数" standing in for rounds whose quantities
    /// actually differ).
    public var rounds: [WODRoundDraft]
    public var scoringRule: WODScoringRule
    public var variant: WODVariant
    /// Recovery anchor for a currently-RUNNING live timer, or `nil` when no
    /// timer is running (idle/paused/ended) -- persisted through the same
    /// draft-snapshot/debounced-autosave path M0 built for strength drafts
    /// (`CONTRACT-M10.md` §7), so a kill-and-relaunch mid-WOD can restore
    /// the countdown via `WODTimerModel.restore(from:)`. Updated at phase
    /// boundaries and start/pause/end, not every tick -- see
    /// `WODBlockDraftCard` for why per-tick updates would starve the
    /// debounced autosave instead of ever letting it actually fire.
    public var timerAnchor: WODTimerAnchor?

    // MARK: Identity/version (see `resolveIdentity()`)

    /// This block's persisted prescription id, if it was ever loaded from
    /// one (`fromPrescription` -- continuing an edit, retesting a copy, or
    /// starting from a template). `nil` for a block newly created from
    /// scratch, which mints its own id on first save.
    public private(set) var prescriptionID: String?
    /// The revision this block was loaded at. `resolveIdentity()` keeps this
    /// UNLESS the freshly-resolved prescription is no longer comparably
    /// equivalent to `originalPrescription`.
    public private(set) var revision: Int = 1
    /// The exact prescription this draft was loaded from, kept verbatim so
    /// `resolveIdentity()` has something to diff the freshly-authored
    /// prescription against. `nil` for a from-scratch block.
    public private(set) var originalPrescription: WODPrescription?
    /// Free-text source/standard reference on the PRESCRIPTION itself
    /// (`WODPrescription.standardNotes`, distinct from a per-movement
    /// `standard`) -- no UI edits this field yet, so it is carried through
    /// verbatim rather than silently dropped on every edit round-trip.
    public private(set) var standardNotesPassthrough: String?
    /// The full result this draft was loaded from (`SessionDraftLoader`'s
    /// "continue editing" path only -- `fromPrescription`'s own "retest"
    /// callers never set this, since a retest must start from
    /// `.notRecorded`). Fields the authoring UI doesn't expose an editor
    /// for (`actualMovements`, `rpe`, `cappedAtStepID`/`cappedProgress`,
    /// `intervalResults`, extra `typedTotals` entries) are read back from
    /// here in `resolvedResult()` rather than silently zeroed.
    public var originalResult: WODResult?
    /// Where the CURRENT result came from. Defaults to `.manual` for a
    /// fresh draft (matches this UI's primary manual-entry path); set to
    /// `.timer` when a live timer actually produced the result
    /// (`WODBlockDraftCard.applyTimerResultIfApplicable`), and restored from
    /// the original result when continuing to edit an already-saved attempt
    /// -- previously this was hardcoded to `.manual` on every save,
    /// silently overwriting a genuinely timer-recorded attempt's
    /// provenance the moment the coach reopened it to fix a typo in the
    /// notes.
    public var recordedVia: WODRecordingSource = .manual

    // MARK: Result (manual entry -- no timer)

    public var status: WODResultStatus
    public var elapsedSeconds: Int?
    public var completedRounds: Int?
    public var partialRoundReps: Int?
    /// EMOM/interval v1: one aggregate completed-quantity total across all
    /// intervals -- per-interval breakdown (`WODResult.intervalResults`) is
    /// fully supported by the data model already but not yet exposed by
    /// this v1 authoring UI (documented gap, `CONTRACT-M10.md`); its content
    /// is still preserved losslessly through `originalResult` when editing
    /// an attempt that already has it.
    public var totalCompletedValue: Int?
    /// The unit `totalCompletedValue` is in -- meters/calories/reps/seconds
    /// are NOT interchangeable (工程审阅: "不要直接取数组第一项当作通用总
    /// 成绩"／"米和卡永遠是兩個獨立值"). Defaults to `.reps` only for a
    /// brand-new draft; loading an existing total reads back its actual unit
    /// (`SessionDraftLoader`).
    public var totalCompletedQuantityKind: WorkoutQuantityKind = .reps
    public var notes: String

    public init(
        id: UUID = UUID(), name: String = "", format: WODFormat = .amrap,
        timeCapSeconds: Int? = 720, intervalSeconds: Int? = nil, restSeconds: Int? = nil, intervalCount: Int? = nil,
        movements: [WODMovementDraft] = [], rounds: [WODRoundDraft] = [],
        scoringRule: WODScoringRule = .roundsAndReps, variant: WODVariant = .unknown,
        status: WODResultStatus = .notRecorded, elapsedSeconds: Int? = nil, completedRounds: Int? = nil,
        partialRoundReps: Int? = nil, totalCompletedValue: Int? = nil,
        totalCompletedQuantityKind: WorkoutQuantityKind = .reps,
        notes: String = "", timerAnchor: WODTimerAnchor? = nil
    ) {
        self.id = id
        self.name = name
        self.format = format
        self.timeCapSeconds = timeCapSeconds
        self.intervalSeconds = intervalSeconds
        self.restSeconds = restSeconds
        self.intervalCount = intervalCount
        self.rounds = rounds.isEmpty ? [WODRoundDraft(movements: movements)] : rounds
        self.scoringRule = scoringRule
        self.variant = variant
        self.status = status
        self.elapsedSeconds = elapsedSeconds
        self.completedRounds = completedRounds
        self.partialRoundReps = partialRoundReps
        self.totalCompletedValue = totalCompletedValue
        self.totalCompletedQuantityKind = totalCompletedQuantityKind
        self.notes = notes
        self.timerAnchor = timerAnchor
    }

    /// Round 0's movements -- kept as a convenience for the (still by far
    /// most common) single-round WOD, and for every existing call site
    /// written before multi-round support existed. Reads/writes
    /// `rounds[0]`.
    public var movements: [WODMovementDraft] {
        get { rounds.first?.movements ?? [] }
        set {
            if rounds.isEmpty {
                rounds = [WODRoundDraft(movements: newValue)]
            } else {
                rounds[0].movements = newValue
            }
        }
    }

    /// 追加一个动作行到第一轮。
    ///
    /// 2026-09-09 起入口都是「先选动作再建行」（教练反馈：新开 WOD 给一个空行
    /// 不如像添加動作那样先让人选），所以名字是必填参数——`exercise` 为 nil
    /// 表示这个名字是教练自己打的、库里没有对应条目，这是 WOD 一直允许的情况
    /// （见 `WODMovementDraft.nameText`）。
    public func addMovement(named name: String, exercise: Exercise? = nil) {
        addMovement(toRoundAt: 0, named: name, exercise: exercise)
    }

    public func removeMovement(id: UUID) {
        removeMovement(fromRoundAt: 0, id: id)
    }

    /// 加动作到指定轮次（多轮编排 UI 用）；越界索引静默忽略而不是崩溃，因为
    /// 这个方法只从 UI 的 `ForEach` 回调调用，索引理论上不该越界，但草稿在
    /// 同一次 body 求值周期内被并发删除轮次不是不可能。
    public func addMovement(toRoundAt index: Int, named name: String, exercise: Exercise? = nil) {
        guard rounds.indices.contains(index) else { return }
        let movement = WODMovementDraft(exercise: exercise, nameText: name)
        if let exercise { movement.applyExercise(exercise) }
        rounds[index].movements.append(movement)
    }

    public func removeMovement(fromRoundAt index: Int, id: UUID) {
        guard rounds.indices.contains(index), rounds[index].movements.count > 1 else { return }
        rounds[index].movements.removeAll { $0.id == id }
    }

    // MARK: - Multi-round management (21-15-9 etc.)

    /// Appends a new round, seeded as a COPY of the last round's movements
    /// (same exercises/names/units, editable quantities) rather than empty
    /// -- 21-15-9's three rounds share the same two movements at different
    /// rep counts; starting from a blank round would make the coach re-pick
    /// every movement three times for what is, in practice, the same WOD
    /// repeated at different quantities.
    public func addRound() {
        let template = rounds.last?.movements ?? []
        let cloned = template.map { movement in
            WODMovementDraft(
                exercise: movement.exercise, nameText: movement.nameText, quantityKind: movement.quantityKind,
                quantityValue: movement.quantityValue, loadKg: movement.loadKg, standard: movement.standard
            )
        }
        rounds.append(WODRoundDraft(movements: cloned))
    }

    /// A WOD must always have at least one round -- mirrors
    /// `removeMovement`'s "always at least one movement" floor.
    public func removeRound(id: UUID) {
        guard rounds.count > 1 else { return }
        rounds.removeAll { $0.id == id }
    }

    public func moveRoundUp(id: UUID) {
        guard let index = rounds.firstIndex(where: { $0.id == id }), index > 0 else { return }
        rounds.swapAt(index, index - 1)
    }

    public func moveRoundDown(id: UUID) {
        guard let index = rounds.firstIndex(where: { $0.id == id }), index < rounds.count - 1 else { return }
        rounds.swapAt(index, index + 1)
    }

    /// Setting a format resets the scoring rule to that format's
    /// conventional default -- a coach switching AMRAP→For Time expects the
    /// comparison rule to follow, not to keep AMRAP's rule silently
    /// mismatched against the new format.
    public func applyFormatDefaults(_ newFormat: WODFormat) {
        format = newFormat
        switch newFormat {
        case .amrap: scoringRule = .roundsAndReps
        case .forTime: scoringRule = .completionTime
        case .emom: scoringRule = .manual
        case .interval: scoringRule = .totalQuantity
        case .unknown: scoringRule = .unknown
        }
    }

    public func resolvedPrescription(prescriptionID: String, revision: Int = 1) -> WODPrescription {
        let resolvedRounds = rounds.enumerated().map { roundIndex, round in
            WODRoundPrescription(
                roundIndex: roundIndex,
                movements: round.movements.enumerated().map { movementIndex, movement in
                    movement.resolvedPrescription(stepID: "\(prescriptionID)-r\(roundIndex)-m\(movementIndex)")
                }
            )
        }
        return WODPrescription(
            id: prescriptionID, revision: revision, name: name.isEmpty ? nil : name, format: format,
            timeCapSeconds: timeCapSeconds, intervalSeconds: intervalSeconds, restSeconds: restSeconds,
            intervalCount: intervalCount, rounds: resolvedRounds, scoringRule: scoringRule,
            standardNotes: standardNotesPassthrough
        )
    }

    /// Decides this block's persisted `(id, revision)` pair for the NEXT
    /// save -- the single place identity/version bookkeeping happens.
    /// Previously `TodayView` derived a prescription id from the SESSION id
    /// and the block's ARRAY POSITION (`"wod-\(session.id)-block\(index)"`):
    /// copying a session for a same-standard retest changes `session.id`,
    /// so every retest silently started a brand-new PR group (its first
    /// attempt always flagged as a false "new record"); reordering blocks
    /// changed the index and broke identity even within the SAME session.
    /// Both failure modes are closed by keeping identity on the draft
    /// itself instead of re-deriving it from surrounding structure:
    ///
    /// - A block that has never been tied to a saved prescription
    ///   (`prescriptionID == nil` -- created from scratch, never loaded via
    ///   `fromPrescription`) mints a brand-new stable id at revision 1.
    /// - A block that WAS loaded from a saved prescription (continuing an
    ///   edit, a same-standard retest copy, or starting from a template)
    ///   keeps that SAME id forever. Its revision stays the SAME as the
    ///   original unless the freshly-resolved prescription is no longer
    ///   comparably equivalent to the one it was loaded from (a meaningful
    ///   edit to a comparability field, `WODPrescription
    ///   .isComparablyEquivalent(to:)`) -- editing only the RESULT
    ///   (score/notes/variant) never bumps either, and copying an
    ///   unmodified prescription for a retest never does either, which is
    ///   exactly what lets `WODPRAnalyzer` compare the retest against the
    ///   original.
    ///
    /// Idempotent for a GIVEN draft instance across repeated calls with no
    /// intervening edits: resolving identity CACHES it back onto
    /// `prescriptionID`/`revision`/`originalPrescription`. This matters for
    /// the exact "暫存三次再結束" flow -- `TodayView` keeps re-committing
    /// the SAME live `WODBlockDraft` instances across repeated "暫存"
    /// presses (no `SessionDraftLoader` reload happens in between). Without
    /// caching, a from-scratch block (`prescriptionID == nil`) would mint a
    /// BRAND NEW random id on every single "暫存" press -- defeating the
    /// whole point of this method for the most common real usage pattern.
    /// After caching, the 2nd/3rd/... press on the same instance takes the
    /// "already established identity" branch below and reuses the same id,
    /// bumping revision only if something was actually edited since the
    /// LAST resolve (not since the original load) -- `originalPrescription`
    /// is refreshed to the just-resolved shape every time, so a 3rd
    /// unmodified press never re-bumps a revision the 2nd press already
    /// bumped once.
    public func resolveIdentity() -> (id: String, revision: Int) {
        guard let existingID = prescriptionID, let original = originalPrescription else {
            let newID = "wod-\(UUID().uuidString)"
            prescriptionID = newID
            revision = 1
            originalPrescription = resolvedPrescription(prescriptionID: newID, revision: 1)
            return (newID, 1)
        }
        let candidate = resolvedPrescription(prescriptionID: existingID, revision: original.revision)
        let resolvedRevision = candidate.isComparablyEquivalent(to: original) ? original.revision : original.revision + 1
        revision = resolvedRevision
        originalPrescription = resolvedPrescription(prescriptionID: existingID, revision: resolvedRevision)
        return (existingID, resolvedRevision)
    }

    /// Builds an editable draft from a SAVED `WODPrescription` (a real
    /// session's or template's), with the result always starting fresh
    /// (`.notRecorded`) -- used by "复制上次课次"/"从模板新建" for a
    /// same-standard retest: the plan carries over (including its id and
    /// revision, so a retest compares correctly against the original in
    /// `WODPRAnalyzer`), the previous attempt's score never does (工程审阅
    /// §5.2/§6). "继续编辑同一次" additionally calls `applyExistingResult`
    /// afterward to bring the score back too (`SessionDraftLoader`).
    ///
    /// All rounds are carried over (not just the first) -- a multi-round
    /// prescription (21-15-9) round-trips fully.
    public static func fromPrescription(_ prescription: WODPrescription, exercises: [Exercise]) -> WODBlockDraft {
        let rounds = prescription.rounds.map { round in
            WODRoundDraft(movements: round.movements.map { WODMovementDraft.fromPrescription($0, exercises: exercises) })
        }
        let draft = WODBlockDraft(
            name: prescription.name ?? "", format: prescription.format, timeCapSeconds: prescription.timeCapSeconds,
            intervalSeconds: prescription.intervalSeconds, restSeconds: prescription.restSeconds,
            intervalCount: prescription.intervalCount, rounds: rounds, scoringRule: prescription.scoringRule
        )
        draft.prescriptionID = prescription.id
        draft.revision = prescription.revision
        draft.originalPrescription = prescription
        draft.standardNotesPassthrough = prescription.standardNotes
        return draft
    }

    /// Restores identity/version bookkeeping from a `TodayDraftSnapshot`
    /// (`WODBlockDraftSnapshot`'s `restore(from:)`) -- these fields are
    /// `private(set)` so nothing outside this type's own file/`fromPrescription`
    /// can mutate them by accident; a disk-restore is the one other
    /// legitimate writer.
    public func restoreIdentity(
        prescriptionID: String?, revision: Int, originalPrescription: WODPrescription?,
        standardNotesPassthrough: String?, originalResult: WODResult?, recordedVia: WODRecordingSource
    ) {
        self.prescriptionID = prescriptionID
        self.revision = revision
        self.originalPrescription = originalPrescription
        self.standardNotesPassthrough = standardNotesPassthrough
        self.originalResult = originalResult
        self.recordedVia = recordedVia
    }

    /// "继续编辑同一次"专用：把已保存的成绩原样填回草稿，包括这版 UI 没有
    /// 编辑入口的字段（`originalResult`，由 `resolvedResult()` 在保存时读回）
    /// ——`fromPrescription`本身永远不做这件事，保持它对"复制/从模板新建"
    /// 两个调用方仍然是"处方原样、成绩清空"。
    public func applyExistingResult(_ result: WODResult) {
        status = result.status
        elapsedSeconds = result.elapsedSeconds
        completedRounds = result.completedRounds
        partialRoundReps = result.partialRoundQuantity?.value
        variant = result.variant
        notes = result.notes ?? ""
        recordedVia = result.recordedVia
        if let firstTotal = result.typedTotals.first, result.typedTotals.count == 1,
           let kind = WorkoutQuantityKind.of(firstTotal) {
            totalCompletedValue = firstTotal.value
            totalCompletedQuantityKind = kind
        } else {
            // Zero or 2+ entries: this v1 single-total UI can't represent
            // it as one editable number. Leave the field blank rather than
            // showing a misleading partial read -- `originalResult` below
            // still carries the real data through untouched.
            totalCompletedValue = nil
        }
        originalResult = result
    }

    public func resolvedResult() -> WODResult {
        let typedTotals: [WorkoutQuantity]
        if let totalCompletedValue {
            typedTotals = [totalCompletedQuantityKind.makeQuantity(totalCompletedValue)]
        } else {
            typedTotals = originalResult?.typedTotals ?? []
        }
        // A cap/stop location only means something while the status is
        // still capped/stopped -- if the coach changed the outcome to
        // completed/not-recorded, a stale "stopped at step 7" pointer would
        // misdescribe the new status.
        let stillCappedOrStopped = status == .capped || status == .stopped
        return WODResult(
            status: status,
            elapsedSeconds: status == .completed ? elapsedSeconds : nil,
            completedRounds: completedRounds,
            partialRoundQuantity: partialRoundReps.map { .reps($0, raw: "\($0)") },
            cappedAtStepID: stillCappedOrStopped ? originalResult?.cappedAtStepID : nil,
            cappedProgress: stillCappedOrStopped ? originalResult?.cappedProgress : nil,
            intervalResults: originalResult?.intervalResults ?? [],
            typedTotals: typedTotals,
            variant: variant,
            actualMovements: originalResult?.actualMovements ?? [],
            notes: notes.isEmpty ? nil : notes,
            rpe: originalResult?.rpe,
            recordedVia: recordedVia
        )
    }
}
