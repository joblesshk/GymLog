import Foundation
import SwiftData
import CryptoKit

/// CONTRACT-M7.md §3.8/§3.9: the SwiftData persistence layer for an
/// incremental Excel import -- natural-key dedup, the §3.8.4 decision
/// matrix, exercise resolution (Levels 1-2 automatic; Levels 3-4 are the
/// caller's job, see `resolveExercises` below), and the same
/// parse-then-persist / single-save / rollback-on-error transaction shape
/// `SeedImporter` already established.
public enum XLSXHistoryImporter {
    public struct ImportResult {
        public var newSessions = 0
        public var existingSessions = 0
        public var updatedSessions = 0
        public var conflictedSessions = 0
        /// Sessions where >half the file's natural keys already exist under
        /// a DIFFERENT client -- CONTRACT-M7.md §9.2's "wrong client file"
        /// guard. Populated only, never acted on automatically.
        public var possiblyWrongClient = false
    }

    public enum ImportError: LocalizedError {
        case unresolvedExercises([String])

        public var errorDescription: String? {
            switch self {
            case .unresolvedExercises(let keys):
                return "\(keys.count) exercise name(s) need the coach's confirmation before import can continue: \(keys.joined(separator: ", "))"
            }
        }
    }

    // MARK: - Exercise resolution (§3.6 levels 1-2; level 3/4 auto-create is the caller's job)

    /// Resolves each exercise the parsed workbook references to an existing
    /// `Exercise`, via Level 1 (stable id -- exact name match, case/whitespace-
    /// insensitive) then Level 2 (matches an existing exercise's alias).
    /// Returns the still-unresolved keys for the caller (`ExcelImportFlow`,
    /// which auto-creates a new `Exercise` for each one rather than the
    /// original CONTRACT-M7.md §3.6 coach-confirmation flow) -- this
    /// function itself never creates an `Exercise` and never guesses.
    public static func resolveExercises(_ workbook: ParsedWorkbook, existing: [Exercise]) -> (resolved: [String: Exercise], unresolvedKeys: [String]) {
        let byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var byNormalizedAliasOrName: [String: Exercise] = [:]
        for exercise in existing {
            byNormalizedAliasOrName[ExerciseNameCanonicalizer.normalizeKey(exercise.canonicalName)] = exercise
            for alias in exercise.aliases {
                byNormalizedAliasOrName[ExerciseNameCanonicalizer.normalizeKey(alias)] = exercise
            }
        }
        var resolved: [String: Exercise] = [:]
        var unresolved: [String] = []
        for parsedExercise in workbook.exercises {
            if let exercise = byId[parsedExercise.id] {
                resolved[parsedExercise.key] = exercise
            } else if let exercise = byNormalizedAliasOrName[parsedExercise.key] {
                resolved[parsedExercise.key] = exercise
            } else {
                unresolved.append(parsedExercise.key)
            }
        }
        return (resolved, unresolved.sorted())
    }

    // MARK: - Session import

    /// - Parameters:
    ///   - exerciseResolutions: a COMPLETE mapping from every
    ///     `ParsedExercise.key`/`ParsedExerciseEntry.exerciseKey` the
    ///     workbook references to the `Exercise` it should resolve to
    ///     (including any newly created via the Level 4 UI flow). Any key
    ///     present in `skippedExerciseKeys` may be absent here instead.
    ///   - skippedExerciseKeys: entries whose exercise the coach chose to
    ///     skip (§3.6 level 4's third option) are dropped from their block
    ///     entirely; a block left with zero entries is not created.
    private enum SessionDecision {
        case new
        case existing
        case updated
        case conflicted
    }

