import Foundation
import SwiftData

/// CONTRACT.md §11 import layer.
///
/// Contract requirements and how each is met:
///   1. Idempotent (upsert by id) -- entities with a contract-defined `id`
///      (Exercise, Client, WorkoutSession) are fetched by id and updated in
///      place rather than re-inserted. Entities with NO independent id in
///      the contract (SessionBlock, ExerciseEntry, SetLog are nested/owned
///      data, not separately addressable) are handled by deleting the
///      existing block subtree for a re-imported session and rebuilding it
///      fresh from the JSON -- since the JSON fully determines the subtree,
///      this produces byte-identical results on every re-run, which is
///      exactly what idempotency requires, without needing an artificial
///      composite key scheme the contract never defined.
///   2. Atomic -- all writes happen on a `ModelContext` with autosave
///      disabled; `context.save()` is only called once, at the very end,
///      after the self-check in step 3 passes. Any failure along the way
///      (decode error before touching the context at all, or a stats
///      mismatch after building the object graph) triggers
///      `context.rollback()` before the error propagates, so the persistent
///      store never observes a partial import.
///   3. Self-check -- computed counts (from the parsed DTO tree actually
///      written) are compared against the `stats` block of THIS import's
///      JSON. Any mismatch is a hard failure (rolled back), not a warning.
///   4. Unknown enum fallback -- handled entirely at the `Decodable` layer
///      (see ClassificationEnums.swift / LoadValue.swift / RepTarget.swift);
///      decoding never throws for an unrecognized string, it degrades and
///      logs via `ImportLog`.
///   5. `raw` fields -- DTOs carry every `*Raw`/`raw` field through
///      unconditionally into the model; there is no code path that drops
///      them.
public enum SeedImporter {

    public struct ImportResult {
        public var clientCount: Int
        public var sessionCount: Int
        public var exerciseCount: Int
        public var entryCount: Int
        public var setLogCount: Int
        /// CONTRACT.md §2.1 (v2): count of exercises with `needsReview == true`.
        /// Self-checked against `stats.exercisesNeedingReviewCount`.
        public var exercisesNeedingReviewCount: Int
        /// Self-checked against `stats.sessionsNeedingReviewCount`.
        public var sessionsNeedingReviewCount: Int
        /// Pass-through only: `stats.needsReviewCount` is an "audit layer"
        /// count (affected source cells in migration_audit.csv) that the App
        /// cannot independently derive from the decoded JSON tree, so it is
        /// never compared against a computed value -- see StatsDTO. Exposed
        /// here purely for display/debugging.
        public var auditNeedsReviewCount: Int
        public var warnings: [String]
        public var unresolvedExerciseRefs: Int
    }

    public enum ImportError: LocalizedError {
        case decodeFailed(String)
        case statsMismatch(detail: String)

        public var errorDescription: String? {
            switch self {
            case .decodeFailed(let reason):
                return "Seed JSON failed to decode: \(reason)"
            case .statsMismatch(let detail):
                return "Post-import self-check failed, import rolled back: \(detail)"
            }
        }
    }

    /// Imports a seed file's contents into `context`. Throws and leaves the
    /// store untouched (rolled back) on any decode or self-check failure.
    ///
    /// Deliberately NOT `@MainActor`: `ModelContext` itself carries no actor
    /// requirement (only `ModelContainer.mainContext`'s convenience accessor
    /// does), and forcing this function onto the main actor bought nothing
    /// for the app -- SwiftUI already calls it from the main thread via
    /// `@Environment(\.modelContext)` -- while costing tests an implicit
    /// actor hop that reliably deadlocked under XCTest's test-runner thread
    /// (see VERIFICATION.md). Callers remain responsible for using `context`
    /// only from the thread/queue it was created on, same as any ModelContext.
    public static func importSeed(data: Data, into context: ModelContext) throws -> ImportResult {
        // --- Step 0: pure decode, no context writes yet. A throw here means
        // literally nothing has been touched -- trivially atomic.
        let seed: SeedFile
        do {
            seed = try JSONDecoder().decode(SeedFile.self, from: data)
        } catch {
            throw ImportError.decodeFailed(String(describing: error))
        }

        // exercises before clients, per CONTRACT.md §2.
        let wasAutosaveEnabled = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = wasAutosaveEnabled }

        var warnings: [String] = []
        var unresolvedExerciseRefs = 0

