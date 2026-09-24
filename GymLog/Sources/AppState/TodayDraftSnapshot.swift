import Foundation

/// Codable, `Exercise`-free mirror of `RoundDraft`/`EntryDraft`/`BlockDraft`/
/// `TodayDraftStore`, so an in-progress "今天" draft can survive the app
/// being terminated mid-entry (审查报告"适合当前范围的功能"第一批: 草稿自动保存
/// 与恢复 -- "现在草稿仅在内存中，放弃立即清空").
///
/// Stores `exerciseID` rather than an `Exercise` reference: the live object
/// only exists inside a `ModelContext`, which a plain JSON snapshot on disk
/// has no access to. Resolving back to a real `Exercise` happens at restore
/// time, against whatever the exercise library contains then -- an entry
/// whose exercise was deleted/merged away in the meantime is simply dropped
/// (mirrors `TodayView.startFromTemplate`'s existing "跳过未匹配的模板动作,
/// 明确提示教练" precedent, not a silent shrink).
/// R01 (2026-09-16): `target`/`actual` are the real `RepTarget` (`RepTarget`
/// is itself `Codable`), not a re-quantized `Int` -- an in-progress
/// `.range`/`.perSide` Round must survive an app-kill/restore cycle exactly
/// as losslessly as it survives the normal save/load round trip
/// (`RoundDraft`'s own doc comment). An old on-disk snapshot written before
/// this field shape existed simply fails to decode as a whole -- see
/// `DraftPersistence.load()`'s `.corrupted` handling, which quarantines a
/// decode failure instead of losing it silently, so this is a safe schema
/// change for a single-slot autosave file, not one that needs a migration
/// path of its own.
public struct RoundDraftSnapshot: Codable, Equatable {
    public var id: UUID
    public var setsCount: Int
    public var load: LoadValue
    public var target: RepTarget
    public var actual: RepTarget
    public var actualRecorded: Bool?
    /// `nil` for snapshots written before this field existed (= not inferred).
    public var isInferred: Bool?
    public var unrecordedActualRaw: String?

    public init(id: UUID, setsCount: Int, load: LoadValue, target: RepTarget, actual: RepTarget, actualRecorded: Bool? = nil, isInferred: Bool? = nil, unrecordedActualRaw: String? = nil) {
        self.id = id
        self.setsCount = setsCount
        self.load = load
        self.target = target
        self.actual = actual
        self.actualRecorded = actualRecorded
        self.isInferred = isInferred
        self.unrecordedActualRaw = unrecordedActualRaw
    }
}

public struct EntryDraftSnapshot: Codable, Equatable {
    public var id: UUID
    public var exerciseID: String
    public var rounds: [RoundDraftSnapshot]
    public var restSeconds: Int?
    /// The unit `rounds`' quantities were recorded in, captured at snapshot
    /// time (`EntryDraft.recordingMetric`) -- see that property's doc
    /// comment for why this must never be re-derived from the exercise
    /// library at restore time (2026-09-07 审阅 B02).
    ///
    /// `nil` only for a snapshot written before this field existed: an old
    /// on-disk draft from before this fix genuinely doesn't carry its
    /// original unit anywhere, so restore falls back to the exercise's
    /// CURRENT `recordingMetric` and flags the result as unverified rather
    /// than pretending it's exact (`EntryDraft.restore`'s `metricUncertain`
    /// return value).
    public var recordingMetric: RecordingMetric?
    public var source: EntrySourceFields?

    public init(id: UUID, exerciseID: String, rounds: [RoundDraftSnapshot], restSeconds: Int?, recordingMetric: RecordingMetric?, source: EntrySourceFields? = nil) {
        self.id = id
        self.exerciseID = exerciseID
        self.rounds = rounds
        self.restSeconds = restSeconds
        self.recordingMetric = recordingMetric
        self.source = source
    }
}

/// 2026-09-07 M2 CrossFit extension -- draft mirror of `WODMovementDraft`.
public struct WODMovementDraftSnapshot: Codable, Equatable {
    public var id: UUID
    public var exerciseID: String?
    public var nameText: String
    public var quantityKind: WorkoutQuantityKind
    public var quantityValue: Int
    public var loadKg: Double?
    public var standard: String

