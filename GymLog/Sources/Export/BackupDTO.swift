import Foundation

/// Wire format for a full-app backup (审查报告"适合当前范围的功能"第一批:
/// "完整备份与恢复" — "一份文件包含学员、体测、训练、动作库及模板，换机可恢复").
///
/// Deliberately separate `Codable` structs mirroring each `@Model`, same
/// rationale as `Sources/Import/SeedDTO.swift`: a future model refactor must
/// not silently change what an old backup file decodes as. Every entity
/// that carries its own stable `@Attribute(.unique) id` in the model layer
/// keeps that id here too, so restore can upsert by id (see
/// `BackupImporter`) instead of guessing identity. `SessionBlock`/
/// `ExerciseEntry`/`SetLog` have no independent id in the model layer either
/// (CONTRACT.md's existing convention: they're owned/nested under their
/// stable-id parent) -- restore rebuilds these three as a whole subtree,
/// same as `SeedImporter`/`XLSXHistoryImporter` already do.
public struct ExerciseBackupDTO: Codable, Equatable {
    public var id: String
    public var canonicalName: String
    public var aliases: [String]
    public var movementPattern: MovementPattern
    public var equipment: Equipment
    public var loadDirection: LoadDirection
    public var isUnilateral: Bool
    public var occurrenceCount: Int
    public var needsReview: Bool
    public var reviewReason: String?
    public var recordingMetric: RecordingMetric
    /// `nil` only in a backup written before this field existed (2026-09-09)
    /// -- restore reads that as `.strength`, the same default a
    /// lightweight-migrated row gets. Optional for decode compatibility,
    /// same convention as `WorkoutSessionBackupDTO.isInProgress`.
    public var discipline: ExerciseDiscipline?
    public var nameZh: String
    public var notes: String

    public init(
        id: String, canonicalName: String, aliases: [String], movementPattern: MovementPattern,
        equipment: Equipment, loadDirection: LoadDirection, isUnilateral: Bool, occurrenceCount: Int,
        needsReview: Bool, reviewReason: String?, recordingMetric: RecordingMetric,
        discipline: ExerciseDiscipline? = nil, nameZh: String, notes: String
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.aliases = aliases
        self.movementPattern = movementPattern
        self.equipment = equipment
        self.loadDirection = loadDirection
        self.isUnilateral = isUnilateral
        self.occurrenceCount = occurrenceCount
        self.needsReview = needsReview
        self.reviewReason = reviewReason
        self.recordingMetric = recordingMetric
        self.discipline = discipline
        self.nameZh = nameZh
        self.notes = notes
    }
}

public struct AssessmentBackupDTO: Codable, Equatable {
    public var id: String
    public var pattern: MovementPattern
    public var date: Date
    public var level: String?
    public var notes: String?

    public init(id: String, pattern: MovementPattern, date: Date, level: String?, notes: String?) {
        self.id = id
        self.pattern = pattern
        self.date = date
        self.level = level
        self.notes = notes
    }
}

public struct BodyMetricBackupDTO: Codable, Equatable {
    public var id: String
    public var date: Date
    public var weightKg: Double?
    public var bodyFatPercent: Double?
    public var skeletalMuscleKg: Double?
    public var bmi: Double?
    public var visceralFatLevel: Int?
    public var bmr: Double?
    public var tdee: Double?
    public var bodyFatMassKg: Double?
    public var notes: String?

    public init(
        id: String, date: Date, weightKg: Double?, bodyFatPercent: Double?, skeletalMuscleKg: Double?,
        bmi: Double?, visceralFatLevel: Int?, bmr: Double?, tdee: Double?, bodyFatMassKg: Double?, notes: String?
    ) {
        self.id = id
        self.date = date
        self.weightKg = weightKg
        self.bodyFatPercent = bodyFatPercent
        self.skeletalMuscleKg = skeletalMuscleKg
        self.bmi = bmi
        self.visceralFatLevel = visceralFatLevel
        self.bmr = bmr
        self.tdee = tdee
        self.bodyFatMassKg = bodyFatMassKg
        self.notes = notes
    }
}

public struct SetLogBackupDTO: Codable, Equatable {
    public var setIndex: Int
    public var load: LoadValue
    public var target: RepTarget
    public var actual: RepTarget
    public var isInferred: Bool

    public init(setIndex: Int, load: LoadValue, target: RepTarget, actual: RepTarget, isInferred: Bool) {
        self.setIndex = setIndex
        self.load = load
        self.target = target
        self.actual = actual
        self.isInferred = isInferred
    }
}

public struct ExerciseEntryBackupDTO: Codable, Equatable {
    public var order: Int
    public var exerciseIdRef: String
    public var exerciseRaw: String
    public var plannedSets: Int
    public var sets: [SetLogBackupDTO]

    public init(order: Int, exerciseIdRef: String, exerciseRaw: String, plannedSets: Int, sets: [SetLogBackupDTO]) {
        self.order = order
        self.exerciseIdRef = exerciseIdRef
        self.exerciseRaw = exerciseRaw
        self.plannedSets = plannedSets
        self.sets = sets
    }
}

