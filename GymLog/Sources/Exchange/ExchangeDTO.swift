import Foundation

/// Wire format for a coach/student exchange package (`.gymlogshare`,
/// `执行Prompt与实施计划.md` §5). Deliberately INDEPENDENT of `BackupDTO`
/// (§5.3: "建立獨立 Exchange DTO...不復用『全庫恢復』的破壞性行為") -- same
/// "mirror the model, don't reuse it" rationale as `BackupDTO` itself, plus
/// this format's own shape is genuinely different: it carries only ONE
/// client's data, only the exercises actually referenced, and a content
/// digest/record-identity header `BackupFile` has no concept of.
///
/// A package is either a **plan** (处方 only -- target values, no actual
/// results, no timers/completion state) or **results** (a fully-recorded
/// completed session). `ExchangeSetDTO.actual` is `nil` for `.plan`
/// packages and always present for `.results` packages -- the two payload
/// kinds share one DTO tree rather than forking it, since a plan is simply
/// a results package with every `actual` stripped.
public struct ExchangePackage: Codable {
    /// Bumped whenever a field is added/removed/reinterpreted in a way an
    /// older `ExchangeImporter` couldn't handle. A file whose version is
    /// NEWER than this app knows about is refused outright with an
    /// upgrade-needed message (§5.3: "未知新格式拒絕並提示升級") --  never
    /// silently misread.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    /// Unique per export action -- re-exporting the SAME sessions again
    /// (even completely unchanged) gets a fresh `packageID`. Re-sending the
    /// exact same package (same `packageID`) is naturally idempotent
    /// because every record inside it re-resolves to the same
    /// (`originInstallationID`, `recordID`, digest) triple `ExchangeImporter`
    /// already dedups on -- no separate packageID-level tracking needed.
    public var packageID: String
    /// UTC instant the package was built (§5.3: "傳輸時間用 UTC").
    public var createdAt: Date
    public var originInstallationID: String
    public var payloadKind: ExchangePayloadKind
    public var client: ExchangeClientRef
    public var sessions: [ExchangeSessionDTO]
    /// Only the exercises actually referenced by `sessions` (§5.3: "包內只
    /// 帶引用到的動作"), full snapshots for the importer to create if the
    /// receiving library doesn't already resolve the reference.
    public var exercises: [ExchangeExerciseSnapshot]
    /// SHA-256 over a canonical encoding of `sessions` + `exercises` only
    /// (excludes `packageID`/`createdAt`, see `ExchangeDigest`) -- lets a
    /// re-export of genuinely unchanged content be recognized as "same
    /// content, different package" rather than "changed." Integrity/dedup
    /// check only, never an authentication mechanism (§5.3).
    public var contentDigestSHA256: String

    public init(
        formatVersion: Int = ExchangePackage.currentFormatVersion, packageID: String, createdAt: Date,
        originInstallationID: String, payloadKind: ExchangePayloadKind, client: ExchangeClientRef,
        sessions: [ExchangeSessionDTO], exercises: [ExchangeExerciseSnapshot], contentDigestSHA256: String
    ) {
        self.formatVersion = formatVersion
        self.packageID = packageID
        self.createdAt = createdAt
        self.originInstallationID = originInstallationID
        self.payloadKind = payloadKind
        self.client = client
        self.sessions = sessions
        self.exercises = exercises
        self.contentDigestSHA256 = contentDigestSHA256
    }
}

public enum ExchangePayloadKind: String, Codable {
    case plan
    case results
}

/// Minimal学员 identity (§5.2: "分享預覽顯示學員...不夾帶其他學員、體測、
/// 聯繫方式或全部資料庫") -- name only, nothing else about the client rides
/// along in an exchange package.
public struct ExchangeClientRef: Codable, Equatable {
    /// Stable across every package the SENDING side ever exports for this
    /// client (generated once, see `ExchangeExporter.stableRemoteClientID`).
    /// This is what `ExchangeClientMapping` keys on, alongside
    /// `originInstallationID`, so a receiver's chosen mapping ("这个远程学员
    /// = 我这边的张三") survives across multiple future exchanges without
    /// re-asking every time (§5.3: "已有明確映射時可預選").
    public var remoteClientID: String
    public var displayName: String

    public init(remoteClientID: String, displayName: String) {
        self.remoteClientID = remoteClientID
        self.displayName = displayName
    }
}

public struct ExchangeSessionDTO: Codable, Equatable {
    /// The exporting side's own stable `WorkoutSession.id` -- already
    /// globally unique, so reused directly rather than inventing a second
    /// identity concept (§5.3: "計劃/結果有獨立穩定 recordID").
    public var recordID: String
    /// Present when this session's results were recorded against a plan
    /// imported from elsewhere -- that plan's own `recordID` (§5.3:
    /// "計劃執行結果攜帶 sourcePlanID 以供關聯").
    public var sourcePlanID: String?
    /// Local training day, `yyyy-MM-dd`, NOT a UTC instant (§5.3: "日期明確
    /// 存訓練當地日期和時區語義...不能按接收者時區移動訓練日").
    public var trainingLocalDate: String
    public var weekNumber: Int
    public var plannedDurationMinutes: Int?
    public var blocks: [ExchangeBlockDTO]

