import Foundation
import Observation

/// The in-progress (never-yet-saved) "今天" session being built by the
/// coach. Nothing here is a `@Model` -- it's plain in-memory state, which is
/// exactly what makes the unsaved-work guard in `ClientSwitchCoordinator`
/// meaningful: switching clients while this is non-empty would silently
/// discard real, unsaved work (CONTRACT-UI.md §3.4).
@MainActor
@Observable
public final class TodayDraftStore {
    public var clientID: String?
    public var sessionDate: Date
    public var blocks: [BlockDraft] = []
    /// Whether a session draft is currently "open" (post 新建/复制上次课次,
    /// pre-save) as opposed to the idle "开始训练" screen.
    public var isActive: Bool = false
    /// 这份草稿正在读写的那一节 `WorkoutSession.id`，`nil` = 还没落过库。
    ///
    /// 2026-09-09 教练要求把「暫時保存」和「結束課次存入歷史記錄」拆成两件事。
    /// 拆开之后草稿不再是「只在内存里、保存即结束」：按一次「暫存」就会建出
    /// （或更新）一节 `isInProgress == true` 的课次，草稿仍然开着；这个 id 就
    /// 是两者之间的那根线，没有它，第二次「暫存」会再建一节新的，同一堂课在
    /// 歷史里出现好几遍。
    /// 从歷史点「繼續記錄」/「完整編輯」打开一节已有课次时同样在这里落 id。
    public var persistedSessionID: String?
    /// 这份草稿是从歷史里已有的课次打开的（而不是本轮新建后暫存出来的）。
    /// 只影响「放棄」的措辞与选项：新建暫存出来的那一节可以顺手删掉，别人已经
    /// 在歷史里的课次绝不能因为一次「放棄編輯」就消失。
    public var openedFromHistory: Bool = false
    /// 从歷史打开这节课时，有多少个动作因为已经从动作库里删除/合并而没能载入。
    /// 由「今天」在下一次渲染时弹窗告知教练，弹完置回 `nil`。
    ///
    /// 放在这里而不是「歷史」那边的 `@State`：触发载入的是歷史列表，但教练落
    /// 地的是「今天」，弹窗必须在他真正看到的那一屏上——跨 tab 传一个 `Int`
    /// 是这里最短的一条路。
    public var pendingLoadDroppedEntryCount: Int?
    /// CONTRACT-M5.md §3.1: "训练持续时间：默认1小时，必须可改". Draft-only
    /// (not a `@Model` field) -- written into `WorkoutSession
    /// .plannedDurationMinutes` on save, same as every other draft value.
    /// `nil` only while editing a saved session that never recorded one.
    public var plannedDurationMinutes: Int? = 60
    /// 2026-09-07 M3: the `WODBlockDraft.id` currently running a live
    /// `WODTimerModel`, or `nil` if none is. 工程审阅 §7: "只有一個主訓練
    /// 計時器" -- a session can have multiple WOD blocks, but only one may
    /// have an active countdown at a time; each `WODBlockDraftCard` checks
    /// this before allowing its own "開始計時" and clears it back to `nil`
    /// only if it's the one that set it (never clobbers a DIFFERENT block's
    /// claim).
    public var activeWODTimerOwnerID: UUID?

    public init(sessionDate: Date = Date()) {
        self.sessionDate = sessionDate
    }

    /// True exactly when discarding right now would lose real work -- the
    /// condition CONTRACT-UI.md §3.4 requires a confirmation for before a
    /// client switch.
    public var hasUnsavedWork: Bool {
        isActive && !blocks.isEmpty
    }

    public func startNew(clientID: String, date: Date = Date()) {
        self.clientID = clientID
        self.sessionDate = date
        self.blocks = []
        self.isActive = true
        self.persistedSessionID = nil
        self.openedFromHistory = false
    }

    public func reset() {
        clientID = nil
        blocks = []
        isActive = false
        plannedDurationMinutes = 60
        activeWODTimerOwnerID = nil
        persistedSessionID = nil
        openedFromHistory = false
        pendingLoadDroppedEntryCount = nil
    }

    /// All entry drafts across all blocks, flattened, in block/entry order --
    /// convenient for the flat "add exercise" list UI, which doesn't offer
    /// manual superset composition (see VERIFICATION-M2.md for that scope
    /// note); only 复制上次同类课 currently produces multi-entry blocks.
    public var allEntries: [EntryDraft] {
        blocks.flatMap(\.entries)
    }
}
