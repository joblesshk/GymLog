import Foundation
import SwiftData

/// A comparable "has anything in the draft changed" token -- wraps the
/// existing `TodayDraftSnapshot`/`Codable`/`Equatable` machinery (the same
/// shape crash-recovery autosave already uses, `TodayDraftSnapshot.swift`)
/// rather than a literal monotonic counter threaded through every UI
/// mutation site (that would mean touching ~12 existing, already-tested
/// view files for a correctness property M3a's synchronous text-entry flow
/// barely exercises). Coarser than a true per-field counter -- ANY manual
/// edit anywhere in today's draft invalidates a pending token, not just an
/// edit to the same target -- a conscious trade-off for M3a; revisit once
/// M3b's real multi-second recording window makes that gap more visible.
public struct DraftRevisionToken: Equatable {
    fileprivate let normalizedSnapshot: TodayDraftSnapshot?
    fileprivate init(normalizedSnapshot: TodayDraftSnapshot?) {
        self.normalizedSnapshot = normalizedSnapshot
    }
}

extension TodayDraftStore {
    /// `snapshot()` stamps `savedAt: Date()` fresh on every call -- comparing
    /// two raw snapshots would always differ even when nothing about the
    /// draft's actual CONTENT changed between calls. Normalizing `savedAt`
    /// to a fixed value before wrapping it is what makes this token usable
    /// as an equality-based "did anything change" check.
    public func currentRevisionToken() -> DraftRevisionToken {
        var snap = snapshot()
        snap?.savedAt = Date(timeIntervalSince1970: 0)
        return DraftRevisionToken(normalizedSnapshot: snap)
    }
}

/// 真機測試時發現的真實可用性問題：歧義澄清原本只把候選名字接成一串純
/// 文字丟給用戶看，使用者得自己重新完整打一遍/念一遍某個候選的精確名字
/// 才能繼續──語音輸入的意義因此被打掉大半。`VoiceCommandLibraryResolver`/
/// `VoiceCommandTargetResolver` 其實已經算出了每個候選的精確身份
/// （`Exercise.id`、或 `blockID`+`entryID`），只是被 `.map(\.canonicalName)`
/// 這一步丟掉了。這裡把身份保留下來，UI 才能把候選做成可以直接點的按鈕。
public struct ClarificationCandidate: Equatable, Identifiable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// 使用者明確點選某個候選之後，還缺哪些欄位才能完成原本那條命令──candidate
/// 已經是唯一、明確指定的了，接下來只是把原本命令的「其他」欄位（組數/
/// 數值/單位……）套用上去，不再有任何猜測的空間。`chosenCandidateID` 落在
/// 哪個 id 空間（`Exercise.id` 或 entry 的 `UUID`）由這裡的 case 決定，
/// `applyClarifiedChoice` 據此決定要去哪張表查。
public enum PendingClarification: Equatable {
    case addExercise(AddExercisePayload)
    case replaceExerciseOldTarget(newExerciseSpokenName: String, forceApply: Bool)
    case replaceExerciseNewExercise(blockID: UUID, entryID: UUID, forceApply: Bool)
    case setPlanTarget(SetPlanPayload)
    case setActualTarget(SetActualPayload)
}

public enum VoiceCommandOutcome: Equatable {
    case applied(summary: String, canUndo: Bool)
    /// §6.3: 批量覆蓋/刪除已有實際數據/歧義/單位衝突需要預覽確認 -- currently
    /// only `replaceExercise` onto an entry with already-recorded results
    /// reaches this. Re-issue the SAME request with `forceApply: true` to
    /// proceed.
    case needsPreviewConfirm(summary: String)
    /// `candidates`/`pending` are both non-empty/non-nil ONLY when the
    /// clarification is "which exercise did you mean" (i.e. it came from
    /// `VoiceCommandLibraryResolver`/`VoiceCommandTargetResolver`'s
    /// `.ambiguous` case) -- UI can render those as tap-to-resolve buttons
    /// via `applyClarifiedChoice`. Every other clarification reason
    /// (missing set index, no reliable context, parse-level failures before
    /// any resolution ran) has no candidate to offer, same as before this
    /// mechanism existed.
    case needsClarification(reason: ClarificationReason, candidates: [ClarificationCandidate], pending: PendingClarification?)
    case rejected(reason: String)
    /// The draft changed (a manual edit, or a prior command) between when
    /// this request's `contextToken` was captured and when it was applied.
    case staleDraft
}