public struct SessionBlockBackupDTO: Codable, Equatable {
    public var order: Int
    public var blockType: BlockType
    public var restSeconds: Int?
    public var restRaw: String?
    public var note: String?
    public var sourceRow: Int
    public var entries: [ExerciseEntryBackupDTO]
    /// 2026-09-07 M1 CrossFit extension. `Optional`, not a defaulted
    /// non-optional, so Swift's synthesized `Decodable` uses
    /// `decodeIfPresent` for it -- a v1 backup written before this field
    /// existed decodes with `nil` here instead of failing to decode
    /// entirely. `BackupImporter` treats `nil` as `.strength` (every
    /// pre-CrossFit block's true section kind).
    public var sectionKind: SectionKind?
    /// Raw JSON text of `SessionBlock.wodPayload`, exactly as stored --
    /// NEVER decoded into a typed `WODPayload` by the backup layer itself.
    /// This is what makes "an unsupported future payload round-trips
    /// through backup/restore" possible: `BackupExporter` writes whatever
    /// `wodPayloadRawJSON` already is (opaque or not), and `BackupImporter`
    /// writes it straight back without attempting to understand it (工程审阅
    /// §5.2: "未知payload原文保留且不允許破壞性編輯").
    public var wodPayloadRawJSON: String?

    public init(
        order: Int, blockType: BlockType, restSeconds: Int?, restRaw: String?, note: String?, sourceRow: Int,
        entries: [ExerciseEntryBackupDTO], sectionKind: SectionKind? = nil, wodPayloadRawJSON: String? = nil
    ) {
        self.order = order
        self.blockType = blockType
        self.restSeconds = restSeconds
        self.restRaw = restRaw
        self.note = note
        self.sourceRow = sourceRow
        self.entries = entries
        self.sectionKind = sectionKind
        self.wodPayloadRawJSON = wodPayloadRawJSON
    }
}

public struct WorkoutSessionBackupDTO: Codable, Equatable {
    public var id: String
    public var date: Date
    public var dateOrigin: DateOrigin
    public var dateRaw: String
    public var weekNumber: Int
    public var sourceSheet: String
    public var sourceRow: Int
    public var warmup: String?
    public var warmupNote: String?
    public var cooldown: String?
    public var cooldownNote: String?
    public var needsReview: Bool
    public var reviewReason: String?
    public var insightJSON: String?
    public var plannedDurationMinutes: Int?
    public var importSourceFile: String?
    public var importedAt: Date?
    public var sourceDigest: String?
    public var importDigest: String?
    /// `nil` only in a backup written before this field existed (2026-09-09)
    /// -- restore reads that as `false`（已完成），which is what every session
    /// in such a backup actually was. Optional rather than a plain `Bool` for
    /// exactly the same decode-compatibility reason as
    /// `SessionBlockBackupDTO.sectionKind`.
    public var isInProgress: Bool?
    public var blocks: [SessionBlockBackupDTO]

    public init(
        id: String, date: Date, dateOrigin: DateOrigin, dateRaw: String, weekNumber: Int, sourceSheet: String,
        sourceRow: Int, warmup: String?, warmupNote: String?, cooldown: String?, cooldownNote: String?,
        needsReview: Bool, reviewReason: String?, plannedDurationMinutes: Int?, importSourceFile: String?,
        importedAt: Date?, sourceDigest: String?, importDigest: String?, isInProgress: Bool? = nil,
        blocks: [SessionBlockBackupDTO], insightJSON: String? = nil
    ) {
        self.id = id
        self.date = date
        self.dateOrigin = dateOrigin
        self.dateRaw = dateRaw
        self.weekNumber = weekNumber
        self.sourceSheet = sourceSheet
        self.sourceRow = sourceRow
        self.warmup = warmup
        self.warmupNote = warmupNote
        self.cooldown = cooldown
        self.cooldownNote = cooldownNote
        self.needsReview = needsReview
        self.reviewReason = reviewReason
        self.insightJSON = insightJSON
        self.plannedDurationMinutes = plannedDurationMinutes
        self.importSourceFile = importSourceFile
        self.importedAt = importedAt
        self.sourceDigest = sourceDigest
        self.importDigest = importDigest
        self.isInProgress = isInProgress
        self.blocks = blocks
    }
}

public struct ClientBackupDTO: Codable, Equatable {
    public var id: String
    public var name: String
    public var phone: String?
    public var gender: String?
    public var age: Int?
    public var heightCm: Double?
    public var startWeightKg: Double?
    public var goal: String?
    public var frequency: String?
    public var bmr: Double?
    public var tdee: Double?
    public var habits: String?
    public var medicalHistory: String?
    public var assessments: [AssessmentBackupDTO]
    public var bodyMetrics: [BodyMetricBackupDTO]
    public var sessions: [WorkoutSessionBackupDTO]