    /// The §3.8.4 decision matrix, factored out so `importSessions(preview:
    /// true)` (for `ExcelImportPreviewSheet`'s counts) and the real commit
    /// path share EXACTLY one implementation -- a preview that could drift
    /// from what actually happens on commit would be worse than no preview.
    private static func decide(
        _ parsedSession: ParsedSession, client: Client, existingSessions: [WorkoutSession],
        rawWorkbook: XLSXWorkbook
    ) -> (decision: SessionDecision, existing: WorkoutSession?, sourceDigest: String, matchesAnotherClient: Bool) {
        // Natural key is (client.id, sourceSheet, weekNumber, dateRaw) --
        // CONTRACT-M7.md §3.8.2 -- so the client filter belongs IN the
        // match itself, not bolted on afterward. Two clients can
        // legitimately have sessions sharing the same (sourceSheet,
        // weekNumber, dateRaw) triple (e.g. two coaches' clients both
        // training in "Week 1"), and conflating them would silently
        // attribute one client's history to another.
        let naturalKeyMatch = existingSessions.first {
            $0.client?.id == client.id
                && $0.sourceSheet == parsedSession.sourceSheet
                && $0.weekNumber == parsedSession.weekNumber
                && $0.dateRaw == parsedSession.dateRaw
        }
        // Separate, additive signal (CONTRACT-M7.md §9.2): does this
        // natural key ALSO exist under a different client? That's evidence
        // of "wrong client file," not itself part of dedup.
        let matchesAnotherClient = existingSessions.contains {
            $0.client?.id != client.id
                && $0.sourceSheet == parsedSession.sourceSheet
                && $0.weekNumber == parsedSession.weekNumber
                && $0.dateRaw == parsedSession.dateRaw
        }

        let sourceDigest = SessionDigest.sourceDigest(sheet: parsedSession.sourceSheet, rows: parsedSession.sourceRowsUsed, workbook: rawWorkbook)

        guard let existing = naturalKeyMatch else {
            return (.new, nil, sourceDigest, matchesAnotherClient)
        }
        guard let storedSourceDigest = existing.sourceDigest else {
            // §3.8.4 last row: no digest on record (seed-imported) --
            // origin unclear, never touched.
            return (.existing, existing, sourceDigest, matchesAnotherClient)
        }
        if storedSourceDigest == sourceDigest {
            // Source unchanged either way -- whether or not the app has
            // since edited it, there is no reason to touch it.
            return (.existing, existing, sourceDigest, matchesAnotherClient)
        }
        // Source changed. Distinguish "app also edited it" (conflict) from
        // "app never touched it" (safe to replace) by recomputing the
        // import digest from the CURRENT database state.
        let recomputedImportDigest = importDigest(forExisting: existing)
        if recomputedImportDigest == existing.importDigest {
            return (.updated, existing, sourceDigest, matchesAnotherClient)
        }
        return (.conflicted, existing, sourceDigest, matchesAnotherClient)
    }

    /// - Parameter preview: when `true`, computes and returns the exact
    ///   same `ImportResult` the real commit would produce, WITHOUT writing
    ///   anything -- this is what `ExcelImportPreviewSheet` calls so its
    ///   displayed counts are guaranteed to match what "確認導入" then
    ///   actually does, not a separately-maintained estimate.
    public static func importSessions(
        _ workbook: ParsedWorkbook,
        rawWorkbook: XLSXWorkbook,
        client: Client,
        sourceFileName: String,
        exerciseResolutions: [String: Exercise],
        skippedExerciseKeys: Set<String> = [],
        preview: Bool = false,
        into context: ModelContext
    ) throws -> ImportResult {
        let missingResolutions = Set(workbook.exercises.map(\.key))
            .subtracting(exerciseResolutions.keys)
            .subtracting(skippedExerciseKeys)
        guard missingResolutions.isEmpty else {
            throw ImportError.unresolvedExercises(missingResolutions.sorted())
        }

        var result = ImportResult()
        let now = Date()
        let wasAutosaveEnabled = context.autosaveEnabled
        if !preview {
            context.autosaveEnabled = false
        }
        defer { if !preview { context.autosaveEnabled = wasAutosaveEnabled } }

        do {
            let existingSessions = try context.fetch(FetchDescriptor<WorkoutSession>())
            var otherClientMatches = 0

            for parsedSession in workbook.sessions {
                let (decision, existing, sourceDigest, matchesAnotherClient) = decide(parsedSession, client: client, existingSessions: existingSessions, rawWorkbook: rawWorkbook)
                if matchesAnotherClient { otherClientMatches += 1 }

                switch decision {
                case .new:
                    result.newSessions += 1
                    if !preview {
                        try insertSession(parsedSession, client: client, sourceFileName: sourceFileName, sourceDigest: sourceDigest, importedAt: now, exerciseResolutions: exerciseResolutions, skippedExerciseKeys: skippedExerciseKeys, into: context)
                    }
                case .existing:
                    result.existingSessions += 1
                case .updated:
                    result.updatedSessions += 1
                    if !preview, let existing {
                        try replaceBlocks(of: existing, with: parsedSession, exerciseResolutions: exerciseResolutions, skippedExerciseKeys: skippedExerciseKeys, in: context)
                        existing.sourceDigest = sourceDigest
                        existing.importDigest = importDigest(forParsed: parsedSession, exerciseResolutions: exerciseResolutions, skippedExerciseKeys: skippedExerciseKeys)
                        existing.importSourceFile = sourceFileName
                        existing.importedAt = now
                    }
                case .conflicted:
                    result.conflictedSessions += 1
                }
            }

            result.possiblyWrongClient = workbook.sessions.count > 0 && otherClientMatches * 2 > workbook.sessions.count
        } catch {
            if !preview { context.rollback() }
            throw error
        }

        if !preview {
            try context.save()
        } else {
            // A preview must not leave any trace -- discard anything
            // SwiftData may have staged even though nothing above touched
            // `context.insert`/mutation on a real object (defensive: this
            // path currently performs no mutations at all, but rollback
            // here costs nothing and keeps that guarantee explicit rather
            // than implicit).
            context.rollback()
        }
        return result
    }

