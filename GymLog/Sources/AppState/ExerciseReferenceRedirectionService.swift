import Foundation
import SwiftData

/// The one place that knows how to redirect every real reference to an
/// `Exercise.id` when the coach merges (or a one-time device heal reassigns)
/// one exercise into another. Before this existed there were TWO independent
/// implementations that had drifted apart:
///
/// - `SeedImporter.redirectExerciseReferences` (B04, 2026-09-07) covered
///   `ExerciseEntry.exercise`/`exerciseIdRef` and `TemplateExerciseSlot
///   .exerciseID`, but not WOD payloads/prescriptions (documented gap,
///   `CONTRACT-M10.md` §5/§10).
/// - `ExerciseLibraryView`'s own merge button (`performMerge`) was a
///   SEPARATE, smaller implementation that only redirected `ExerciseEntry`
///   -- it never redirected `TemplateExerciseSlot.exerciseID` at all, a real
///   bug this review found: merging an exercise a template referenced left
///   that template's slot pointing at a deleted id, silently dropped by
///   `TemplateSessionBuilder` on every future "从模板新建" exactly like the
///   original B04 bug it was supposed to have fixed.
///
/// Both call sites now go through this service, which additionally covers
/// `SessionBlock.wodPayload` and `TemplateBlock.wodPrescription` (closing
/// the M1-era documented gap).
///
/// Explicitly NOT covered, by design: an in-progress "今天" draft
/// (`TodayDraftStore`/`WODBlockDraft`) currently open in memory, or its
/// on-disk `TodayDraftSnapshot`. Those live in a different store (plain
/// files, not `ModelContext`) that this service has no handle to, and a
/// coach merging exercises while ALSO mid-edit on a session referencing one
/// of them is a narrow, pre-existing risk shared with the original B04 fix
/// (which never touched drafts either) -- an open draft's in-memory
/// `Exercise` reference could still point at the just-deleted row until the
/// draft is reloaded. Every restore/snapshot path already degrades a
/// reference that no longer resolves by dropping/flagging it rather than
/// crashing (`EntryDraft.restore`, `WODMovementDraft.restore`), so the
/// failure mode here is "coach re-picks the movement next time they look at
/// this draft", not data loss or a crash.
public enum ExerciseReferenceRedirectionService {
    public struct Summary {
        public let entryCount: Int
        public let sessionCount: Int
        public let templateSlotCount: Int
        public let wodPayloadCount: Int
        public let wodPrescriptionCount: Int

        public var isEmpty: Bool {
            entryCount == 0 && templateSlotCount == 0 && wodPayloadCount == 0 && wodPrescriptionCount == 0
        }
    }

    /// Exactly what this one call changed, in a form sufficient to reverse
    /// it byte-for-byte -- raw JSON snapshots for WOD payloads/prescriptions
    /// (rather than re-deriving them) so undo restores the EXACT original
    /// text, not a re-encoded approximation, and never touches a block this
    /// call didn't itself modify (so a later, independent edit to some other
    /// block is never accidentally reverted by this undo).
    public struct UndoToken {
        fileprivate let sourceExerciseID: String
        fileprivate let entryIDs: [PersistentIdentifier]
        fileprivate let slotIDs: [PersistentIdentifier]
        fileprivate let wodPayloadSnapshots: [(blockID: PersistentIdentifier, rawJSON: String?)]
        fileprivate let wodPrescriptionSnapshots: [(blockID: PersistentIdentifier, rawJSON: String?)]
    }

