import Foundation
import SwiftData

/// The actual `ModelContext` mutation logic behind "暫時保存"/"結束課次"
/// (`TodayView.commit(client:finishing:)`), extracted so it is directly
/// unit-testable against a real (in-memory) `ModelContext` via
/// `@testable import GymLogKit`, rather than only reachable through a live
/// SwiftUI view -- "暂存多次→结束：数据库只有同一条课次" and "编辑处方与编辑
/// 成绩分别产生正确的身份和版本行为" both need to be tested through this
/// exact code path, not a hand-rolled stand-in.
///
/// `TodayView` becomes a thin caller: it resolves the UI-only bits this
/// service has no business knowing about (the App-target-only
/// `TrainingDayEncoding` timezone conversion -- see `SessionDraftLoader`'s
/// own doc comment for the same GymLogKit/App split -- and what to DO with
/// the result: success/error banners, clearing the on-disk draft snapshot,
/// ending the active rest-timer/heart-rate session) and hands everything
/// else here.
@MainActor
public enum SessionCommitService {
    public struct Input {
        public let client: Client
        /// The draft's own recorded owner -- checked against `client.id`
        /// before anything else (B08: never let a restored/stale draft
        /// silently attribute its content to whichever client happens to be
        /// currently selected).
        public let draftClientID: String
        public let existingSessionID: String?
        /// Already converted to this app's canonical UTC-midnight storage
        /// convention -- this service performs no date/timezone conversion
        /// itself (that logic is App-target-only, `TrainingDayEncoding`).
        public let sessionDateUTC: Date
        /// Verbatim raw date text used ONLY when creating a brand-new
        /// session; ignored when updating an existing one, which keeps its
        /// own `dateRaw`/`dateOrigin` untouched (CONTRACT.md §11.5 -- this
        /// same path also edits Excel-imported sessions, so it must never
        /// overwrite their original imported cell text).
        public let newSessionDateRawText: String
        public let weekNumberForNewSession: Int
        /// `nil` keeps an edited session's duration unrecorded.
        public let plannedDurationMinutes: Int?
        public let blocks: [BlockDraft]
        /// `false` = "暫時保存" (`WorkoutSession.isInProgress = true`);
        /// `true` = "結束課次" (`isInProgress = false`). Both go through this
        /// SAME path against the SAME `existingSessionID` once one exists,
        /// which is what keeps repeated "暫存" from ever creating more than
        /// one history row for the same session.
        public let finishing: Bool

        public init(
            client: Client, draftClientID: String, existingSessionID: String?, sessionDateUTC: Date,
            newSessionDateRawText: String, weekNumberForNewSession: Int, plannedDurationMinutes: Int?,
            blocks: [BlockDraft], finishing: Bool
        ) {
            self.client = client
            self.draftClientID = draftClientID
            self.existingSessionID = existingSessionID
            self.sessionDateUTC = sessionDateUTC
            self.newSessionDateRawText = newSessionDateRawText
            self.weekNumberForNewSession = weekNumberForNewSession
            self.plannedDurationMinutes = plannedDurationMinutes
            self.blocks = blocks
            self.finishing = finishing
        }
    }

    public enum Failure: Error {
        case clientMismatch
        case persistence(Error)
    }

    public struct Output {
        public let session: WorkoutSession
        public let blockCount: Int
        public let setCount: Int
    }

    /// Rewrites the session's entire block content in place: existing
    /// blocks are deleted (`SessionBlock -> ExerciseEntry -> SetLog` cascade
    /// takes the sets with them) and rebuilt fresh from `input.blocks`, then
    /// the whole thing is saved as ONE `context.save()` -- a failure rolls
    /// back every change this call made (the delete-and-rebuild included),
    /// leaving the persisted store exactly as it was before this call and
    /// the caller's draft still fully intact and re-committable.
    public static func commit(_ input: Input, in context: ModelContext) -> Swift.Result<Output, Failure> {
        guard input.draftClientID == input.client.id else { return .failure(.clientMismatch) }

        let session: WorkoutSession
        if let existing = input.existingSessionID.flatMap({ fetchSession(id: $0, in: context) }) {
            // A restored/stale session ID must not bypass the draft-owner
            // check above. Reject before deleting any persisted content.
            guard existing.client?.id == input.client.id else { return .failure(.clientMismatch) }
            for block in existing.blocks ?? [] {
                context.delete(block)
            }
            existing.blocks = []
            existing.date = input.sessionDateUTC
            existing.plannedDurationMinutes = input.plannedDurationMinutes
            session = existing
        } else {
            session = WorkoutSession(
                id: "se-local-\(UUID().uuidString)", date: input.sessionDateUTC, dateOrigin: .asRecorded,
                dateRaw: input.newSessionDateRawText, weekNumber: input.weekNumberForNewSession,
                sourceSheet: "App", sourceRow: 0, plannedDurationMinutes: input.plannedDurationMinutes
            )
            session.client = input.client
            context.insert(session)
        }
        session.isInProgress = !input.finishing

        for (blockIndex, blockDraft) in input.blocks.enumerated() {
            let block = SessionBlock(
                order: blockIndex, blockType: blockDraft.blockType, restSeconds: blockDraft.restSeconds,
                restRaw: blockDraft.resolvedRestRaw, note: blockDraft.source?.note,
                sourceRow: blockDraft.source?.sourceRow ?? 0, sectionKind: blockDraft.sectionKind
            )
            block.session = session
            context.insert(block)

            if blockDraft.sectionKind == .wod, let wodDraft = blockDraft.wodDraft {
                // Identity/version bookkeeping lives on the draft itself,
                // never derived from this session's id or this block's
                // array position -- see `WODBlockDraft.resolveIdentity()`'s
                // doc comment for the retest/reorder bugs that caused.
                let (prescriptionID, revision) = wodDraft.resolveIdentity()
                block.wodPayload = WODPayload(
                    prescription: wodDraft.resolvedPrescription(prescriptionID: prescriptionID, revision: revision),
                    result: wodDraft.resolvedResult()
                )
                continue
            }

            for (entryIndex, entryDraft) in blockDraft.entries.enumerated() {
                let entry = ExerciseEntry(
                    order: entryIndex, exerciseIdRef: entryDraft.exercise.id,
                    exerciseRaw: entryDraft.resolvedExerciseRaw, plannedSets: entryDraft.plannedSets,
                    exercise: entryDraft.exercise
                )
                entry.block = block
                context.insert(entry)
                let inferredFlags = entryDraft.resolvedInferredFlags()
                for (setIndex, values) in entryDraft.resolvedSets().enumerated() {
                    let setLog = SetLog(
                        setIndex: setIndex, load: values.load, target: values.target, actual: values.actual,
                        isInferred: inferredFlags[setIndex]
                    )
                    setLog.entry = entry
                    context.insert(setLog)
                }
            }
        }

        TrainingInsights.capture(session)
        do {
            try context.save()
            let setCount = input.blocks.reduce(0) { $0 + $1.entries.reduce(0) { $0 + $1.plannedSets } }
            return .success(Output(session: session, blockCount: input.blocks.count, setCount: setCount))
        } catch {
            context.rollback()
            return .failure(.persistence(error))
        }
    }

    private static func fetchSession(id: String, in context: ModelContext) -> WorkoutSession? {
        var descriptor = FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}