    // MARK: - Insert / replace helpers

    private static func insertSession(
        _ parsedSession: ParsedSession, client: Client, sourceFileName: String,
        sourceDigest: String, importedAt: Date,
        exerciseResolutions: [String: Exercise], skippedExerciseKeys: Set<String>,
        into context: ModelContext
    ) throws {
        let id = sessionID(client: client, sourceSheet: parsedSession.sourceSheet, weekNumber: parsedSession.weekNumber, dateRaw: parsedSession.dateRaw)
        let session = WorkoutSession(
            id: id, date: parsedSession.date, dateOrigin: parsedSession.dateOrigin, dateRaw: parsedSession.dateRaw,
            weekNumber: parsedSession.weekNumber, sourceSheet: parsedSession.sourceSheet, sourceRow: parsedSession.sourceRow,
            needsReview: parsedSession.needsReview, reviewReason: parsedSession.reviewReason,
            warmup: parsedSession.warmup, warmupNote: parsedSession.warmupNote,
            cooldown: parsedSession.cooldown, cooldownNote: parsedSession.cooldownNote
        )
        session.client = client
        session.importSourceFile = sourceFileName
        session.importedAt = importedAt
        session.sourceDigest = sourceDigest
        session.importDigest = importDigest(forParsed: parsedSession, exerciseResolutions: exerciseResolutions, skippedExerciseKeys: skippedExerciseKeys)
        context.insert(session)
        try buildBlocks(parsedSession.blocks, for: session, exerciseResolutions: exerciseResolutions, skippedExerciseKeys: skippedExerciseKeys, in: context)
    }

    private static func replaceBlocks(
        of session: WorkoutSession, with parsedSession: ParsedSession,
        exerciseResolutions: [String: Exercise], skippedExerciseKeys: Set<String>, in context: ModelContext
    ) throws {
        session.date = parsedSession.date
        session.dateOrigin = parsedSession.dateOrigin
        session.dateRaw = parsedSession.dateRaw
        session.weekNumber = parsedSession.weekNumber
        session.sourceSheet = parsedSession.sourceSheet
        session.sourceRow = parsedSession.sourceRow
        session.needsReview = parsedSession.needsReview
        session.reviewReason = parsedSession.reviewReason
        session.warmup = parsedSession.warmup
        session.warmupNote = parsedSession.warmupNote
        session.cooldown = parsedSession.cooldown
        session.cooldownNote = parsedSession.cooldownNote
        // Idempotent rebuild -- same approach as `SeedImporter`: delete the
        // old block subtree (cascade takes entries/sets with it; Exercise's
        // `.nullify` rule leaves the exercise library untouched), rebuild
        // fresh from the newly-parsed data.
        if let oldBlocks = session.blocks {
            for block in oldBlocks { context.delete(block) }
        }
        session.blocks = []
        try buildBlocks(parsedSession.blocks, for: session, exerciseResolutions: exerciseResolutions, skippedExerciseKeys: skippedExerciseKeys, in: context)
    }

