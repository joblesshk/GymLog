import SwiftUI
import SwiftData
import GymLogKit

/// 今天 tab -- the M2 entry-flow home (CONTRACT-UI.md §3). Owns session
/// start/copy-last (§3.5), the entry list built from the four wheels via
/// `EntryRowView` (§3.1/§3.2), and the save path that turns
/// `TodayDraftStore`'s in-memory draft into real `WorkoutSession` /
/// `SessionBlock` / `ExerciseEntry` / `SetLog` rows with `isInferred == false`
/// (§3.6).
struct TodayView: View {
    // Passed in explicitly rather than read via `@Environment(Type.self)`:
    // see ClientSwitchConfirmationModifier.swift's note on the
    // `.alert`/environment interaction crash this app hit at launch --
    // explicit passing sidesteps that whole class of issue.
    @Bindable var clientStore: CurrentClientStore
    @Bindable var draft: TodayDraftStore
    let switchCoordinator: ClientSwitchCoordinator
    // CONTRACT-M5.md §1.2: lets the nav bar's "编辑「...」资料" menu entry jump
    // to 个人信息. Not required (nil elsewhere still compiles), but 今天 is
    // one of the two owned screens that actually wires it up.
    var tabSelection: TabSelectionStore? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    @Query(sort: \Client.name) private var clients: [Client]
    @Query(sort: \Exercise.canonicalName) private var allExercises: [Exercise]
    @Query private var allEntries: [ExerciseEntry]

    // 2026-09-09：选动作面板现在有两个入口——底部的「添加動作」建一个新训练块，
    // 训练块自己的「加入動作到這一塊」把动作加进已有的块里（组成超级组/循环
    // 组）。用一个可空的目标而不是两个布尔，`nil` 就是没在选。
    @State private var exercisePickerTarget: ExercisePickerTarget?
    // P1 (2026-09-11)：「組成 Superset」用一個獨立的選取面板，不疊在
    // `exercisePickerTarget` 那條 sheet 狀態機上——两者互斥、各自的生命週期
    // 也不同（這個不涉及選動作，是在既有 block 之間做結構調整）。
    @State private var showingComposeSuperset = false
    // 2026-09-04：组间休息倒计时（M9 曾整体移除，教练本轮要求恢复并加上响铃）
    // 与训练中的实时心率。两者都只是"这次训练进行中"的临时状态，不属于
    // `TodayDraftStore` 那份会被保存成 WorkoutSession 的草稿，所以留在视图里。
    @State private var restTimer = RestTimerModel()
    @State private var heartRate = HeartRateMonitor()
    // 2026-09-09：休息到点提醒的通知授权状态。`nil` = 还没问过（第一次按下
    // 计时条时才问，不在启动时打扰）；`false` = 教练拒绝了，计时条下方显示一
    // 行说明，而不是静默排一堆系统必然丢弃的请求。
    @State private var restAlertsAuthorized: Bool?
    @State private var saveErrorMessage: String?
    @State private var saveSuccessMessage: String?
    @State private var templateResolutionWarning: String?
    // 2026-09-16：複製上次課次／從歷史記錄複製都走同一個提示，用詞不提「模板」。
    @State private var copyResolutionWarning: String?
    // 2026-09-16：「從歷史記錄選擇」——教練從自己完整的歷史課次列表裡挑一天
    // 複製，不限於最近一次。
    @State private var showingHistoryCopyPicker = false
    // 2026-09-16：「添加 Superset」預設彈出這個 picker（復用
    // `SessionTemplatePickerView`，篩成只顯示 `isSupersetOnly` 的模板），選中
    // 後直接把該模板的那個 superset block 加進目前這堂課（不是新建課次）；
    // 2026-09-17：picker 裡找不到想要的組合時，`onManualFallback` 改回原本
    // 的手動選動作流程（`exercisePickerTarget = .newSuperset`）。
    @State private var showingSupersetTemplatePicker = false
    // 同上，「添加 WOD」的預設路徑——篩成 `isWODOnly` 的模板（網上知名的
    // CrossFit 基準 WOD），找不到時一樣能退回手動輸入。
    @State private var showingWODTemplatePicker = false
    // P2 (2026-09-11)：「分享計劃」——生成的文件 URL 兼做 `.sheet` 觸發條件
    // （非 nil 就顯示），與 `SettingsView`/`HistoryListView` 既有的
    // `exportedBackupURL`/`exportedFileURL` 是同一個模式。
    @State private var sharedPlanURL: URL?
    @State private var sharedPlanText = ""
    @State private var sharePlanErrorMessage: String?
    // 2026-09-13 全局語音改造：語音服務/錄音 session 已升級成
    // `ContentView` 持有的全局 `VoiceCommandCoordinator`（見該檔案說明），
    // 不再是這裡的私有 `@State`；這裡不再持有、也不再需要自己處理背景
    // 取消錄音（`ContentView` 自己的 `.onChange(of: scenePhase)` 已接手）。

    // 草稿自动保存与恢复（2026-09-06 审查报告"适合当前范围的功能"第一批）：
    // 训练草稿一直只在内存里，进程被系统终止或教练强制退出 App 就整段丢失。
    // 后台/不活跃时把草稿写到磁盘，下次打开「今天」若发现有未处理完的草稿就
    // 提示恢复。
    private let draftPersistence = DraftPersistence()
    @State private var pendingDraftRestore: TodayDraftSnapshot?
    @State private var draftRestoreDroppedCount: Int?
    // 2026-09-07 审阅 B02/B08 additions:
    @State private var draftRestoreMetricUncertainCount: Int?
    /// The saved draft's client no longer exists -- restoring would silently
    /// attribute it to whatever client happens to be selected right now
    /// (B08). Blocks the normal restore prompt in favor of a
    /// discard-only one; holds the snapshot only so "discard" has something
    /// to clear.
    @State private var draftRestoreBlockedMissingClient: TodayDraftSnapshot?
    @State private var draftQuarantinedNotice = false
    @State private var lastAutosaveFailed = false
    @State private var autosaveTask: Task<Void, Never>?
    @State private var showingDiscardConfirmation = false
    // Only worth checking disk once per launch -- a TabView can re-fire
    // `.onAppear` every time this tab is re-selected, and re-showing the
    // restore prompt after the coach already answered it once would be a
    // regression, not a safety net.
    @State private var hasCheckedForDraftRestore = false

    // Perf fix (see EntryRowView.swift's history for the original bug):
    // `FrequencyAnalyzer.repTargetPresetOrder` / `LoadWheelResolver
    // .historicalBandColors` each used to run their own full-table
    // SwiftData fetch + decode-every-set scan, called independently by
    // EVERY visible `EntryRowView`. Confirmed on-device: 233ms + 32ms per
    // call against the real dataset (124 sessions / 2372 sets). Caching the
    // per-row result in the row itself (an earlier fix) still meant N rows
    // appearing at once -- e.g. "复制上次课次", which creates a whole
    // session's worth of entries in one shot -- fired N of those calls
    // back-to-back, still visibly freezing. Computed ONCE here per
    // appearance/client-change instead, and handed down as plain data:
    // every row's per-render cost is now an O(1) dictionary lookup.
    @State private var repTargetPresetsCache: [RepTargetPreset] =
        FrequencyAnalyzer.baseRepTargetPresets + [FrequencyAnalyzer.customPreset]
    @State private var bandColorIndex: [String: [String]] = [:]

