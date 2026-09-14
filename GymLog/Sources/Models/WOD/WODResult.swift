import Foundation

/// Explicit completion state -- 工程审阅 §5.2's `WODResult`: "不要用0同時表示
/// 未記錄、失敗和沒做". A fresh WOD always starts `.notRecorded`; the app must
/// never default an unstarted result to `.completed` with zeroed fields.
public enum WODResultStatus: String, Codable, CaseIterable, Sendable {
    case notRecorded
    case completed
    /// Time cap reached before finishing (For Time) -- keeps whatever
    /// progress was captured (`WODResult.cappedProgress`), never presented
    /// as if it were a completion time (工程审阅's B03-adjacent rule:
    /// "12分鐘cap，停在某動作第7次" 不得顯示為 "12:00完賽 PR").
    case capped
    /// Manually ended before either finishing or hitting a cap (injury,
    /// time constraints, etc.) -- same "keep the partial progress, don't
    /// pretend it's a finish" treatment as `.capped`.
    case stopped
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = WODResultStatus(rawValue: raw) ?? .unknown
    }
}

/// Rx is relative to a specific prescription revision, never a permanent
/// property of an exercise and never inferred from the athlete's sex
/// (工程审阅 §5.3: "Rx相對於某個明確處方版本...不按學員性別自動推斷").
public enum WODVariant: Codable, Equatable, Hashable, Sendable {
    case rx
    case scaled
    case custom(String)
    case unknown

    private enum CodingKeys: String, CodingKey { case kind, label }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? container.decode(String.self, forKey: .kind)) ?? "unknown"
        switch kind {
        case "rx": self = .rx
        case "scaled": self = .scaled
        case "custom":
            self = .custom((try? container.decode(String.self, forKey: .label)) ?? "")
        default: self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .rx: try container.encode("rx", forKey: .kind)
        case .scaled: try container.encode("scaled", forKey: .kind)
        case .custom(let label):
            try container.encode("custom", forKey: .kind)
            try container.encode(label, forKey: .label)
        case .unknown: try container.encode("unknown", forKey: .kind)
        }
    }

    public var displayName: String {
        switch self {
        case .rx: return "Rx"
        case .scaled: return L("Scaled（調整版）", "Scaled")
        case .custom(let label): return label.isEmpty ? L("自訂版", "Custom") : label
        case .unknown: return L("未指定", "Unspecified")
        }
    }
}

/// One interval's outcome (EMOM/interval formats). `completedQuantity ==
/// nil` means "not recorded for this interval" -- distinct from a recorded
/// zero, and distinct from a skipped interval (工程审阅 §4's EMOM row:
/// "每段完成/未完成/跳過").
public struct WODIntervalResult: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case completed
        case incomplete
        case skipped
        case notRecorded
    }

    public var intervalIndex: Int
    public var outcome: Outcome
    public var completedQuantity: WorkoutQuantity?

    public init(intervalIndex: Int, outcome: Outcome, completedQuantity: WorkoutQuantity? = nil) {
        self.intervalIndex = intervalIndex
        self.outcome = outcome
        self.completedQuantity = completedQuantity
    }
}

/// Where the recorded values came from -- a live timer run, or entered by
/// hand after the fact. Both are first-class (工程审阅 §4: "現場計時與訓練後
/// 補錄並存"); this is provenance only, not a validity judgment.
public enum WODRecordingSource: String, Codable, Sendable {
    case manual
    case timer
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = WODRecordingSource(rawValue: raw) ?? .unknown
    }
}

/// The actual outcome of one WOD attempt. Always paired with the exact
/// `WODPrescription` (snapshot) it was recorded against -- see
/// `WODPayload`.
public struct WODResult: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var status: WODResultStatus
    /// For Time: total elapsed seconds to finish. `nil` unless `status ==
    /// .completed`.
    public var elapsedSeconds: Int?
    /// AMRAP: number of FULLY completed rounds.
    public var completedRounds: Int?
    /// AMRAP: progress into the round after `completedRounds` -- e.g. "5
    /// rounds + 12 reps" is `completedRounds: 5, partialRoundQuantity:
    /// .reps(12, ...)`. Two integers, never a decimal "5.12" (工程审阅 §5.1:
    /// "'5+12'是兩個整數，不是5.12輪").
    public var partialRoundQuantity: WorkoutQuantity?
    /// For a capped/stopped For Time attempt (or a partially-completed
    /// task list), which step/round progress had reached -- kept instead of
    /// pretending a cap time is a finish time.
    public var cappedAtStepID: String?
    public var cappedProgress: WorkoutQuantity?
    /// EMOM/interval: per-interval outcomes, in interval order.
    public var intervalResults: [WODIntervalResult]
    /// Interval/Tabata total-quantity scoring: summed completed quantity
    /// PER movement type (never merging distinct units -- e.g. a rowing+
    /// wall-ball interval keeps separate meters and reps totals, matching
    /// `WorkoutQuantity`'s own no-cross-unit-conversion rule).
    public var typedTotals: [WorkoutQuantity]
    public var variant: WODVariant
    /// Actual movements/loads/equipment, when they differ from the
    /// prescription (substitution, reduced weight, etc.) -- `nil` entries
    /// mean "as prescribed". Never empty-vs-nil-ambiguous: an empty array
    /// means "no substitutions", not "not recorded".
    public var actualMovements: [WODMovementPrescription]
    public var notes: String?
    public var rpe: Double?
    public var recordedVia: WODRecordingSource

    public init(
        schemaVersion: Int = WODResult.currentSchemaVersion, status: WODResultStatus = .notRecorded,
        elapsedSeconds: Int? = nil, completedRounds: Int? = nil, partialRoundQuantity: WorkoutQuantity? = nil,
        cappedAtStepID: String? = nil, cappedProgress: WorkoutQuantity? = nil,
        intervalResults: [WODIntervalResult] = [], typedTotals: [WorkoutQuantity] = [],
        variant: WODVariant = .unknown, actualMovements: [WODMovementPrescription] = [],
        notes: String? = nil, rpe: Double? = nil, recordedVia: WODRecordingSource = .unknown
    ) {
        self.schemaVersion = schemaVersion
        self.status = status
        self.elapsedSeconds = elapsedSeconds
        self.completedRounds = completedRounds
        self.partialRoundQuantity = partialRoundQuantity
        self.cappedAtStepID = cappedAtStepID
        self.cappedProgress = cappedProgress
        self.intervalResults = intervalResults
        self.typedTotals = typedTotals
        self.variant = variant
        self.actualMovements = actualMovements
        self.notes = notes
        self.rpe = rpe
        self.recordedVia = recordedVia
    }
}