        do {
            // ---- Exercises (upsert by id) ----
            let existingExercises = try context.fetch(FetchDescriptor<Exercise>())
            var exerciseById: [String: Exercise] = Dictionary(
                uniqueKeysWithValues: existingExercises.map { ($0.id, $0) }
            )

            for dto in seed.exercises {
                if let existing = exerciseById[dto.id] {
                    existing.canonicalName = dto.canonicalName
                    existing.aliases = dto.aliases
                    existing.movementPattern = dto.movementPattern
                    existing.equipment = dto.equipment
                    existing.loadDirection = dto.loadDirection
                    existing.isUnilateral = dto.isUnilateral
                    existing.occurrenceCount = dto.occurrenceCount
                    existing.needsReview = dto.needsReview
                    existing.reviewReason = dto.reviewReason
                    existing.recordingMetric = dto.recordingMetric
                    existing.discipline = dto.discipline ?? .strength
                    existing.nameZh = dto.nameZh ?? ""
                    existing.notes = dto.notes ?? ""
                } else {
                    let ex = Exercise(
                        id: dto.id,
                        canonicalName: dto.canonicalName,
                        aliases: dto.aliases,
                        movementPattern: dto.movementPattern,
                        equipment: dto.equipment,
                        loadDirection: dto.loadDirection,
                        isUnilateral: dto.isUnilateral,
                        occurrenceCount: dto.occurrenceCount,
                        needsReview: dto.needsReview,
                        reviewReason: dto.reviewReason,
                        recordingMetric: dto.recordingMetric,
                        discipline: dto.discipline ?? .strength,
                        nameZh: dto.nameZh ?? "",
                        notes: dto.notes ?? ""
                    )
                    context.insert(ex)
                    exerciseById[dto.id] = ex
                }
            }

            // ---- Clients (upsert by id) ----
            let existingClients = try context.fetch(FetchDescriptor<Client>())
            var clientById: [String: Client] = Dictionary(
                uniqueKeysWithValues: existingClients.map { ($0.id, $0) }
            )

            let existingSessions = try context.fetch(FetchDescriptor<WorkoutSession>())
            var sessionById: [String: WorkoutSession] = Dictionary(
                uniqueKeysWithValues: existingSessions.map { ($0.id, $0) }
            )

            for clientDTO in seed.clients {
                let client: Client
                if let existing = clientById[clientDTO.id] {
                    client = existing
                    client.name = clientDTO.name
                    client.phone = clientDTO.phone
                    client.gender = clientDTO.gender
                    client.age = clientDTO.age
                    client.heightCm = clientDTO.heightCm
                    client.startWeightKg = clientDTO.startWeightKg
                    client.goal = clientDTO.goal
                    client.frequency = clientDTO.frequency
                    client.bmr = clientDTO.bmr
                    client.tdee = clientDTO.tdee
                    client.habits = clientDTO.habits
                    client.medicalHistory = clientDTO.medicalHistory
                } else {
                    client = Client(
                        id: clientDTO.id,
                        name: clientDTO.name,
                        phone: clientDTO.phone,
                        gender: clientDTO.gender,
                        age: clientDTO.age,
                        heightCm: clientDTO.heightCm,
                        startWeightKg: clientDTO.startWeightKg,
                        goal: clientDTO.goal,
                        frequency: clientDTO.frequency,
                        bmr: clientDTO.bmr,
                        tdee: clientDTO.tdee,
                        habits: clientDTO.habits,
                        medicalHistory: clientDTO.medicalHistory
                    )
                    context.insert(client)
                    clientById[clientDTO.id] = client
                }

                // Assessments / BodyMetrics: replace-in-place. Always empty
                // in this migration's real data; handled defensively.
                if let oldAssessments = client.assessments {
                    for a in oldAssessments { context.delete(a) }
                }
                client.assessments = []
                for aDTO in clientDTO.assessments {
                    guard let dateStr = aDTO.date, let date = SeedDateParser.parseDay(dateStr) else { continue }
                    let pattern = MovementPattern(rawValue: aDTO.pattern ?? "") ?? .unknown
                    let assessment = Assessment(
                        id: aDTO.id ?? UUID().uuidString,
                        pattern: pattern,
                        date: date,
                        level: aDTO.level,
                        notes: aDTO.notes
                    )
                    assessment.client = client
                    context.insert(assessment)
                }

                if let oldMetrics = client.bodyMetrics {
                    for m in oldMetrics { context.delete(m) }
                }
                client.bodyMetrics = []
                for mDTO in clientDTO.bodyMetrics {
                    guard let dateStr = mDTO.date, let date = SeedDateParser.parseDay(dateStr) else { continue }
                    let metric = BodyMetric(
                        id: mDTO.id ?? UUID().uuidString,
                        date: date,
                        weightKg: mDTO.weightKg,
                        bodyFatPercent: mDTO.bodyFatPercent,
                        skeletalMuscleKg: mDTO.skeletalMuscleKg,
                        bmi: mDTO.bmi,
                        visceralFatLevel: mDTO.visceralFatLevel,
                        bmr: mDTO.bmr,
                        tdee: mDTO.tdee,
                        notes: mDTO.notes
                    )
                    metric.client = client
                    context.insert(metric)
                }

                // ---- Sessions (upsert by id) ----
                for sessionDTO in clientDTO.sessions {
                    guard let date = SeedDateParser.parseDay(sessionDTO.date) else {
                        warnings.append("Session \(sessionDTO.id): unparseable date \"\(sessionDTO.date)\", skipped.")
                        continue
                    }

                    let session: WorkoutSession
                    if let existing = sessionById[sessionDTO.id] {
                        session = existing
                        session.date = date
                        session.dateOrigin = sessionDTO.dateOrigin
                        session.dateRaw = sessionDTO.dateRaw
                        session.weekNumber = sessionDTO.weekNumber
                        session.sourceSheet = sessionDTO.sourceSheet
                        session.sourceRow = sessionDTO.sourceRow
                        session.needsReview = sessionDTO.needsReview
                        session.reviewReason = sessionDTO.reviewReason
                        session.warmup = sessionDTO.warmup
                        session.warmupNote = sessionDTO.warmupNote
                        session.cooldown = sessionDTO.cooldown
                        session.cooldownNote = sessionDTO.cooldownNote
                        // Idempotent rebuild: drop the old block subtree,
                        // rebuild fresh below. Cascade delete rule takes
                        // entries/sets with it; Exercise (nullify) is untouched.
                        if let oldBlocks = session.blocks {
                            for b in oldBlocks { context.delete(b) }
                        }
                        session.blocks = []
                    } else {
                        session = WorkoutSession(
                            id: sessionDTO.id,
                            date: date,
                            dateOrigin: sessionDTO.dateOrigin,
                            dateRaw: sessionDTO.dateRaw,
                            weekNumber: sessionDTO.weekNumber,
                            sourceSheet: sessionDTO.sourceSheet,
                            sourceRow: sessionDTO.sourceRow,
                            needsReview: sessionDTO.needsReview,
                            reviewReason: sessionDTO.reviewReason,
                            warmup: sessionDTO.warmup,
                            warmupNote: sessionDTO.warmupNote,
                            cooldown: sessionDTO.cooldown,
                            cooldownNote: sessionDTO.cooldownNote
                        )
                        context.insert(session)
                        sessionById[sessionDTO.id] = session
                    }
                    session.client = client

                    for blockDTO in sessionDTO.blocks {
                        let block = SessionBlock(
                            order: blockDTO.order,
                            blockType: blockDTO.blockType,
                            restSeconds: blockDTO.restSeconds,
                            restRaw: blockDTO.restRaw,
                            note: blockDTO.note,
                            sourceRow: blockDTO.sourceRow
                        )
                        block.session = session
                        context.insert(block)

                        for entryDTO in blockDTO.entries {
                            let resolvedExercise = exerciseById[entryDTO.exerciseId]
                            if resolvedExercise == nil {
                                unresolvedExerciseRefs += 1
                                warnings.append(
                                    "Entry order=\(entryDTO.order) in session \(sessionDTO.id): " +
                                    "exerciseId \"\(entryDTO.exerciseId)\" not found in exercise library."
                                )
                            }
                            let entry = ExerciseEntry(
                                order: entryDTO.order,
                                exerciseIdRef: entryDTO.exerciseId,
                                exerciseRaw: entryDTO.exerciseRaw,
                                plannedSets: entryDTO.plannedSets,
                                exercise: resolvedExercise
                            )
                            entry.block = block
                            context.insert(entry)

                            for setDTO in entryDTO.sets {
                                let setLog = SetLog(
                                    setIndex: setDTO.setIndex,
                                    load: setDTO.load,
                                    target: setDTO.target,
                                    actual: setDTO.actual,
                                    isInferred: setDTO.isInferred
                                )
                                setLog.entry = entry
                                context.insert(setLog)
                            }
                        }
                    }
                }
            }
        } catch {
            context.rollback()
            throw error
        }

