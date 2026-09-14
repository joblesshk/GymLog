import SwiftUI
import GymLogKit

/// 把歷史里的一节课载入「今天」继续编辑（2026-09-09 教练要求：暫存后能回来
/// 接着录，且「所有生成的 section 都可以方便地进行修改」）。
///
/// 为什么复用「今天」而不是给歷史再写一个编辑器：`SessionEditSheet` 只能改已
/// 有组的重量/次数和课次日期，加不了动作、删不了组、碰不了 WOD。而「今天」那
/// 一屏本来就是完整的录入界面——四个滚轮、Round 表、WOD 卡片、动作选择面板全
/// 在。走这条路，「能改什么」永远等于「能录什么」，不会出现两套编辑器各支持一
/// 半的局面。`SessionEditSheet` 保留，用于「只想改一个数字」的快速修正。
///
/// 放在 App target 而不是 GymLogKit：日期的 UTC/本地换算（`TrainingDayEncoding`）
/// 在这一层。块与动作的还原是纯逻辑，在 `SessionDraftLoader`（GymLogKit，有单测）。
enum SessionEditingCoordinator {

    enum Result {
        case opened
        /// 「今天」里已经开着另一份还没暫存/結束的草稿。直接覆盖会把它冲掉，
        /// 所以这里什么都不做，由调用方提示教练先处理完手上那一堂。
        case blockedByOpenDraft
    }

    /// 载入成功后把 tab 切到「今天」（`tabSelection` 为 nil 时只载入不切）。
    @MainActor
    @discardableResult
    static func open(
        _ session: WorkoutSession,
        exercises: [Exercise],
        into draft: TodayDraftStore,
        tabSelection: TabSelectionStore?
    ) -> Result {
        // 已经开着的就是这一节本身（教练从歷史点了两次）——放行，重载一次没有
        // 副作用；开着的是别的课次才拦。
        if draft.hasUnsavedWork, draft.persistedSessionID != session.id {
            return .blockedByOpenDraft
        }

        let loaded = SessionDraftLoader.load(from: session, exercises: exercises)
        draft.clientID = session.client?.id
        draft.sessionDate = TrainingDayEncoding.localDisplayDate(from: session.date)
        draft.plannedDurationMinutes = session.plannedDurationMinutes ?? 60
        draft.blocks = loaded.blocks
        draft.persistedSessionID = session.id
        draft.openedFromHistory = true
        draft.activeWODTimerOwnerID = nil
        draft.pendingLoadDroppedEntryCount = loaded.droppedEntryCount > 0 ? loaded.droppedEntryCount : nil
        draft.isActive = true

        tabSelection?.select(tab: 0)
        return .opened
    }
}