    public init(id: UUID, exerciseID: String?, nameText: String, quantityKind: WorkoutQuantityKind, quantityValue: Int, loadKg: Double?, standard: String) {
        self.id = id
        self.exerciseID = exerciseID
        self.nameText = nameText
        self.quantityKind = quantityKind
        self.quantityValue = quantityValue
        self.loadKg = loadKg
        self.standard = standard
    }
}

/// Draft mirror of `WODRoundDraft` (2026-09-10, multi-round authoring).
public struct WODRoundDraftSnapshot: Codable, Equatable {
    public var id: UUID
    public var movements: [WODMovementDraftSnapshot]

    public init(id: UUID, movements: [WODMovementDraftSnapshot]) {
        self.id = id
        self.movements = movements
    }
}

/// Draft mirror of `WODBlockDraft`.
public struct WODBlockDraftSnapshot: Codable, Equatable {
    public var id: UUID
    public var name: String
    public var format: WODFormat
    public var timeCapSeconds: Int?
    public var intervalSeconds: Int?
    public var restSeconds: Int?
    public var intervalCount: Int?
    /// Legacy flat movement list from before multi-round authoring existed
    /// -- kept ONLY so a snapshot written before 2026-09-10 still decodes
    /// (its `rounds` key is absent). `restore(from:)` prefers `rounds` when
    /// present and falls back to wrapping this as the single round every
    /// pre-existing WOD actually was.
    public var movements: [WODMovementDraftSnapshot]
    /// `nil` only for a pre-2026-09-10 snapshot (before multi-round
    /// authoring existed) -- see `movements`' doc comment.
    public var rounds: [WODRoundDraftSnapshot]?
    public var scoringRule: WODScoringRule
    public var variant: WODVariant
    public var status: WODResultStatus
    public var elapsedSeconds: Int?
    public var completedRounds: Int?
    public var partialRoundReps: Int?
    public var totalCompletedValue: Int?
    /// `nil` for a snapshot written before this field existed -- restore
    /// falls back to `.reps` (`WODBlockDraft`'s own default), matching this
    /// field's pre-existing hardcoded-to-reps behavior for anything that old.
    public var totalCompletedQuantityKind: WorkoutQuantityKind?
    public var notes: String
    /// 2026-09-07 M3: mirrors `WODBlockDraft.timerAnchor` -- `nil` for every
    /// snapshot written before M3 (decode-compatible via `decodeIfPresent`,
    /// same convention as every other M1/M2 additive field).
    public var timerAnchor: WODTimerAnchor?

    // MARK: Identity/version + full result passthrough (2026-09-10)

    public var prescriptionID: String?
    public var revision: Int?
    public var originalPrescription: WODPrescription?
    public var standardNotesPassthrough: String?
    public var originalResult: WODResult?
    public var recordedVia: WODRecordingSource?

    public init(
        id: UUID, name: String, format: WODFormat, timeCapSeconds: Int?, intervalSeconds: Int?, restSeconds: Int?,
        intervalCount: Int?, movements: [WODMovementDraftSnapshot], rounds: [WODRoundDraftSnapshot]? = nil,
        scoringRule: WODScoringRule, variant: WODVariant,
        status: WODResultStatus, elapsedSeconds: Int?, completedRounds: Int?, partialRoundReps: Int?,
        totalCompletedValue: Int?, totalCompletedQuantityKind: WorkoutQuantityKind? = nil, notes: String,
        timerAnchor: WODTimerAnchor? = nil, prescriptionID: String? = nil, revision: Int? = nil,
        originalPrescription: WODPrescription? = nil, standardNotesPassthrough: String? = nil,
        originalResult: WODResult? = nil, recordedVia: WODRecordingSource? = nil
    ) {
        self.id = id
        self.name = name
        self.format = format
        self.timeCapSeconds = timeCapSeconds
        self.intervalSeconds = intervalSeconds
        self.restSeconds = restSeconds
        self.intervalCount = intervalCount
        self.movements = movements
        self.rounds = rounds
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
        self.prescriptionID = prescriptionID
        self.revision = revision
        self.originalPrescription = originalPrescription
        self.standardNotesPassthrough = standardNotesPassthrough
        self.originalResult = originalResult
        self.recordedVia = recordedVia
    }
}