        // ---- Self-check against this file's `stats` block ----
        let actualClientCount = seed.clients.count
        let actualSessionCount = seed.clients.reduce(0) { $0 + $1.sessions.count }
        let actualExerciseCount = seed.exercises.count
        let actualEntryCount = seed.clients.reduce(0) { total, c in
            total + c.sessions.reduce(0) { $0 + $1.blocks.reduce(0) { $0 + $1.entries.count } }
        }
        let actualSetLogCount = seed.clients.reduce(0) { total, c in
            total + c.sessions.reduce(0) { total, s in
                total + s.blocks.reduce(0) { total, b in
                    total + b.entries.reduce(0) { $0 + $1.sets.count }
                }
            }
        }
        // CONTRACT.md §2.1 (v2): only these two review counts are
        // independently derivable from the decoded JSON tree, so only these
        // two participate in the self-check. `stats.needsReviewCount` (the
        // audit-layer count) is NOT re-derived or checked here -- there is
        // no field on Exercise/Session/Block/Entry/SetLog that sums to it;
        // it's a pass-through count from migration_audit.csv, a file this
        // importer never reads. Checking it against a guessed formula would
        // be exactly the kind of silent, unverifiable assumption CONTRACT.md
        // §2.1 was written to rule out.
        let actualExercisesNeedingReviewCount = seed.exercises.filter { $0.needsReview }.count
        let actualSessionsNeedingReviewCount = seed.clients.reduce(0) { total, c in
            total + c.sessions.filter { $0.needsReview }.count
        }

        var mismatches: [String] = []
        if actualClientCount != seed.stats.clientCount {
            mismatches.append("clientCount expected \(seed.stats.clientCount), got \(actualClientCount)")
        }
        if actualSessionCount != seed.stats.sessionCount {
            mismatches.append("sessionCount expected \(seed.stats.sessionCount), got \(actualSessionCount)")
        }
        if actualExerciseCount != seed.stats.exerciseCount {
            mismatches.append("exerciseCount expected \(seed.stats.exerciseCount), got \(actualExerciseCount)")
        }
        if actualEntryCount != seed.stats.entryCount {
            mismatches.append("entryCount expected \(seed.stats.entryCount), got \(actualEntryCount)")
        }
        if actualSetLogCount != seed.stats.setLogCount {
            mismatches.append("setLogCount expected \(seed.stats.setLogCount), got \(actualSetLogCount)")
        }
        if actualExercisesNeedingReviewCount != seed.stats.exercisesNeedingReviewCount {
            mismatches.append("exercisesNeedingReviewCount expected \(seed.stats.exercisesNeedingReviewCount), got \(actualExercisesNeedingReviewCount)")
        }
        if actualSessionsNeedingReviewCount != seed.stats.sessionsNeedingReviewCount {
            mismatches.append("sessionsNeedingReviewCount expected \(seed.stats.sessionsNeedingReviewCount), got \(actualSessionsNeedingReviewCount)")
        }

        if !mismatches.isEmpty {
            context.rollback()
            throw ImportError.statsMismatch(detail: mismatches.joined(separator: "; "))
        }

        try context.save()

        warnings.append(contentsOf: ImportLog.drainMessages())

