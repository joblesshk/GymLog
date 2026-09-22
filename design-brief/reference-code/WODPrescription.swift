import Foundation

/// The four first-version WOD formats (工程审阅与CrossFit适配方案.md §5.1's
/// table). `.unknown` is a decode-safety fallback only, same convention as
/// every other classification enum in this app (`BlockType`, `RecordingMetric`, …).
public enum WODFormat: String, Codable, CaseIterable, Sendable {
    case amrap
    case forTime
    case emom
    /// Generic work/rest intervals -- covers "20s/10s×8"-style presets
    /// without hardcoding Tabata's specific scoring rule to this format.
    case interval
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = WODFormat(rawValue: raw) ?? .unknown
    }

    public var displayName: String {
        switch self {
        case .amrap: return "AMRAP"
        case .forTime: return L("計時完成", "For Time")
        case .emom: return "EMOM"
        case .interval: return L("間歇", "Interval")
        case .unknown: return L("未知形式", "Unknown Format")
        }
    }
}

/// How two results of the SAME prescription revision compare -- deliberately
/// separate from `LoadDirection` (a strength-exercise concept keyed off a
/// single load number): a WOD's "better" depends on its FORMAT, not a load.
/// `AnalyticsMath`/PR logic for WODs (M3) must dispatch on this, never
/// assume "bigger number wins" the way `LoadDirection.higherIsStronger` does
/// for weight (工程审阅 §5.3: "計時越小越好，AMRAP完整輪數再比較剩餘進度...
/// 不預設統一'越多越好'").
public enum WODScoringRule: String, Codable, CaseIterable, Sendable {
    /// For Time: lower `WODResult.elapsedSeconds` is better.
    case completionTime
    /// AMRAP: more `completedRounds` is better; ties break on
    /// `partialRoundQuantity`.
    case roundsAndReps
    /// Interval/Tabata scored by total work across all intervals: higher
    /// `WODResult.typedTotals` sum is better.
    case totalQuantity
    /// Interval/Tabata scored by the WORST single interval (classic Tabata
    /// scoring): higher `WODResult.intervalResults`' minimum is better.
    case worstInterval
    /// No defined automatic comparison -- results are recorded but not
    /// ranked against each other by this app.
    case manual
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = WODScoringRule(rawValue: raw) ?? .unknown
    }
}

/// One movement's prescribed parameters within a round. `exerciseID` is
/// optional and `exerciseNameSnapshot` is always captured verbatim
/// (工程审阅 §5.2's `WODMovement`: "動作名快照... 歷史不能依賴最新庫名才能解釋")
/// -- a later exercise-library rename/merge must never change what an old
/// WOD's history displays.
public struct WODMovementPrescription: Codable, Equatable, Sendable {
    public var stepID: String
    public var exerciseID: String?
    public var exerciseNameSnapshot: String
    public var quantity: WorkoutQuantity
    /// Prescribed load, if any -- reuses `LoadValue` (kg/lb, bodyweight,
    /// etc.) rather than inventing a parallel type, per 工程审阅 §5.3's
    /// "優先保持舊LoadValue和RepTarget讀取兼容".
    public var load: LoadValue?
    /// Number of implements, e.g. two dumbbells vs one (工程审阅 §5.3:
    /// "雙啞鈴數量及單隻重量不丟"). `nil` when not applicable.
    public var equipmentCount: Int?
    /// Box/target height in cm, when relevant (box jump, wall ball target).
    public var heightCm: Double?
    /// Free-text standard/variant note (e.g. "chest-to-bar", "24in box",
    /// "20lb ball to 10ft").
    public var standard: String?