    /// Redirects every reference to `source.id` over to `target.id` across
    /// `ExerciseEntry`, `TemplateExerciseSlot`, `SessionBlock.wodPayload`,
    /// and `TemplateBlock.wodPrescription`. Does NOT call `context.save()`
    /// or delete `source` -- the caller decides whether/when to save (and
    /// roll back on failure) and whether the source exercise itself should
    /// be deleted afterward, exactly like the pre-existing
    /// `SeedImporter.redirectExerciseReferences` contract this supersedes.
    ///
    /// Redirecting `exerciseID` inside a WOD movement/prescription is a pure
    /// identity fix -- it never rewrites `exerciseNameSnapshot`, `load`,
    /// `standard`, or `quantity` (those stay exactly what was recorded at
    /// the time, per "身份重定向不得覆盖历史名称、负重、标准、数量等原始快
    /// 照"), and it never changes `WODPrescription.revision`: two
    /// exercise-library rows being consolidated into one is not "the coach
    /// edited this workout's shape" the way changing a movement's
    /// quantity/load/standard is (`WODPrescription.comparabilitySnapshot`
    /// keys movement identity off `exerciseID` when present specifically so
    /// this redirect is invisible to `WODPRAnalyzer`'s comparison logic and
    /// `WODBlockDraft.resolveIdentity()`'s revision-bump check).
    public static func redirect(from source: Exercise, to target: Exercise, in context: ModelContext) throws -> (summary: Summary, undo: UndoToken) {
        let sourceID = source.id
        let targetID = target.id

        var entryIDs: [PersistentIdentifier] = []
        var sessionIDs = Set<String>()
        for entry in source.entries ?? [] {
            entryIDs.append(entry.persistentModelID)
            if let sessionID = entry.block?.session?.id { sessionIDs.insert(sessionID) }
            entry.exercise = target
            entry.exerciseIdRef = targetID
        }

        let slots = try context.fetch(FetchDescriptor<TemplateExerciseSlot>(
            predicate: #Predicate<TemplateExerciseSlot> { $0.exerciseID == sourceID }
        ))
        let slotIDs = slots.map(\.persistentModelID)
        for slot in slots {
            slot.exerciseID = targetID
        }

        var wodPayloadSnapshots: [(blockID: PersistentIdentifier, rawJSON: String?)] = []
        for block in try context.fetch(FetchDescriptor<SessionBlock>()) {
            guard var payload = block.wodPayload, payloadReferences(payload, exerciseID: sourceID) else { continue }
            wodPayloadSnapshots.append((block.persistentModelID, block.wodPayloadRawJSON))
            redirect(&payload, from: sourceID, to: targetID)
            block.wodPayload = payload
            if let sessionID = block.session?.id { sessionIDs.insert(sessionID) }
        }

        var wodPrescriptionSnapshots: [(blockID: PersistentIdentifier, rawJSON: String?)] = []
        for templateBlock in try context.fetch(FetchDescriptor<TemplateBlock>()) {
            guard var prescription = templateBlock.wodPrescription, prescriptionReferences(prescription, exerciseID: sourceID) else { continue }
            wodPrescriptionSnapshots.append((templateBlock.persistentModelID, templateBlock.wodPrescriptionRawJSON))
            redirect(&prescription, from: sourceID, to: targetID)
            templateBlock.wodPrescription = prescription
        }

        let summary = Summary(
            entryCount: entryIDs.count, sessionCount: sessionIDs.count, templateSlotCount: slotIDs.count,
            wodPayloadCount: wodPayloadSnapshots.count, wodPrescriptionCount: wodPrescriptionSnapshots.count
        )
        let undo = UndoToken(
            sourceExerciseID: sourceID, entryIDs: entryIDs, slotIDs: slotIDs,
            wodPayloadSnapshots: wodPayloadSnapshots, wodPrescriptionSnapshots: wodPrescriptionSnapshots
        )
        return (summary, undo)
    }

    /// Reverses exactly the changes recorded in `token` -- nothing else.
    /// `source` must still exist (the caller is responsible for not having
    /// permanently deleted it if undo is still offered; `ExerciseLibraryView`
    /// only offers "撤銷" before the source row itself would ever be
    /// deleted). Like `redirect`, does not call `context.save()`.
    public static func undo(_ token: UndoToken, source: Exercise, in context: ModelContext) {
        for entryID in token.entryIDs {
            if let entry = context.model(for: entryID) as? ExerciseEntry {
                entry.exercise = source
                entry.exerciseIdRef = token.sourceExerciseID
            }
        }
        for slotID in token.slotIDs {
            if let slot = context.model(for: slotID) as? TemplateExerciseSlot {
                slot.exerciseID = token.sourceExerciseID
            }
        }
        for (blockID, rawJSON) in token.wodPayloadSnapshots {
            if let block = context.model(for: blockID) as? SessionBlock {
                block.setWODPayloadRawJSON(rawJSON)
            }
        }
        for (blockID, rawJSON) in token.wodPrescriptionSnapshots {
            if let templateBlock = context.model(for: blockID) as? TemplateBlock {
                templateBlock.setWODPrescriptionRawJSON(rawJSON)
            }
        }
    }

    // MARK: - WOD payload/prescription traversal

    private static func payloadReferences(_ payload: WODPayload, exerciseID: String) -> Bool {
        prescriptionReferences(payload.prescription, exerciseID: exerciseID)
            || payload.result.actualMovements.contains { $0.exerciseID == exerciseID }
    }

    private static func prescriptionReferences(_ prescription: WODPrescription, exerciseID: String) -> Bool {
        prescription.rounds.contains { round in round.movements.contains { $0.exerciseID == exerciseID } }
    }

    private static func redirect(_ payload: inout WODPayload, from sourceID: String, to targetID: String) {
        redirect(&payload.prescription, from: sourceID, to: targetID)
        for index in payload.result.actualMovements.indices where payload.result.actualMovements[index].exerciseID == sourceID {
            payload.result.actualMovements[index].exerciseID = targetID
        }
    }

    private static func redirect(_ prescription: inout WODPrescription, from sourceID: String, to targetID: String) {
        for roundIndex in prescription.rounds.indices {
            for movementIndex in prescription.rounds[roundIndex].movements.indices
            where prescription.rounds[roundIndex].movements[movementIndex].exerciseID == sourceID {
                prescription.rounds[roundIndex].movements[movementIndex].exerciseID = targetID
            }
        }
    }
}