public struct BlockDraftSnapshot: Codable, Equatable {
    public var id: UUID
    public var blockType: BlockType
    public var restSeconds: Int?
    public var entries: [EntryDraftSnapshot]
    /// `nil` only for a snapshot written before M2 (2026-09-07) -- restore
    /// treats that the same as `.strength` (every pre-CrossFit draft's true
    /// kind), same convention as `SessionBlockBackupDTO.sectionKind`.
    public var sectionKind: SectionKind?
    public var wodDraft: WODBlockDraftSnapshot?
    public var source: BlockSourceFields?

    public init(id: UUID, blockType: BlockType, restSeconds: Int?, entries: [EntryDraftSnapshot], sectionKind: SectionKind? = nil, wodDraft: WODBlockDraftSnapshot? = nil, source: BlockSourceFields? = nil) {
        self.id = id
        self.blockType = blockType
        self.restSeconds = restSeconds
        self.entries = entries
        self.sectionKind = sectionKind
        self.wodDraft = wodDraft
        self.source = source
    }
}

/// Top-level snapshot of one in-progress session draft, plus `savedAt` so a
/// restore prompt can show the coach roughly how old the abandoned draft is.
public struct TodayDraftSnapshot: Codable, Equatable {
    public var clientID: String
    public var sessionDate: Date
    /// `nil` = the session being edited never recorded a duration.
    public var plannedDurationMinutes: Int?
    public var blocks: [BlockDraftSnapshot]
    public var savedAt: Date
    /// 2026-09-09：草稿已经「暫存」进 `WorkoutSession` 时的那一节的 id。
    /// `nil` = 还没落过库，或是这个字段出现之前写下的旧快照。带上它，进程被
    /// 杀掉后恢复出来的草稿仍然指向同一节课，不会在歷史里留下两份。
    public var persistedSessionID: String?
    /// 同上，`TodayDraftStore.openedFromHistory` 的镜像。
    public var openedFromHistory: Bool?

    public init(
        clientID: String, sessionDate: Date, plannedDurationMinutes: Int?, blocks: [BlockDraftSnapshot], savedAt: Date,
        persistedSessionID: String? = nil, openedFromHistory: Bool? = nil
    ) {
        self.clientID = clientID
        self.sessionDate = sessionDate
        self.plannedDurationMinutes = plannedDurationMinutes
        self.blocks = blocks
        self.savedAt = savedAt
        self.persistedSessionID = persistedSessionID
        self.openedFromHistory = openedFromHistory
    }
}

// MARK: - Snapshot <-> live draft conversion

extension RoundDraft {
    public func snapshot() -> RoundDraftSnapshot {
        RoundDraftSnapshot(id: id, setsCount: setsCount, load: load, target: target, actual: actual, actualRecorded: actualRecorded, isInferred: isInferred, unrecordedActualRaw: unrecordedActualRaw)
    }
}

extension EntryDraft {
    public func snapshot() -> EntryDraftSnapshot {
        EntryDraftSnapshot(id: id, exerciseID: exercise.id, rounds: rounds.map { $0.snapshot() }, restSeconds: restSeconds, recordingMetric: recordingMetric, source: source)
    }

    /// Rebuilds a live `EntryDraft` from a snapshot, resolving `exerciseID`
    /// against `exercises`. `entry` is `nil` if the exercise no longer
    /// exists (deleted or merged away since the draft was saved).
    /// `metricUncertain` is true when the snapshot predates
    /// `EntryDraftSnapshot.recordingMetric` and the restored unit is only a
    /// best-effort fallback to the exercise's current classification, not a
    /// value known to match what was actually recorded (2026-09-07 审阅 B02).
    public static func restore(from snapshot: EntryDraftSnapshot, exercises: [Exercise]) -> (entry: EntryDraft?, metricUncertain: Bool) {
        guard let exercise = exercises.first(where: { $0.id == snapshot.exerciseID }) else { return (nil, false) }
        let rounds = snapshot.rounds.map {
            RoundDraft(id: $0.id, setsCount: $0.setsCount, load: $0.load, target: $0.target, actual: $0.actual, actualRecorded: $0.actualRecorded ?? true, isInferred: $0.isInferred ?? false, unrecordedActualRaw: $0.unrecordedActualRaw)
        }
        let entry = EntryDraft(id: snapshot.id, exercise: exercise, rounds: rounds, restSeconds: snapshot.restSeconds, recordingMetric: snapshot.recordingMetric)
        entry.source = snapshot.source
        return (entry, snapshot.recordingMetric == nil)
    }
}