    public init(
        id: String, name: String, phone: String?, gender: String?, age: Int?, heightCm: Double?,
        startWeightKg: Double?, goal: String?, frequency: String?, bmr: Double?, tdee: Double?,
        habits: String?, medicalHistory: String?, assessments: [AssessmentBackupDTO],
        bodyMetrics: [BodyMetricBackupDTO], sessions: [WorkoutSessionBackupDTO]
    ) {
        self.id = id
        self.name = name
        self.phone = phone
        self.gender = gender
        self.age = age
        self.heightCm = heightCm
        self.startWeightKg = startWeightKg
        self.goal = goal
        self.frequency = frequency
        self.bmr = bmr
        self.tdee = tdee
        self.habits = habits
        self.medicalHistory = medicalHistory
        self.assessments = assessments
        self.bodyMetrics = bodyMetrics
        self.sessions = sessions
    }
}

public struct TemplateExerciseSlotBackupDTO: Codable, Equatable {
    public var id: String
    public var order: Int
    public var exerciseID: String
    public var defaultSets: Int
    public var defaultRepTarget: RepTarget

    public init(id: String, order: Int, exerciseID: String, defaultSets: Int, defaultRepTarget: RepTarget) {
        self.id = id
        self.order = order
        self.exerciseID = exerciseID
        self.defaultSets = defaultSets
        self.defaultRepTarget = defaultRepTarget
    }
}

public struct TemplateBlockBackupDTO: Codable, Equatable {
    public var id: String
    public var order: Int
    public var blockType: BlockType
    public var restSeconds: Int
    public var slots: [TemplateExerciseSlotBackupDTO]
    /// 2026-09-07 M1 CrossFit extension -- see `SessionBlockBackupDTO`'s
    /// matching fields for why both are `Optional` (v1-backup decode
    /// compatibility) and why the WOD prescription is carried as raw JSON
    /// text rather than a decoded, possibly-lossy `WODPrescription`.
    public var sectionKind: SectionKind?
    public var wodPrescriptionRawJSON: String?

    public init(
        id: String, order: Int, blockType: BlockType, restSeconds: Int, slots: [TemplateExerciseSlotBackupDTO],
        sectionKind: SectionKind? = nil, wodPrescriptionRawJSON: String? = nil
    ) {
        self.id = id
        self.order = order
        self.blockType = blockType
        self.restSeconds = restSeconds
        self.slots = slots
        self.sectionKind = sectionKind
        self.wodPrescriptionRawJSON = wodPrescriptionRawJSON
    }
}

public struct SessionTemplateBackupDTO: Codable, Equatable {
    public var id: String
    public var name: String
    public var templateNote: String?
    public var order: Int
    public var blocks: [TemplateBlockBackupDTO]

    public init(id: String, name: String, templateNote: String?, order: Int, blocks: [TemplateBlockBackupDTO]) {
        self.id = id
        self.name = name
        self.templateNote = templateNote
        self.order = order
        self.blocks = blocks
    }
}

/// Counts recomputed two different ways (once at export time from the same
/// arrays being serialized, once at restore time from the decoded arrays)
/// so a truncated/corrupted file is caught before anything is written to
/// the store -- same self-check idiom `SeedImporter` already uses for the
/// seed JSON.
public struct BackupCounts: Codable, Equatable {
    public var clientCount: Int
    public var exerciseCount: Int
    public var sessionCount: Int
    public var entryCount: Int
    public var setLogCount: Int
    public var templateCount: Int

    public init(clientCount: Int, exerciseCount: Int, sessionCount: Int, entryCount: Int, setLogCount: Int, templateCount: Int) {
        self.clientCount = clientCount
        self.exerciseCount = exerciseCount
        self.sessionCount = sessionCount
        self.entryCount = entryCount
        self.setLogCount = setLogCount
        self.templateCount = templateCount
    }

    public static func compute(exercises: [ExerciseBackupDTO], clients: [ClientBackupDTO], templates: [SessionTemplateBackupDTO]) -> BackupCounts {
        var sessionCount = 0, entryCount = 0, setLogCount = 0
        for client in clients {
            sessionCount += client.sessions.count
            for session in client.sessions {
                for block in session.blocks {
                    entryCount += block.entries.count
                    for entry in block.entries {
                        setLogCount += entry.sets.count
                    }
                }
            }
        }
        return BackupCounts(
            clientCount: clients.count, exerciseCount: exercises.count, sessionCount: sessionCount,
            entryCount: entryCount, setLogCount: setLogCount, templateCount: templates.count
        )
    }
}

public struct BackupFile: Codable {
    /// Bumped whenever a field is added/removed/reinterpreted in a way an
    /// older `BackupImporter` couldn't handle. `BackupImporter` refuses to
    /// restore a file whose version is NEWER than it knows about (silently
    /// misreading an unknown future format is worse than a clear refusal).
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var generatedAt: Date
    public var counts: BackupCounts
    public var exercises: [ExerciseBackupDTO]
    public var clients: [ClientBackupDTO]
    public var templates: [SessionTemplateBackupDTO]

    public init(schemaVersion: Int = BackupFile.currentSchemaVersion, generatedAt: Date, counts: BackupCounts, exercises: [ExerciseBackupDTO], clients: [ClientBackupDTO], templates: [SessionTemplateBackupDTO]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.counts = counts
        self.exercises = exercises
        self.clients = clients
        self.templates = templates
    }
}
