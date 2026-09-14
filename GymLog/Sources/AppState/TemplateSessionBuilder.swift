import Foundation
import SwiftData

/// CONTRACT-M4.md §4.4 / §5 -- converts a `SessionTemplate`'s blocks/slots
/// into fresh `BlockDraft`/`EntryDraft`s for the "从模板新建" entry point.
/// Lives in `AppState` (GymLogKit), not `TodayView` itself, so this
/// conversion is directly unit-testable via `@testable import GymLogKit`
/// (`GymLogTests`, which links GymLogKit but not the GymLog app target that
/// hosts `TodayView`/SwiftUI).
@MainActor
public enum TemplateSessionBuilder {
    public struct Result {
        public let blocks: [BlockDraft]
        /// Count of `TemplateExerciseSlot`s whose `exerciseID` did not
        /// resolve to any exercise in `allExercises` (e.g. a stale
        /// reference after a library merge/delete). CONTRACT-M4.md's risk
        /// callout requires this be surfaced visibly to the coach, never
        /// silently dropped -- the caller (TodayView) turns a non-zero
        /// count into a coach-facing alert.
        public let unresolvedSlotCount: Int
    }

    /// `exercise` resolves `TemplateExerciseSlot.exerciseID` against
    /// `allExercises`; `setsCount` comes from `defaultSets`; `repTarget`
    /// from `defaultRepTarget`. Weight is deliberately **never** taken from
    /// the template (CONTRACT-M4.md §3/§4.4: templates don't describe
    /// weight) -- every resolved slot instead runs through
    /// `PrefillResolver`, exactly as a manually-added exercise would, so a
    /// template-started session still benefits from per-client last-value
    /// prefill.
    public static func build(
        from template: SessionTemplate,
        clientID: String,
        allExercises: [Exercise],
        in context: ModelContext
    ) -> Result {
        var unresolvedCount = 0
        var blocks: [BlockDraft] = []

        for block in template.orderedBlocks {
            // M2 CrossFit extension: a WOD template block carries only a
            // prescription (never a result, per 工程审阅 §5.2) -- starting a
            // session from it copies that plan into a fresh `WODBlockDraft`
            // with the result reset to `.notRecorded`, same "复测默认带出同版
            // 计划，成绩清空" rule `copyLastSession` follows for a prior
            // session's WOD block (`TodayView.copyLastSession`).
            if block.sectionKind == .wod {
                guard let prescription = block.wodPrescription else { continue }
                let wodDraft = WODBlockDraft.fromPrescription(prescription, exercises: allExercises)
                blocks.append(BlockDraft(blockType: block.blockType, restSeconds: block.restSeconds, sectionKind: .wod, wodDraft: wodDraft))
                continue
            }
            let entries: [EntryDraft] = block.orderedSlots.compactMap { slot in
                guard let exercise = allExercises.first(where: { $0.id == slot.exerciseID }) else {
                    unresolvedCount += 1
                    return nil
                }
                let prefill = PrefillResolver.resolvedPrefill(clientID: clientID, exerciseID: exercise.id, equipment: exercise.equipment, in: context)
                // CONTRACT-M5.md §3.3.2 / §3.4 (extended by CONTRACT-M8.md/
                // CONTRACT-M9.md): EntryDraft now takes `rounds:` (single
                // Round for a fresh template-started entry). The template
                // slot only defines one "planned" RepTarget -- there is no
                // "actual" concept yet since this Round has never been
                // performed -- so 目标 and 实际 both start from the same
                // converted quantity; the coach edits 實際 after doing the
                // work, same as `Sources/Views/Wheels/RepTargetCustomSheet.swift`'s
                // planning-only scope.
                let quantity = RepTargetToRoundQuantity.quantity(from: slot.defaultRepTarget, metric: exercise.recordingMetric)
                return EntryDraft(
                    exercise: exercise,
                    setsCount: slot.defaultSets,
                    load: prefill.load,
                    targetQuantity: quantity,
                    actualQuantity: quantity,
                    restSeconds: block.restSeconds, actualRecorded: false
                )
            }
            guard !entries.isEmpty else { continue }
            blocks.append(BlockDraft(blockType: block.blockType, restSeconds: block.restSeconds, entries: entries))
        }

        return Result(blocks: blocks, unresolvedSlotCount: unresolvedCount)
    }
}
