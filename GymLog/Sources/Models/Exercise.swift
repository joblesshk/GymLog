import Foundation
import SwiftData

/// CONTRACT.md §3. Global exercise library, shared across clients.
@Model
public final class Exercise {
    /// Stable id from the migration script (e.g. "ex-0001"). Upsert key for
    /// idempotent import -- see CONTRACT.md §11.1.
    @Attribute(.unique) public var id: String
    public var canonicalName: String
    public var aliases: [String]

    // Classification enums are String-raw-value and stored as their raw
    // string so SwiftData can index/query them trivially; the typed enum is
    // exposed via a computed property with graceful unknown-string fallback.
    private var movementPatternRaw: String
    private var equipmentRaw: String
    private var loadDirectionRaw: String
    /// CONTRACT-M8.md. Literal default -> existing installed `Exercise` rows
    /// (created before M8) pick up `.reps` via SwiftData lightweight
    /// migration with no data loss; reimporting the seed backfills the real
    /// classification for the 177 canonical exercises by id match (see
    /// `SeedImporter.swift`).
    private var recordingMetricRaw: String = "reps"
    /// 2026-09-09 教练要求的「訓練體系」分类（力量 / CrossFit / 兩者皆是）。
    /// 字面量默认 -> 已装机的每一行通过 SwiftData 轻量迁移拿到 `.strength`，
    /// 随后由 `SeedImporter.applyExerciseDisciplineClassification20260909`
    /// 按 id 回填内建动作库的真实分类。同 `recordingMetric` 的先例。
    private var disciplineRaw: String = ExerciseDiscipline.strength.rawValue

    public var isUnilateral: Bool
    public var occurrenceCount: Int
    public var needsReview: Bool
    public var reviewReason: String?

    /// 2026-09 curated bilingual content, application-layer addition
    /// alongside `recordingMetric` (not part of CONTRACT.md's frozen §3
    /// schema). Literal `""` defaults -> existing installed rows pick these
    /// up via SwiftData lightweight migration with no data loss; a coach-
    /// created custom exercise simply has no Chinese name/description until
    /// someone fills them in. `displayName` below degrades gracefully when
    /// `nameZh` is empty.
    public var nameZh: String = ""
    /// Short (<=50 character) description of the movement. Always written in
    /// Traditional Chinese, same as the rest of this app's data-driven copy
    /// (`reviewReason` is the one precedent for an intentionally
    /// single-language data field) -- not branched per `AppLanguage` the way
    /// `displayName` below is.
    public var notes: String = ""

    @Relationship(deleteRule: .nullify, inverse: \ExerciseEntry.exercise)
    public var entries: [ExerciseEntry]? = []

    public init(
        id: String,
        canonicalName: String,
        aliases: [String],
        movementPattern: MovementPattern,
        equipment: Equipment,
        loadDirection: LoadDirection,
        isUnilateral: Bool,
        occurrenceCount: Int,
        needsReview: Bool,
        reviewReason: String?,
        recordingMetric: RecordingMetric = .reps,
        discipline: ExerciseDiscipline = .strength,
        nameZh: String = "",
        notes: String = ""
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.aliases = aliases
        self.movementPatternRaw = movementPattern.rawValue
        self.equipmentRaw = equipment.rawValue
        self.loadDirectionRaw = loadDirection.rawValue
        self.isUnilateral = isUnilateral
        self.occurrenceCount = occurrenceCount
        self.needsReview = needsReview
        self.reviewReason = reviewReason
        self.recordingMetricRaw = recordingMetric.rawValue
        self.disciplineRaw = discipline.rawValue
        self.nameZh = nameZh
        self.notes = notes
    }

    public var movementPattern: MovementPattern {
        get { MovementPattern(rawValue: movementPatternRaw) ?? .unknown }
        set { movementPatternRaw = newValue.rawValue }
    }

    public var equipment: Equipment {
        get { Equipment(rawValue: equipmentRaw) ?? .other }
        set { equipmentRaw = newValue.rawValue }
    }

    public var loadDirection: LoadDirection {
        get { LoadDirection(rawValue: loadDirectionRaw) ?? .unknown }
        set { loadDirectionRaw = newValue.rawValue }
    }

    public var recordingMetric: RecordingMetric {
        get { RecordingMetric(rawValue: recordingMetricRaw) ?? .reps }
        set { recordingMetricRaw = newValue.rawValue }
    }

    public var discipline: ExerciseDiscipline {
        get { ExerciseDiscipline(rawValue: disciplineRaw) ?? .strength }
        set { disciplineRaw = newValue.rawValue }
    }

    /// Bilingual display form: Chinese name with the English name parenthesized
    /// in `zhHant`, English name with the Chinese name parenthesized in `en`
    /// (`L`/`LanguageContext`, see `AppLanguage.swift`). Falls back to plain
    /// `canonicalName` when `nameZh` hasn't been filled in yet (coach-created
    /// custom exercises) so nothing ever renders an empty pair of parens.
    public var displayName: String {
        guard !nameZh.isEmpty else { return canonicalName }
        return L("\(nameZh)（\(canonicalName)）", "\(canonicalName) (\(nameZh))")
    }

    /// Presentation pair for compact bilingual exercise-name stacks. The app
    /// language selects the prominent line while the other language remains a
    /// secondary aid. Empty and duplicate translations collapse to one line.
    public func localizedNamePair(for language: AppLanguage) -> (primary: String, secondary: String?) {
        let english = canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
        let chinese = nameZh.trimmingCharacters(in: .whitespacesAndNewlines)
        let primary = language == .zhHant
            ? (chinese.isEmpty ? english : chinese)
            : (english.isEmpty ? chinese : english)
        let alternate = language == .zhHant ? english : chinese
        return (primary, alternate.isEmpty || alternate == primary ? nil : alternate)
    }

    /// Single search-matching rule shared by every exercise picker/filter in
    /// the app (library list, merge-target picker, single-exercise query,
    /// add-exercise sheet). Before this, each screen re-implemented its own
    /// subset -- the library list and merge-target picker never checked
    /// `nameZh`, so a Chinese-only search term (like 阿諾德推舉's own Chinese
    /// name) found nothing there even though the same exercise turned up
    /// searching from the other two screens (2026-09-06 审查报告 #6).
    public func matches(searchText: String) -> Bool {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        return canonicalName.lowercased().contains(q)
            || nameZh.lowercased().contains(q)
            || aliases.contains { $0.lowercased().contains(q) }
    }
}

// NOTE ON `isBilateralLoad` (resolved, CONTRACT.md §13 item 9):
// 工程规划.md §3.2 named this as a "must-have" flag, but it was never in
// CONTRACT.md's Exercise schema. Flagged upstream; Opus's ruling (v2, §13
// item 9) confirmed it's redundant -- unilateral semantics are already
// carried by `isUnilateral` (this type) and `LoadValue.perSide` (per-set),
// and the field will not be introduced. Not present on this model.
