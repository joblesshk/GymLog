import Foundation
import SwiftData

/// Restores a `BackupFile` into a `ModelContext` -- the import half of
/// "完整备份与恢复" (2026-09-06 审查报告"适合当前范围的功能"第一批: "换机可恢复").
///
/// Restore is purely additive/upsert, never deletes: a coach restoring onto
/// a fresh install (the common "换机" case) has an empty store, so upsert
/// behaves like a plain import; a coach restoring onto a store that already
/// has OTHER local data (a partial/merge restore) must not have that other
/// data silently wiped just because it wasn't in the backup file. Every
/// entity that carries its own stable `@Attribute(.unique) id` (`Exercise`,
/// `Client`, `Assessment`, `BodyMetric`, `WorkoutSession`, `SessionTemplate`,
/// `TemplateBlock`, `TemplateExerciseSlot`) is upserted by that id --
/// existing fields are overwritten with the backup's values, matching
/// `SeedImporter`'s own upsert idiom. The three id-less nested types
/// (`SessionBlock`/`ExerciseEntry`/`SetLog`) have no independent identity in
/// the model layer, so each matched `WorkoutSession`'s subtree is deleted
/// and rebuilt whole from the backup, exactly as both existing importers
/// already do for the same reason.
///
/// 2026-09-07 审阅 B05/B06 (实验确认): two independent gaps fixed here.
///
/// B05 -- `parse` only checked ARRAY-LENGTH counts (`BackupCounts`), which
/// says nothing about the graph's actual integrity: two `Client` DTOs
/// sharing one `id` pass the count check trivially (the count is `2` either
/// way), and only surface as data loss later, silently, when SwiftData's
/// own `.unique` upsert coalesces them into one record at restore time.
/// `validateStructure` below checks global id uniqueness for every
/// `@Attribute(.unique)` entity type, plus per-parent order/setIndex
/// uniqueness and basic numeric sanity, and runs inside `parse` so preview
/// and restore can never observe a file that failed this check differently.
///
/// B06 -- restoring a session whose id already exists locally under a
/// DIFFERENT client silently overwrote that session's content while never
/// updating its `client` relationship (the existing-session branch of the
/// old `rebuildSession` never touched `.client` at all) -- the record ended
/// up attributed to the WRONG client with the BACKUP's content, the worst
/// of both. `Assessment`/`BodyMetric`/`TemplateBlock`/`TemplateExerciseSlot`
/// had the same class of bug one level down: their upsert lookups searched
/// only the CURRENT parent's own children (`client.assessments`,
/// `template.blocks`, `block.slots`), never a global fetch, so a globally
/// duplicate id belonging to a DIFFERENT parent was invisible to the
/// lookup and could be silently re-parented by SwiftData's own `.unique`-id
/// upsert semantics. Every one of these is now looked up globally first;
/// an ownership mismatch is skipped by default (own content untouched) and
/// counted, not silently overwritten -- `restore(reassignSessionOwnership:)`
/// lets the caller explicitly approve reassigning specific sessions after
/// reviewing `PreviewResult.ownershipConflicts`.
public enum BackupImporter {
    public enum ImportError: LocalizedError {
        case unsupportedSchemaVersion(Int)
        case corruptCounts(declared: BackupCounts, actual: BackupCounts)
        case invalidData(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedSchemaVersion(let version):
                return "This backup was made by a newer version of the app (format \(version)); this version doesn't know how to read it."
            case .corruptCounts(let declared, let actual):
                return "This backup file looks corrupted or truncated (declared \(declared), found \(actual))."
            case .invalidData(let detail):
                return "This backup file failed validation and was not imported: \(detail)"
            }
        }
    }

    public struct OwnershipConflict: Equatable {
        public var sessionID: String
        public var localClientID: String
        public var backupClientID: String
    }

    public struct PreviewResult {
        public var newClients = 0
        public var updatedClients = 0
        public var newExercises = 0
        public var updatedExercises = 0
        public var newSessions = 0
        public var updatedSessions = 0
        public var newTemplates = 0
        public var updatedTemplates = 0
        public var counts: BackupCounts
        /// Sessions whose id already exists locally under a DIFFERENT
        /// client than the backup declares (B06). None of these are
        /// restored unless their id is passed in
        /// `restore(reassignSessionOwnership:)`.
        public var ownershipConflicts: [OwnershipConflict] = []
    }

    public struct RestoreResult {
        public var clientsWritten = 0
        public var exercisesWritten = 0
        public var sessionsWritten = 0
        public var templatesWritten = 0
        /// Sessions skipped because of an unresolved ownership conflict
        /// (B06) -- surfaced so the caller/UI can tell "restored everything"
        /// from "restored everything EXCEPT N contested sessions".
        public var sessionsSkippedDueToOwnershipConflict = 0
        /// Assessments/BodyMetrics/TemplateBlocks/TemplateExerciseSlots
        /// skipped because their id already exists under a different parent
        /// than the backup declares. There is no explicit-reassignment path
        /// for these yet (unlike sessions) -- they are always skipped, never
        /// silently re-parented.
        public var otherEntitiesSkippedDueToOwnershipConflict = 0
    }

    /// Decodes and validates a backup file's bytes without touching
    /// `context` -- shared by `preview` and `restore` so a file that fails
    /// one fails the other identically.
    public static func parse(_ data: Data) throws -> BackupFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(BackupFile.self, from: data)
        // >= 1, not just "<= current": the old check let a nonsensical
        // schemaVersion of 0 or negative through unchallenged.
        guard (1...BackupFile.currentSchemaVersion).contains(file.schemaVersion) else {
            throw ImportError.unsupportedSchemaVersion(file.schemaVersion)
        }
        let actualCounts = BackupCounts.compute(exercises: file.exercises, clients: file.clients, templates: file.templates)
        guard actualCounts == file.counts else {
            throw ImportError.corruptCounts(declared: file.counts, actual: actualCounts)
        }
        let issues = validateStructure(file)
        guard issues.isEmpty else {
            throw ImportError.invalidData(issues.joined(separator: "; "))
        }
        return file
    }

    /// B05: structural validation beyond array-length counts -- global id
    /// uniqueness for every `@Attribute(.unique)` entity type this backup
    /// carries, plus per-parent order/index uniqueness and basic numeric
    /// sanity. Returns a human-readable issue per problem found (empty =
    /// valid); deliberately collects everything rather than stopping at the
    /// first issue, so one bad file reports its full extent at once.
    ///
    /// What this intentionally does NOT reject: an unresolved
    /// `exerciseIdRef`/`TemplateExerciseSlot.exerciseID` (a legitimately
    /// deleted/merged exercise from history, or an exercise this file's own
    /// `exercises` array doesn't happen to include because the coach's
    /// export predates it) -- `restore` already resolves these
    /// best-effort via `exercisesByID[...]`, leaving `entry.exercise = nil`
    /// while preserving `exerciseRaw`/`exerciseIdRef` verbatim, matching
    /// every other importer's "historical raw exercise reference, kept
    /// faithfully" convention. Flagging that as invalid would make a
    /// perfectly legitimate old backup un-restorable.
    static func validateStructure(_ file: BackupFile) -> [String] {
        var issues: [String] = []

        func checkUnique<T: Hashable>(_ ids: [T], label: String) {
            var seen = Set<T>()
            for id in ids where !seen.insert(id).inserted {
                issues.append("duplicate \(label) id: \(id)")
            }
        }

        checkUnique(file.exercises.map(\.id), label: "Exercise")
        checkUnique(file.clients.map(\.id), label: "Client")
        checkUnique(file.templates.map(\.id), label: "SessionTemplate")

        var assessmentIDs: [String] = []
        var bodyMetricIDs: [String] = []
        var sessionIDs: [String] = []

        for client in file.clients {
            assessmentIDs.append(contentsOf: client.assessments.map(\.id))
            bodyMetricIDs.append(contentsOf: client.bodyMetrics.map(\.id))
            sessionIDs.append(contentsOf: client.sessions.map(\.id))

            for session in client.sessions {
                var blockOrders = Set<Int>()
                for block in session.blocks {
                    if block.order < 0 || !blockOrders.insert(block.order).inserted {
                        issues.append("session \(session.id): invalid or duplicate block order \(block.order)")
                    }
                    var entryOrders = Set<Int>()
                    for entry in block.entries {
                        if entry.order < 0 || !entryOrders.insert(entry.order).inserted {
                            issues.append("session \(session.id) block order=\(block.order): invalid or duplicate entry order \(entry.order)")
                        }
                        if entry.plannedSets < 0 {
                            issues.append("session \(session.id) block order=\(block.order) entry order=\(entry.order): negative plannedSets")
                        }
                        var setIndices = Set<Int>()
                        for set in entry.sets {
                            if set.setIndex < 0 || !setIndices.insert(set.setIndex).inserted {
                                issues.append("session \(session.id) entry order=\(entry.order): invalid or duplicate setIndex \(set.setIndex)")
                            }
                            if let kg = AnalyticsMath.comparableKg(set.load), !kg.isFinite {
                                issues.append("session \(session.id) entry order=\(entry.order) set \(set.setIndex): non-finite load value")
                            }
                        }
                    }
                }
            }
        }
        checkUnique(assessmentIDs, label: "Assessment")
        checkUnique(bodyMetricIDs, label: "BodyMetric")
        checkUnique(sessionIDs, label: "WorkoutSession")

        var templateBlockIDs: [String] = []
        var templateSlotIDs: [String] = []
        for template in file.templates {
            for block in template.blocks {
                templateBlockIDs.append(block.id)
                if block.restSeconds < 0 {
                    issues.append("template \(template.id) block \(block.id): negative restSeconds")
                }
                for slot in block.slots {
                    templateSlotIDs.append(slot.id)
                    if slot.defaultSets < 0 {
                        issues.append("template \(template.id) block \(block.id) slot \(slot.id): negative defaultSets")
                    }
                }
            }
        }
        checkUnique(templateBlockIDs, label: "TemplateBlock")
        checkUnique(templateSlotIDs, label: "TemplateExerciseSlot")

        return issues
    }

    /// Dry run: reports how many of each entity would be newly added vs.
    /// updated, without writing anything -- what the restore confirmation
    /// screen shows before the coach commits. Also surfaces ownership
    /// conflicts (B06) so the UI can ask the coach about each one instead
    /// of restore silently picking a side.
    public static func preview(_ file: BackupFile, in context: ModelContext) throws -> PreviewResult {
        let existingClientIDs = Set(try context.fetch(FetchDescriptor<Client>()).map(\.id))
        let existingExerciseIDs = Set(try context.fetch(FetchDescriptor<Exercise>()).map(\.id))
        let existingSessions = try context.fetch(FetchDescriptor<WorkoutSession>())
        let existingSessionOwnerByID: [String: String?] = Dictionary(uniqueKeysWithValues: existingSessions.map { ($0.id, $0.client?.id) })
        let existingTemplateIDs = Set(try context.fetch(FetchDescriptor<SessionTemplate>()).map(\.id))

        var result = PreviewResult(counts: file.counts)
        for exercise in file.exercises {
            if existingExerciseIDs.contains(exercise.id) { result.updatedExercises += 1 } else { result.newExercises += 1 }
        }
        for client in file.clients {
            if existingClientIDs.contains(client.id) { result.updatedClients += 1 } else { result.newClients += 1 }
            for session in client.sessions {
                if let existingOwner = existingSessionOwnerByID[session.id] {
                    if let existingOwner, existingOwner != client.id {
                        result.ownershipConflicts.append(OwnershipConflict(sessionID: session.id, localClientID: existingOwner, backupClientID: client.id))
                    }
                    result.updatedSessions += 1
                } else {
                    result.newSessions += 1
                }
            }
        }
        for template in file.templates {
            if existingTemplateIDs.contains(template.id) { result.updatedTemplates += 1 } else { result.newTemplates += 1 }
        }
        return result
    }

    /// Restores the whole file into `context`. Exercises are written first
    /// so `ExerciseEntry.exercise`/`TemplateExerciseSlot` can resolve
    /// against them, mirroring `SeedImporter`'s own ordering rule. Wrapped
    /// in a single rollback-on-error transaction, one `save()` at the end,
    /// same shape as `SeedImporter.importSeed`.
    ///
    /// - Parameter reassignSessionOwnership: session ids the caller has
    ///   explicitly confirmed should be reassigned to the backup's client
    ///   despite a local ownership conflict (from `preview`'s
    ///   `ownershipConflicts`). Any conflicting session NOT in this set is
    ///   skipped entirely -- neither its content nor its ownership changes.
    @discardableResult
    public static func restore(_ file: BackupFile, into context: ModelContext, reassignSessionOwnership: Set<String> = []) throws -> RestoreResult {
        let wasAutosaveEnabled = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = wasAutosaveEnabled }

        do {
            var exercisesByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Exercise>()).map { ($0.id, $0) })
            var clientsByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Client>()).map { ($0.id, $0) })
            var sessionsByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<WorkoutSession>()).map { ($0.id, $0) })
            var templatesByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<SessionTemplate>()).map { ($0.id, $0) })
            // B06: these three used to be looked up LOCALLY (within the
            // current client/template/block's own children only) -- a
            // global fetch is the only way to notice "this id already
            // exists, just under someone else" instead of blindly inserting
            // a second object SwiftData's own `.unique` constraint would
            // then silently coalesce/re-parent.
            var assessmentsByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Assessment>()).map { ($0.id, $0) })
            var bodyMetricsByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<BodyMetric>()).map { ($0.id, $0) })
            var templateBlocksByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<TemplateBlock>()).map { ($0.id, $0) })
            var templateSlotsByID = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<TemplateExerciseSlot>()).map { ($0.id, $0) })

            var result = RestoreResult()

            for dto in file.exercises {
                upsertExercise(dto, existing: &exercisesByID, in: context)
                result.exercisesWritten += 1
            }
            for clientDTO in file.clients {
                let client = upsertClient(clientDTO, existing: &clientsByID, in: context)
                result.clientsWritten += 1
                for assessmentDTO in clientDTO.assessments {
                    if !upsertAssessment(assessmentDTO, client: client, existing: &assessmentsByID, in: context) {
                        result.otherEntitiesSkippedDueToOwnershipConflict += 1
                    }
                }
                for bodyMetricDTO in clientDTO.bodyMetrics {
                    if !upsertBodyMetric(bodyMetricDTO, client: client, existing: &bodyMetricsByID, in: context) {
                        result.otherEntitiesSkippedDueToOwnershipConflict += 1
                    }
                }
                for sessionDTO in clientDTO.sessions {
                    let applied = try rebuildSession(
                        sessionDTO, client: client, existing: &sessionsByID, exercisesByID: exercisesByID,
                        reassignOwnership: reassignSessionOwnership, in: context
                    )
                    if applied {
                        result.sessionsWritten += 1
                    } else {
                        result.sessionsSkippedDueToOwnershipConflict += 1
                    }
                }
            }
            for templateDTO in file.templates {
                upsertTemplate(
                    templateDTO, existing: &templatesByID, blocksByID: &templateBlocksByID, slotsByID: &templateSlotsByID,
                    otherConflictsSkipped: &result.otherEntitiesSkippedDueToOwnershipConflict, in: context
                )
                result.templatesWritten += 1
            }

            try context.save()
            return result
        } catch {
            context.rollback()
            throw error
        }
    }

    // MARK: - Upsert helpers (entities with their own stable id)

    private static func upsertExercise(_ dto: ExerciseBackupDTO, existing: inout [String: Exercise], in context: ModelContext) {
        let exercise: Exercise
        if let found = existing[dto.id] {
            exercise = found
        } else {
            exercise = Exercise(
                id: dto.id, canonicalName: dto.canonicalName, aliases: dto.aliases, movementPattern: dto.movementPattern,
                equipment: dto.equipment, loadDirection: dto.loadDirection, isUnilateral: dto.isUnilateral,
                occurrenceCount: dto.occurrenceCount, needsReview: dto.needsReview, reviewReason: dto.reviewReason,
                recordingMetric: dto.recordingMetric, discipline: dto.discipline ?? .strength,
                nameZh: dto.nameZh, notes: dto.notes
            )
            context.insert(exercise)
            existing[dto.id] = exercise
        }
        exercise.canonicalName = dto.canonicalName
        exercise.aliases = dto.aliases
        exercise.movementPattern = dto.movementPattern
        exercise.equipment = dto.equipment
        exercise.loadDirection = dto.loadDirection
        exercise.isUnilateral = dto.isUnilateral
        exercise.occurrenceCount = dto.occurrenceCount
        exercise.needsReview = dto.needsReview
        exercise.reviewReason = dto.reviewReason
        exercise.recordingMetric = dto.recordingMetric
        exercise.discipline = dto.discipline ?? .strength
        exercise.nameZh = dto.nameZh
        exercise.notes = dto.notes
    }

    private static func upsertClient(_ dto: ClientBackupDTO, existing: inout [String: Client], in context: ModelContext) -> Client {
        let client: Client
        if let found = existing[dto.id] {
            client = found
        } else {
            client = Client(id: dto.id, name: dto.name)
            context.insert(client)
            existing[dto.id] = client
        }
        client.name = dto.name
        client.phone = dto.phone
        client.gender = dto.gender
        client.age = dto.age
        client.heightCm = dto.heightCm
        client.startWeightKg = dto.startWeightKg
        client.goal = dto.goal
        client.frequency = dto.frequency
        client.bmr = dto.bmr
        client.tdee = dto.tdee
        client.habits = dto.habits
        client.medicalHistory = dto.medicalHistory
        return client
    }

    /// Returns `false` (skips, touches nothing) when `dto.id` already
    /// exists globally under a different client (B06) -- no explicit
    /// reassignment path for this entity type yet, so a conflict is always
    /// left alone rather than guessed at.
    @discardableResult
    private static func upsertAssessment(_ dto: AssessmentBackupDTO, client: Client, existing: inout [String: Assessment], in context: ModelContext) -> Bool {
        if let found = existing[dto.id] {
            guard found.client?.id == client.id else { return false }
            found.pattern = dto.pattern
            found.date = dto.date
            found.level = dto.level
            found.notes = dto.notes
        } else {
            let assessment = Assessment(id: dto.id, pattern: dto.pattern, date: dto.date, level: dto.level, notes: dto.notes)
            assessment.client = client
            context.insert(assessment)
            existing[dto.id] = assessment
        }
        return true
    }

    @discardableResult
    private static func upsertBodyMetric(_ dto: BodyMetricBackupDTO, client: Client, existing: inout [String: BodyMetric], in context: ModelContext) -> Bool {
        if let found = existing[dto.id] {
            guard found.client?.id == client.id else { return false }
            found.date = dto.date
            found.weightKg = dto.weightKg
            found.bodyFatPercent = dto.bodyFatPercent
            found.skeletalMuscleKg = dto.skeletalMuscleKg
            found.bmi = dto.bmi
            found.visceralFatLevel = dto.visceralFatLevel
            found.bmr = dto.bmr
            found.tdee = dto.tdee
            found.bodyFatMassKg = dto.bodyFatMassKg
            found.notes = dto.notes
        } else {
            let metric = BodyMetric(
                id: dto.id, date: dto.date, weightKg: dto.weightKg, bodyFatPercent: dto.bodyFatPercent,
                skeletalMuscleKg: dto.skeletalMuscleKg, bmi: dto.bmi, visceralFatLevel: dto.visceralFatLevel,
                bmr: dto.bmr, tdee: dto.tdee, bodyFatMassKg: dto.bodyFatMassKg, notes: dto.notes
            )
            metric.client = client
            context.insert(metric)
            existing[dto.id] = metric
        }
        return true
    }

    /// Upserts the session's own scalar fields by id, then deletes and
    /// rebuilds its blocks/entries/sets subtree whole from the backup (see
    /// the type's doc comment for why: those three have no independent id).
    ///
    /// Returns `false` (skips entirely -- no field, no subtree, no
    /// ownership change) when the session already exists under a different
    /// client and its id isn't in `reassignOwnership` (B06).
    private static func rebuildSession(
        _ dto: WorkoutSessionBackupDTO, client: Client, existing: inout [String: WorkoutSession],
        exercisesByID: [String: Exercise], reassignOwnership: Set<String>, in context: ModelContext
    ) throws -> Bool {
        let session: WorkoutSession
        if let found = existing[dto.id] {
            if let currentOwner = found.client, currentOwner.id != client.id {
                guard reassignOwnership.contains(dto.id) else { return false }
                found.client = client
            }
            session = found
        } else {
            session = WorkoutSession(
                id: dto.id, date: dto.date, dateOrigin: dto.dateOrigin, dateRaw: dto.dateRaw, weekNumber: dto.weekNumber,
                sourceSheet: dto.sourceSheet, sourceRow: dto.sourceRow, needsReview: dto.needsReview, reviewReason: dto.reviewReason,
                warmup: dto.warmup, warmupNote: dto.warmupNote, cooldown: dto.cooldown, cooldownNote: dto.cooldownNote,
                plannedDurationMinutes: dto.plannedDurationMinutes,
                isInProgress: dto.isInProgress ?? false
            )
            session.client = client
            context.insert(session)
            existing[dto.id] = session
        }
        session.date = dto.date
        session.dateOrigin = dto.dateOrigin
        session.dateRaw = dto.dateRaw
        session.weekNumber = dto.weekNumber
        session.sourceSheet = dto.sourceSheet
        session.sourceRow = dto.sourceRow
        session.warmup = dto.warmup
        session.warmupNote = dto.warmupNote
        session.cooldown = dto.cooldown
        session.cooldownNote = dto.cooldownNote
        session.needsReview = dto.needsReview
        session.reviewReason = dto.reviewReason
        session.insightJSON = dto.insightJSON
        session.plannedDurationMinutes = dto.plannedDurationMinutes
        session.isInProgress = dto.isInProgress ?? false
        session.importSourceFile = dto.importSourceFile
        session.importedAt = dto.importedAt
        session.sourceDigest = dto.sourceDigest
        session.importDigest = dto.importDigest

        for block in session.blocks ?? [] {
            context.delete(block)
        }
        session.blocks = []
        for blockDTO in dto.blocks {
            let block = SessionBlock(
                order: blockDTO.order, blockType: blockDTO.blockType, restSeconds: blockDTO.restSeconds, restRaw: blockDTO.restRaw,
                note: blockDTO.note, sourceRow: blockDTO.sourceRow, sectionKind: blockDTO.sectionKind ?? .strength
            )
            // Raw passthrough, not the typed setter -- see
            // `SessionBlockBackupDTO.wodPayloadRawJSON`'s doc comment for
            // why an unsupported-future payload must round-trip verbatim.
            block.setWODPayloadRawJSON(blockDTO.wodPayloadRawJSON)
            block.session = session
            context.insert(block)
            for entryDTO in blockDTO.entries {
                let exercise = exercisesByID[entryDTO.exerciseIdRef]
                let entry = ExerciseEntry(order: entryDTO.order, exerciseIdRef: entryDTO.exerciseIdRef, exerciseRaw: entryDTO.exerciseRaw, plannedSets: entryDTO.plannedSets, exercise: exercise)
                entry.block = block
                context.insert(entry)
                for setDTO in entryDTO.sets {
                    let setLog = SetLog(setIndex: setDTO.setIndex, load: setDTO.load, target: setDTO.target, actual: setDTO.actual, isInferred: setDTO.isInferred)
                    setLog.entry = entry
                    context.insert(setLog)
                }
            }
        }
        return true
    }

    /// `blocksByID`/`slotsByID` are GLOBAL maps (see `restore`'s comment on
    /// why) -- a block/slot whose id already exists under a DIFFERENT
    /// parent template/block is skipped (counted via `otherConflictsSkipped`)
    /// rather than silently re-parented.
    private static func upsertTemplate(
        _ dto: SessionTemplateBackupDTO, existing: inout [String: SessionTemplate],
        blocksByID: inout [String: TemplateBlock], slotsByID: inout [String: TemplateExerciseSlot],
        otherConflictsSkipped: inout Int, in context: ModelContext
    ) {
        let template: SessionTemplate
        if let found = existing[dto.id] {
            template = found
        } else {
            template = SessionTemplate(id: dto.id, name: dto.name, templateNote: dto.templateNote, order: dto.order)
            context.insert(template)
            existing[dto.id] = template
        }
        template.name = dto.name
        template.templateNote = dto.templateNote
        template.order = dto.order

        for blockDTO in dto.blocks {
            let block: TemplateBlock
            if let foundBlock = blocksByID[blockDTO.id] {
                guard foundBlock.template?.id == template.id else {
                    otherConflictsSkipped += 1
                    continue
                }
                block = foundBlock
            } else {
                block = TemplateBlock(id: blockDTO.id, order: blockDTO.order, blockType: blockDTO.blockType, restSeconds: blockDTO.restSeconds)
                block.template = template
                context.insert(block)
                blocksByID[blockDTO.id] = block
            }
            block.order = blockDTO.order
            block.blockType = blockDTO.blockType
            block.restSeconds = blockDTO.restSeconds
            block.sectionKind = blockDTO.sectionKind ?? .strength
            block.setWODPrescriptionRawJSON(blockDTO.wodPrescriptionRawJSON)

            for slotDTO in blockDTO.slots {
                if let foundSlot = slotsByID[slotDTO.id] {
                    guard foundSlot.block?.id == block.id else {
                        otherConflictsSkipped += 1
                        continue
                    }
                    foundSlot.order = slotDTO.order
                    foundSlot.exerciseID = slotDTO.exerciseID
                    foundSlot.defaultSets = slotDTO.defaultSets
                    foundSlot.defaultRepTarget = slotDTO.defaultRepTarget
                } else {
                    let slot = TemplateExerciseSlot(id: slotDTO.id, order: slotDTO.order, exerciseID: slotDTO.exerciseID, defaultSets: slotDTO.defaultSets, defaultRepTarget: slotDTO.defaultRepTarget)
                    slot.block = block
                    context.insert(slot)
                    slotsByID[slotDTO.id] = slot
                }
            }
        }
    }
}