    public init(
        recordID: String, sourcePlanID: String?, trainingLocalDate: String, weekNumber: Int,
        plannedDurationMinutes: Int?, blocks: [ExchangeBlockDTO]
    ) {
        self.recordID = recordID
        self.sourcePlanID = sourcePlanID
        self.trainingLocalDate = trainingLocalDate
        self.weekNumber = weekNumber
        self.plannedDurationMinutes = plannedDurationMinutes
        self.blocks = blocks
    }
}

public struct ExchangeBlockDTO: Codable, Equatable {
    public var order: Int
    public var blockType: BlockType
    public var restSeconds: Int?
    public var sectionKind: SectionKind
    public var entries: [ExchangeEntryDTO]
    /// Raw JSON passthrough, same mechanism as
    /// `SessionBlockBackupDTO.wodPayloadRawJSON` -- an exchange package
    /// built by a NEWER app version carrying a WOD payload shape this one
    /// doesn't understand still round-trips byte-for-byte instead of
    /// dropping fields (§5.3: "未知 WOD 負載若能原樣保留則只讀").
    public var wodPayloadRawJSON: String?

    public init(order: Int, blockType: BlockType, restSeconds: Int?, sectionKind: SectionKind, entries: [ExchangeEntryDTO], wodPayloadRawJSON: String?) {
        self.order = order
        self.blockType = blockType
        self.restSeconds = restSeconds
        self.sectionKind = sectionKind
        self.entries = entries
        self.wodPayloadRawJSON = wodPayloadRawJSON
    }
}

public struct ExchangeEntryDTO: Codable, Equatable {
    public var order: Int
    public var exerciseRef: ExchangeExerciseRef
    public var plannedSets: Int
    public var sets: [ExchangeSetDTO]

    public init(order: Int, exerciseRef: ExchangeExerciseRef, plannedSets: Int, sets: [ExchangeSetDTO]) {
        self.order = order
        self.exerciseRef = exerciseRef
        self.plannedSets = plannedSets
        self.sets = sets
    }
}

/// What `ExchangeImporter` needs to resolve an exercise reference without
/// ever silently merging two exercises that only coincidentally share a
/// name (§5.3: "自定義同名不同單位不可自動合併"). `id` matches directly
/// against the receiver's own library first -- reliable for every built-in
/// exercise, since the bundled seed library is identical across installs
/// (same `exercise_library_seed.json`, see `ContentView.importFixtureIfNeeded`).
/// Only custom (coach-added) exercises can miss on `id` and fall back to
/// `canonicalName` + `recordingMetric` matching, or -- failing that --
/// the importer offers to create a new exercise from `ExchangeExerciseSnapshot`.
public struct ExchangeExerciseRef: Codable, Equatable {
    public var exerciseID: String
    public var canonicalName: String
    public var nameZh: String
    public var recordingMetric: RecordingMetric
    public var equipment: Equipment

    public init(exerciseID: String, canonicalName: String, nameZh: String, recordingMetric: RecordingMetric, equipment: Equipment) {
        self.exerciseID = exerciseID
        self.canonicalName = canonicalName
        self.nameZh = nameZh
        self.recordingMetric = recordingMetric
        self.equipment = equipment
    }
}

public struct ExchangeSetDTO: Codable, Equatable {
    public var setIndex: Int
    public var load: LoadValue
    public var target: RepTarget
    /// `nil` for a `.plan` package (never recorded); always present for a
    /// `.results` package.
    public var actual: RepTarget?

    public init(setIndex: Int, load: LoadValue, target: RepTarget, actual: RepTarget?) {
        self.setIndex = setIndex
        self.load = load
        self.target = target
        self.actual = actual
    }
}

/// Full snapshot of one referenced exercise -- only used by the importer
/// when `ExchangeExerciseRef` doesn't resolve against the local library, to
/// create a new exercise that preserves the sender's original name/unit
/// (§5.3: "不能匹配時預覽新建或人工選擇，保留來源名稱/單位快照").
public struct ExchangeExerciseSnapshot: Codable, Equatable {
    public var id: String
    public var canonicalName: String
    public var nameZh: String
    public var aliases: [String]
    public var movementPattern: MovementPattern
    public var equipment: Equipment
    public var recordingMetric: RecordingMetric
    public var discipline: ExerciseDiscipline
    public var loadDirection: LoadDirection
    public var isUnilateral: Bool

    public init(
        id: String, canonicalName: String, nameZh: String, aliases: [String], movementPattern: MovementPattern,
        equipment: Equipment, recordingMetric: RecordingMetric, discipline: ExerciseDiscipline,
        loadDirection: LoadDirection, isUnilateral: Bool
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.nameZh = nameZh
        self.aliases = aliases
        self.movementPattern = movementPattern
        self.equipment = equipment
        self.recordingMetric = recordingMetric
        self.discipline = discipline
        self.loadDirection = loadDirection
        self.isUnilateral = isUnilateral
    }
}
