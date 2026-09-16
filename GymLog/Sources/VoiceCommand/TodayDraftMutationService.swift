import Foundation
import SwiftData

/// P3/M3a (2026-09-12): the block/entry-list-level mutation operations that
/// used to live only as private methods on `TodayView`/`SupersetBlockDraftCard`
/// -- extracted so both the UI and the new voice command service
/// (`VoiceCommandService`) call exactly one implementation, never two that
/// can drift apart. `TodayView`/`SupersetBlockDraftCard`'s own methods become
/// thin forwarding calls to these; every existing button/accessibility
/// identifier/confirmation-dialog trigger stays exactly where it was.
///
/// Split into two groups by what each operation actually needs to reach:
/// operations that add/remove whole BLOCKS take `draft: TodayDraftStore` and
/// look the target block up by id (mirroring how `TodayView` itself only
/// ever has `draft.blocks` to work with); operations that only touch one
/// block's own `entries`/rounds take the `BlockDraft` directly, matching
/// `SupersetBlockDraftCard`'s existing shape (it holds a `block` reference,
/// never the whole `TodayDraftStore`) -- no new prop-drilling into that view.
@MainActor
public enum TodayDraftMutationService {

    // MARK: - Block-list-level operations (mutate `draft.blocks` itself)

    public enum EntryPlacement: Equatable {
        case newBlock
        case existingBlock(UUID)
        case newSuperset
    }

    /// Ports `TodayView.addEntry(for:clientID:into:)` minus the
    /// `.newWODBlock` routing (WOD block creation stays a `TodayView`-only
    /// concern this service does not touch -- none of P3/M3a's 6 voice
    /// commands operate on WOD blocks). Returns the block/entry id the
    /// exercise ended up in, so a caller (a voice command, in particular)
    /// can act on it immediately without a second lookup.
    @discardableResult
    public static func addEntry(
        _ exercise: Exercise, clientID: String, placement: EntryPlacement,
        draft: TodayDraftStore, context: ModelContext
    ) -> (blockID: UUID, entryID: UUID) {
        let prefill = PrefillResolver.resolvedPrefill(clientID: clientID, exerciseID: exercise.id, equipment: exercise.equipment, in: context)
        let entry = EntryDraft(
            exercise: exercise,
            setsCount: prefill.sets,
            load: prefill.load,
            targetQuantity: RepTargetToRoundQuantity.quantity(from: prefill.targetRepTarget, metric: exercise.recordingMetric),
            actualQuantity: RepTargetToRoundQuantity.quantity(from: prefill.actualRepTarget, metric: exercise.recordingMetric), actualRecorded: false
        )
        switch placement {
        case .newSuperset:
            // P1 计划书 §4.1 的默认值：3 轮、组间休息 60 秒 -- 与
            // TodayView.addEntry 的 .newSuperset 分支保持完全一致。
            let fallback = RepTargetToRoundQuantity.defaultQuantity(for: exercise.recordingMetric)
            let round1 = RoundDraft(
                setsCount: 1, load: prefill.load,
                targetQuantity: RepTargetToRoundQuantity.quantity(from: prefill.targetRepTarget, metric: exercise.recordingMetric),
                actualQuantity: RepTargetToRoundQuantity.quantity(from: prefill.actualRepTarget, metric: exercise.recordingMetric),
                metric: exercise.recordingMetric, actualRecorded: false
            )
            let laterRounds = (1..<3).map { _ in
                RoundDraft(setsCount: 1, load: prefill.load, targetQuantity: fallback, actualQuantity: fallback, metric: exercise.recordingMetric, actualRecorded: false)
            }
            let supersetEntry = EntryDraft(exercise: exercise, rounds: [round1] + laterRounds)
            let block = BlockDraft(blockType: .superset, restSeconds: 60, entries: [supersetEntry], sectionKind: .strength)
            draft.blocks.append(block)
            return (block.id, supersetEntry.id)
        case .newBlock:
            let block = BlockDraft(blockType: .single, entries: [entry])
            draft.blocks.append(block)
            return (block.id, entry.id)
        case .existingBlock(let blockID):
            guard let block = draft.blocks.first(where: { $0.id == blockID }) else {
                let newBlock = BlockDraft(blockType: .single, entries: [entry])
                draft.blocks.append(newBlock)
                return (newBlock.id, entry.id)
            }
            block.entries.append(entry)
            // 一个块里出现第二个动作，默认就是超级组 -- 跟 TodayView.addEntry
            // 同一条规则（CONTRACT.md §6）。
            if block.entries.count > 1, block.blockType == .single {
                block.blockType = .superset
            }
            return (block.id, entry.id)
        }
    }

    /// Ports `TodayView.removeEntry(_:from:)`.
    public static func removeEntry(_ entryID: UUID, from blockID: UUID, draft: TodayDraftStore) {
        guard let block = draft.blocks.first(where: { $0.id == blockID }) else { return }
        block.entries.removeAll { $0.id == entryID }
        if block.entries.isEmpty {
            draft.blocks.removeAll { $0.id == blockID }
        }
    }