extension WODMovementDraft {
    public func snapshot() -> WODMovementDraftSnapshot {
        WODMovementDraftSnapshot(
            id: id, exerciseID: exercise?.id, nameText: nameText, quantityKind: quantityKind,
            quantityValue: quantityValue, loadKg: loadKg, standard: standard
        )
    }

    /// Re-resolves `exercise` against `exercises` by id if present; `nil`
    /// (an exercise deleted/merged since the snapshot was taken) simply
    /// leaves the movement's `exercise` unset -- `nameText` was captured
    /// independently at authoring time, so the movement still displays and
    /// saves correctly with no exercise-library backing, exactly like a
    /// hand-typed movement never had one.
    public static func restore(from snapshot: WODMovementDraftSnapshot, exercises: [Exercise]) -> WODMovementDraft {
        let exercise = snapshot.exerciseID.flatMap { id in exercises.first(where: { $0.id == id }) }
        return WODMovementDraft(
            id: snapshot.id, exercise: exercise, nameText: snapshot.nameText, quantityKind: snapshot.quantityKind,
            quantityValue: snapshot.quantityValue, loadKg: snapshot.loadKg, standard: snapshot.standard
        )
    }
}

extension WODRoundDraft {
    public func snapshot() -> WODRoundDraftSnapshot {
        WODRoundDraftSnapshot(id: id, movements: movements.map { $0.snapshot() })
    }

    public static func restore(from snapshot: WODRoundDraftSnapshot, exercises: [Exercise]) -> WODRoundDraft {
        WODRoundDraft(id: snapshot.id, movements: snapshot.movements.map { WODMovementDraft.restore(from: $0, exercises: exercises) })
    }
}

extension WODBlockDraft {
    public func snapshot() -> WODBlockDraftSnapshot {
        WODBlockDraftSnapshot(
            id: id, name: name, format: format, timeCapSeconds: timeCapSeconds, intervalSeconds: intervalSeconds,
            restSeconds: restSeconds, intervalCount: intervalCount, movements: movements.map { $0.snapshot() },
            rounds: rounds.map { $0.snapshot() },
            scoringRule: scoringRule, variant: variant, status: status, elapsedSeconds: elapsedSeconds,
            completedRounds: completedRounds, partialRoundReps: partialRoundReps,
            totalCompletedValue: totalCompletedValue, totalCompletedQuantityKind: totalCompletedQuantityKind,
            notes: notes, timerAnchor: timerAnchor,
            prescriptionID: prescriptionID, revision: revision, originalPrescription: originalPrescription,
            standardNotesPassthrough: standardNotesPassthrough, originalResult: originalResult, recordedVia: recordedVia
        )
    }

    /// `rounds` (present on every snapshot written 2026-09-10 or later)
    /// takes priority; a pre-multi-round snapshot only has the legacy flat
    /// `movements` list, which becomes the single round it always meant.
    public static func restore(from snapshot: WODBlockDraftSnapshot, exercises: [Exercise]) -> WODBlockDraft {
        let rounds: [WODRoundDraft]
        if let snapshotRounds = snapshot.rounds, !snapshotRounds.isEmpty {
            rounds = snapshotRounds.map { WODRoundDraft.restore(from: $0, exercises: exercises) }
        } else {
            rounds = [WODRoundDraft(movements: snapshot.movements.map { WODMovementDraft.restore(from: $0, exercises: exercises) })]
        }
        let draft = WODBlockDraft(
            id: snapshot.id, name: snapshot.name, format: snapshot.format, timeCapSeconds: snapshot.timeCapSeconds,
            intervalSeconds: snapshot.intervalSeconds, restSeconds: snapshot.restSeconds, intervalCount: snapshot.intervalCount,
            rounds: rounds,
            scoringRule: snapshot.scoringRule, variant: snapshot.variant, status: snapshot.status,
            elapsedSeconds: snapshot.elapsedSeconds, completedRounds: snapshot.completedRounds,
            partialRoundReps: snapshot.partialRoundReps, totalCompletedValue: snapshot.totalCompletedValue,
            totalCompletedQuantityKind: snapshot.totalCompletedQuantityKind ?? .reps,
            notes: snapshot.notes, timerAnchor: snapshot.timerAnchor
        )
        draft.restoreIdentity(
            prescriptionID: snapshot.prescriptionID, revision: snapshot.revision ?? 1,
            originalPrescription: snapshot.originalPrescription, standardNotesPassthrough: snapshot.standardNotesPassthrough,
            originalResult: snapshot.originalResult, recordedVia: snapshot.recordedVia ?? .manual
        )
        return draft
    }
}