    private var currentClient: Client? {
        clientStore.currentClient(in: clients)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let client = currentClient {
                    if draft.isActive {
                        activeSessionBody(client: client)
                    } else {
                        SessionStartView(
                            client: client,
                            hasPriorSession: mostRecentSession(for: client) != nil,
                            unfinishedSession: unfinishedSession(for: client),
                            onStartEmpty: { draft.startNew(clientID: client.id) },
                            onCopyLast: { copyLastSession(client: client) },
                            onCopyFromHistory: { showingHistoryCopyPicker = true },
                            onSelectTemplate: { template in startFromTemplate(template, client: client) },
                            onContinueUnfinished: { session in
                                SessionEditingCoordinator.open(session, exercises: allExercises, into: draft, tabSelection: nil)
                            }
                        )
                        .sheet(isPresented: $showingHistoryCopyPicker) {
                            SessionCopyPickerView(client: client) { session in
                                showingHistoryCopyPicker = false
                                startFromCopy(of: session, client: client)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label(language.t("暫無學員", "No Clients"), systemImage: "person.crop.circle.badge.exclamationmark")
                    } description: {
                        Text(language.t("新增一位學員開始使用，或到「歷史」導入 Excel 訓練記錄", "Add a client to get started, or import Excel history from the History tab"))
                    } actions: {
                        Button(language.t("新增學員", "Add Client")) { createFirstClient() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .background(DS.C.canvas)
            .reserveFloatingTabBarSpace()
            .navigationTitle(language.t("今天", "Today"))
            .toolbarBackground(DS.C.canvas, for: .navigationBar)
            .toolbar {
                // GymLog 改版設計 §問題一：課次日期不再單獨佔一整行卡片，收進
                // 這個導航行、與學員切換 pill 同一 HStack 靠右對齊。沒有進行中
                // 課次時（例如「選擇動作」空狀態）不顯示日期，維持原本只有
                // 切換器居中的樣子。
                ToolbarItem(placement: .principal) {
                    if let client = currentClient {
                        HStack(spacing: 8) {
                            ClientSwitcherButton(currentClient: client, coordinator: switchCoordinator, tabSelection: tabSelection)
                            if draft.isActive {
                                Spacer(minLength: 8)
                                SessionDateChip(date: $draft.sessionDate)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .onAppear {
            if clientStore.currentClientID == nil {
                clientStore.currentClientID = clients.first?.id
            }
            refreshCaches()
            checkForDraftRestoreIfNeeded()
        }
        .onChange(of: clientStore.currentClientID) { oldValue, _ in
            refreshCaches()
            // 切换学员只清空了训练草稿（ClientSwitchCoordinator.performSwitch）
            // ——计时器和心率会话是这个视图单独持有的，保存/放弃都会结束它们，
            // 但切换学员之前没有，导致上一位学员的休息倒计时、蓝牙连接和本次
            // 心率统计继续留着（2026-09-06 审查报告 #8）。挂在这里而不是仅仅
            // 在 ClientSwitchCoordinator 里，是因为无论切换是从这个 tab 的切
            // 换按钮触发，还是从历史 tab 等别处触发，`currentClientID` 变化都
            // 会经过这里，一处清理覆盖所有入口。
            endActiveWorkoutSession()
            // `oldValue != nil` 排除了"App 冷启动时把 currentClientID 从 nil
            // 设成第一位学员"那次触发——那不是一次教练发起的切换，如果这时候
            // 顺手清掉磁盘快照，会在 checkForDraftRestoreIfNeeded 还没来得及
            // 读取之前就把它删掉。真正的切换（已经有一个学员，换成另一个）才
            // 等于确认放弃了原学员的草稿（ClientSwitchCoordinator 的未保存
            // 工作确认弹窗已经问过一次），这时磁盘上的自动保存快照才该一并清
            // 掉，否则下次重启会提示恢复一份教练已经主动放弃的草稿。
            if oldValue != nil {
                draftPersistence.clear()
            }
        }
        .alert(language.t("保存失敗", "Save Failed"), isPresented: Binding(get: { saveErrorMessage != nil }, set: { if !$0 { saveErrorMessage = nil } })) {
            Button(language.t("好", "OK"), role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "")
        }
        .alert(language.t("已保存", "Saved"), isPresented: Binding(get: { saveSuccessMessage != nil }, set: { if !$0 { saveSuccessMessage = nil } })) {
            Button(language.t("好", "OK"), role: .cancel) {}
        } message: {
            Text(saveSuccessMessage ?? "")
        }
        .alert(language.t("發現未保存的訓練草稿", "Found an unsaved draft"), isPresented: Binding(
            get: { pendingDraftRestore != nil },
            set: { if !$0 { pendingDraftRestore = nil } }
        )) {
            Button(language.t("捨棄", "Discard"), role: .destructive) {
                draftPersistence.clear()
                pendingDraftRestore = nil
            }
            Button(language.t("恢復草稿", "Restore Draft")) {
                restorePendingDraft()
            }
        } message: {
            if let snapshot = pendingDraftRestore {
                Text(language.t(
                    "上次退出時還有一份未保存的訓練（\(RelativeTime.string(from: snapshot.savedAt))），要繼續嗎？",
                    "There's an unsaved session from last time (\(RelativeTime.string(from: snapshot.savedAt))). Continue it?"
                ))
            }
        }
        .alert(language.t("部分動作未能恢復", "Some Exercises Couldn't Be Restored"), isPresented: Binding(
            get: { draftRestoreDroppedCount != nil },
            set: { if !$0 { draftRestoreDroppedCount = nil } }
        )) {
            Button(language.t("好", "OK"), role: .cancel) {}
        } message: {
            Text(language.t(
                "有 \(draftRestoreDroppedCount ?? 0) 個動作已從動作庫中刪除或合併，未能恢復，其餘內容已恢復，請檢查後再保存。",
                "\(draftRestoreDroppedCount ?? 0) exercise(s) were deleted or merged from the library and couldn't be restored; the rest has been restored — please review before saving."
            ))
        }
        // 2026-09-07 审阅 B02: 恢复时如果动作分类已变更，原记录单位无法从
        // 快照确认（旧版快照没有存单位），只能按当前分类猜测——必须明确告知，
        // 不能悄悄当作确定值。
        .alert(language.t("部分記錄單位需要核對", "Some Recorded Units Need Review"), isPresented: Binding(
            get: { draftRestoreMetricUncertainCount != nil },
            set: { if !$0 { draftRestoreMetricUncertainCount = nil } }
        )) {
            Button(language.t("好", "OK"), role: .cancel) {}
        } message: {
            Text(language.t(
                "有 \(draftRestoreMetricUncertainCount ?? 0) 個動作的記錄單位無法從舊草稿確認，已按動作庫目前的分類顯示，請核對後再保存。",
                "\(draftRestoreMetricUncertainCount ?? 0) exercise(s)' recorded unit couldn't be confirmed from the old draft and are shown using the library's current classification — please review before saving."
            ))
        }
        // B08: the saved draft's client no longer exists -- restoring would
        // silently attribute it to whichever client happens to be selected
        // right now. Only "discard" is offered; the snapshot stays on disk
        // (available for restore once the client exists again) if dismissed.
        .alert(language.t("原學員已不存在", "Original Client No Longer Exists"), isPresented: Binding(
            get: { draftRestoreBlockedMissingClient != nil },
            set: { if !$0 { draftRestoreBlockedMissingClient = nil } }
        )) {
            Button(language.t("捨棄草稿", "Discard Draft"), role: .destructive) {
                draftPersistence.clear()
                draftRestoreBlockedMissingClient = nil
            }
            Button(language.t("稍後處理", "Later"), role: .cancel) { draftRestoreBlockedMissingClient = nil }
        } message: {
            Text(language.t(
                "上次退出時未保存的訓練所屬學員已被刪除，為避免記到錯誤學員身上，無法自動恢復。",
                "The client this unsaved session belonged to has been deleted. To avoid attributing it to the wrong client, it can't be restored automatically."
            ))
        }
        .alert(language.t("發現一份損壞的草稿", "Found a Corrupted Draft"), isPresented: $draftQuarantinedNotice) {
            Button(language.t("好", "OK"), role: .cancel) {}
        } message: {
            Text(language.t(
                "上次退出時的草稿檔案已損壞，未能恢復，原始檔案已另存供排查。",
                "The draft file from last time was corrupted and couldn't be restored; the original file has been kept aside for diagnosis."
            ))
        }
        // 2026-09-09：从歷史打开一节课继续编辑时，动作库里已被删掉/合并的条目
        // 会被跳过——和模板/草稿恢复一样必须明确说出来，不能让内容悄悄变少。
        // 计数由 `SessionEditingCoordinator` 放进草稿里（它在歷史那一侧运行，
        // 弹窗要在教练落地的这一侧弹）。
        .alert(language.t("部分動作未能載入", "Some Exercises Couldn't Be Loaded"), isPresented: Binding(
            get: { draft.pendingLoadDroppedEntryCount != nil },
            set: { if !$0 { draft.pendingLoadDroppedEntryCount = nil } }
        )) {
            Button(language.t("好", "OK"), role: .cancel) {}
        } message: {
            Text(language.t(
                "這節課有 \(draft.pendingLoadDroppedEntryCount ?? 0) 個動作已從動作庫中刪除或合併，未能載入編輯器；直接按「結束課次」會讓它們從這節記錄裡消失。",
                "\(draft.pendingLoadDroppedEntryCount ?? 0) exercise(s) in this session were deleted or merged from the library and couldn't be loaded — finishing the session as-is would drop them from the record."
            ))
        }
        .alert(language.t("部分模板動作未能加入", "Some Template Exercises Couldn't Be Added"), isPresented: Binding(get: { templateResolutionWarning != nil }, set: { if !$0 { templateResolutionWarning = nil } })) {
            Button(language.t("好", "OK"), role: .cancel) {}
        } message: {
            Text(templateResolutionWarning ?? "")
        }
        .alert(language.t("部分動作未能複製", "Some Exercises Couldn't Be Copied"), isPresented: Binding(get: { copyResolutionWarning != nil }, set: { if !$0 { copyResolutionWarning = nil } })) {
            Button(language.t("好", "OK"), role: .cancel) {}
        } message: {
            Text(copyResolutionWarning ?? "")
        }
        .sheet(isPresented: $showingSupersetTemplatePicker) {
            SessionTemplatePickerView(
                onSelect: { template in
                    if let client = currentClient {
                        addSupersetFromTemplate(template, client: client)
                    }
                },
                filter: { $0.isSupersetOnly },
                titleOverride: (zh: "選擇 Superset 模板", en: "Select Superset Template"),
                emptyStateOverride: (
                    title: (zh: "暫無 Superset 模板", en: "No Superset Templates"),
                    description: (zh: "請先在「動作庫」的「Superset 模板」分段中創建", en: "Please create one under \"Exercises\" › \"Superset Templates\" first")
                ),
                onManualFallback: { exercisePickerTarget = .newSuperset },
                manualFallbackLabel: (zh: "找不到想要的組合？手動選擇動作", en: "Can't find the combo you want? Pick exercises manually")
            )
        }
        .sheet(isPresented: $showingWODTemplatePicker) {
            SessionTemplatePickerView(
                onSelect: { template in
                    if let client = currentClient {
                        addWODFromTemplate(template, client: client)
                    }
                },
                filter: { $0.isWODOnly },
                titleOverride: (zh: "選擇 WOD 模板", en: "Select WOD Template"),
                emptyStateOverride: (
                    title: (zh: "暫無 WOD 模板", en: "No WOD Templates"),
                    description: (zh: "知名的 CrossFit 基準 WOD 會顯示在這裡", en: "Well-known CrossFit benchmark WODs will appear here")
                ),
                onManualFallback: { exercisePickerTarget = .newWODBlock },
                manualFallbackLabel: (zh: "找不到想要的 WOD？手動輸入", en: "Can't find the WOD you want? Enter one manually")
            )
        }
    }

    // MARK: - Active session

    @ViewBuilder
    private func activeSessionBody(client: Client) -> some View {
        let energy = EnergyLookup(report: TrainingInsights.draft(draft, client: client))
        ScrollView {
            VStack(spacing: DS.Space.cardGap) {
                ForEach(Array(draft.blocks.enumerated()), id: \.element.id) { blockIndex, block in
                    if block.sectionKind == .wod, let wodDraft = block.wodDraft {
                        WODBlockDraftCard(wodDraft: wodDraft, allExercises: allExercises, activeWODTimerOwnerID: $draft.activeWODTimerOwnerID, energyText: energy.block(blockIndex)) {
                            removeBlock(block)
                        }
                    } else if block.sectionKind == .strength, block.blockType == .superset {
                        // P1 (2026-09-11)：Superset 走專門的卡片（A1/A2 標識、
                        // 輪次同步、組間休息觸發）——`dropset`/`circuit` 不受
                        // 影響，繼續用下面的通用 `BlockDraftCard`。
                        SupersetBlockDraftCard(
                            block: block,
                            clientID: client.id,
                            bandColorIndex: bandColorIndex,
                            canMoveUp: canMoveBlock(block, by: -1),
                            canMoveDown: canMoveBlock(block, by: 1),
                            onMove: { offset in moveBlock(block, by: offset) },
                            onDissolve: { dissolveSuperset(block) },
                            onDelete: { removeBlock(block) },
                            energyText: energy.block(blockIndex),
                            onStartRest: { seconds in
                                restTimer.setTotal(seconds)
                                restTimer.start()
                            }
                        )
                    } else {
                        BlockDraftCard(
                            block: block,
                            clientID: client.id,
                            repTargetPresets: repTargetPresetsCache,
                            bandColorIndex: bandColorIndex,
                            canMoveUp: canMoveBlock(block, by: -1),
                            canMoveDown: canMoveBlock(block, by: 1),
                            onDeleteEntry: { entryID in removeEntry(entryID, from: block) },
                            onAddEntry: { exercisePickerTarget = .existingBlock(block.id) },
                            onMove: { offset in moveBlock(block, by: offset) },
                            onDelete: { removeBlock(block) },
                            energyText: { entryIndex in energy.entry(blockIndex, entryIndex) }
                        )
                    }
                }

                // 「往这堂课里加内容」——虚线描边的加号按钮，与下面那组「结束
                // 这堂课」的实心按钮在形状、颜色、高度上都不同一档
                // （2026-09-09 教练反馈：几个按钮都一样大，看不出性质不同）。
                HStack(spacing: 12) {
                    Button {
                        exercisePickerTarget = .newBlock
                    } label: {
                        Label(language.t("添加動作", "Add Exercise"), systemImage: "plus")
                    }
                    .buttonStyle(.gymAdd)
                    .accessibilityIdentifier("add-exercise-button")

                    // 2026-09-17：預設先從模板庫選，模板裡沒有想要的組合/WOD
                    // 才手動一個個加動作（`SessionTemplatePickerView` 的
                    // `onManualFallback` 接手既有的 `exercisePickerTarget` 流程）。
                    Button {
                        showingSupersetTemplatePicker = true
                    } label: {
                        Label(language.t("添加 Superset", "Add Superset"), systemImage: "plus")
                    }
                    .buttonStyle(.gymAdd)
                    .accessibilityIdentifier("add-superset-button")

                    Button {
                        showingWODTemplatePicker = true
                    } label: {
                        Label(language.t("添加 WOD", "Add WOD"), systemImage: "plus")
                    }
                    .buttonStyle(.gymAdd)
                    .accessibilityIdentifier("add-wod-button")
                }
                .padding(.top, 4)

                // P1 (2026-09-11)：把已經錄好的幾個獨立動作事後合併成一個
                // Superset——只有存在 2 個以上符合條件的獨立動作時才有意義，
                // 沒有時按下去也不會弹出可組成的清單，直接禁用更誠實。
                if composeSupersetEligibleBlocks.count >= 2 {
                    Button {
                        showingComposeSuperset = true
                    } label: {
                        Label(language.t("組成 Superset", "Combine into Superset"), systemImage: "square.on.square")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.C.textMid)
                    .padding(.top, 2)
                    .accessibilityIdentifier("compose-superset-button")
                }

                // P2 (2026-09-11)：「分享計劃」只分享處方（重量/組數/次數/
                // 時間/距離、Superset 順序/休息、WOD 處方），不含實際成績——
                // 直接讀活躍草稿，不要求已經暫存過。
                Button {
                    sharePlan(client: client)
                } label: {
                    Label(language.t("分享計劃", "Share Plan"), systemImage: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.C.textMid)
                .disabled(draft.blocks.isEmpty)
                .accessibilityIdentifier("share-plan-button")

                // 2026-09-13：語音入口已升級成 App 全局常駐按鈕（見
                // `ContentView`/`GlobalVoiceButton`），這裡不再重複放一顆
                // 只在今天頁才看得到的入口——執行 Prompt §4.1「語音不再藏
                // 在添加動作下的小按鈕裡」正是要移除這一顆。

                // 一条分隔线把「编辑这堂课的内容」和「处置这堂课」两件事在视觉
                // 上切开。上面是加内容，下面是收工。
                sessionActionsDivider

                // 2026-09-09 教练要求把「保存」拆成两件事：「暫時保存」防止中途
                // 丢数据、课次仍然开着可以接着录；「結束課次」才是真的收工、把
                // 这一节标成已完成。两个按钮必须同时存在——只有一个「保存」时，
                // 教练中途想存一下，就只能选择结束这堂课。
                //
                // 「結束課次」独占一整行、实心 accent、带对勾：整屏只有它一个
                // 长这样，是唯一的「做完了」按钮。「暫時保存」退到下面一行、
                // 描边不填色、宽度只占一半，与同一行的「放棄」并列——两个都是
                // 「先不收工」的处置动作，只是一个留下、一个不留。
                Button {
                    commit(client: client, finishing: true)
                } label: {
                    Label(language.t("結束課次，存入歷史", "Finish Session"), systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.gymPrimary)
                .disabled(!canCommit)
                .opacity(canCommit ? 1 : 0.4)

                HStack(spacing: 12) {
                    Button {
                        commit(client: client, finishing: false)
                    } label: {
                        Label(language.t("暫時保存", "Save Draft"), systemImage: "tray.and.arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.gymSecondary)
                    .disabled(!canCommit)
                    .opacity(canCommit ? 1 : 0.4)

                    discardButton
                }

            }
            .padding(DS.Space.pageMargin)
        }
        .reserveFloatingTabBarSpace()
        // 教练的原话是「把这个倒计时放在训练界面的正上方」。用 safeAreaInset
        // 钉在顶部而不是塞进 ScrollView 第一行：组间休息恰恰是教练一边往下翻
        // 动作卡片一边要按的东西，跟着内容滚走就失去意义了。
        .safeAreaInset(edge: .top) {
            sessionTopBar
        }
        .sheet(item: $exercisePickerTarget) { target in
            ExercisePickerSheet(
                allExercises: allExercises,
                clientID: client.id,
                initialDiscipline: target.initialDiscipline,
                // 新建 WOD 时允许"库里没有就直接用这个名字"——WOD 动作名一直
                // 可以是自由文本（见 `WODMovementDraft.nameText`），力量录入
                // 则必须落到一个真的 `Exercise` 上，所以只在 WOD 这一支给。
                onUseRawName: target == .newWODBlock ? { name in addWODBlock(movementName: name, exercise: nil) } : nil
            ) { exercise in
                addEntry(for: exercise, clientID: client.id, into: target)
            }
        }
        .sheet(isPresented: $showingComposeSuperset) {
            ComposeSupersetSheet(eligibleBlocks: composeSupersetEligibleBlocks) { selectedIDs in
                composeSuperset(from: selectedIDs)
            }
        }
        .sheet(isPresented: Binding(get: { sharedPlanURL != nil }, set: { if !$0 { sharedPlanURL = nil } })) {
            if let sharedPlanURL {
                ExchangeShareChoiceSheet(fileURL: sharedPlanURL, text: sharedPlanText)
            }
        }
        .alert(language.t("分享失敗", "Share Failed"), isPresented: Binding(get: { sharePlanErrorMessage != nil }, set: { if !$0 { sharePlanErrorMessage = nil } })) {
            Button(language.t("好", "OK"), role: .cancel) {}
        } message: {
            Text(sharePlanErrorMessage ?? "")
        }
        .onAppear {
            restTimer.onFinish = { RestTimerAlarm.ring() }
            restTimer.onScheduleChange = { deadline in scheduleRestAlert(deadline: deadline) }
            // B08: autosave must not depend solely on scenePhase transitions
            // -- a coach who never backgrounds the app during a long active
            // session (crash, force-quit while foregrounded) would find the
            // on-disk snapshot stale by however long ago the last background
            // transition was, or missing entirely if there was never one
            // this session. Debounced-on-edit observation below is the
            // primary autosave path; scenePhase remains a supplementary one.
            startObservingDraftForAutosave()
        }
        // 回到前台时按墙钟补算一次：倒计时是按 deadline 记的，切走的那段时间
        // 同样要算进休息里（见 RestTimerModel 的说明）。
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { restTimer.sync() }
            // 草稿自动保存：一旦不再处于前台，系统随时可能把进程挂起后杀掉、
            // 不会再给任何回调机会，所以在这里落盘，而不是等到某个"结束"操作
            // 被点击才保存。
            if phase == .inactive || phase == .background {
                persistDraftIfNeeded()
                // 2026-09-13：語音錄音的後台取消已經挪到 `ContentView`
                // 自己的 `.onChange(of: scenePhase)`（協調器現在是全局的）。
            }
        }
    }

    /// 「加内容」与「收工」之间的那条线。左右留白比页边距再收一点，读起来是
    /// 「同一页里的两段」，不是「两张卡片」。
    private var sessionActionsDivider: some View {
        Rectangle()
            .fill(DS.C.hairline)
            .frame(height: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }

    /// 放棄 / 放棄編輯。与「暫時保存」并排放在最后一行——两者都是「先不收工」
    /// 的处置动作，一个留下一个不留，摆在一起才看得出是同一类选择。
    private var discardButton: some View {
        Button {
            // 放弃前确认（审查报告"适合当前范围的功能"第一批）：只有
            // 真的会丢东西才弹确认，空草稿直接放弃不必多此一举。
            if draft.blocks.isEmpty && draft.persistedSessionID == nil {
                discardDraft()
            } else {
                showingDiscardConfirmation = true
            }
        } label: {
            Label(discardButtonTitle, systemImage: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.C.danger)
        }
        .buttonStyle(.gymTertiary)
        .confirmationDialog(
            discardButtonTitle,
            isPresented: $showingDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.t("關閉編輯", "Close Editor")) {
                discardDraft()
            }
            // 只有「本轮暫存出来、还没结束」的那一节才给删除入口。已经
            // 结束、或本来就躺在歷史里的课次，绝不能因为一次「放棄」就
            // 消失——要删有歷史列表里的左滑删除，那里有它自己的确认。
            if canDeleteDraftSession {
                Button(language.t("刪除這次暫存的記錄", "Delete This Saved Draft"), role: .destructive) {
                    deleteDraftSessionAndDiscard()
                }
            }
            Button(language.t("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(discardDialogMessage)
        }
    }

    private var sessionTopBar: some View {
        VStack(spacing: 4) {
            RestTimerHeaderRow(timer: restTimer) {
                HeartRateChip(monitor: heartRate, age: currentClient?.age)
            }
            if restAlertsAuthorized == false {
                // 与 WODBlockDraftCard 的同名提示一致：说清楚「后台不会响，画面
                // 上的计时照常」，而不是让教练以为提醒坏了。
                HStack(spacing: 4) {
                    Image(systemName: "bell.slash")
                    Text(language.t(
                        "尚未授權通知，App 切到背景時休息結束不會響鈴（畫面上的倒計時仍照常）。",
                        "Notifications aren't authorized — no alert when rest ends while backgrounded (the on-screen countdown still runs)."
                    ))
                }
                .font(.system(size: 11))
                .foregroundStyle(DS.C.textLow)
            }
            if lastAutosaveFailed {
                // B08: "轻量可见状态，不只打日志" -- a small non-blocking
                // caption, not an alert that would interrupt entry.
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(language.t("自動保存失敗，請盡快手動保存", "Autosave failed — save manually soon"))
                }
                .font(.system(size: 11))
                .foregroundStyle(DS.C.danger)
            }
        }
        .padding(.horizontal, DS.Space.pageMargin)
        .padding(.bottom, 8)
        .background(DS.C.canvas)
    }

    /// 把「休息倒计时到点」这件事提前交给系统排程（`RestTimerNotificationScheduler`）。
    ///
    /// 教练 2026-09-09 的反馈是到期只显示、不响。前台那条路径（`RestTimerAlarm`）
    /// 本来就在，真正缺的是 App 不在前台的那一分钟——计时器的 tick 被系统挂起，
    /// 到点时没有任何代码在跑。本地通知由系统在到点时刻投递，与 App 是否在跑无关。
    private func scheduleRestAlert(deadline: Date?) {
        guard let deadline else {
            RestTimerNotificationScheduler.cancel()
            return
        }
        // 顺手唤醒 Taptic Engine，让一分钟后的第一下震动不被吞掉。
        RestTimerAlarm.prepare()
        let totalSeconds = restTimer.totalSeconds
        if restAlertsAuthorized == true {
            RestTimerNotificationScheduler.schedule(at: deadline, totalSeconds: totalSeconds)
            return
        }
        Task { @MainActor in
            let authorized = await WODTimerNotificationScheduler.requestAuthorizationIfNeeded()
            restAlertsAuthorized = authorized
            // 授权弹窗期间教练可能已经暂停、重置或换了预设时长；只有计时器还在跑
            // 且跑的仍是刚才那一轮（deadline 未变），补排才是对的。
            guard authorized, restTimer.isRunning, restTimer.deadline == deadline else { return }
            RestTimerNotificationScheduler.schedule(at: deadline, totalSeconds: totalSeconds)
        }
    }

    /// Debounced autosave-on-edit (B08). `withObservationTracking`'s
    /// operation closure reads through `draft.snapshot()` -- which touches
    /// every `@Observable` property (blocks/entries/rounds/quantities) that
    /// could make the draft worth persisting -- so `onChange` fires on any
    /// of those mutating, not just scenePhase transitions. Each firing
    /// re-registers itself (`withObservationTracking` only ever fires once
    /// per registration) as long as a session is still active.
    private func startObservingDraftForAutosave() {
        withObservationTracking {
            _ = draft.snapshot()
        } onChange: {
            Task { @MainActor in
                scheduleDebouncedAutosave()
                if draft.isActive {
                    startObservingDraftForAutosave()
                }
            }
        }
    }

    private func scheduleDebouncedAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            persistDraftIfNeeded()
        }
    }

    // MARK: - Entry management

    /// 把选中的动作放到哪儿：新开一个力量训练块、加进某个已有的块里，还是
    /// 新开一个 WOD 并把它作为第一个动作。
    private enum ExercisePickerTarget: Identifiable, Equatable {
        case newBlock
        case existingBlock(UUID)
        /// 2026-09-09 教练反馈：「新开一个 WOD 时默认给的是空的，不像 Exercise
        /// 每新开一个都会先让我选择运动」。现在「添加 WOD」也先选动作，选完才
        /// 建块，两个入口的手感一致。
        case newWODBlock
        /// P1 (2026-09-11)：跟 WOD 同一条规矩——先选第一个动作，直接建一个
        /// 只有 1 个成员的 Superset block；第二个成员用卡片自己的「加入動作」
        /// 补上，不做「连续弹两次选择器」的状态机（那条路径需要在一个 sheet
        /// 关闭动画进行时重新触发另一个 sheet，属于 P0 刚修过的那类风险，能
        /// 避免就避免）。
        case newSuperset

        var id: String {
            switch self {
            case .newBlock: return "new"
            case .newWODBlock: return "new-wod"
            case .newSuperset: return "new-superset"
            case .existingBlock(let blockID): return blockID.uuidString
            }
        }

        /// WOD 的动作面板默认落在 CrossFit 筛选上；力量录入不预设，保持「全部」。
        var initialDiscipline: ExerciseDiscipline? {
            self == .newWODBlock ? .crossfit : nil
        }
    }

    private func canMoveBlock(_ block: BlockDraft, by offset: Int) -> Bool {
        guard let index = draft.blocks.firstIndex(where: { $0.id == block.id }) else { return false }
        return draft.blocks.indices.contains(index + offset)
    }

    /// 上移/下移一个训练块。用两个按钮而不是拖拽排序：这一屏是 `ScrollView` +
    /// `ForEach`，`onMove` 只有 `List` 才有，为了拖拽把整屏改成 List 会连带动
    /// 到每一张卡片的布局，代价远大于收益。
    private func moveBlock(_ block: BlockDraft, by offset: Int) {
        guard let index = draft.blocks.firstIndex(where: { $0.id == block.id }) else { return }
        let target = index + offset
        guard draft.blocks.indices.contains(target) else { return }
        draft.blocks.swapAt(index, target)
    }

    /// P3/M3a (2026-09-12): the actual block/entry-list mutation logic moved
    /// into `TodayDraftMutationService` (`GymLogKit`) so the voice command
    /// service can call the SAME implementation -- this stays as a thin
    /// routing layer over `ExercisePickerTarget` (a `TodayView`-private type
    /// the service knows nothing about) plus the `.newWODBlock` branch,
    /// which is out of the service's scope entirely (WOD isn't part of any
    /// of P3's 6 voice commands).
    private func addEntry(for exercise: Exercise, clientID: String, into target: ExercisePickerTarget) {
        if target == .newWODBlock {
            addWODBlock(movementName: exercise.canonicalName, exercise: exercise)
            return
        }
        let placement: TodayDraftMutationService.EntryPlacement
        switch target {
        case .newWODBlock:
            // 上面那个 early return 已经处理掉了；留一个显式分支而不是 default，
            // 这样以后再加目标类型时编译器还会在这里报错提醒。
            return
        case .newSuperset:
            placement = .newSuperset
        case .newBlock:
            placement = .newBlock
        case .existingBlock(let blockID):
            placement = .existingBlock(blockID)
        }
        TodayDraftMutationService.addEntry(exercise, clientID: clientID, placement: placement, draft: draft, context: modelContext)
    }

    private func removeEntry(_ entryID: UUID, from block: BlockDraft) {
        TodayDraftMutationService.removeEntry(entryID, from: block.id, draft: draft)
    }

    // MARK: - Superset composition (P1, 2026-09-11)

    /// 只有力量、单一 `.single`、只有 1 个成员的 block 才能被「组成
    /// Superset」选中——WOD、已经是多成员组合的 block 不能被隐式并进来
    /// （CONTRACT 2026-09-11 P1 §4.1）。
    private var composeSupersetEligibleBlocks: [BlockDraft] {
        draft.blocks.filter { $0.sectionKind == .strength && $0.blockType == .single && $0.entries.count == 1 }
    }

    /// 把选中的几个独立动作合并成一个新 Superset block，插在最靠前那个被选
    /// block 的原位置，按原有相对顺序排列；其余 block 顺序不变地补上空位。
    private func composeSuperset(from selectedIDs: Set<UUID>) {
        TodayDraftMutationService.composeSuperset(selectedBlockIDs: selectedIDs, draft: draft)
    }

    /// 「解散為獨立動作」：拆回 N 个独立 `.single` block，顺序＝原成员顺序，
    /// 每个成员的 `rounds` 数据原样保留（不做任何数值调整）。
    private func dissolveSuperset(_ block: BlockDraft) {
        TodayDraftMutationService.dissolveSuperset(block.id, draft: draft)
    }

    // MARK: - WOD block management (M2 CrossFit extension)

    /// 新建一个 WOD 段落，第一个动作已经填好。
    ///
    /// 2026-09-09 之前这里建的是一个空 WOD（`WODBlockDraft()` 自带一个空动作
    /// 行），教练的反馈是「不像 Exercise 每新开一个都会先让我选择运动，后者
    /// 比较符合逻辑」——所以入口改成先弹选动作面板，选完才走到这里。
    /// `exercise` 为 nil 表示教练在面板里直接用了一个库里没有的名字。
    private func addWODBlock(movementName: String, exercise: Exercise?) {
        let movement = WODMovementDraft(exercise: exercise, nameText: movementName)
        if let exercise { movement.applyExercise(exercise) }
        draft.blocks.append(BlockDraft(sectionKind: .wod, wodDraft: WODBlockDraft(movements: [movement])))
    }

    private func removeBlock(_ block: BlockDraft) {
        TodayDraftMutationService.removeBlock(block.id, draft: draft)
    }

    /// Every WOD block must have at least one movement with a non-empty
    /// name before Save is enabled -- mirrors the existing "添加動作" flow's
    /// implicit guarantee (a strength entry can't exist without a resolved
    /// `Exercise`) for WOD's free-text movement names.
    private var hasInvalidWODBlock: Bool {
        draft.blocks.contains { block in
            guard block.sectionKind == .wod, let wodDraft = block.wodDraft else { return false }
            return wodDraft.movements.contains { $0.nameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    // MARK: - Copy last session (CONTRACT-UI.md §3.5)

    /// Recomputes the two shared caches every `EntryRowView` reads from
    /// instead of fetching independently -- see the perf-fix comment on
    /// their declarations above. `client.sessions` (a relationship walk) is
    /// used rather than a fresh `context.fetch(FetchDescriptor<WorkoutSession>())`
    /// so this only touches the current client's own history, not every
    /// client's.
    private func refreshCaches() {
        guard let client = currentClient else { return }
        repTargetPresetsCache = FrequencyAnalyzer.repTargetPresetOrder(clientSessions: client.sessions ?? [])
        bandColorIndex = LoadWheelResolver.bandColorIndex(entries: allEntries)
    }

    /// Same "blank local client" convention as `ClientSwitcherButton.createBlankClient`
    /// (name `""` -> reads as "默认用户" via `displayName`) -- needed here as
    /// its own copy because that button only renders once `currentClient`
    /// already exists (its own `currentClient: Client` parameter is
    /// non-optional), which a genuinely fresh install -- no bundled client
    /// or history, only the approved exercise library, see
    /// `ContentView.importFixtureIfNeeded` -- never has on first launch.
    private func createFirstClient() {
        let client = Client(id: "cl-local-\(UUID().uuidString)", name: "")
        modelContext.insert(client)
        do {
            try modelContext.save()
            clientStore.currentClientID = client.id
        } catch {
            modelContext.rollback()
            saveErrorMessage = error.localizedDescription
        }
    }

    /// 只看已经结束的课次。「複製上次課次」要复制的是上一堂**练完的**课，
    /// 而 `nextWeekNumber` 更是必须跳过进行中的那一节——否则一节课在暫存和
    /// 結束之间会被自己算进「上一次」，週次每暫存一轮就多跳一格。
    /// 这位学员最近一节「暫存了但还没結束」的课次。同时存在多节（教练分别在
    /// 不同日期暫存过）时取日期最新的那一节。
    private func unfinishedSession(for client: Client) -> WorkoutSession? {
        (client.sessions ?? []).filter(\.isInProgress).max { $0.date < $1.date }
    }

    private func mostRecentSession(for client: Client) -> WorkoutSession? {
        (client.sessions ?? []).filter { !$0.isInProgress }.max { $0.date < $1.date }
    }

    private func copyLastSession(client: Client) {
        guard let last = mostRecentSession(for: client) else { return }
        startFromCopy(of: last, client: client)
    }

    /// 2026-09-16：「複製上次課次」與「從歷史記錄選擇」共用的複製邏輯——
    /// 兩者現在都透過 `SessionDraftLoader.copy` 完整帶出每個動作原本的所有
    /// Round（不再只取第一組簡化成一輪），差異只在於挑的是哪一節課。
    /// `SessionDraftLoader.copy` 本身已經處理好「新的一天」該有的重置
    /// （WOD 成績清空、每輪「實際」標成未確認），這裡只負責把結果接上
    /// `draft` 並把跳過的動作數量顯示成提示。
    private func startFromCopy(of session: WorkoutSession, client: Client) {
        draft.startNew(clientID: client.id)
        let result = SessionDraftLoader.copy(from: session, exercises: allExercises)
        draft.blocks.append(contentsOf: result.blocks)
        if result.droppedEntryCount > 0 {
            copyResolutionWarning = language.t(
                "這節課有 \(result.droppedEntryCount) 個動作已從動作庫中刪除或合併，未能複製；其餘動作已加入今天的課次。",
                "\(result.droppedEntryCount) exercise(s) from that session were deleted or merged from the library and couldn't be copied; the rest have been added to today's session."
            )
        }
    }

    // MARK: - Start from template (CONTRACT-M4.md §4.4 / §5 seam)

    /// Thin UI wrapper around `TemplateSessionBuilder.build` (AppState,
    /// directly unit-tested) -- opens a new draft, converts the template
    /// into blocks/entries, and turns any unresolved `exerciseID`s into a
    /// visible coach-facing alert rather than a silent drop, per
    /// CONTRACT-M4.md's explicit risk callout.
    private func startFromTemplate(_ template: SessionTemplate, client: Client) {
        draft.startNew(clientID: client.id)
        let result = TemplateSessionBuilder.build(from: template, clientID: client.id, allExercises: allExercises, in: modelContext)
        draft.blocks.append(contentsOf: result.blocks)

        if result.unresolvedSlotCount > 0 {
            let totalSlots = template.orderedBlocks.reduce(0) { $0 + $1.orderedSlots.count }
            let word = language.t(
                totalSlots == result.unresolvedSlotCount ? "全部" : "\(result.unresolvedSlotCount) 個",
                totalSlots == result.unresolvedSlotCount ? "all" : "\(result.unresolvedSlotCount)"
            )
            templateResolutionWarning = language.t(
                "模板「\(template.name)」中有\(word)動作未能匹配到當前動作庫（可能已被合並或刪除），已跳過；其餘動作已加入課次，請檢查後再保存。",
                "\(word) exercise(s) in template \"\(template.name)\" couldn't be matched to the current exercise library (possibly merged or deleted) and were skipped; the rest have been added to this session — please review before saving."
            )
        }
    }

    /// 2026-09-16：與 `startFromTemplate` 共用同一個 `TemplateSessionBuilder`
    /// 轉換，但**不**呼叫 `draft.startNew`——這裡是把 Superset 模板的那個
    /// block 加進「目前這堂課」，不是開一堂新課，跟「添加動作」「添加
    /// Superset」兩顆按鈕一樣是純新增。一個 superset 模板照定義只有一個
    /// `.superset` block，所以 `result.blocks` 正常情況下就是那一個 block；
    /// 未能解析的動作走同一套「加入但提示」慣例，不整塊丟棄。
    private func addSupersetFromTemplate(_ template: SessionTemplate, client: Client) {
        let result = TemplateSessionBuilder.build(from: template, clientID: client.id, allExercises: allExercises, in: modelContext)
        draft.blocks.append(contentsOf: result.blocks)

        if result.unresolvedSlotCount > 0 {
            let totalSlots = template.orderedBlocks.reduce(0) { $0 + $1.orderedSlots.count }
            let word = language.t(
                totalSlots == result.unresolvedSlotCount ? "全部" : "\(result.unresolvedSlotCount) 個",
                totalSlots == result.unresolvedSlotCount ? "all" : "\(result.unresolvedSlotCount)"
            )
            templateResolutionWarning = language.t(
                "Superset 模板「\(template.name)」中有\(word)動作未能匹配到當前動作庫（可能已被合並或刪除），已跳過。",
                "\(word) exercise(s) in superset template \"\(template.name)\" couldn't be matched to the current exercise library (possibly merged or deleted) and were skipped."
            )
        }
    }

    /// 2026-09-17：跟 `addSupersetFromTemplate` 同一種「純新增、不 startNew」
    /// 手法——一個 WOD 模板照定義只有一個 `sectionKind == .wod` 的 block，
    /// `TemplateSessionBuilder.build` 既有的 WOD 分支（見該檔案）會把
    /// `block.wodPrescription` 轉成一份全新的 `WODBlockDraft`（成績重置、
    /// 處方原樣帶出，動作名稱走 `exerciseNameSnapshot` 快照，不像 strength
    /// slot 需要重新解析 `exerciseID`，所以這裡沒有「部分動作未能匹配」的
    /// 提示需要處理），這裡只需要把結果接到目前這堂課。
    private func addWODFromTemplate(_ template: SessionTemplate, client: Client) {
        let result = TemplateSessionBuilder.build(from: template, clientID: client.id, allExercises: allExercises, in: modelContext)
        draft.blocks.append(contentsOf: result.blocks)
    }

    // MARK: - Save (CONTRACT-UI.md §3.6, 2026-09-09 拆成「暫存 / 結束」两步)

    /// 两个保存按钮共同的可用条件。空课次没什么可存的；WOD 动作名没填完的
    /// 课次存下去会留下一条没有名字的动作（与拆分之前的 `保存課次` 一致）。
    private var canCommit: Bool {
        !draft.blocks.isEmpty && !hasInvalidWODBlock
    }

    /// 「本轮暫存出来、还没結束」的那一节课——只有它可以在放棄时顺手删掉。
    private var canDeleteDraftSession: Bool {
        draft.persistedSessionID != nil && !draft.openedFromHistory
    }

    private var discardButtonTitle: String {
        draft.openedFromHistory
            ? language.t("放棄編輯", "Discard Edits")
            : language.t("放棄", "Discard")
    }

    private var discardDialogMessage: String {
        if draft.openedFromHistory {
            return language.t(
                "關閉編輯後，這次打開之後改的內容不會寫回歷史記錄，歷史裡的原記錄保持不變。",
                "Closing the editor drops the changes made since you opened it; the session in history stays as it was."
            )
        }
        if draft.persistedSessionID != nil {
            return language.t(
                "這堂課已經暫存進歷史記錄（標記為「進行中」）。關閉編輯只是收起這份草稿，記錄仍在歷史裡，可以隨時回來繼續。",
                "This session is already saved to history as \"In Progress\". Closing the editor just puts the draft away — the record stays in history and you can come back to it."
            )
        }
        return language.t(
            "這堂課還沒有存進歷史記錄，放棄之後就找不回來了。",
            "This session has never been saved to history — discarding it can't be undone."
        )
    }

    /// 把当前草稿写进 `WorkoutSession`。`finishing == false` 是「暫時保存」：
    /// 课次落库但标成 `isInProgress`，草稿继续开着；`finishing == true` 是
    /// 「結束課次」：同一节课标成已完成，草稿收起来。
    ///
    /// 两者走同一条写入路径而不是各写一遍，原因很直接——第二次「暫存」必须更新
    /// 第一次建出来的那一节，而不是再建一节新的（`draft.persistedSessionID`
    /// 就是这根线）。分成两个函数的话，「暫存三次再結束」几乎必然在歷史里留下
    /// 四条重复记录。
    /// UI-only wrapper around `SessionCommitService.commit(_:in:)` (2026-09-10
    /// extraction): resolves the App-target-only date conversion this
    /// service doesn't do itself, then turns its `Result` into the
    /// success/error banners and draft-lifecycle side effects (clearing the
    /// on-disk snapshot, ending the active rest-timer/heart-rate session)
    /// that only make sense at the view layer.
    private func commit(client: Client, finishing: Bool) {
        let input = SessionCommitService.Input(
            client: client, draftClientID: draft.clientID ?? "", existingSessionID: draft.persistedSessionID,
            sessionDateUTC: TrainingDayEncoding.utcDay(from: draft.sessionDate),
            newSessionDateRawText: TrainingDayEncoding.isoDateString(from: draft.sessionDate),
            weekNumberForNewSession: nextWeekNumber(for: client), plannedDurationMinutes: draft.plannedDurationMinutes,
            blocks: draft.blocks, finishing: finishing
        )
        switch SessionCommitService.commit(input, in: modelContext) {
        case .success(let output):
            if finishing {
                Task { @MainActor in
                    do { try await TrainingReviewCoordinator.generate(session: output.session, context: modelContext) }
                    catch { /* History provides an explicit retry without affecting the saved workout. */ }
                }
            }
            let summary = language.t(
                "\(client.displayName) · \(output.blockCount) 個訓練塊 · \(output.setCount) 組記錄",
                "\(client.displayName) · \(output.blockCount) blocks · \(output.setCount) sets logged"
            )
            if finishing {
                saveSuccessMessage = summary
                autosaveTask?.cancel()
                draft.reset()
                endActiveWorkoutSession()
                draftPersistence.clear()
            } else {
                draft.persistedSessionID = output.session.id
                saveSuccessMessage = language.t(
                    "已暫存（標記為「進行中」）\n\(summary)\n可以繼續錄入，錄完後按「結束課次」。",
                    "Saved as \"In Progress\"\n\(summary)\nKeep going — tap Finish Session when you're done."
                )
                // 磁盘快照要跟着更新，里面现在带着 persistedSessionID：进程被杀
                // 掉后恢复出来的草稿仍然指向同一节课，不会再建一份。
                persistDraftIfNeeded()
            }
        case .failure(.clientMismatch):
            // B08: never save against a client other than the one this
            // draft was actually built for -- the view's `currentClient`
            // and `draft.clientID` can disagree after a restore whose
            // original client no longer exists, or (defensively) after any
            // other path that could leave them out of sync. Silently
            // writing to the wrong client's history is exactly the failure
            // mode B08 exists to close off.
            saveErrorMessage = language.t(
                "草稿所屬學員與目前選擇的學員不一致，為避免記錯學員，已阻止保存。",
                "This draft's client doesn't match the currently selected client — save was blocked to avoid attributing it to the wrong client."
            )
        case .failure(.persistence(let error)):
            // CONTRACT-UI.md §3.6: "保存失败要有可见反馈，不得静默吞掉." The
            // service already rolled back the context on failure -- the
            // draft itself is untouched either way, so the coach can just
            // try again.
            saveErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Share plan (P2, 2026-09-11)

    /// `TodayDraftStore.persistedSessionID`（本节课已经暫存過時）被當作
    /// Exchange `recordID`——這樣同一節課改完再分享一次，接收端能認出「這是
    /// 同一個計劃的更新」而不是全新的一份；從未暫存過的草稿每次分享都是新
    /// 的 `recordID`，符合它本來就沒有穩定身份這件事。
    private func sharePlan(client: Client) {
        let package = ExchangeExporter.buildPlanPackage(
            blocks: draft.blocks, client: client, trainingDate: draft.sessionDate,
            weekNumber: nextWeekNumber(for: client), plannedDurationMinutes: draft.plannedDurationMinutes,
            existingSessionID: draft.persistedSessionID
        )
        do {
            sharedPlanURL = try ExchangeExporter.writeTempFile(package, suggestedFileName: ExchangeExporter.suggestedFileName(clientName: client.displayName, payloadKind: .plan))
            sharedPlanText = try ExchangeExporter.chatText(for: package)
        } catch {
            sharePlanErrorMessage = error.localizedDescription
        }
    }

    /// 这份草稿正在读写的那一节课（`persistedSessionID` 指向的），`nil` = 还
    /// 没落过库、或那一节已经在别处被删掉了（这时按新建处理，不报错）。
    private func existingDraftSession() -> WorkoutSession? {
        guard let id = draft.persistedSessionID else { return nil }
        var descriptor = FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func nextWeekNumber(for client: Client) -> Int {
        (mostRecentSession(for: client)?.weekNumber ?? 0) + 1
    }

    /// Ends the current "训练进行中" state (rest-timer countdown + Bluetooth
    /// heart-rate connection) -- the one path shared by 保存, 放弃, and
    /// switching clients, so none of them can forget the other two
    /// (2026-09-06 审查报告 #8). 课次结束就放掉蓝牙连接，别让它在 App 里空跑
    /// 一整天。
    private func endActiveWorkoutSession() {
        heartRate.endSession()
        restTimer.reset()
    }

    private func discardDraft() {
        autosaveTask?.cancel()
        draft.reset()
        endActiveWorkoutSession()
        draftPersistence.clear()
    }

    /// 「刪除這次暫存的記錄」：只在 `canDeleteDraftSession` 为真时出现，也就是
    /// 这一节确实是本轮暫存出来、还没結束的那一节。
    private func deleteDraftSessionAndDiscard() {
        if let session = existingDraftSession() {
            modelContext.delete(session)
            do {
                try modelContext.save()
            } catch {
                modelContext.rollback()
                saveErrorMessage = error.localizedDescription
                return
            }
        }
        discardDraft()
    }

    // MARK: - Draft autosave / restore

    /// Checked once per launch, only when no draft is already live in memory
    /// -- a saved snapshot only matters after the process was actually
    /// killed and restarted; if `draft.isActive` is already true, this app
    /// session never stopped, and a stale disk snapshot must not clobber it.
    private func checkForDraftRestoreIfNeeded() {
        guard !hasCheckedForDraftRestore else { return }
        hasCheckedForDraftRestore = true
        guard !draft.isActive else { return }
        switch draftPersistence.load() {
        case .none:
            break
        case .corrupted:
            // B08: surfaced distinctly from "nothing saved" -- the file was
            // already quarantined/removed by `load()` itself.
            draftQuarantinedNotice = true
        case .snapshot(let snapshot):
            // B08: if the snapshot's client no longer exists at all, do NOT
            // fall through to the normal restore prompt -- that path would
            // restore into whichever client happens to be currently
            // selected, silently misattributing the work. Offer discard-only
            // instead, and leave the snapshot on disk otherwise (it becomes
            // restorable again if that client ever comes back, e.g. an
            // accidental delete gets undone via a backup restore).
            if !clients.contains(where: { $0.id == snapshot.clientID }) {
                draftRestoreBlockedMissingClient = snapshot
            } else {
                pendingDraftRestore = snapshot
            }
        }
    }

    private func restorePendingDraft() {
        guard let snapshot = pendingDraftRestore else { return }
        pendingDraftRestore = nil
        // The snapshot's client may not be the one currently selected (the
        // coach could have switched clients, or restarted the app, since the
        // draft was auto-saved) -- restoring only makes sense if we also
        // switch back to that client. `checkForDraftRestoreIfNeeded` already
        // guarantees the client still exists before ever setting
        // `pendingDraftRestore`.
        if snapshot.clientID != clientStore.currentClientID {
            clientStore.currentClientID = snapshot.clientID
        }
        let (dropped, metricUncertain) = draft.restore(from: snapshot, exercises: allExercises)
        // B08: do NOT clear the disk snapshot here. If the app is killed
        // again before the coach explicitly saves or discards this restored
        // draft, the on-disk copy must still be there to restore from next
        // launch -- clearing immediately on restore (the old behavior) threw
        // away the only recovery source the moment it was used. It's only
        // cleared by an explicit save (`save(client:)`) or discard
        // (`discardDraft()`) from here on, same as the debounced autosave's
        // own writes. (`draft.isActive` flipping to true here re-renders
        // into `activeSessionBody`, whose own `.onAppear` starts the
        // debounced-autosave observer -- no separate call needed here.)
        if dropped > 0 {
            draftRestoreDroppedCount = dropped
        }
        if metricUncertain > 0 {
            draftRestoreMetricUncertainCount = metricUncertain
        }
    }

    /// Writes the current draft to disk if there's anything worth saving --
    /// called both by the debounced edit-observer (`scheduleDebouncedAutosave`)
    /// and whenever the scene stops being active (see `activeSessionBody`'s
    /// `onChange(of: scenePhase)`), which is the point at which iOS can
    /// suspend and later kill the process without further warning.
    private func persistDraftIfNeeded() {
        guard let snapshot = draft.snapshot() else { return }
        let succeeded = draftPersistence.save(snapshot)
        lastAutosaveFailed = !succeeded
    }
}

/// Renders one `BlockDraft` -- a single card, with lettered sub-entries when
/// it holds more than one (a copied-over superset), mirroring M3's
/// `SessionDetailView` grouping convention (§6) for visual consistency.
private struct BlockDraftCard: View {
    @Bindable var block: BlockDraft
    let clientID: String
    let repTargetPresets: [RepTargetPreset]
    let bandColorIndex: [String: [String]]
    let canMoveUp: Bool
    let canMoveDown: Bool
    var onDeleteEntry: (UUID) -> Void
    var onAddEntry: () -> Void
    var onMove: (Int) -> Void
    var onDelete: () -> Void
    /// 每个动作的热量估算文字（`≈N kcal`），数据不足时为 nil。
    var energyText: (Int) -> String? = { _ in nil }

    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant
    @State private var showingDeleteConfirmation = false

    /// 该训练块的默认休息秒数，仅作 `EntryRowView` 副标题展示用（纯信息，无交互
    /// 倒计时——组间休息计时功能已按教练要求整体移除）。落不到 restSeconds 时用
    /// 60s 兜底，与 CONTRACT-UI.md §3.5 原本的默认值一致。
    private var defaultRestSeconds: Int {
        block.restSeconds ?? 60
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.cardGap) {
            header
            ForEach(Array(block.entries.enumerated()), id: \.element.id) { entryIndex, entry in
                EntryRowView(
                    draft: entry,
                    clientID: clientID,
                    repTargetPresets: repTargetPresets,
                    bandColorIndex: bandColorIndex,
                    restSeconds: defaultRestSeconds,
                    energyText: energyText(entryIndex)
                ) {
                    onDeleteEntry(entry.id)
                }
            }
        }
        .confirmationDialog(
            language.t("刪除這個訓練塊？", "Delete this block?"),
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.t("刪除", "Delete"), role: .destructive) { onDelete() }
            Button(language.t("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(language.t(
                "這個訓練塊裡的 \(block.entries.count) 個動作會一起移除。",
                "All \(block.entries.count) exercise(s) in this block will be removed."
            ))
        }
    }

    /// 2026-09-09 教练要求「所有生成的 section 都可以方便地进行修改」。原来这一
    /// 行只在超级组时出现、而且纯展示：段落类型（力量/技術）改不了，块的顺序调
    /// 不了，往已有的块里再加一个动作也没有入口——只能一路删掉重录。现在常驻，
    /// 两个标签本身就是可点的菜单，右端一个 ⋯ 放不常用的四项。
    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                // 只在 力量 ↔ 技術 之间切换：改成 WOD 是换一套完全不同的内容
                // （处方 + 成绩，见 `WODBlockDraft`），不是改个标签，那条路走
                // 下面的「添加 WOD」。
                ForEach([SectionKind.strength, .skill], id: \.self) { kind in
                    Button {
                        block.sectionKind = kind
                    } label: {
                        if block.sectionKind == kind {
                            Label(kind.displayName, systemImage: "checkmark")
                        } else {
                            Text(kind.displayName)
                        }
                    }
                }
            } label: {
                headerChip(block.sectionKind.displayName)
            }

            if block.entries.count > 1 {
                Menu {
                    ForEach(BlockType.allCases.filter { $0 != .unknown && $0 != .single }, id: \.self) { type in
                        Button {
                            block.blockType = type
                        } label: {
                            if block.blockType == type {
                                Label(type.displayName, systemImage: "checkmark")
                            } else {
                                Text(type.displayName)
                            }
                        }
                    }
                } label: {
                    headerChip(block.blockType.displayName)
                }
            }

            Spacer(minLength: 0)

            Menu {
                Button {
                    onAddEntry()
                } label: {
                    Label(language.t("加入動作到這一塊", "Add Exercise to This Block"), systemImage: "plus")
                }
                Button {
                    onMove(-1)
                } label: {
                    Label(language.t("上移", "Move Up"), systemImage: "arrow.up")
                }
                .disabled(!canMoveUp)
                Button {
                    onMove(1)
                } label: {
                    Label(language.t("下移", "Move Down"), systemImage: "arrow.down")
                }
                .disabled(!canMoveDown)
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label(language.t("刪除這一塊", "Delete Block"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(DS.C.textMid)
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
        }
    }

    private func headerChip(_ title: String) -> some View {
        HStack(spacing: 3) {
            Text(title)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
        }
        .font(DS.F.dataLabel)
        .foregroundStyle(DS.C.textMid)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(DS.C.inset, in: Capsule())
    }
}

/// 今天页各卡片的热量估算文字。`TrainingInsights.draft` 的行 id 按块/动作在草稿中
/// 的位置编号（力量动作 `b{块}e{动作}`，WOD 整块 `b{块}`）；超级组显示成员合计。
/// 已全部记录时显示完成后估算，否则显示计划估算；缺体重等数据时不显示。
private struct EnergyLookup {
    private let lines: [String: EnergyLine]

    init(report: EnergyReport) {
        lines = Dictionary(report.lines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func entry(_ block: Int, _ entry: Int) -> String? {
        Self.text(for: lines["b\(block)e\(entry)"].flatMap(Self.value))
    }

    func block(_ block: Int) -> String? {
        if let wod = lines["b\(block)"] { return Self.text(for: Self.value(wod)) }
        let members = lines.filter { $0.key.hasPrefix("b\(block)e") }.values.map(Self.value)
        guard !members.isEmpty, members.allSatisfy({ $0 != nil }) else { return nil }
        return Self.text(for: members.compactMap { $0 }.reduce(0, +))
    }

    private static func value(_ line: EnergyLine) -> Double? {
        if let actual = line.actual, line.recordedSets >= line.totalSets { return actual }
        return line.planned
    }

    private static func text(for value: Double?) -> String? {
        value.map(EnergyReport.display)
    }
}