    /// Ports `TodayView.composeSuperset(from:)`.
    public static func composeSuperset(selectedBlockIDs: Set<UUID>, draft: TodayDraftStore) {
        guard selectedBlockIDs.count >= 2 else { return }
        guard let earliestIndex = draft.blocks.firstIndex(where: { selectedBlockIDs.contains($0.id) }) else { return }
        let selectedBlocksInOrder = draft.blocks.filter { selectedBlockIDs.contains($0.id) }
        guard selectedBlocksInOrder.count >= 2 else { return }
        let mergedEntries = selectedBlocksInOrder.flatMap(\.entries)
        let restSeconds = selectedBlocksInOrder.first?.restSeconds ?? 60
        let newBlock = BlockDraft(blockType: .superset, restSeconds: restSeconds, entries: mergedEntries, sectionKind: .strength)
        let insertIndex = draft.blocks[..<earliestIndex].filter { !selectedBlockIDs.contains($0.id) }.count
        draft.blocks.removeAll { selectedBlockIDs.contains($0.id) }
        draft.blocks.insert(newBlock, at: insertIndex)
    }

    /// Ports `TodayView.dissolveSuperset(_:)`.
    public static func dissolveSuperset(_ blockID: UUID, draft: TodayDraftStore) {
        guard let index = draft.blocks.firstIndex(where: { $0.id == blockID }) else { return }
        let block = draft.blocks[index]
        let newBlocks = block.entries.map { BlockDraft(blockType: .single, entries: [$0], sectionKind: block.sectionKind) }
        draft.blocks.remove(at: index)
        draft.blocks.insert(contentsOf: newBlocks, at: index)
    }

    /// Ports `TodayView.removeBlock(_:)`.
    public static func removeBlock(_ blockID: UUID, draft: TodayDraftStore) {
        draft.blocks.removeAll { $0.id == blockID }
    }

    // MARK: - Block-scoped member operations (only touch one block's own `entries`)

    /// Ports `SupersetBlockDraftCard.addMember(_:)`.
    public static func addMember(_ exercise: Exercise, to block: BlockDraft) {
        let roundCount = max(block.entries.map(\.rounds.count).max() ?? 0, 1)
        let fallback = RepTargetToRoundQuantity.defaultQuantity(for: exercise.recordingMetric)
        let rounds = (0..<roundCount).map { _ in
            RoundDraft(setsCount: 1, load: PrefillResolver.defaultLoad(for: exercise.equipment), targetQuantity: fallback, actualQuantity: fallback, metric: exercise.recordingMetric, actualRecorded: false)
        }
        block.entries.append(EntryDraft(exercise: exercise, rounds: rounds))
    }

    /// Ports `SupersetBlockDraftCard.replaceMember(id:with:)` -- a thin
    /// wrapper around `EntryDraft.setExercise(_:)`, the same underlying
    /// primitive P0's "修改動作" flow uses, so voice's "替換動作" command
    /// gets the identical unit-safety guarantee for free.
    @discardableResult
    public static func replaceExercise(_ entryID: UUID, in block: BlockDraft, with exercise: Exercise) -> Bool {
        guard let entry = block.entries.first(where: { $0.id == entryID }) else { return false }
        entry.setExercise(exercise)
        return true
    }

    public enum RemoveMemberOutcome: Equatable {
        case removed
        case needsWholeBlockDeleteConfirmation
        case notFound
    }

    /// Ports `SupersetBlockDraftCard.removeMember(_:)`. Returns an outcome
    /// instead of mutating a `@State` bool directly -- the CALLER decides
    /// whether to show a confirmation dialog (a voice command has no dialog
    /// to show; it surfaces `.needsWholeBlockDeleteConfirmation` as a
    /// needs-preview-confirm result instead); this service never touches UI
    /// state.
    @discardableResult
    public static func removeMember(_ entryID: UUID, from block: BlockDraft) -> RemoveMemberOutcome {
        guard block.entries.contains(where: { $0.id == entryID }) else { return .notFound }
        if block.entries.count <= 1 {
            return .needsWholeBlockDeleteConfirmation
        }
        block.entries.removeAll { $0.id == entryID }
        if block.entries.count == 1 {
            // CONTRACT 2026-09-11 P1: 減少一個成員至只剩一個時保留其所有記錄
            // 並轉普通動作 -- `entries`/`rounds` 完全不動，只是這一塊自己的
            // 分類換了標籤。
            block.blockType = .single
        }
        return .removed
    }

    /// Ports `SupersetBlockDraftCard.moveMember(_:by:)`.
    public static func moveMember(_ entryID: UUID, in block: BlockDraft, by offset: Int) {
        guard let index = block.entries.firstIndex(where: { $0.id == entryID }) else { return }
        let target = index + offset
        guard block.entries.indices.contains(target) else { return }
        block.entries.swapAt(index, target)
    }

    /// Ports `SupersetBlockDraftCard.addRoundToAllMembers()`.
    public static func addRoundToAllMembers(_ block: BlockDraft) {
        for entry in block.entries {
            entry.addRound()
        }
    }

    /// Ports `SupersetBlockDraftCard.confirmRemoveLastRound()` (renamed to
    /// describe the effect, not the confirmation dialog that used to gate it
    /// in the UI -- this service never shows dialogs, see
    /// `RemoveMemberOutcome`'s doc comment for the same reasoning).
    public static func removeLastRoundFromAllMembers(_ block: BlockDraft) {
        let target = block.entries.map(\.rounds.count).max() ?? 0
        for entry in block.entries where entry.rounds.count == target {
            if let lastID = entry.rounds.last?.id {
                entry.removeRound(id: lastID)
            }
        }
    }
}