/// P3/M3a (2026-09-12): orchestrates parse → resolve target → staleness
/// check → apply → undo for the 6 whitelisted voice commands
/// (`VoiceCommand.swift`). One instance is scoped to one active "今天"
/// draft session (holds exactly one undo slot + the last-applied request id
/// for idempotent replay) -- a fresh instance per session is the caller's
/// responsibility, same as `TodayDraftStore` itself.
@MainActor
public final class VoiceCommandService {
    private struct UndoSlot {
        let summary: String
        let revert: (TodayDraftStore) -> Void
    }

    private var undoSlot: UndoSlot?
    private var lastAppliedRequestID: UUID?
    private var lastAppliedOutcome: VoiceCommandOutcome?

    public init() {}

    public var canUndo: Bool { undoSlot != nil }

    /// Parses `rawText` and captures the draft's CURRENT revision token --
    /// the "開始錄音捕獲當前學員/課次/草稿版本" moment (§6.3). For M3a's
    /// synchronous text-entry flow this happens immediately before `apply`
    /// in the same call (via `execute`); exposed separately so a test (or a
    /// future M3b flow with a real gap between "issued" and "applied") can
    /// mutate the draft in between and exercise `.staleDraft` deliberately.
    public func makeRequest(rawText: String, draft: TodayDraftStore) -> VoiceCommandRequest? {
        guard case .recognized(let kind) = VoiceCommandParser.parse(rawText) else { return nil }
        return VoiceCommandRequest(rawText: rawText, kind: kind, contextToken: draft.currentRevisionToken())
    }

    /// P3/M3b (2026-09-12)：真實錄音的版本——語音"開始錄音"到"最終辨識結果
    /// 出來"之間有真實的秒級時間差，`contextToken` 必須在**錄音開始的瞬間**
    /// 由呼叫方（`VoiceRecordingSession` 的使用者）捕獲並傳進來，不能像
    /// `makeRequest(rawText:draft:)` 那樣在這裡才即時抓——那樣如果這幾秒內
    /// 手動編輯了草稿，過時檢測就形同虛設。`apply(_:...)` 完全不用改，兩個
    /// overload 共用同一套過時比對邏輯。
    public func makeRequest(rawText: String, contextToken: DraftRevisionToken) -> VoiceCommandRequest? {
        guard case .recognized(let kind) = VoiceCommandParser.parse(rawText) else { return nil }
        return VoiceCommandRequest(rawText: rawText, kind: kind, contextToken: contextToken)
    }

    /// The parse-only outcome for `rawText`, for a caller that wants to
    /// surface `.needsClarification`/`.rejected` without going through
    /// `makeRequest`'s "only returns non-nil when recognized" shape.
    public func parseOutcome(_ rawText: String) -> VoiceCommandParseResult {
        VoiceCommandParser.parse(rawText)
    }

    /// Re-checks `request.contextToken` against the draft's CURRENT state
    /// and applies if unchanged; `.staleDraft` otherwise. Idempotent: the
    /// same `requestID` applied twice returns the SAME outcome the second
    /// time without re-executing anything (§6.3: "同一請求ID至多執行一次").
    /// `forceApply` bypasses the one confirm-requiring check
    /// (`replaceExercise` onto an entry with recorded results) -- re-issue
    /// the identical request with this set after the user confirms a
    /// `.needsPreviewConfirm` outcome.
    @discardableResult
    public func apply(
        _ request: VoiceCommandRequest, draft: TodayDraftStore, allExercises: [Exercise],
        context: ModelContext, clientID: String, forceApply: Bool = false
    ) -> VoiceCommandOutcome {
        if request.requestID == lastAppliedRequestID, let lastOutcome = lastAppliedOutcome {
            return lastOutcome
        }
        guard draft.currentRevisionToken() == request.contextToken else {
            return .staleDraft
        }
        let outcome = performApply(request.kind, draft: draft, allExercises: allExercises, context: context, clientID: clientID, forceApply: forceApply)
        if case .applied = outcome {
            lastAppliedRequestID = request.requestID
            lastAppliedOutcome = outcome
        }
        return outcome
    }

