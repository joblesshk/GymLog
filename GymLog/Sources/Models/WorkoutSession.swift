import Foundation
import SwiftData

/// CONTRACT.md §5. A single training session on the client's unified
/// timeline (source `Full body` / `Full body 2` sheets merged).
@Model
public final class WorkoutSession {
    @Attribute(.unique) public var id: String
    public var date: Date
    private var dateOriginRaw: String
    /// Original cell text, verbatim, never dropped (CONTRACT.md §11.5).
    public var dateRaw: String
    public var weekNumber: Int
    public var sourceSheet: String
    public var sourceRow: Int
    public var warmup: String?
    public var warmupNote: String?
    public var cooldown: String?
    public var cooldownNote: String?
    /// CONTRACT.md §5 (v2): carries the §8.1 date-anomaly marking
    /// requirement (e.g. the one known-exception out-of-order date).
    public var needsReview: Bool
    public var reviewReason: String?

    /// CONTRACT-M5.md §3.1: "训练持续时间，默认 1 小时，必须可以修改". Optional
    /// so existing/migrated sessions (124 real sessions, none of which
    /// recorded a duration) stay `nil` rather than being backfilled with a
    /// fabricated value -- `nil` means "not recorded", not "zero minutes".
    /// The 60-minute default lives in the UI layer (`TodayDraftStore`), not
    /// here, so this column's meaning stays "what the coach actually set".
    public var insightJSON: String?
    public var plannedDurationMinutes: Int?

    /// 2026-09-09 教练要求：「暫時保存」和「結束課次存入歷史記錄」要同时存在。
    /// `true` 表示这堂课已经落库、但教练还没按「結束課次」——记录随时可以从
    /// 歷史点回「今天」继续录，而不是只活在内存草稿里。
    ///
    /// 字面量 `= false` 默认值 -> 这个字段出现之前建立的每一行（导入的 124 节
    /// 真实课次、Excel 导入、备份还原）都通过 SwiftData 轻量迁移拿到 `false`
    /// ——「已完成」，与它们的实际状态一致。同 `Exercise.recordingMetric` /
    /// `SessionBlock.sectionKind` 的先例。
    public var isInProgress: Bool = false

    /// M7 §3.8: Excel incremental-import provenance and dedup digests. The
    /// four are written together by `XLSXHistoryImporter`, or all left
    /// `nil` together (seed import / a session created directly in the
    /// app) -- never a partial set. `nil` on all four is itself meaningful:
    /// §3.8.4's dedup matrix treats "no digest on record" as "unknown
    /// origin, never touch it," which is exactly the seed-imported 124
    /// sessions' correct behavior on first Excel import.
    public var importSourceFile: String?
    public var importedAt: Date?
    /// SHA-256 of the session's raw source-cell text (`SessionDigest.sourceDigest`).
    public var sourceDigest: String?
    /// SHA-256 of the persisted object graph at import time (`SessionDigest.importDigest`).
    public var importDigest: String?

    /// P2 (2026-09-11): coach/student exchange provenance -- same "written
    /// together or all left `nil`" convention as the Excel-import digest
    /// quartet above. `nil` on all four means "never touched by an exchange
    /// import," which is the correct state for every session that predates
    /// this feature or was created directly in the app. See
    /// `ExchangeImporter` for how these are used to detect an idempotent
    /// re-import (same `exchangeOriginInstallationID` + `exchangeRecordID` +
    /// unchanged `exchangeContentDigestSHA256`) vs. a content-changed record
    /// (same origin+record, different digest -- kept local by default, see
    /// `执行Prompt与实施计划.md` §5.3).
    public var exchangeOriginInstallationID: String?
    /// The `ExchangeSessionDTO.recordID` that created/last confirmed this
    /// row -- on the exporting side this is simply that side's own stable
    /// `WorkoutSession.id`, carried through unchanged on import.
    public var exchangeRecordID: String?
    public var exchangeContentDigestSHA256: String?
    /// The `packageID` of the last exchange package that wrote this row --
    /// traceability only, not used for dedup logic itself.
    public var exchangePackageID: String?
    /// Set when this session's results were recorded against a plan
    /// imported from someone else -- the `recordID` of that plan session,
    /// so a coach can later tell "this result traces back to which plan I
    /// sent." `nil` for a session that didn't originate from an imported
    /// plan.
    public var sourcePlanID: String?

    public var client: Client?

    @Relationship(deleteRule: .cascade, inverse: \SessionBlock.session)
    public var blocks: [SessionBlock]? = []

    public init(
        id: String,
        date: Date,
        dateOrigin: DateOrigin,
        dateRaw: String,
        weekNumber: Int,
        sourceSheet: String,
        sourceRow: Int,
        needsReview: Bool = false,
        reviewReason: String? = nil,
        warmup: String? = nil,
        warmupNote: String? = nil,
        cooldown: String? = nil,
        cooldownNote: String? = nil,
        plannedDurationMinutes: Int? = nil,
        isInProgress: Bool = false,
        exchangeOriginInstallationID: String? = nil,
        exchangeRecordID: String? = nil,
        exchangeContentDigestSHA256: String? = nil,
        exchangePackageID: String? = nil,
        sourcePlanID: String? = nil
    ) {
        self.id = id
        self.date = date
        self.dateOriginRaw = dateOrigin.rawValue
        self.dateRaw = dateRaw
        self.weekNumber = weekNumber
        self.sourceSheet = sourceSheet
        self.sourceRow = sourceRow
        self.needsReview = needsReview
        self.reviewReason = reviewReason
        self.warmup = warmup
        self.warmupNote = warmupNote
        self.cooldown = cooldown
        self.cooldownNote = cooldownNote
        self.plannedDurationMinutes = plannedDurationMinutes
        self.isInProgress = isInProgress
        self.exchangeOriginInstallationID = exchangeOriginInstallationID
        self.exchangeRecordID = exchangeRecordID
        self.exchangeContentDigestSHA256 = exchangeContentDigestSHA256
        self.exchangePackageID = exchangePackageID
        self.sourcePlanID = sourcePlanID
    }

    public var dateOrigin: DateOrigin {
        get { DateOrigin(rawValue: dateOriginRaw) ?? .unknown }
        set { dateOriginRaw = newValue.rawValue }
    }

    /// Blocks in their recorded order, for stable display.
    public var orderedBlocks: [SessionBlock] {
        (blocks ?? []).sorted { $0.order < $1.order }
    }
}

// Declared here (in the module that defines WorkoutSession) rather than in
// the UI layer, so this isn't a cross-module retroactive conformance.
extension WorkoutSession: Identifiable {}
