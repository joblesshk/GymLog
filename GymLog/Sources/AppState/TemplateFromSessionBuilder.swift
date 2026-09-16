import Foundation
import SwiftData

/// 把一節已經落庫的 `WorkoutSession` 轉成一份可重複使用的 `SessionTemplate`
/// (2026-09-16「從歷史記錄的某天生成模板」)——跟 `TemplateSessionBuilder`
/// 正好反方向：那邊是「模板 → 今天的草稿」，這裡是「歷史課次 → 模板」。
///
/// 模板本身不帶重量（`SessionTemplate.swift` 開頭既有的設計決策：
/// "templates carry no LoadValue"），這裡只取每個動作的組數與目標次數，重
/// 量一律丟棄——跟 `TemplateSessionBuilder.build` 反向對稱，那邊套用模板時
/// 的重量也完全不看模板、只看 `PrefillResolver`。
///
/// 每個動作只取「代表性的一組」（第一組的目標）當這個 slot 的
/// `defaultRepTarget`——`TemplateExerciseSlot` 的資料形狀本來就只有一個
/// `defaultSets`/`defaultRepTarget`，不像 `WorkoutSession` 的 `SetLog` 能逐輪
/// 不同，這不是這次轉換丟資料，是模板這個概念本來就是「粗顆粒度的處方」，
/// 跟 `TemplateSessionBuilder` 早就有的單輪限制一致。
@MainActor
public enum TemplateFromSessionBuilder {
    public struct Result {
        public let template: SessionTemplate
        /// 動作已從動作庫刪除、無法在模板裡引用的條目數——模板本身仍會建立，
        /// 只是這些動作被跳過，呼叫端應該把這個數字顯示成提示（跟
        /// `TemplateSessionBuilder.Result.unresolvedSlotCount`／
        /// `SessionDraftLoader`的`droppedEntryCount`同一個慣例）。
        public let droppedEntryCount: Int
    }

    /// 建立並插入一份新模板，直接 `context.save()`——呼叫端只需要處理拋出
    /// 的錯誤，不需要自己再 insert 或 save 一次。
    @discardableResult
    public static func build(from session: WorkoutSession, name: String, in context: ModelContext) throws -> Result {
        var droppedTotal = 0
        let nextOrder = ((try? context.fetch(FetchDescriptor<SessionTemplate>()))?.map(\.order).max() ?? -1) + 1
        let template = SessionTemplate(
            id: "tpl-\(UUID().uuidString.prefix(8))",
            name: name,
            templateNote: nil,
            order: nextOrder
        )
        context.insert(template)

        for (blockIndex, block) in session.orderedBlocks.enumerated() {
            if block.sectionKind == .wod, let payload = block.wodPayload {
                let templateBlock = TemplateBlock(
                    id: "tb-\(UUID().uuidString.prefix(8))", order: blockIndex, blockType: block.blockType,
                    restSeconds: block.restSeconds ?? 0, sectionKind: .wod, wodPrescription: payload.prescription
                )
                templateBlock.template = template
                context.insert(templateBlock)
                continue
            }

            let templateBlock = TemplateBlock(
                id: "tb-\(UUID().uuidString.prefix(8))", order: blockIndex, blockType: block.blockType,
                restSeconds: block.restSeconds ?? 0, sectionKind: block.sectionKind
            )
            var slotOrder = 0
            for entry in block.orderedEntries {
                guard let exercise = entry.exercise else {
                    droppedTotal += 1
                    continue
                }
                guard let firstSet = entry.orderedSets.first else { continue }
                let slot = TemplateExerciseSlot(
                    id: "tes-\(UUID().uuidString.prefix(8))", order: slotOrder,
                    exerciseID: exercise.id,
                    defaultSets: entry.plannedSets > 0 ? entry.plannedSets : entry.orderedSets.count,
                    defaultRepTarget: firstSet.target
                )
                slot.block = templateBlock
                context.insert(slot)
                slotOrder += 1
            }
            // 這個區塊裡沒有任何動作能解析成 slot（全部被刪除／合併）——不把
            // 空區塊也插進模板，`templateBlock` 沒被 `context.insert` 過，也
            // 沒有任何 slot 指向它，單純被丟棄。
            guard slotOrder > 0 else { continue }
            templateBlock.template = template
            context.insert(templateBlock)
        }

        try context.save()
        return Result(template: template, droppedEntryCount: droppedTotal)
    }
}