extension BlockDraft {
    public func snapshot() -> BlockDraftSnapshot {
        BlockDraftSnapshot(
            id: id, blockType: blockType, restSeconds: restSeconds, entries: entries.map { $0.snapshot() },
            sectionKind: sectionKind, wodDraft: wodDraft?.snapshot(), source: source
        )
    }

    /// `nil` if every entry in a `.strength`/`.skill` block failed to
    /// resolve (its exercise(s) gone) -- an empty block is never restored,
    /// same rule `TodayView.copyLastSession` already applies ("guard
    /// !entries.isEmpty else { continue }"). A `.wod` block always restores
    /// (its movements degrade individually via `WODMovementDraft.restore`,
    /// never dropping the whole block). `metricUncertainCount` counts
    /// restored entries whose unit is only a best-effort guess (see
    /// `EntryDraft.restore`).
    public static func restore(from snapshot: BlockDraftSnapshot, exercises: [Exercise]) -> (block: BlockDraft?, droppedCount: Int, metricUncertainCount: Int) {
        let sectionKind = snapshot.sectionKind ?? .strength
        if sectionKind == .wod {
            let wodDraft = snapshot.wodDraft.map { WODBlockDraft.restore(from: $0, exercises: exercises) }
            let block = BlockDraft(id: snapshot.id, blockType: snapshot.blockType, restSeconds: snapshot.restSeconds, sectionKind: .wod, wodDraft: wodDraft)
            block.source = snapshot.source
            return (block, 0, 0)
        }
        let resolved = snapshot.entries.map { EntryDraft.restore(from: $0, exercises: exercises) }
        let entries = resolved.compactMap { $0.entry }
        let dropped = resolved.count - entries.count
        let metricUncertainCount = resolved.filter { $0.metricUncertain }.count
        guard !entries.isEmpty else { return (nil, dropped, metricUncertainCount) }
        let block = BlockDraft(id: snapshot.id, blockType: snapshot.blockType, restSeconds: snapshot.restSeconds, entries: entries, sectionKind: sectionKind)
        block.source = snapshot.source
        return (block, dropped, metricUncertainCount)
    }
}

extension TodayDraftStore {
    /// `nil` when there's nothing worth persisting -- mirrors
    /// `hasUnsavedWork`'s own condition, so an idle store never writes an
    /// empty snapshot to disk.
    public func snapshot() -> TodayDraftSnapshot? {
        guard hasUnsavedWork else { return nil }
        return TodayDraftSnapshot(
            clientID: clientID ?? "",
            sessionDate: sessionDate,
            plannedDurationMinutes: plannedDurationMinutes,
            blocks: blocks.map { $0.snapshot() },
            savedAt: Date(),
            persistedSessionID: persistedSessionID,
            openedFromHistory: openedFromHistory
        )
    }

    /// Rebuilds live draft state from a snapshot. Returns the number of
    /// entries dropped (their exercise no longer exists) so the caller can
    /// surface that to the coach, same as a template's unresolved slots, and
    /// the number restored with only a best-effort (unverified) unit guess
    /// (2026-09-07 审阅 B02 -- snapshots written before that fix carry no
    /// unit at all).
    @discardableResult
    public func restore(from snapshot: TodayDraftSnapshot, exercises: [Exercise]) -> (droppedCount: Int, metricUncertainCount: Int) {
        clientID = snapshot.clientID
        sessionDate = snapshot.sessionDate
        plannedDurationMinutes = snapshot.plannedDurationMinutes
        persistedSessionID = snapshot.persistedSessionID
        openedFromHistory = snapshot.openedFromHistory ?? false
        var droppedTotal = 0
        var metricUncertainTotal = 0
        blocks = snapshot.blocks.compactMap { blockSnapshot in
            let (block, dropped, metricUncertain) = BlockDraft.restore(from: blockSnapshot, exercises: exercises)
            droppedTotal += dropped
            metricUncertainTotal += metricUncertain
            return block
        }
        isActive = true
        return (droppedTotal, metricUncertainTotal)
    }
}