    private static func buildBlocks(
        _ parsedBlocks: [ParsedSessionBlock], for session: WorkoutSession,
        exerciseResolutions: [String: Exercise], skippedExerciseKeys: Set<String>, in context: ModelContext
    ) throws {
        var order = 0
        for parsedBlock in parsedBlocks {
            let entries = parsedBlock.entries.filter { !skippedExerciseKeys.contains($0.exerciseKey) }
            guard !entries.isEmpty else { continue }

            let block = SessionBlock(
                order: order, blockType: parsedBlock.blockType, restSeconds: parsedBlock.restSeconds,
                restRaw: parsedBlock.restRaw, note: parsedBlock.note, sourceRow: parsedBlock.sourceRow
            )
            block.session = session
            context.insert(block)
            order += 1

            for (entryOrder, parsedEntry) in entries.enumerated() {
                let exercise = exerciseResolutions[parsedEntry.exerciseKey]
                let entry = ExerciseEntry(
                    order: entryOrder, exerciseIdRef: exercise?.id ?? parsedEntry.exerciseKey,
                    exerciseRaw: parsedEntry.exerciseRaw, plannedSets: parsedEntry.plannedSets, exercise: exercise
                )
                entry.block = block
                context.insert(entry)
                for parsedSet in parsedEntry.sets {
                    let setLog = SetLog(setIndex: parsedSet.setIndex, load: parsedSet.load, target: parsedSet.target, actual: parsedSet.actual, isInferred: parsedSet.isInferred)
                    setLog.entry = entry
                    context.insert(setLog)
                }
            }
        }
    }

    // MARK: - Digest bridging

    private static func importDigest(forParsed session: ParsedSession, exerciseResolutions: [String: Exercise], skippedExerciseKeys: Set<String>) -> String {
        let blocks: [ImportDigestBlock] = session.blocks.enumerated().compactMap { blockOrder, block in
            let entries = block.entries.filter { !skippedExerciseKeys.contains($0.exerciseKey) }
            guard !entries.isEmpty else { return nil }
            let digestEntries = entries.enumerated().map { entryOrder, entry -> ImportDigestEntry in
                let exerciseId = exerciseResolutions[entry.exerciseKey]?.id ?? entry.exerciseKey
                let sets = entry.sets.map { ImportDigestSet(setIndex: $0.setIndex, load: $0.load, target: $0.target, actual: $0.actual, isInferred: $0.isInferred) }
                return ImportDigestEntry(order: entryOrder, exerciseIdRef: exerciseId, exerciseRaw: entry.exerciseRaw, plannedSets: entry.plannedSets, sets: sets)
            }
            return ImportDigestBlock(order: blockOrder, blockType: block.blockType, restSeconds: block.restSeconds, restRaw: block.restRaw, note: block.note, entries: digestEntries)
        }
        return SessionDigest.importDigest(
            date: session.date, weekNumber: session.weekNumber, sourceSheet: session.sourceSheet,
            warmup: session.warmup, warmupNote: session.warmupNote, cooldown: session.cooldown, cooldownNote: session.cooldownNote,
            blocks: blocks
        )
    }

    private static func importDigest(forExisting session: WorkoutSession) -> String {
        let blocks: [ImportDigestBlock] = session.orderedBlocks.map { block in
            let digestEntries = block.orderedEntries.map { entry -> ImportDigestEntry in
                let sets = entry.orderedSets.map { ImportDigestSet(setIndex: $0.setIndex, load: $0.load, target: $0.target, actual: $0.actual, isInferred: $0.isInferred) }
                return ImportDigestEntry(order: entry.order, exerciseIdRef: entry.exerciseIdRef, exerciseRaw: entry.exerciseRaw, plannedSets: entry.plannedSets, sets: sets)
            }
            return ImportDigestBlock(order: block.order, blockType: block.blockType, restSeconds: block.restSeconds, restRaw: block.restRaw, note: block.note, entries: digestEntries)
        }
        return SessionDigest.importDigest(
            date: session.date, weekNumber: session.weekNumber, sourceSheet: session.sourceSheet,
            warmup: session.warmup, warmupNote: session.warmupNote, cooldown: session.cooldown, cooldownNote: session.cooldownNote,
            blocks: blocks
        )
    }

    // MARK: - Session id

    /// `"xs-" + sha256(client.id|sourceSheet|weekNumber|dateRaw).hex.prefix(12)`
    /// (CONTRACT-M7.md §3.8.5) -- derived purely from the natural key, so
    /// the same session computes the same id on every import, independent
    /// of whether the natural-key lookup itself has a bug. `@Attribute(.unique)`
    /// on `WorkoutSession.id` is the last line of defense if it doesn't.
    private static func sessionID(client: Client, sourceSheet: String, weekNumber: Int, dateRaw: String) -> String {
        let key = "\(client.id)|\(sourceSheet)|\(weekNumber)|\(dateRaw)"
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "xs-" + hex.prefix(12)
    }
}
