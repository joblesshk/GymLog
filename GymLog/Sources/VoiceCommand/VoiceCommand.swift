import Foundation

/// P3/M3a (2026-09-12): the whitelist of typed commands `VoiceCommandParser`
/// can produce -- 執行Prompt與實施計劃.md §6.2's exact 6-command first-version
/// set. The parser can only ever CONSTRUCT one of these cases (or fail with
/// `.needsClarification`/`.rejected`, see `VoiceCommandParser.swift`); there
/// is no "run arbitrary code/query" case, satisfying §6.2's "模型只生成白名單
/// 命令，無任意數據庫/代碼執行能力" structurally, not by convention.
public enum VoiceCommandKind: Equatable {
    /// "添加深蹲，三組，每組十次，四十公斤" -- 添加庫內動作.
    case addExercise(AddExercisePayload)
    /// "把第一個動作換成硬舉" -- 替換指定動作.
    case replaceExercise(ReplaceExercisePayload)
    /// "臥推改成三組十二次" (no 實際/完成了 keyword) -- 設置計劃組數/目標/重量.
    case setPlan(SetPlanPayload)
    /// "把臥推第二組實際次數改為八次" -- 修改指定組的實際次數/時間/距離.
    case setActual(SetActualPayload)
    /// "把第一個超級組的休息改為九十秒" -- 設置 Superset 輪間休息.
    case setSupersetRest(SetSupersetRestPayload)
    /// "撤銷剛才的修改" -- 撤銷上一條語音操作.
    case undoLastVoiceCommand
}

public struct AddExercisePayload: Equatable {
    public let exerciseSpokenName: String
    public let setsCount: Int?
    public let targetQuantity: Int?
    /// 2026-09-13 修正：跟 `SetPlanPayload`/`SetActualPayload` 現在是同一條
    /// 規則──不符就拒絕，不靜默沿用默認值。舊行為（新增動作沒有既有數據
    /// 可能被寫錯，所以放行、沿用 prefill 默認值）看似安全，實際上使用者
    /// 會聽到「已添加」卻不知道自己口述的數字被悄悄丟掉，跟計劃書「不可
    /// 忽略口述後提示成功」的要求衝突。
    public let spokenMetricForTargetQuantity: RecordingMetric?
    public let load: LoadValue?

    public init(exerciseSpokenName: String, setsCount: Int? = nil, targetQuantity: Int? = nil, spokenMetricForTargetQuantity: RecordingMetric? = nil, load: LoadValue? = nil) {
        self.exerciseSpokenName = exerciseSpokenName
        self.setsCount = setsCount
        self.targetQuantity = targetQuantity
        self.spokenMetricForTargetQuantity = spokenMetricForTargetQuantity
        self.load = load
    }
}

public struct ReplaceExercisePayload: Equatable {
    public let target: ExerciseTargetSpec
    public let newExerciseSpokenName: String

    public init(target: ExerciseTargetSpec, newExerciseSpokenName: String) {
        self.target = target
        self.newExerciseSpokenName = newExerciseSpokenName
    }
}

/// §6.2: "默認『做三組十次』是計劃" -- this payload never carries an `actual`
/// field at all, so there is no way for the parser to accidentally write a
/// plan-only command into recorded results.
public struct SetPlanPayload: Equatable {
    public let target: ExerciseTargetSpec
    public let setsCount: Int?
    public let targetQuantity: Int?
    /// The unit DIMENSION the spoken `targetQuantity` implies (e.g. "十次"
    /// -> `.reps`, "三十秒" -> `.time`) -- `nil` only when `targetQuantity`
    /// itself is `nil` (no quantity was spoken at all, e.g. "把臥推改成三
    /// 組" only changes the set count). Checked against the resolved
    /// entry's actual `Exercise.recordingMetric` before applying; a
    /// mismatch is rejected, never silently reinterpreted under a
    /// different unit (§6.2's explicit requirement).
    public let spokenMetricForTargetQuantity: RecordingMetric?
    public let load: LoadValue?

    public init(target: ExerciseTargetSpec, setsCount: Int? = nil, targetQuantity: Int? = nil, spokenMetricForTargetQuantity: RecordingMetric? = nil, load: LoadValue? = nil) {
        self.target = target
        self.setsCount = setsCount
        self.targetQuantity = targetQuantity
        self.spokenMetricForTargetQuantity = spokenMetricForTargetQuantity
        self.load = load
    }
}

public struct SetActualPayload: Equatable {
    public let target: ExerciseTargetSpec
    /// 1-based, across the WHOLE entry in `resolvedSets()` order -- "第二組"
    /// means physical set 2, never RoundDraft index 2 (§6.2's explicit
    /// requirement; see `EntryDraft.splitRound(atPhysicalSetIndex:)`). `nil`
    /// = the utterance didn't name which set -- always `.needsClarification`,
    /// this payload is never constructed with a guessed index.
    public let physicalSetIndex: Int?
    public let actualQuantity: Int
    /// Same role as `SetPlanPayload.spokenMetricForTargetQuantity`, but
    /// never `nil` here -- `setActual` always names a quantity (that's the
    /// whole point of the command), so there's always a unit to check.
    public let spokenMetric: RecordingMetric

    public init(target: ExerciseTargetSpec, physicalSetIndex: Int?, actualQuantity: Int, spokenMetric: RecordingMetric) {
        self.target = target
        self.physicalSetIndex = physicalSetIndex
        self.actualQuantity = actualQuantity
        self.spokenMetric = spokenMetric
    }
}

public struct SetSupersetRestPayload: Equatable {
    /// "第一個超級組" -> 1; `nil` = unspecified, resolved against however many
    /// supersets exist in the draft right now (exactly one -> use it; 0 or
    /// 2+ -> clarify, see `VoiceCommandTargetResolver`).
    public let supersetOrdinal: Int?
    public let restSeconds: Int

    public init(supersetOrdinal: Int?, restSeconds: Int) {
        self.supersetOrdinal = supersetOrdinal
        self.restSeconds = restSeconds
    }
}

/// Envelope every command travels in through `VoiceCommandService` -- carries
/// the identity/staleness fields §6.2/§6.3 require alongside the parsed
/// `kind`'s own target/field/value/unit payload.
public struct VoiceCommandRequest: Equatable {
    /// §6.3: "同一請求ID至多執行一次" -- idempotency key. `VoiceCommandService`
    /// refuses to apply the same `requestID` twice.
    public let requestID: UUID
    public let rawText: String
    public let issuedAt: Date
    public let kind: VoiceCommandKind
    /// Captured at the moment the command was ISSUED (§6.3: "開始錄音捕獲
    /// 當前學員/課次/草稿版本") -- re-checked against the draft's CURRENT
    /// token immediately before applying; a mismatch means the draft changed
    /// (a manual edit, or a prior command) since this request was issued,
    /// and the command is refused rather than written against a stale
    /// target. See `DraftRevisionToken`.
    public let contextToken: DraftRevisionToken

    public init(requestID: UUID = UUID(), rawText: String, issuedAt: Date = Date(), kind: VoiceCommandKind, contextToken: DraftRevisionToken) {
        self.requestID = requestID
        self.rawText = rawText
        self.issuedAt = issuedAt
        self.kind = kind
        self.contextToken = contextToken
    }
}