    /// One-shot convenience for M3a's synchronous text-entry UI: parse,
    /// capture context, and apply in a single call (there's no real time
    /// gap for staleness to matter here -- everything happens on the main
    /// actor within this one function call).
    @discardableResult
    public func execute(
        rawText: String, draft: TodayDraftStore, allExercises: [Exercise],
        context: ModelContext, clientID: String, forceApply: Bool = false
    ) -> VoiceCommandOutcome {
        let outcome: VoiceCommandOutcome
        switch VoiceCommandParser.parse(rawText) {
        case .rejected(let reason):
            outcome = .rejected(reason: reason)
        case .needsClarification(let reason):
            outcome = .needsClarification(reason: reason, candidates: [], pending: nil)
        case .recognized(let kind):
            let request = VoiceCommandRequest(rawText: rawText, kind: kind, contextToken: draft.currentRevisionToken())
            outcome = apply(request, draft: draft, allExercises: allExercises, context: context, clientID: clientID, forceApply: forceApply)
        }
        return withFuzzyExerciseFallback(outcome, rawText: rawText, allExercises: allExercises)
    }

    /// P3/M3b (2026-09-12)：真實錄音版本的一次呼叫便利方法——跟 `execute`
    /// 同樣的 parse→apply 一步到位形狀，差別是 `contextToken` 由呼叫方
    /// （`VoiceRecordingSession` 的使用者，在錄音開始那一刻）傳入，不是在
    /// 這裡即時抓 `draft.currentRevisionToken()`。讓 UI 層不用自己重寫一遍
    /// parse 失敗時該怎麼組出 `.needsClarification`/`.rejected`。
    @discardableResult
    public func apply(
        rawText: String, contextToken: DraftRevisionToken, draft: TodayDraftStore, allExercises: [Exercise],
        context: ModelContext, clientID: String, forceApply: Bool = false
    ) -> VoiceCommandOutcome {
        let outcome: VoiceCommandOutcome
        switch VoiceCommandParser.parse(rawText) {
        case .rejected(let reason):
            outcome = .rejected(reason: reason)
        case .needsClarification(let reason):
            outcome = .needsClarification(reason: reason, candidates: [], pending: nil)
        case .recognized(let kind):
            let request = VoiceCommandRequest(rawText: rawText, kind: kind, contextToken: contextToken)
            outcome = apply(request, draft: draft, allExercises: allExercises, context: context, clientID: clientID, forceApply: forceApply)
        }
        return withFuzzyExerciseFallback(outcome, rawText: rawText, allExercises: allExercises)
    }

    // MARK: - 模糊輸入回退：說出一個運動名稱就給候選，不要直接判死

    /// 2026-09-13 真機試用反饋：使用者只是說出一個籠統/口語的運動相關字眼
    /// （沒有用到"添加/改成"這類動詞，或動詞認出來了但動作名稱沒能定位到
    /// 草稿/動作庫裡任何東西），舊版在這裡直接回報"無法識別的指令"或空
    /// 候選的"找不到明確的動作"，使用者除了換句話重講一次之外沒有任何
    /// 其他路可走。這裡在「完全沒有頭緒」的兩種結果上，退回去對整句原始
    /// 文字跑一次動作名稱抽取＋動作庫召回，只要抽得出一個像動作名稱的
    /// 片段、且動作庫裡真的有東西被召回，就把這些候選當成"添加這個動作"
    /// 的候選秀出來讓使用者直接點，而不是死路一條。
    ///
    /// 刻意只在兩種"完全沒有頭緒"的結果上觸發，不是任何 `.rejected`：
    /// `applySetPlan`/`applySetActual`/`applyAddExerciseResolved` 那些
    /// "語法認出來了、但單位不符/組不存在/沒有可撤銷的操作"之類的拒絕
    /// 都有明確、具體的原因，不該被這個回退機制蓋過去變成一堆不相關的
    /// "要不要新增動作"候選。
    private func withFuzzyExerciseFallback(_ outcome: VoiceCommandOutcome, rawText: String, allExercises: [Exercise]) -> VoiceCommandOutcome {
        switch outcome {
        case .rejected(let reason) where reason == VoiceCommandParser.genericUnrecognizedReason:
            break
        case .needsClarification(let reason, let candidates, let pending) where reason == .missingExerciseName && candidates.isEmpty && pending == nil:
            break
        default:
            return outcome
        }
        return fuzzyExerciseFallbackOutcome(rawText: rawText, allExercises: allExercises) ?? outcome
    }