    public init(
        stepID: String, exerciseID: String?, exerciseNameSnapshot: String, quantity: WorkoutQuantity,
        load: LoadValue? = nil, equipmentCount: Int? = nil, heightCm: Double? = nil, standard: String? = nil
    ) {
        self.stepID = stepID
        self.exerciseID = exerciseID
        self.exerciseNameSnapshot = exerciseNameSnapshot
        self.quantity = quantity
        self.load = load
        self.equipmentCount = equipmentCount
        self.heightCm = heightCm
        self.standard = standard
    }
}

/// One ordered "round" of the prescription -- e.g. 21-15-9's three rounds
/// each carry the same movements at a different `quantity`; a plain AMRAP's
/// single round template is what repeats each time through the clock.
/// Deliberately NOT the same type as the legacy `RoundDraft` (a strength
/// entry's repeated parameter-group, capped at 4) -- CrossFit rounds carry
/// no such cap and mean something structurally different (工程审阅 §2/§5.1).
public struct WODRoundPrescription: Codable, Equatable, Sendable {
    public var roundIndex: Int
    public var movements: [WODMovementPrescription]

    public init(roundIndex: Int, movements: [WODMovementPrescription]) {
        self.roundIndex = roundIndex
        self.movements = movements
    }
}

/// The full WOD plan -- what was PRESCRIBED, independent of what actually
/// happened (`WODResult`). `revision` bumps whenever the coach meaningfully
/// edits an existing prescription (weight, movement, time cap, …); a saved
/// historical result always keeps the prescription snapshot it was recorded
/// against, so editing a template/prescription later can never rewrite a
/// past result's meaning (工程审阅 §5.2: "已存歷史必須保存處方快照").
public struct WODPrescription: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Stable across revisions -- identifies "the same WOD" (e.g. for
    /// same-standard retest comparisons); `revision` distinguishes versions
    /// of it.
    public var id: String
    public var revision: Int
    /// Optional display name (a saved template's name, or a benchmark-style
    /// name the coach typed in) -- benchmark names like "Fran"/"Cindy" are
    /// template names, never `Exercise` rows (工程审阅 §6/§5.1).
    public var name: String?
    public var format: WODFormat
    /// AMRAP's duration, or For Time's optional cap.
    public var timeCapSeconds: Int?
    /// EMOM/interval: length of each work interval, in seconds (Tabata's
    /// "20" in 20s/10s×8).
    public var intervalSeconds: Int?
    /// Interval: rest between work periods, in seconds (Tabata's "10").
    /// `nil` for EMOM (whose "rest" is just "whatever's left of the minute
    /// after the prescribed work" -- not a separately-timed phase).
    public var restSeconds: Int?
    /// EMOM/interval: total number of intervals (Tabata's "8").
    public var intervalCount: Int?
    /// Ordered rounds; for AMRAP this is the single repeating template
    /// (`rounds.count == 1`), for EMOM/interval this is the ordered station
    /// cycle, for For Time it's the ordered task list (one round unless the
    /// prescription is explicitly multi-round like 21-15-9).
    public var rounds: [WODRoundPrescription]
    public var scoringRule: WODScoringRule
    /// Free-text standard/source reference (e.g. "2026 Open 26.1 standards"),
    /// never a hardcoded competition ruleset (工程审阅 §5.1: "保留標準與
    /// tiebreak字段，不硬編碼某一賽事規則").
    public var standardNotes: String?

    public init(
        schemaVersion: Int = WODPrescription.currentSchemaVersion, id: String, revision: Int, name: String? = nil,
        format: WODFormat, timeCapSeconds: Int? = nil, intervalSeconds: Int? = nil, restSeconds: Int? = nil,
        intervalCount: Int? = nil, rounds: [WODRoundPrescription], scoringRule: WODScoringRule, standardNotes: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.revision = revision
        self.name = name
        self.format = format
        self.timeCapSeconds = timeCapSeconds
        self.intervalSeconds = intervalSeconds
        self.restSeconds = restSeconds
        self.intervalCount = intervalCount
        self.rounds = rounds
        self.scoringRule = scoringRule
        self.standardNotes = standardNotes
    }
}
