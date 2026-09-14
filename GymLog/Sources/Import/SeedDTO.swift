import Foundation

// MARK: - Wire-format DTOs mirroring CONTRACT.md exactly.
//
// These are intentionally separate from the SwiftData `@Model` types: the
// JSON shape is the migration script's contract, the model shape is our
// storage/query concern, and keeping them distinct means a future model
// refactor (indexes, denormalization, etc.) never risks silently changing
// what we accept on import.

struct SeedFile: Decodable {
    let schemaVersion: Int
    let generatedAt: String
    let source: String
    let stats: StatsDTO
    let exercises: [ExerciseDTO]
    let clients: [ClientDTO]
}

struct StatsDTO: Decodable {
    let clientCount: Int
    let sessionCount: Int
    let exerciseCount: Int
    let entryCount: Int
    let setLogCount: Int
    // CONTRACT.md §2.1 (v2): three orthogonal review-count fields, each with
    // a distinct, non-derivable-from-the-others scope. Only the latter two
    // are things the App can independently recompute from the decoded JSON
    // tree and therefore self-check; `needsReviewCount` is an "audit layer"
    // count (deduplicated affected source cells in migration_audit.csv,
    // a file the App never reads) that has no counterpart the App can
    // derive -- it's decoded and carried through for display only, never
    // compared against a computed value. See SeedImporter.swift.
    let needsReviewCount: Int
    let exercisesNeedingReviewCount: Int
    let sessionsNeedingReviewCount: Int
}

struct ExerciseDTO: Decodable {
    let id: String
    let canonicalName: String
    let aliases: [String]
    let movementPattern: MovementPattern
    let equipment: Equipment
    let loadDirection: LoadDirection
    let isUnilateral: Bool
    let occurrenceCount: Int
    let needsReview: Bool
    let reviewReason: String?
    /// CONTRACT-M8.md. Not part of CONTRACT.md's frozen §3 schema.
    let recordingMetric: RecordingMetric
    /// 2026-09-09「訓練體系」分类。可选，理由同下面的 `nameZh`：
    /// `gymlog_seed.json`（冻结的历史镜像）里没有这个键，缺省按 `.strength`。
    let discipline: ExerciseDiscipline?
    /// 2026-09 curated bilingual content. Not part of CONTRACT.md's frozen §3
    /// schema, and absent from `gymlog_seed.json` (the frozen historical
    /// mirror) -- optional so that file keeps decoding unchanged; only
    /// `exercise_library_seed.json` (the shipped default library) sets these.
    let nameZh: String?
    let notes: String?
}

struct ClientDTO: Decodable {
    let id: String
    let name: String
    let phone: String?
    let gender: String?
    let age: Int?
    let heightCm: Double?
    let startWeightKg: Double?
    let goal: String?
    let frequency: String?
    let bmr: Double?
    let tdee: Double?
    let habits: String?
    let medicalHistory: String?
    let assessments: [AssessmentDTO]
    let bodyMetrics: [BodyMetricDTO]
    let sessions: [SessionDTO]
}

/// Not defined by CONTRACT.md -- always `[]` in this migration's output
/// (source `Info` sheet is a blank template). Fields are all optional and
/// decoding of an individual malformed element is skipped rather than
/// failing the whole import, since this isn't part of the authoritative
/// interface.
struct AssessmentDTO: Decodable {
    let id: String?
    let pattern: String?
    let date: String?
    let level: String?
    let notes: String?
}

/// Not defined by CONTRACT.md -- always `[]` this period (工程规划.md §3.2:
/// InBody UI is a placeholder in M1). See `AssessmentDTO` note above.
struct BodyMetricDTO: Decodable {
    let id: String?
    let date: String?
    let weightKg: Double?
    let bodyFatPercent: Double?
    let skeletalMuscleKg: Double?
    let bmi: Double?
    let visceralFatLevel: Int?
    let bmr: Double?
    let tdee: Double?
    let notes: String?
}

struct SessionDTO: Decodable {
    let id: String
    let date: String
    let dateOrigin: DateOrigin
    let dateRaw: String
    let weekNumber: Int
    let sourceSheet: String
    let sourceRow: Int
    // CONTRACT.md §5 (v2): added to carry the §8.1 date-anomaly marking
    // requirement, which v1 had no field to hold.
    let needsReview: Bool
    let reviewReason: String?
    let warmup: String?
    let warmupNote: String?
    let cooldown: String?
    let cooldownNote: String?
    let blocks: [BlockDTO]
}

struct BlockDTO: Decodable {
    let order: Int
    let blockType: BlockType
    let restSeconds: Int?
    let restRaw: String?
    let note: String?
    let sourceRow: Int
    let entries: [EntryDTO]
}

struct EntryDTO: Decodable {
    let order: Int
    let exerciseId: String
    let exerciseRaw: String
    let plannedSets: Int
    let sets: [SetLogDTO]
}

struct SetLogDTO: Decodable {
    let setIndex: Int
    let load: LoadValue
    let target: RepTarget
    let actual: RepTarget
    let isInferred: Bool
}

// MARK: - Date parsing

enum SeedDateParser {
    /// CONTRACT.md §5: `date` is "ISO 8601" but observed as a bare
    /// `yyyy-MM-dd` (already-reconstructed calendar date, no time
    /// component). Parsed as UTC midnight so the same string always
    /// produces the same `Date` regardless of device timezone -- important
    /// since sort order and "same day" comparisons must be stable.
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parseDay(_ string: String) -> Date? {
        dayFormatter.date(from: string)
    }
}