    private func fuzzyExerciseFallbackOutcome(rawText: String, allExercises: [Exercise]) -> VoiceCommandOutcome? {
        let normalized = NumberUnitNormalizer.foldSynonyms(rawText.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !normalized.isEmpty, let candidateName = VoiceCommandParser.extractLeadingExerciseName(from: Substring(normalized)), !candidateName.isEmpty else {
            return nil
        }
        let matches = ExerciseVoiceIndex.recallExercises(spokenName: candidateName, in: allExercises)
        guard !matches.isEmpty else { return nil }
        // 順便把整句裡能抽到的組數/數量/重量也一起帶上——這句話語法上
        // 沒能被認成一條完整命令，不代表使用者完全沒說這些資訊（例如
        // "深蹲三十公斤"：沒有"添加"這個動詞，但重量講得很清楚）。
        let setsCount = NumberUnitNormalizer.numberImmediatelyBefore("組", in: normalized)?.value
        let load = NumberUnitNormalizer.parseLoad(Substring(normalized))
        let quantity = NumberUnitNormalizer.parseAnyQuantity(Substring(normalized))
        let payload = AddExercisePayload(
            exerciseSpokenName: candidateName, setsCount: setsCount, targetQuantity: quantity?.value,
            spokenMetricForTargetQuantity: quantity?.metric, load: load
        )
        let candidates = matches.map { ClarificationCandidate(id: $0.id, displayName: $0.voiceCandidateDisplayName) }
        return .needsClarification(reason: .missingExerciseName, candidates: candidates, pending: .addExercise(payload))
    }

    /// 2026-09-13 修正：直接呼叫撤銷，不經過 `VoiceCommandParser`。舊版
    /// UI 的撤銷按鈕是 `service.execute(rawText: language.t("撤銷", "undo"),
    /// ...)`──在英文界面（`language == .en`）下送出的是字面 "undo"，但
    /// `VoiceCommandParser.parse` 只認 `text.contains("撤銷")`，英文 UI 點
    /// 撤銷會直接判定成「無法識別的指令」而失敗。撤銷是一個明確的類型化
    /// 操作，UI 顯示語言完全不該影響它能不能執行──不繞回會受顯示語言
    /// 影響的自然語言解析器（執行 Prompt §3「撤銷可能受 UI 語言影響」）。
    @discardableResult
    public func applyUndo(draft: TodayDraftStore) -> VoiceCommandOutcome {
        performUndo(draft: draft)
    }

    // MARK: - Dispatch

    private func performApply(
        _ kind: VoiceCommandKind, draft: TodayDraftStore, allExercises: [Exercise],
        context: ModelContext, clientID: String, forceApply: Bool
    ) -> VoiceCommandOutcome {
        switch kind {
        case .undoLastVoiceCommand:
            return performUndo(draft: draft)
        case .addExercise(let payload):
            return applyAddExercise(payload, draft: draft, allExercises: allExercises, context: context, clientID: clientID)
        case .replaceExercise(let payload):
            return applyReplaceExercise(payload, draft: draft, allExercises: allExercises, forceApply: forceApply)
        case .setPlan(let payload):
            return applySetPlan(payload, draft: draft)
        case .setActual(let payload):
            return applySetActual(payload, draft: draft)
        case .setSupersetRest(let payload):
            return applySetSupersetRest(payload, draft: draft)
        }
    }

    /// 使用者在「找不到明確的動作」畫面上直接點了某個候選之後的入口──不
    /// 重新解析文字、不重新跑一次模糊比對，直接拿候選的精確身份把原本那條
    /// 命令剩下的欄位套用上去。`contextToken` 由呼叫方在「點下去」那一刻
    /// 現抓（跟 `execute`/`apply(rawText:...)` 同一個「捕獲即套用」的同步
    /// 模式一致），不是沿用最初語音/文字送出時的舊 token。
    @discardableResult
    public func applyClarifiedChoice(
        _ pending: PendingClarification, chosenCandidateID: String, contextToken: DraftRevisionToken,
        draft: TodayDraftStore, allExercises: [Exercise], context: ModelContext, clientID: String, forceApply: Bool = false
    ) -> VoiceCommandOutcome {
        guard draft.currentRevisionToken() == contextToken else {
            return .staleDraft
        }
        switch pending {
        case .addExercise(let payload):
            guard let exercise = allExercises.first(where: { $0.id == chosenCandidateID }) else {
                return .rejected(reason: "目標動作已不存在")
            }
            return applyAddExerciseResolved(payload, exercise: exercise, draft: draft, context: context, clientID: clientID)
        case .replaceExerciseNewExercise(let blockID, let entryID, let pendingForceApply):
            guard let exercise = allExercises.first(where: { $0.id == chosenCandidateID }) else {
                return .rejected(reason: "目標動作已不存在")
            }
            guard let block = draft.blocks.first(where: { $0.id == blockID }), let entry = block.entries.first(where: { $0.id == entryID }) else {
                return .rejected(reason: "目標動作已不存在")
            }
            return applyReplaceExerciseResolved(blockID: blockID, block: block, entry: entry, newExercise: exercise, forceApply: pendingForceApply || forceApply)
        case .replaceExerciseOldTarget(let newExerciseSpokenName, let pendingForceApply):
            guard let entryUUID = UUID(uuidString: chosenCandidateID), let found = findEntry(entryUUID, in: draft) else {
                return .rejected(reason: "目標動作已不存在")
            }
            switch VoiceCommandLibraryResolver.resolve(spokenName: newExerciseSpokenName, in: allExercises) {
            case .notFound:
                return .needsClarification(reason: .missingExerciseName, candidates: [], pending: nil)
            case .ambiguous(let candidates):
                return .needsClarification(
                    reason: .missingExerciseName,
                    candidates: candidates.map { ClarificationCandidate(id: $0.id, displayName: $0.voiceCandidateDisplayName) },
                    pending: .replaceExerciseNewExercise(blockID: found.blockID, entryID: entryUUID, forceApply: pendingForceApply)
                )
            case .matched(let newExercise):
                return applyReplaceExerciseResolved(blockID: found.blockID, block: found.block, entry: found.entry, newExercise: newExercise, forceApply: pendingForceApply || forceApply)
            }
        case .setPlanTarget(let payload):
            guard let entryUUID = UUID(uuidString: chosenCandidateID), let found = findEntry(entryUUID, in: draft) else {
                return .rejected(reason: "目標動作已不存在")
            }
            return applySetPlanResolved(payload, blockID: found.blockID, entry: found.entry, draft: draft)
        case .setActualTarget(let payload):
            guard let entryUUID = UUID(uuidString: chosenCandidateID), let found = findEntry(entryUUID, in: draft) else {
                return .rejected(reason: "目標動作已不存在")
            }
            return applySetActualResolved(payload, blockID: found.blockID, entry: found.entry, draft: draft)
        }
    }

    private func findEntry(_ entryID: UUID, in draft: TodayDraftStore) -> (blockID: UUID, block: BlockDraft, entry: EntryDraft)? {
        for block in draft.blocks {
            if let entry = block.entries.first(where: { $0.id == entryID }) {
                return (block.id, block, entry)
            }
        }
        return nil
    }

    // MARK: - 添加庫內動作

    private func applyAddExercise(_ payload: AddExercisePayload, draft: TodayDraftStore, allExercises: [Exercise], context: ModelContext, clientID: String) -> VoiceCommandOutcome {
        switch VoiceCommandLibraryResolver.resolve(spokenName: payload.exerciseSpokenName, in: allExercises) {
        case .notFound:
            return .needsClarification(reason: .missingExerciseName, candidates: [], pending: nil)
        case .ambiguous(let candidates):
            return .needsClarification(
                reason: .missingExerciseName,
                candidates: candidates.map { ClarificationCandidate(id: $0.id, displayName: $0.voiceCandidateDisplayName) },
                pending: .addExercise(payload)
            )
        case .matched(let exercise):
            return applyAddExerciseResolved(payload, exercise: exercise, draft: draft, context: context, clientID: clientID)
        }
    }

    private func applyAddExerciseResolved(_ payload: AddExercisePayload, exercise: Exercise, draft: TodayDraftStore, context: ModelContext, clientID: String) -> VoiceCommandOutcome {
        // 2026-09-13 全局語音改造：口述了具體數量、但單位跟這個動作的
        // 記錄方式不符時，必須先澄清/拒絕，不能沿用默認值後回報「已添加」
        // 卻悄悄丟掉使用者說的數字──執行 Prompt §3「新增時忽略不匹配單位」
        // 明確指出的真實 bug：之前這裡會建立動作、卻對不匹配單位的數量
        // 靜默沿用 prefill 默認值，使用者聽到「已添加」會以為口述的數字生
        // 效了。
        if let spokenMetric = payload.spokenMetricForTargetQuantity, spokenMetric != exercise.recordingMetric {
            return .rejected(reason: "「\(exercise.voiceCandidateDisplayName)」以\(unitLabel(exercise.recordingMetric))記錄，口述的單位與此不符")
        }
        let (blockID, entryID) = TodayDraftMutationService.addEntry(exercise, clientID: clientID, placement: .newBlock, draft: draft, context: context)
        if let block = draft.blocks.first(where: { $0.id == blockID }), let entry = block.entries.first(where: { $0.id == entryID }), var firstRound = entry.rounds.first {
            if let setsCount = payload.setsCount { firstRound.setsCount = setsCount }
            if let targetQuantity = payload.targetQuantity {
                firstRound.targetQuantity = targetQuantity
                firstRound.actualQuantity = targetQuantity
            }
            if let load = payload.load { firstRound.load = load }
            entry.rounds[0] = firstRound
        }
        let summary = "已添加「\(exercise.voiceCandidateDisplayName)」"
        undoSlot = UndoSlot(summary: summary) { draft in
            TodayDraftMutationService.removeBlock(blockID, draft: draft)
        }
        return .applied(summary: summary, canUndo: true)
    }

    // MARK: - 替換指定動作

    private func applyReplaceExercise(_ payload: ReplaceExercisePayload, draft: TodayDraftStore, allExercises: [Exercise], forceApply: Bool) -> VoiceCommandOutcome {
        switch VoiceCommandTargetResolver.resolve(payload.target, in: draft) {
        case .notFound:
            return .needsClarification(reason: .missingExerciseName, candidates: [], pending: nil)
        case .ambiguous(let candidates):
            return .needsClarification(
                reason: .missingExerciseName,
                candidates: candidates.map { ClarificationCandidate(id: $0.entryID.uuidString, displayName: $0.displayName) },
                pending: .replaceExerciseOldTarget(newExerciseSpokenName: payload.newExerciseSpokenName, forceApply: forceApply)
            )
        case .entry(let blockID, let entryID):
            guard let block = draft.blocks.first(where: { $0.id == blockID }), let entry = block.entries.first(where: { $0.id == entryID }) else {
                return .rejected(reason: "目標動作已不存在")
            }
            switch VoiceCommandLibraryResolver.resolve(spokenName: payload.newExerciseSpokenName, in: allExercises) {
            case .notFound:
                return .needsClarification(reason: .missingExerciseName, candidates: [], pending: nil)
            case .ambiguous(let candidates):
                return .needsClarification(
                    reason: .missingExerciseName,
                    candidates: candidates.map { ClarificationCandidate(id: $0.id, displayName: $0.voiceCandidateDisplayName) },
                    pending: .replaceExerciseNewExercise(blockID: blockID, entryID: entryID, forceApply: forceApply)
                )
            case .matched(let newExercise):
                return applyReplaceExerciseResolved(blockID: blockID, block: block, entry: entry, newExercise: newExercise, forceApply: forceApply)
            }
        }
    }

    private func applyReplaceExerciseResolved(blockID: UUID, block: BlockDraft, entry: EntryDraft, newExercise: Exercise, forceApply: Bool) -> VoiceCommandOutcome {
        let entryID = entry.id
        let hasRecordedActual = entry.rounds.contains { $0.actualQuantity != RepTargetToRoundQuantity.defaultQuantity(for: entry.recordingMetric) }
        if hasRecordedActual, !forceApply {
            return .needsPreviewConfirm(summary: "「\(entry.exercise.voiceCandidateDisplayName)」已有記錄成績，換成「\(newExercise.voiceCandidateDisplayName)」會重置該動作的組數/目標/實際 -- 確認嗎？")
        }
        let oldExercise = entry.exercise
        let oldRounds = entry.rounds
        TodayDraftMutationService.replaceExercise(entryID, in: block, with: newExercise)
        let summary = "已將「\(oldExercise.voiceCandidateDisplayName)」換成「\(newExercise.voiceCandidateDisplayName)」"
        undoSlot = UndoSlot(summary: summary) { draft in
            guard let block = draft.blocks.first(where: { $0.id == blockID }), let entry = block.entries.first(where: { $0.id == entryID }) else { return }
            entry.setExercise(oldExercise)
            entry.rounds = oldRounds
        }
        return .applied(summary: summary, canUndo: true)
    }

    // MARK: - 設置計劃組數/目標/重量

    private func applySetPlan(_ payload: SetPlanPayload, draft: TodayDraftStore) -> VoiceCommandOutcome {
        switch VoiceCommandTargetResolver.resolve(payload.target, in: draft) {
        case .notFound:
            return .needsClarification(reason: .missingExerciseName, candidates: [], pending: nil)
        case .ambiguous(let candidates):
            return .needsClarification(
                reason: .missingExerciseName,
                candidates: candidates.map { ClarificationCandidate(id: $0.entryID.uuidString, displayName: $0.displayName) },
                pending: .setPlanTarget(payload)
            )
        case .entry(let blockID, let entryID):
            guard let entry = draft.blocks.first(where: { $0.id == blockID })?.entries.first(where: { $0.id == entryID }) else {
                return .rejected(reason: "目標動作已不存在")
            }
            return applySetPlanResolved(payload, blockID: blockID, entry: entry, draft: draft)
        }
    }

    private func applySetPlanResolved(_ payload: SetPlanPayload, blockID: UUID, entry: EntryDraft, draft: TodayDraftStore) -> VoiceCommandOutcome {
        let entryID = entry.id
        if let spokenMetric = payload.spokenMetricForTargetQuantity, spokenMetric != entry.recordingMetric {
            return .rejected(reason: "單位與動作記錄方式不符")
        }
        guard !entry.rounds.isEmpty else { return .rejected(reason: "目標動作沒有可修改的輪次") }
        let oldRounds = entry.rounds
        var newRounds = entry.rounds
        // "設置計劃" 沒有指定特定一輪時，組數只調整第一輪，目標/重量套用到
        // 所有輪次 -- 對單輪 entry（絕大多數情況）等同整條調整；多輪 entry
        // 若要精確改某一輪，用 setActual 的「第N組」定位（那條命令走
        // splitRound，本身就是為精確定位設計的）。
        if let setsCount = payload.setsCount {
            newRounds[0].setsCount = setsCount
        }
        if let targetQuantity = payload.targetQuantity {
            for i in newRounds.indices { newRounds[i].targetQuantity = targetQuantity }
        }
        if let load = payload.load {
            for i in newRounds.indices { newRounds[i].load = load }
        }
        entry.rounds = newRounds
        let summary = "已更新「\(entry.exercise.voiceCandidateDisplayName)」的計劃"
        undoSlot = UndoSlot(summary: summary) { draft in
            guard let block = draft.blocks.first(where: { $0.id == blockID }), let entry = block.entries.first(where: { $0.id == entryID }) else { return }
            entry.rounds = oldRounds
        }
        return .applied(summary: summary, canUndo: true)
    }

    // MARK: - 修改指定組的實際成績

    private func applySetActual(_ payload: SetActualPayload, draft: TodayDraftStore) -> VoiceCommandOutcome {
        switch VoiceCommandTargetResolver.resolve(payload.target, in: draft) {
        case .notFound:
            return .needsClarification(reason: .missingExerciseName, candidates: [], pending: nil)
        case .ambiguous(let candidates):
            return .needsClarification(
                reason: .missingExerciseName,
                candidates: candidates.map { ClarificationCandidate(id: $0.entryID.uuidString, displayName: $0.displayName) },
                pending: .setActualTarget(payload)
            )
        case .entry(let blockID, let entryID):
            guard let entry = draft.blocks.first(where: { $0.id == blockID })?.entries.first(where: { $0.id == entryID }) else {
                return .rejected(reason: "目標動作已不存在")
            }
            return applySetActualResolved(payload, blockID: blockID, entry: entry, draft: draft)
        }
    }

    private func applySetActualResolved(_ payload: SetActualPayload, blockID: UUID, entry: EntryDraft, draft: TodayDraftStore) -> VoiceCommandOutcome {
        let entryID = entry.id
        guard payload.spokenMetric == entry.recordingMetric else {
            return .rejected(reason: "單位與動作記錄方式不符")
        }
        guard let setIndex = payload.physicalSetIndex else {
            return .needsClarification(reason: .missingSetIndex, candidates: [], pending: nil)
        }
        let oldRounds = entry.rounds
        guard let roundID = entry.splitRound(atPhysicalSetIndex: setIndex) else {
            return .rejected(reason: "第\(setIndex)組不存在")
        }
        guard let idx = entry.rounds.firstIndex(where: { $0.id == roundID }) else {
            entry.rounds = oldRounds
            return .rejected(reason: "內部錯誤")
        }
        let didSplit = entry.rounds.count != oldRounds.count
        entry.rounds[idx].actualQuantity = payload.actualQuantity
        let summary = "已將「\(entry.exercise.voiceCandidateDisplayName)」第\(setIndex)組實際\(unitLabel(entry.recordingMetric))改為\(payload.actualQuantity)"
        if didSplit {
            // splitRound 是結構性操作 -- 撤銷粒度是整個 entry 的 rounds
            // 陣列，不是單一欄位，跟 plan 裡明確記錄的例外一致。
            undoSlot = UndoSlot(summary: summary) { draft in
                guard let block = draft.blocks.first(where: { $0.id == blockID }), let entry = block.entries.first(where: { $0.id == entryID }) else { return }
                entry.rounds = oldRounds
            }
        } else {
            let oldValue = oldRounds[idx].actualQuantity
            undoSlot = UndoSlot(summary: summary) { draft in
                guard let block = draft.blocks.first(where: { $0.id == blockID }), let entry = block.entries.first(where: { $0.id == entryID }),
                      let i = entry.rounds.firstIndex(where: { $0.id == roundID }) else { return }
                entry.rounds[i].actualQuantity = oldValue
            }
        }
        return .applied(summary: summary, canUndo: true)
    }

    // MARK: - 設置 Superset 輪間休息

    private func applySetSupersetRest(_ payload: SetSupersetRestPayload, draft: TodayDraftStore) -> VoiceCommandOutcome {
        let supersetBlocks = draft.blocks.filter { $0.blockType == .superset }
        let targetBlock: BlockDraft
        if let ordinal = payload.supersetOrdinal {
            guard supersetBlocks.indices.contains(ordinal - 1) else {
                return .needsClarification(reason: .noReliableContext, candidates: [], pending: nil)
            }
            targetBlock = supersetBlocks[ordinal - 1]
        } else {
            guard supersetBlocks.count == 1, let only = supersetBlocks.first else {
                return .needsClarification(reason: .noReliableContext, candidates: [], pending: nil)
            }
            targetBlock = only
        }
        let blockID = targetBlock.id
        let oldRest = targetBlock.restSeconds
        targetBlock.restSeconds = payload.restSeconds
        let summary = "已將超級組休息時間改為\(payload.restSeconds)秒"
        undoSlot = UndoSlot(summary: summary) { draft in
            guard let block = draft.blocks.first(where: { $0.id == blockID }) else { return }
            block.restSeconds = oldRest
        }
        return .applied(summary: summary, canUndo: true)
    }

    // MARK: - 撤銷上一條語音操作

    private func performUndo(draft: TodayDraftStore) -> VoiceCommandOutcome {
        guard let slot = undoSlot else {
            return .rejected(reason: "沒有可撤銷的語音操作")
        }
        slot.revert(draft)
        undoSlot = nil
        return .applied(summary: slot.summary, canUndo: false)
    }

    private func unitLabel(_ metric: RecordingMetric) -> String {
        switch metric {
        case .reps, .unknown: return "次數"
        case .time: return "時間"
        case .distance: return "距離"
        case .rounds: return "輪數"
        }
    }
}