        return ImportResult(
            clientCount: actualClientCount,
            sessionCount: actualSessionCount,
            exerciseCount: actualExerciseCount,
            entryCount: actualEntryCount,
            setLogCount: actualSetLogCount,
            exercisesNeedingReviewCount: actualExercisesNeedingReviewCount,
            sessionsNeedingReviewCount: actualSessionsNeedingReviewCount,
            auditNeedsReviewCount: seed.stats.needsReviewCount,
            warnings: warnings,
            unresolvedExerciseRefs: unresolvedExerciseRefs
        )
    }

    public static func importSeed(from url: URL, into context: ModelContext) throws -> ImportResult {
        let data = try Data(contentsOf: url)
        return try importSeed(data: data, into: context)
    }

    // MARK: - Exercise reference redirection (2026-09-07 审阅 B04)

    /// Redirects every reference to `source` onto `target` -- call this
    /// BEFORE `context.delete(source)` in any merge that deletes the source
    /// exercise. Every merge below used to redirect only
    /// `ExerciseEntry.exercise`/`exerciseIdRef` (a real relationship plus
    /// its mirrored string id); `TemplateExerciseSlot.exerciseID` is a plain
    /// `String` with NO relationship to `Exercise` at all (see that type's
    /// doc comment), so SwiftData's own delete/nullify rules can never fix
    /// it up on their own -- it has to be redirected explicitly, the same
    /// way `exerciseIdRef` is.
    ///
    /// (实验确认: a coach's custom exercise, referenced by a template slot,
    /// merged away by `applyExerciseLibraryAdditions20260904` -- the slot
    /// kept pointing at the now-deleted id, and `TemplateSessionBuilder`
    /// silently dropped that slot on every future "从模板新建".)
    ///
    /// Does not touch in-memory `EntryDraft`/on-disk `TodayDraftSnapshot`
    /// references -- those already degrade safely (an unresolved
    /// `exerciseID` is dropped with an explicit coach-facing count, not
    /// silently) via `EntryDraft.restore`/`TemplateSessionBuilder`'s own
    /// unresolved-reference handling; this only closes the gap for
    /// references SwiftData itself owns.
    /// Thin wrapper kept for this file's many existing call sites --
    /// `ExerciseReferenceRedirectionService.redirect(from:to:in:)` is the
    /// actual implementation, now shared with `ExerciseLibraryView`'s merge
    /// UI (which had its own smaller, divergent copy that never redirected
    /// `TemplateExerciseSlot`, let alone WOD payloads) and additionally
    /// covers `SessionBlock.wodPayload`/`TemplateBlock.wodPrescription`
    /// (2026-09-07 M1's documented gap, `CONTRACT-M10.md` §5/§10).
    @discardableResult
    static func redirectExerciseReferences(from source: Exercise, to target: Exercise, in context: ModelContext) throws -> ExerciseReferenceRedirectionService.Summary {
        try ExerciseReferenceRedirectionService.redirect(from: source, to: target, in: context).summary
    }

    // MARK: - Post-import curator corrections (2026-08, not part of the frozen migration output)

    /// A small, explicitly-curated set of corrections the coach asked for
    /// that intentionally diverge from `gymlog_seed.json`'s classifier-
    /// derived output. These are deliberately NOT baked into the seed JSON
    /// itself: every field in that file is verified byte-for-byte against a
    /// fresh re-parse of the original historical workbook
    /// (`M7WorkbookParityTests`/`M7ExerciseClassifierPortTests`), including
    /// each `ExerciseEntry`'s `exerciseId` being a pure hash of its own raw
    /// exercise name (`ExerciseNameCanonicalizer.stableExerciseID`). There's
    /// no way to encode "these two differently-named historical entries are
    /// actually the same exercise" inside that frozen mirror without
    /// breaking that invariant, so corrections that reassign entries between
    /// exercises (a merge) -- or that diverge from name-derived
    /// classification -- live here instead, applied once right after a
    /// fresh seed import (`ContentView.importFixtureIfNeeded`). Mirrors
    /// exactly what a coach would do by hand via `ExerciseLibraryView`'s 器械
    /// picker / "合並到其他動作" feature; this just automates it so a fresh
    /// install doesn't need those taps repeated.
    ///
    /// Idempotent and safe to call on a store that already has these
    /// corrections applied, or one that never had the source exercises at
    /// all (e.g. the small hand-written test fixture) -- every step no-ops
    /// if its precondition isn't met.
    public static func applyKnownExerciseCorrections(context: ModelContext) throws {
        let exercises = try context.fetch(FetchDescriptor<Exercise>())

        // "Ball plank" (ex-7b819413) is named for the stability ball it's
        // performed ON, not a ball being lifted -- treat it like every
        // other bodyweight plank variant (adjustable-weight wheel
        // defaulting to "自重"), not like a thrown/held medicine ball.
        if let ballPlank = exercises.first(where: { $0.id == "ex-7b819413" }) {
            ballPlank.equipment = .bodyweight
        }

        // "Dips w/leg" (ex-7ea0b4db, 1 historical record) is the same
        // real-world exercise as "Dips w/assist" (ex-bf9b8acb, 31 records)
        // -- merge the former's entries into the latter and rename the
        // survivor to "Dips w/legs" (the coach's chosen name, kept
        // consistent with the pre-existing 31 records rather than the
        // single "Dips w/leg" one).
        if let legDip = exercises.first(where: { $0.id == "ex-7ea0b4db" }),
           let assistDip = exercises.first(where: { $0.id == "ex-bf9b8acb" }) {
            try redirectExerciseReferences(from: legDip, to: assistDip, in: context)
            assistDip.canonicalName = "Dips w/legs"
            if !assistDip.aliases.contains("Dips w/leg") {
                assistDip.aliases.append("Dips w/leg")
            }
        }

        try context.save()
    }

    // MARK: - 2026-09 exercise-library review (工程记录.md 十八): one-time device healing

    /// `exercise_library_seed.json` only auto-imports on a completely empty
    /// exercise library (`ContentView.importFixtureIfNeeded`'s
    /// `existingCount == 0` guard) -- an install that already had exercises
    /// before this review shipped (i.e. every real device that's been
    /// TestFlight-upgraded across builds, not fresh-installed) never sees
    /// the corrected file at all. This function is the one-time heal for
    /// that case, called by `ContentView` gated on a `UserDefaults` flag
    /// (not on exercise count) so it runs exactly once per install and
    /// never fights a coach's own edits made afterward through
    /// `ExerciseLibraryView`.
    ///
    /// Two parts:
    /// 1. Re-run `importSeed` against the corrected file. Safe on a store
    ///    with real client/session history -- `exercise_library_seed.json`'s
    ///    `clients` array is always `[]`, so this only upserts `Exercise`
    ///    rows by id (refreshing classification/`nameZh`/`notes`) and
    ///    never touches a `Client`/`WorkoutSession`.
    /// 2. `importSeed`'s upsert loop can update ids the file still defines
    ///    but never deletes ids the review removed -- the 11 rows 工程记录.md
    ///    十八之二 merged away or deleted as junk still exist untouched on
    ///    an old device after step 1. Handle them explicitly here, same
    ///    reassign-then-delete / delete-with-nullify shape as
    ///    `applyKnownExerciseCorrections` above.
    ///
    /// Idempotent: every step is a presence-checked no-op on a second call
    /// (e.g. if the coach already merged/deleted one of these by hand, or
    /// this function runs again after a interrupted first run).
    public static func applyExerciseLibraryReview202609(seedURL: URL, context: ModelContext) throws {
        _ = try importSeed(from: seedURL, into: context)

        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        var exerciseById: [String: Exercise] = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })

        // 7 true-duplicate merges (identical real-world exercise, split
        // into two rows by a naming/typo/superset-parsing artifact).
        let merges: [(source: String, target: String)] = [
            ("ex-cf4bf1fc", "ex-2bd54069"), // Barbell curl superset -> Barbell biceps curl
            ("ex-69b51cc5", "ex-39619e15"), // Ezbar biceps curl superset -> Ezbar curl
            ("ex-5a313a49", "ex-39619e15"), // Ezbar curl superset -> Ezbar curl
            ("ex-41538f63", "ex-6f52c23d"), // Machine high row (unilateral) -> Machine high row unilateral
            ("ex-a09d709b", "ex-8f282296"), // T bar row -> Tbar row
            ("ex-cb8193c0", "ex-e80642f6"), // Rest lunges to curl (typo) -> Rear lunges to curl
            ("ex-7ea0b4db", "ex-bf9b8acb"), // Dips w/leg -> Dips w/legs (orphan left by the 2026-08 merge above)
        ]
        for pair in merges {
            guard let source = exerciseById[pair.source], let target = exerciseById[pair.target] else { continue }
            try redirectExerciseReferences(from: source, to: target, in: context)
            if !target.aliases.contains(source.canonicalName) {
                target.aliases.append(source.canonicalName)
            }
            for alias in source.aliases where !target.aliases.contains(alias) {
                target.aliases.append(alias)
            }
            context.delete(source)
            exerciseById.removeValue(forKey: pair.source)
        }

        // 4 OCR/superset-split fragments that were never real exercises
        // ("2026", "curl", "press", "row"). No sensible merge target --
        // deleting them leaves any of their entries showing as "未識別動作",
        // same fallback `ExerciseLibraryView`'s own manual delete produces.
        let junkIDs = ["ex-aee65577", "ex-5300d17a", "ex-cd09e18a", "ex-e8cdc05b"]
        for id in junkIDs {
            guard let exercise = exerciseById[id] else { continue }
            context.delete(exercise)
        }

        try context.save()
    }

    // MARK: - Post-review library additions (2026-09-04)

    /// The two exercises the coach added by hand on 2026-09-04 and asked to
    /// have promoted into the standard library with proper bilingual names
    /// and classification (工程记录.md). They live in
    /// `exercise_library_seed.json` like every other canonical row, so a
    /// *fresh* install picks them up through `importFixtureIfNeeded` with no
    /// help from this function — this is the same already-installed-device
    /// problem `applyExerciseLibraryReview202609` above solves, one release
    /// later.
    public static let libraryAdditionIDs20260904 = ["ex-d134356d", "ex-f68651c5"]

    /// One-time heal for devices whose library predates the 2026-09-04
    /// additions. See `applyLibraryAdditions(ids:seedURL:context:)` below
    /// for what this actually does; kept as its own named entry point
    /// (rather than a single generic public function) so each dated
    /// addition has its own stable, greppable call site in `ContentView`.
    @discardableResult
    public static func applyExerciseLibraryAdditions20260904(seedURL: URL, context: ModelContext) throws -> Int {
        try applyLibraryAdditions(ids: libraryAdditionIDs20260904, seedURL: seedURL, context: context)
    }

    // MARK: - Post-review library additions (2026-09-07: CrossFit 动作库扩展第一批)

    /// 56 CrossFit-oriented movements added per `CrossFit动作目录候选.csv`'s
    /// "新增" rows (`output/review-2026-09-07/`) -- the nine official
    /// CrossFit foundational movements (Air/Front/Overhead Squat, Shoulder/
    /// Push Press, Push Jerk, Deadlift, Sumo Deadlift High Pull, Medicine-
    /// ball Clean), the main Olympic-lift variants, gymnastics skills, and
    /// core conditioning movements. Deliberately does NOT include the CSV's
    /// 15 "复用增强" rows (existing ids like Wall ball/Clean/Rowing/KB
    /// swing/Box step -- those keep their original ids and only gained new
    /// SEARCH ALIASES directly in `exercise_library_seed.json`, applied by
    /// `importSeed`'s ordinary upsert path since they're not new rows) nor
    /// the 1 "需复核" row (`ex-b9c935b2`, Squat to press / DB Thruster --
    /// left completely untouched pending the coach's own standard
    /// confirmation, per the CSV's own note).
    public static let libraryAdditionIDs20260907: [String] = [
        "ex-5f108875", "ex-5e0ede8b", "ex-984666a6", "ex-ef26dcb3", "ex-77974c4c",
        "ex-5c7943a6", "ex-43564d3c", "ex-eb0024d3", "ex-08aa1c35", "ex-e9ef8fb3",
        "ex-09d73ac6", "ex-a2697e16", "ex-034e105f", "ex-3a2d91c5", "ex-4c73f4b2",
        "ex-86b761a3", "ex-1e3dafbe", "ex-c5ab5b11", "ex-58ac402b", "ex-eaaf4f1c",
        "ex-afb2b407", "ex-0820da78", "ex-1580b80a", "ex-554f2806", "ex-11e1f889",
        "ex-1fba2dfd", "ex-19bf2777", "ex-cc8a7af9", "ex-11ef521e", "ex-2cd83ae8",
        "ex-7f1a460e", "ex-8c333bb6", "ex-47115df9", "ex-c023fa4c", "ex-1e5a5b78",
        "ex-f844f4d4", "ex-87d0143b", "ex-8467ec01", "ex-b629c8ae", "ex-58ed9ee4",
        "ex-e0f4c3a5", "ex-4b0be87d", "ex-7de77bd8", "ex-2fa4f95b", "ex-995c9678",
        "ex-3e20e8d7", "ex-6265b272", "ex-151b56ac", "ex-f211f4c2", "ex-1575b343",
        "ex-386a19b8", "ex-b7ba5a6c", "ex-df6ad190", "ex-0ffcf9da", "ex-fbc85912",
        "ex-3e4be989",
    ]

    /// One-time heal for devices whose library predates the 2026-09-07
    /// CrossFit-movement additions. Same shape and same reasoning as
    /// `applyExerciseLibraryAdditions20260904` -- see
    /// `applyLibraryAdditions(ids:seedURL:context:)`.
    @discardableResult
    public static func applyExerciseLibraryAdditions20260907(seedURL: URL, context: ModelContext) throws -> Int {
        try applyLibraryAdditions(ids: libraryAdditionIDs20260907, seedURL: seedURL, context: context)
    }

    /// 2026-09-09：主流 CrossFit 动作里库中仍缺的 16 个（Devil Press、Turkish
    /// Get-up、L-sit Hold、Man Maker 等）。同上，ids 与
    /// `Resources/exercise_library_seed.json` 对应。
    public static let libraryAdditionIDs20260909: [String] = [
        "ex-571ac40f", "ex-0d71fff2", "ex-18d4b760", "ex-6245e544", "ex-d1de2d8a",
        "ex-c30a1785", "ex-ef9b9ecc", "ex-dcbbd5de", "ex-41e3e5b5", "ex-b5452bae",
        "ex-4458f5e5", "ex-e01a8720", "ex-e7168108", "ex-e3a98ca7", "ex-ecfe5599",
        "ex-a3a00c28",
    ]

    @discardableResult
    public static func applyExerciseLibraryAdditions20260909(seedURL: URL, context: ModelContext) throws -> Int {
        try applyLibraryAdditions(ids: libraryAdditionIDs20260909, seedURL: seedURL, context: context)
    }

    /// 一次性回填 2026-09-09 新增的「訓練體系」分类（力量 / CrossFit / 兩者皆是）。
    ///
    /// 需要单独一支而不是搭在 `applyLibraryAdditions` 上：那一支只插入缺失的行，
    /// 而这次要改的是**已经在库里的 224 行**——它们通过 SwiftData 轻量迁移一律
    /// 拿到默认值 `.strength`，其中 Thruster、Toes-to-bar、Double-under 这些显然
    /// 不该只算力量。
    ///
    /// 也不能用 `importSeed`：那会把整份文件重新 upsert 一遍，把教练在動作庫里
    /// 手工改过的分类/名称/记录方式一起覆盖掉（`applyLibraryAdditions` 的注释里
    /// 已经写过同一条理由）。所以这里**只写 `discipline` 一个字段**，别的一概
    /// 不碰。
    ///
    /// 教练自己新增的 `ex-local-…` 行不在种子文件里，保持默认的「力量」——需要
    /// 改成 CrossFit 的话在動作庫里点一下即可。
    ///
    /// 幂等：重复调用只是把同样的值再写一遍。返回实际改动的行数。
    @discardableResult
    public static func applyExerciseDisciplineClassification20260909(seedURL: URL, context: ModelContext) throws -> Int {
        let seed: SeedFile
        do {
            seed = try JSONDecoder().decode(SeedFile.self, from: try Data(contentsOf: seedURL))
        } catch {
            throw ImportError.decodeFailed(String(describing: error))
        }
        var disciplineByID: [String: ExerciseDiscipline] = [:]
        for dto in seed.exercises {
            disciplineByID[dto.id] = dto.discipline ?? .strength
        }
        guard !disciplineByID.isEmpty else { return 0 }

        let wasAutosaveEnabled = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = wasAutosaveEnabled }

        var changed = 0
        for exercise in try context.fetch(FetchDescriptor<Exercise>()) {
            guard let discipline = disciplineByID[exercise.id], exercise.discipline != discipline else { continue }
            exercise.discipline = discipline
            changed += 1
        }
        guard changed > 0 else { return 0 }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return changed
    }

    /// 2026-09-16：從兩位學員（Example Athlete A、Example Athlete B）的教練 Excel
    /// 訓練紀錄中萃取出的 58 個常見動作，之前完全不在庫裡（用別名比對過，
    /// 排除了純標點/大小寫差異的假陽性，例如 "High row unilateral" 其實就是
    /// 已存在的 "High row (unilateral)"）。同上，ids 與
    /// `Resources/exercise_library_seed.json` 對應。
    public static let libraryAdditionIDs20260916: [String] = [
        "ex-663266e4", "ex-dd58671c", "ex-be94615b", "ex-7ba18d46", "ex-f09deb9a",
        "ex-6668b450", "ex-aeec5aa1", "ex-6a60e964", "ex-9bf2a3cd", "ex-ab63a873",
        "ex-ce5d154a", "ex-4e322498", "ex-286dd122", "ex-85a2151e", "ex-87b3686f",
        "ex-e8ecdf38", "ex-a59fa6e0", "ex-8415812b", "ex-47770467", "ex-a2582a4c",
        "ex-91269c92", "ex-0ecd8c9d", "ex-2b91d5dd", "ex-8d54a8ef", "ex-5fa36308",
        "ex-966fe2f5", "ex-0dec11c8", "ex-beb86180", "ex-dd3e882f", "ex-b6eaac46",
        "ex-2eda03c8", "ex-a62d454c", "ex-f9685a70", "ex-4b82d1f1", "ex-d6949a32",
        "ex-f77f92bc", "ex-700e182b", "ex-eae66146", "ex-6760bf3d", "ex-954df3ee",
        "ex-67b42521", "ex-ac4527f4", "ex-22c5bcf9", "ex-451eaee4", "ex-2d047587",
        "ex-48094ad3", "ex-899b2eb5", "ex-b184c857", "ex-86436867", "ex-49181262",
        "ex-0ee4de89", "ex-6dba0069", "ex-fcfe8f08", "ex-614bd2e6", "ex-ff368f42",
        "ex-675a7e5b", "ex-c4b3dfe5", "ex-5d119fa7",
    ]

    /// One-time heal for devices whose library predates the 2026-09-16
    /// Excel-derived additions. Same shape and same reasoning as
    /// `applyExerciseLibraryAdditions20260907` -- see
    /// `applyLibraryAdditions(ids:seedURL:context:)`.
    @discardableResult
    public static func applyExerciseLibraryAdditions20260916(seedURL: URL, context: ModelContext) throws -> Int {
        try applyLibraryAdditions(ids: libraryAdditionIDs20260916, seedURL: seedURL, context: context)
    }

    /// 同一批 2026-09-16 萃取裡，另外 8 個動作原本就在庫裡、只是這兩位學員的
    /// Excel 用了不同措辭（例如 "Barbell squat" 其實就是已有的 "Back Squat"）
    /// —— 這裡不新增行，只把這些措辭補進既有行的 `aliases`，這樣之後語音指令
    /// 或匯入比對才認得出來。跟 `applyExerciseDisciplineClassification20260909`
    /// 同一種「只動一個欄位、只加不減」的安全heal手法，不會覆蓋教練自己在
    /// 動作庫裡改過的名稱或分類。冪等：已經有的別名不會重複加。
    private static let aliasAdditions20260916: [String: [String]] = [
        "ex-e9ef8fb3": ["Barbell squat"],           // Back Squat
        "ex-d7ed000f": ["Hip abduction superset"],  // Hip abduction
        "ex-4f57f3d5": ["Seated row narrow grip"],  // Seated row narrow
        "ex-fcf79b0c": ["Side extension"],          // Back extension (side)
        "ex-5600ec08": ["Machine row reardelt"],    // Machine rear row
        "ex-1c6724ff": ["Spider curl reverse eccentric"], // Spider curl
        "ex-f0582022": ["Split squat 1.5"],         // DB split squat 1.5
        "ex-90a95057": ["Chest support row"],       // Chest support DB row
    ]

    @discardableResult
    public static func applyExerciseLibraryAliasAdditions20260916(context: ModelContext) throws -> Int {
        let exercises = try context.fetch(FetchDescriptor<Exercise>())
        let byId = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        var changed = 0
        for (id, aliasesToAdd) in aliasAdditions20260916 {
            guard let exercise = byId[id] else { continue }
            for alias in aliasesToAdd where !exercise.aliases.contains(alias) {
                exercise.aliases.append(alias)
                changed += 1
            }
        }
        guard changed > 0 else { return 0 }
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return changed
    }

    /// Shared implementation behind every dated "add N new rows to an
    /// already-populated library" heal.
    ///
    /// Deliberately NOT `importSeed(from:)`: that re-upserts every row in
    /// the file and would overwrite any classification the coach corrected
    /// by hand through `ExerciseLibraryView` since the last full pass. This
    /// only reads `ids` out of the seed file and inserts whichever of them
    /// are missing, so nothing else in the library is touched.
    ///
    /// It then folds away the coach's own hand-typed rows for the same
    /// movements (created through `ExercisePickerSheet`/`ExerciseLibraryView`
    /// and therefore carrying unclassified `ex-local-…` ids), reassigning
    /// their entries AND any template slot referencing them (B04's
    /// `redirectExerciseReferences`) onto the new canonical row — otherwise
    /// the coach ends up with two rows for one movement and a split
    /// history. Merge candidates are restricted to `ex-local-` ids matched
    /// by exact normalized name against the new row's own `aliases`, so a
    /// canonical row can never be swallowed by this pass and a near-miss
    /// spelling simply leaves both rows visible in 動作庫 rather than
    /// guessing.
    ///
    /// Idempotent: presence-checked at every step, so a second call (or a
    /// call on a fresh install that already has every row) is a no-op.
    private static func applyLibraryAdditions(ids: [String], seedURL: URL, context: ModelContext) throws -> Int {
        let seed: SeedFile
        do {
            seed = try JSONDecoder().decode(SeedFile.self, from: try Data(contentsOf: seedURL))
        } catch {
            throw ImportError.decodeFailed(String(describing: error))
        }
        let additions = seed.exercises.filter { ids.contains($0.id) }
        guard !additions.isEmpty else { return 0 }

        let wasAutosaveEnabled = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = wasAutosaveEnabled }

        var exerciseById: [String: Exercise] = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<Exercise>()).map { ($0.id, $0) }
        )
        var insertedCount = 0

        for dto in additions {
            let canonical: Exercise
            if let existing = exerciseById[dto.id] {
                canonical = existing
            } else {
                canonical = Exercise(
                    id: dto.id,
                    canonicalName: dto.canonicalName,
                    aliases: dto.aliases,
                    movementPattern: dto.movementPattern,
                    equipment: dto.equipment,
                    loadDirection: dto.loadDirection,
                    isUnilateral: dto.isUnilateral,
                    occurrenceCount: dto.occurrenceCount,
                    needsReview: dto.needsReview,
                    reviewReason: dto.reviewReason,
                    recordingMetric: dto.recordingMetric,
                    discipline: dto.discipline ?? .strength,
                    nameZh: dto.nameZh ?? "",
                    notes: dto.notes ?? ""
                )
                context.insert(canonical)
                exerciseById[dto.id] = canonical
                insertedCount += 1
            }

            let knownNames = Set(([dto.canonicalName] + dto.aliases).map(normalizedExerciseName))
            // 从 `exerciseById`（每删掉一行就同步剔除）里找，而不是从一份
            // 一次性 fetch 出来、此后不再更新的数组里找：处理第二个动作时，
            // 第一个动作的重复行可能已经 `context.delete` 过了，再把它当候选
            // 既可能重复合并，也是在拿一个已标记删除的 SwiftData 对象做判断。
            // （本轮的 `context.save()` 只在函数末尾调用一次，所以实测还没到
            // 触发 "This model instance was invalidated" 那一步；这里是把不
            // 变量写死，不是在修一个已复现的崩溃。）
            let duplicates = exerciseById.values.filter { candidate in
                candidate.id != canonical.id
                    && candidate.id.hasPrefix("ex-local-")
                    && (knownNames.contains(normalizedExerciseName(candidate.canonicalName))
                        || candidate.aliases.contains { knownNames.contains(normalizedExerciseName($0)) })
            }

            for duplicate in duplicates {
                try redirectExerciseReferences(from: duplicate, to: canonical, in: context)
                for alias in [duplicate.canonicalName] + duplicate.aliases
                where !canonical.aliases.contains(alias) {
                    canonical.aliases.append(alias)
                }
                context.delete(duplicate)
                exerciseById.removeValue(forKey: duplicate.id)
            }
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return insertedCount
    }

    /// Case-, whitespace- and punctuation-insensitive comparison key used to
    /// recognise the coach's hand-typed row as "the same movement" as a
    /// canonical one. Narrower than `ExerciseNameCanonicalizer` on purpose:
    /// this only ever compares against an explicit alias list, so it needs
    /// to forgive typing noise, not to classify unknown names.
    static func normalizedExerciseName(_ raw: String) -> String {
        raw.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Template seed import (CONTRACT-M5.md §4.2)

    /// Imports `Resources/template_seed.json`'s 5 hand-picked session
    /// templates, building the `SessionTemplate` -> `TemplateBlock` ->
    /// `TemplateExerciseSlot` object graph and inserting it into `context`.
    /// Returns the number of templates imported.
    ///
    /// Unlike `importSeed` (which explicitly fetches-then-updates existing
    /// rows by id), this function does not fetch or check for existing
    /// `SessionTemplate`s -- it always builds and inserts a fresh object
    /// graph. Per CONTRACT-M5.md §4.2 point 3, the "only import when
    /// `SessionTemplate` count is 0" guard belongs in the caller (mirroring
    /// where `importFixtureIfNeeded`'s guard lives in `ContentView.swift`
    /// for `gymlog_seed.json`), not here -- callers MUST apply that guard;
    /// do not rely on this function to no-op on a second call. (In
    /// practice, calling it twice on the same context does not duplicate
    /// rows, because block/slot ids are derived deterministically from the
    /// template id + order and `SessionTemplate`/`TemplateBlock`/
    /// `TemplateExerciseSlot.id` are all `@Attribute(.unique)` -- SwiftData
    /// coalesces the re-inserted objects into the existing rows on save.
    /// That is a side effect of the `.unique` id scheme, not a documented
    /// or tested substitute for the caller-side guard.)
    ///
    /// Exercise-name resolution: each slot's `exerciseName` is matched
    /// case-insensitively against `Exercise.canonicalName` among whatever
    /// `Exercise` rows already exist in `context` -- callers must run this
    /// AFTER the main seed import, or every slot will fail to resolve.
    /// A slot that doesn't resolve is skipped (not the whole template, not
    /// the whole block) and a warning is recorded via `ImportLog`, mirroring
    /// `TemplateSessionBuilder`'s existing unresolved-reference philosophy
    /// (CONTRACT.md §11.4: degrade and log, never crash, never silently
    /// drop without a trace). A block left with zero resolved slots is
    /// itself dropped rather than inserted empty, same as
    /// `TemplateSessionBuilder.build`'s `guard !entries.isEmpty else { continue }`.
    public static func importTemplateSeed(data: Data, into context: ModelContext) throws -> Int {
        let seed: TemplateSeedFile
        do {
            seed = try JSONDecoder().decode(TemplateSeedFile.self, from: data)
        } catch {
            throw ImportError.decodeFailed(String(describing: error))
        }

        let wasAutosaveEnabled = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = wasAutosaveEnabled }

        do {
            let existingExercises = try context.fetch(FetchDescriptor<Exercise>())
            var exerciseByLowercasedName: [String: Exercise] = [:]
            for exercise in existingExercises {
                exerciseByLowercasedName[exercise.canonicalName.lowercased()] = exercise
            }

            for templateDTO in seed.templates {
                let template = SessionTemplate(
                    id: templateDTO.id,
                    name: templateDTO.name,
                    templateNote: templateDTO.templateNote,
                    order: templateDTO.order
                )
                context.insert(template)

                for blockDTO in templateDTO.blocks {
                    var resolvedSlots: [TemplateExerciseSlot] = []
                    for slotDTO in blockDTO.slots {
                        let key = slotDTO.exerciseName
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .lowercased()
                        guard let exercise = exerciseByLowercasedName[key] else {
                            ImportLog.warnDecodeFallback(
                                "TemplateExerciseSlot.exerciseName",
                                reason: "template \"\(templateDTO.id)\" block order=\(blockDTO.order) slot order=\(slotDTO.order): " +
                                    "exerciseName \"\(slotDTO.exerciseName)\" not found in exercise library, slot skipped."
                            )
                            continue
                        }
                        let slot = TemplateExerciseSlot(
                            id: "\(templateDTO.id)-block\(blockDTO.order)-slot\(slotDTO.order)",
                            order: slotDTO.order,
                            exerciseID: exercise.id,
                            defaultSets: slotDTO.defaultSets,
                            defaultRepTarget: slotDTO.defaultRepTarget
                        )
                        resolvedSlots.append(slot)
                    }

                    // Mirrors TemplateSessionBuilder.build: a block with no
                    // resolvable slots is dropped, not inserted empty.
                    guard !resolvedSlots.isEmpty else { continue }

                    let block = TemplateBlock(
                        id: "\(templateDTO.id)-block\(blockDTO.order)",
                        order: blockDTO.order,
                        blockType: blockDTO.blockType,
                        restSeconds: blockDTO.restSeconds
                    )
                    block.template = template
                    context.insert(block)

                    for slot in resolvedSlots {
                        slot.block = block
                        context.insert(slot)
                    }
                }
            }
        } catch {
            context.rollback()
            throw error
        }

        try context.save()
        return seed.templates.count
    }

    public static func importTemplateSeed(from url: URL, into context: ModelContext) throws -> Int {
        let data = try Data(contentsOf: url)
        return try importTemplateSeed(data: data, into: context)
    }
}
