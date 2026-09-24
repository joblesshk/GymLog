import Foundation
import SwiftData

/// Includes empty/inactive drafts, unlike the old optional autosave token.
public struct CloudDraftState: Equatable {
    public var snapshot: TodayDraftSnapshot
    public var active: Bool
    public var clientID: String?
    public var timerID: UUID?
    @MainActor public init(_ draft: TodayDraftStore) {
        snapshot = TodayDraftSnapshot(clientID: draft.clientID ?? "", sessionDate: draft.sessionDate,
            plannedDurationMinutes: draft.plannedDurationMinutes, blocks: draft.blocks.map { $0.snapshot() },
            savedAt: Date(timeIntervalSince1970: 0), persistedSessionID: draft.persistedSessionID,
            openedFromHistory: draft.openedFromHistory)
        active = draft.isActive; clientID = draft.clientID; timerID = draft.activeWODTimerOwnerID
    }
    @MainActor public func restore(into draft: TodayDraftStore, exercises: [Exercise]) {
        draft.restore(from: snapshot, exercises: exercises)
        draft.isActive = active; draft.clientID = clientID; draft.activeWODTimerOwnerID = timerID
    }
}

@MainActor
public final class CloudVoiceExecutor {
    public struct Result { public let summary: String; public let details: [String]; public let lastTarget: String? }
    private var undoState: (before: CloudDraftState, after: CloudDraftState)?
    private var appliedIDs = Set<UUID>()
    public var canUndo: Bool { undoState != nil }
    public init() {}
    public func reset() { undoState = nil; appliedIDs.removeAll() }
    public func undo(draft: TodayDraftStore, exercises: [Exercise]) throws {
        guard let state = undoState else { throw CloudVoiceError.message("沒有可撤銷的語音操作。") }
        guard CloudDraftState(draft) == state.after else { throw CloudVoiceError.message("訓練已經改動，撤銷會覆蓋後來的編輯，請手動調整。") }
        state.before.restore(into: draft, exercises: exercises); undoState = nil
    }
    public func apply(_ plan: CloudVoicePlan, transcript: String, requestID: UUID,
                      origin: CloudDraftState, draft: TodayDraftStore, exercises: [Exercise],
                      clientID: String, context: ModelContext, confirmed: Bool = false) throws -> Result {
        guard !clientID.isEmpty, origin == CloudDraftState(draft), !appliedIDs.contains(requestID),
              !draft.isActive || draft.clientID == clientID else {
            throw CloudVoiceError.message("訓練或學員已改變，請重新說一次。")
        }
        guard plan.version == 1, plan.clarification?.isEmpty != false, !plan.operations.isEmpty,
              plan.operations.count <= 40 else { throw CloudVoiceError.message(plan.clarification ?? "沒有可執行的完整指令。") }
        guard draft.activeWODTimerOwnerID == nil else { throw CloudVoiceError.message("請先停止目前的 WOD 計時，再修改計劃。") }
        for op in plan.operations {
            try validateFields(op)
            guard !op.evidence.isEmpty, transcript.contains(op.evidence) else { throw CloudVoiceError.message("指令缺少原話依據。") }
        }
        if plan.operations.count == 1, plan.operations[0].kind == .undo {
            try undo(draft: draft, exercises: exercises); appliedIDs.insert(requestID)
            return Result(summary: "已撤銷上一句的修改", details: [], lastTarget: nil)
        }
        let work = TodayDraftStore(); origin.restore(into: work, exercises: exercises)
        var refs = [String: UUID](); var details = [String](); var lastTarget: String?
        func entry(_ ref: String?) throws -> (BlockDraft, EntryDraft) {
            guard let ref, let id = refs[ref] ?? UUID(uuidString: ref) else { throw CloudVoiceError.message("請說明要修改哪一個動作。") }
            for block in work.blocks where block.wodDraft == nil {
                if let e = block.entries.first(where: { $0.id == id }) { return (block, e) }
            }
            throw CloudVoiceError.message("要修改的動作已不存在。")
        }
        func exercise(_ id: String?) throws -> Exercise {
            guard let e = exercises.first(where: { $0.id == id }) else { throw CloudVoiceError.message("找不到這個運動項目，請在動作庫確認名稱。") }
            return e
        }
        for op in plan.operations {
            try validateFields(op)
            guard !op.evidence.isEmpty, transcript.contains(op.evidence) else { throw CloudVoiceError.message("指令缺少原話依據，請重新說一次。") }
            if op.kind == .recordActual {
                let markers = ["實際", "实际", "做了", "做咗", "完成了", "完成咗", "已完成", "actual", "completed", "performed", "did "]
                guard markers.contains(where: { op.evidence.lowercased().contains($0) }) else {
                    throw CloudVoiceError.message("未聽到明確的實際完成描述，沒有寫入成績。請說「第二組實際完成八次」。")
                }
            }
            if let n = op.sets, !(1...50).contains(n) { throw CloudVoiceError.message("組數須為 1–50。") }
            if let rest = op.restSeconds, !(0...3600).contains(rest) { throw CloudVoiceError.message("休息時間須在一小時以內。") }
            switch op.kind {
            case .startSession:
                guard !work.isActive else { throw CloudVoiceError.message("已有進行中的訓練。請說「添加動作」繼續這份計劃。") }
                work.startNew(clientID: clientID)
                details.append("已建立今天的訓練計劃；尚未開始計時")
            case .addExercise:
                guard work.isActive else { throw CloudVoiceError.message("請先說「建立今天的訓練計劃」。") }
                let ex = try exercise(op.exerciseID)
                let history = PrefillResolver.lastRecord(clientID: clientID, exerciseID: ex.id, in: context)
                let target = try quantity(op, metric: ex.recordingMetric) ?? history.map {
                    RepTargetToRoundQuantity.quantity(from: $0.targetRepTarget, metric: ex.recordingMetric)
                } ?? (ex.recordingMetric == .distance ? 100 : RepTargetToRoundQuantity.defaultQuantity(for: ex.recordingMetric))
                let load = try op.load?.resolved() ?? history?.load ?? PrefillResolver.defaultLoad(for: ex.equipment)
                let e = EntryDraft(exercise: ex, rounds: [RoundDraft(setsCount: op.sets ?? min(max(history?.sets ?? 3, 1), 50),
                    load: load, targetQuantity: target, actualQuantity: target, metric: ex.recordingMetric, actualRecorded: false)])
                e.restSeconds = op.restSeconds
                work.blocks.append(BlockDraft(blockType: .single, restSeconds: op.restSeconds, entries: [e]))
                if let ref = op.ref {
                    guard UUID(uuidString: ref) == nil, refs[ref] == nil else { throw CloudVoiceError.message("動作引用重複，請重試。") }
                    refs[ref] = e.id
                }
                lastTarget = e.id.uuidString
                var defaults = [String]()
                if op.sets == nil { defaults.append("組數") }; if op.quantity == nil { defaults.append("目標") }; if op.load == nil { defaults.append("重量") }
                details.append("新增「\(ex.voiceCandidateDisplayName)」\(e.plannedSets)組 × \(target)\(unitLabel(ex.recordingMetric)) · \(load.displayText)" + (defaults.isEmpty ? "" : "（\(defaults.joined(separator: "、"))已預填）"))
            case .updatePlan, .recordActual:
                let (_, e) = try entry(op.target)
                let q = try quantity(op, metric: e.recordingMetric)
                let load = try op.load?.resolved()
                guard q != nil || load != nil || op.sets != nil else { throw CloudVoiceError.message("請說明要改成的數值。") }
                if op.kind == .recordActual {
                    guard op.setIndex != nil, q != nil, op.sets == nil, load == nil else { throw CloudVoiceError.message("請明確指定第幾組及實際完成數值。") }
                }
                if let count = op.sets {
                    guard op.setIndex == nil else { throw CloudVoiceError.message("指定單組時不能同時更改總組數。") }
                    if count < e.plannedSets && e.rounds.contains(where: { $0.actualRecorded }) && !confirmed { throw CloudVoiceExecutionNeedsConfirmation() }
                    // R01 (2026-09-16): expand losslessly -- pass each Round's
                    // real `target`/`actual` straight through instead of
                    // re-quantizing via `RepTargetToRoundQuantity`, so
                    // resizing set count never collapses an untouched
                    // `.range`/`.perSide` Round to its midpoint.
                    let expanded = e.rounds.flatMap { r in (0..<r.setsCount).map { _ in r.copying(setsCount: 1) } }
                    var resized = Array(expanded.prefix(count))
                    while resized.count < count {
                        let r = expanded.last!
                        resized.append(RoundDraft(setsCount: 1, load: r.load, target: r.target, actual: r.target, actualRecorded: false))
                    }
                    e.rounds = resized
                }
                var indexes = Array(e.rounds.indices)
                if let spokenIndex = op.setIndex {
                    let physical = spokenIndex == -1 ? e.plannedSets : spokenIndex
                    guard let id = e.splitRound(atPhysicalSetIndex: physical), let i = e.rounds.firstIndex(where: { $0.id == id }) else { throw CloudVoiceError.message("指定的組不存在。") }
                    indexes = [i]
                }
                for i in indexes {
                    if op.kind == .recordActual { e.rounds[i].actual = RepTargetToRoundQuantity.repTarget(quantity: q!, metric: e.recordingMetric) }
                    else { if let q { e.rounds[i].target = RepTargetToRoundQuantity.repTarget(quantity: q, metric: e.recordingMetric) }; if let load { e.rounds[i].load = load } }
                }
                lastTarget = e.id.uuidString
                details.append("已更新「\(e.exercise.voiceCandidateDisplayName)」的\(op.kind == .recordActual ? "實際成績" : "計劃")" + (op.setIndex.map { "（第\($0 == -1 ? e.plannedSets : $0)組）" } ?? ""))
            case .replaceExercise:
                let (_, e) = try entry(op.target); let ex = try exercise(op.exerciseID)
                if e.rounds.contains(where: { $0.actualRecorded }) && !confirmed { throw CloudVoiceExecutionNeedsConfirmation() }
                let old = e.exercise.voiceCandidateDisplayName
                e.setExercise(ex)
                for i in e.rounds.indices { e.rounds[i].actualRecorded = false }
                lastTarget = e.id.uuidString
                details.append("已將「\(old)」換成「\(ex.voiceCandidateDisplayName)」，實際成績留空")
            case .removeExercise:
                let (block, e) = try entry(op.target)
                if e.rounds.contains(where: { $0.actualRecorded }) && !confirmed { throw CloudVoiceExecutionNeedsConfirmation() }
                TodayDraftMutationService.removeEntry(e.id, from: block.id, draft: work)
                if block.entries.count == 1 { block.blockType = .single }
                lastTarget = nil; details.append("已移除「\(e.exercise.voiceCandidateDisplayName)」")
            case .moveExercise:
                let (block, e) = try entry(op.target)
                guard block.entries.count == 1 else { throw CloudVoiceError.message("請先拆開超級組，再移動其中的動作。") }
                let destination = try op.after.map { try entry($0).0 }
                guard destination?.id != block.id else { throw CloudVoiceError.message("動作不能移到自己後面。") }
                work.blocks.removeAll { $0.id == block.id }
                let index = destination.flatMap { d in work.blocks.firstIndex(where: { $0.id == d.id }) }.map { $0 + 1 } ?? 0
                work.blocks.insert(block, at: index); lastTarget = e.id.uuidString; details.append("已調整「\(e.exercise.voiceCandidateDisplayName)」的順序")
            case .composeSuperset:
                let selected = try (op.targets ?? []).map { try entry($0).0 }
                let ids = Set(selected.map(\.id))
                guard ids.count >= 2, selected.allSatisfy({ $0.blockType == .single && $0.sectionKind == .strength }) else { throw CloudVoiceError.message("請選擇至少兩個獨立動作組成超級組。") }
                // Preserve every physical set and actual status; no fallback prefill mutation.
                let blocks = work.blocks.filter { ids.contains($0.id) }
                let entries = blocks.flatMap(\.entries)
                for e in entries {
                    e.rounds = e.rounds.flatMap { r in (0..<r.setsCount).map { _ in r.copying(setsCount: 1) } }
                }
                let index = work.blocks.firstIndex { ids.contains($0.id) }!
                work.blocks.removeAll { ids.contains($0.id) }
                work.blocks.insert(BlockDraft(blockType: .superset, restSeconds: op.restSeconds ?? 60, entries: entries), at: index)
                details.append("已組成超級組，休息\(op.restSeconds ?? 60)秒")
            case .dissolveSuperset:
                let (block, _) = try entry(op.target)
                guard block.blockType == .superset, let index = work.blocks.firstIndex(where: { $0.id == block.id }) else { throw CloudVoiceError.message("這個動作不在超級組中。") }
                work.blocks.replaceSubrange(index...index, with: block.entries.map { BlockDraft(blockType: .single, restSeconds: $0.restSeconds ?? block.restSeconds, entries: [$0], sectionKind: block.sectionKind) })
                details.append("已拆開超級組，各組數值保持不變")
            case .setRest:
                let (block, e) = try entry(op.target)
                guard let seconds = op.restSeconds else { throw CloudVoiceError.message("請說明休息秒數。") }
                block.restSeconds = seconds
                for member in block.entries { member.restSeconds = seconds }
                lastTarget = e.id.uuidString; details.append("已將休息改為\(seconds)秒")
            case .undo: throw CloudVoiceError.message("撤銷請單獨說一句。")
            }
        }
        let after = CloudDraftState(work)
        after.restore(into: draft, exercises: exercises)
        undoState = (origin, after); appliedIDs.insert(requestID)
        return Result(summary: "已完成 \(plan.operations.count) 項操作", details: details, lastTarget: lastTarget)
    }
    private func validateFields(_ op: CloudVoiceOperation) throws {
        var used = Set<String>()
        if op.target != nil { used.insert("target") }; if op.exerciseID != nil { used.insert("exerciseID") }
        if op.ref != nil { used.insert("ref") }; if op.targets != nil { used.insert("targets") }
        if op.after != nil { used.insert("after") }; if op.setIndex != nil { used.insert("setIndex") }
        if op.sets != nil { used.insert("sets") }; if op.quantity != nil { used.insert("quantity") }
        if op.unit != nil { used.insert("unit") }; if op.load != nil { used.insert("load") }
        if op.restSeconds != nil { used.insert("restSeconds") }
        let allowed: Set<String>
        switch op.kind {
        case .startSession, .undo: allowed = []
        case .addExercise: allowed = ["exerciseID", "ref", "sets", "quantity", "unit", "load", "restSeconds"]
        case .updatePlan: allowed = ["target", "setIndex", "sets", "quantity", "unit", "load"]
        case .recordActual: allowed = ["target", "setIndex", "quantity", "unit"]
        case .replaceExercise: allowed = ["target", "exerciseID"]
        case .removeExercise, .dissolveSuperset: allowed = ["target"]
        case .moveExercise: allowed = ["target", "after"]
        case .composeSuperset: allowed = ["targets", "restSeconds"]
        case .setRest: allowed = ["target", "restSeconds"]
        }
        guard used.isSubset(of: allowed) else { throw CloudVoiceError.message("這項指令包含無法執行的細節，沒有修改訓練。") }
    }
    private func quantity(_ op: CloudVoiceOperation, metric: RecordingMetric) throws -> Int? {
        guard let value = op.quantity else {
            guard op.unit == nil else { throw CloudVoiceError.message("數值缺失。") }; return nil
        }
        guard value.isFinite, value >= 0, let unit = op.unit else { throw CloudVoiceError.message("請說明有效數值及單位。") }
        let factor: Double
        switch (metric, unit) {
        case (.reps, "reps"), (.rounds, "rounds"), (.time, "s"), (.distance, "m"): factor = 1
        case (.time, "min"): factor = 60
        case (.distance, "km"): factor = 1000
        default: throw CloudVoiceError.message("單位與動作的記錄方式不符，沒有修改計劃。")
        }
        let result = value * factor
        guard result <= 100000, result.rounded() == result else { throw CloudVoiceError.message("這個欄位只支援整數，請調整數值。") }
        return Int(result)
    }
    private func unitLabel(_ metric: RecordingMetric) -> String {
        switch metric { case .reps, .unknown: return "次"; case .time: return "秒"; case .distance: return "米"; case .rounds: return "輪" }
    }
}
public struct CloudVoiceExecutionNeedsConfirmation: Error { public init() {} }
