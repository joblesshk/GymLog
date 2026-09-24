import SwiftUI
import SwiftData
import GymLogKit

/// One file handed to `.onOpenURL`, classified into which import flow it
/// belongs to -- see `ContentView.classifyIncomingFile`.
private struct IncomingFile {
    enum Kind { case exchange, backup }
    let url: URL
    let kind: Kind
}

/// Tab host, per 工程规划.md §4: 今天 / 学员 / 历史 / 动作库 / 设置.
/// Owned exclusively by M2 (CONTRACT-UI.md §1). 动作库 mounts M3's
/// ExerciseLibraryView through the frozen seam in CONTRACT-UI.md §2, so M3
/// never needs to edit this file.
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var importStatus: ImportStatusBanner.Status?
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    // 語音協調器建在根層級（見 `VoiceCommandCoordinator` 的說明），不是某個
    // tab 私有的 `@State`；入口按鈕目前只在「今天」顯示（產品決定，
    // 2026-09-23 確認），面板與取消邏輯仍由這裡統一管理。
    @State private var voiceCoordinator = CloudVoiceController.forApplication()
    @Query(sort: \Exercise.canonicalName) private var allExercises: [Exercise]
    @Query(sort: \Client.name) private var clients: [Client]

    // P2 (2026-09-11) §5.2: `.onOpenURL` 接收 AirDrop/Files「打開方式：
    // GymLog」送来的文件——冷启动、前台、连续打开多个文件都走这一个入口。
    // 送来的可能是单次分享 `.gymlogshare`/`.txt`，也可能是「设置」导出的完整
    // 备份 `.json`——两者都可能是 `.json` 副档名，所以 `classifyIncomingFile`
    // 靠窥探内容而非副档名区分。（此前两者一律被当成分享文件塞进
    // `ExchangeImportFlow`，备份文件结构对不上单次分享格式，落到其自然语言
    // 兜底解析分支，长时间卡在「解析中」多半仍以失败告终。）训练中收到文件先
    // 排队,不打断当前草稿（不切换学员、不覆盖草稿）;`draftStore.isActive` 变
    // 回 false（暫存/結束/放棄）时才处理队列里下一个。
    @State private var pendingIncomingFiles: [IncomingFile] = []
    @State private var currentExchangeImportURL: URL?
    @State private var showingExchangeImportFlow = false
    @State private var exchangeImportResultMessage: String?
    @State private var exchangeImportErrorMessage: String?
    @State private var currentBackupRestoreURL: URL?
    @State private var showingBackupRestoreFlow = false
    @State private var backupRestoreResultMessage: String?
    @State private var backupRestoreErrorMessage: String?

    // M2 app-wide state (CONTRACT-UI.md §3.4/§3.6): current-client selection,
    // the in-progress entry draft, and the coordinator that gates every
    // client switch behind the unsaved-work guard. Constructed together in
    // `init` since the coordinator needs live references to the other two.
    @State private var clientStore: CurrentClientStore
    @State private var draftStore: TodayDraftStore
    @State private var switchCoordinator: ClientSwitchCoordinator
    // CONTRACT-M5.md §1.2: shared tab-index state so `ClientSwitcherButton`'s
    // "编辑「...」资料" menu entry can jump to 个人信息 from wherever it's
    // tapped. Also carries the same GYMLOG_INITIAL_TAB verification-only
    // launch hook the plain Int @State used to (launching with
    // GYMLOG_INITIAL_TAB=history opens straight to 历史 for screenshotting,
    // no effect unless that env var is explicitly set).
    @State private var tabSelection: TabSelectionStore
    // Measured from `FloatingTabBar` itself via `TabBarHeightKey` (see that
    // file) rather than a hand-picked constant here. Fallback value is a
    // reasonable estimate for the very first frame, before the preference
    // has reported the real size once.
    @State private var tabBarHeight: CGFloat = 78

    init() {
        let clientStore = CurrentClientStore()
        let draftStore = TodayDraftStore()
        let initialTab = ProcessInfo.processInfo.environment["GYMLOG_INITIAL_TAB"] == "history" ? 2 : 0
        _clientStore = State(initialValue: clientStore)
        _draftStore = State(initialValue: draftStore)
        _switchCoordinator = State(initialValue: ClientSwitchCoordinator(clientStore: clientStore, draftStore: draftStore))
        _tabSelection = State(initialValue: TabSelectionStore(selectedTab: initialTab))
    }

    private var tabItems: [FloatingTabBarItem] {
        [
            FloatingTabBarItem(title: language.t("今天", "Today"), systemImage: "sun.max"),
            FloatingTabBarItem(title: language.t("個人信息", "Profile"), systemImage: "person.text.rectangle"),
            FloatingTabBarItem(title: language.t("歷史", "History"), systemImage: "clock.arrow.circlepath"),
            FloatingTabBarItem(title: language.t("動作庫", "Exercises"), systemImage: "figure.strengthtraining.traditional"),
            FloatingTabBarItem(title: language.t("設置", "Settings"), systemImage: "gearshape"),
        ]
    }

    var body: some View {
        TabView(selection: $tabSelection.selectedTab) {
            TodayView(clientStore: clientStore, draft: draftStore, switchCoordinator: switchCoordinator, tabSelection: tabSelection)
                .tag(0)
                .toolbar(.hidden, for: .tabBar)

            ClientProfileView(clientStore: clientStore, coordinator: switchCoordinator, tabSelection: tabSelection)
                .tag(1)
                .toolbar(.hidden, for: .tabBar)

            HistoryListView(clientStore: clientStore, switchCoordinator: switchCoordinator, draft: draftStore, tabSelection: tabSelection)
                .tag(2)
                .toolbar(.hidden, for: .tabBar)

            ExerciseLibraryView(clientStore: clientStore, switchCoordinator: switchCoordinator)
                .tag(3)
                .toolbar(.hidden, for: .tabBar)

            SettingsView(clientStore: clientStore, switchCoordinator: switchCoordinator)
                .tag(4)
                .toolbar(.hidden, for: .tabBar)
        }
        // M2 app-wide state (client/draft/coordinator) is passed explicitly
        // to each tab root rather than via `.environment()` (see
        // ClientSwitchConfirmationModifier.swift's note on the crash that
        // pattern caused with `.alert`). `floatingTabBarHeight` below is a
        // separate, unrelated case: a plain read-only CGFloat used only for
        // layout, not app state, so that crash risk doesn't apply to it --
        // and it specifically NEEDS `.environment()` rather than a
        // constructor parameter, since each tab must read it *inside* its
        // own `NavigationStack` (see `reserveFloatingTabBarSpace` in
        // FloatingTabBar.swift for why a value passed down from here can't
        // just be applied here instead).
        .clientSwitchConfirmation(coordinator: switchCoordinator)
        // HANDOFF.md §3: 系统 Tab Bar 换成悬浮胶囊，5 个 Tab / 选中态交互不变。
        .overlay(alignment: .bottom) {
            FloatingTabBar(selection: $tabSelection.selectedTab, items: tabItems)
        }
        .onPreferenceChange(TabBarHeightKey.self) { tabBarHeight = $0 }
        .environment(\.floatingTabBarHeight, tabBarHeight)
        // 2026-09-13 全局語音改造：疊在悬浮 Tab Bar 上方、左下角——執行
        // Prompt §4.1 的建議位置。跟 `FloatingTabBar` 用同一個
        // `tabBarHeight` 量到的實際高度定位，不是憑感覺寫死一個常數，
        // 這樣底欄本身的高度（大字模式/不同機型）變化時仍然對得上。
        .overlay(alignment: .bottomLeading) {
            if tabSelection.selectedTab == 0 {
                GlobalVoiceButton(coordinator: voiceCoordinator)
                    .padding(.leading, DS.Space.pageMargin)
                    .padding(.bottom, tabBarHeight + 8)
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: Binding(
            get: { voiceCoordinator.isPanelPresented },
            set: { voiceCoordinator.isPanelPresented = $0 }
        )) {
            VoiceCommandPanel(
                coordinator: voiceCoordinator, draft: draftStore, allExercises: allExercises,
                clientID: clientStore.currentClient(in: clients)?.id ?? "",
                clientDisplayName: clientStore.currentClient(in: clients)?.name ?? "",
                context: modelContext, showToday: { tabSelection.select(tab: 0) }
            )
        }
        .onChange(of: scenePhase) { _, phase in
            // App 進背景時，正在錄的語音沒有意義繼續錄——`TodayView` 自己
            // 的 `.onChange(of: scenePhase)` 曾經負責這件事（舊版語音狀態
            // 是 `TodayView` 私有的），現在協調器是全局的，這個責任跟著
            // 挪到協調器實際所在的層級。
            if phase == .background {
                voiceCoordinator.cancel()
            }
        }
        .onChange(of: clientStore.currentClientID) { _, _ in
            // 執行 Prompt §4.3「切換頁面/學員/課次或焦點變化時清除失效指代」
            // ——換學員後，上一個學員待處理的候選/確認/撤銷狀態必須整個
            // 作廢，不能延續到新學員身上。
            voiceCoordinator.resetForContextChange()
        }
        .onChange(of: draftStore.isActive) { _, active in
            if !active { voiceCoordinator.cancel() }
        }
        .overlay(alignment: .top) {
            if let status = importStatus {
                ImportStatusBanner(status: status)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if !pendingIncomingFiles.isEmpty && draftStore.isActive {
                // 训练中收到分享/备份文件：只提示数量，不弹预览、不打断当前
                // 草稿（§5.2 明确要求）。课次結束/暫存/放棄后 `onChange` 会
                // 自动把队列里的第一个文件接着处理。
                HStack(spacing: 6) {
                    Image(systemName: "tray.full")
                    Text(language.t(
                        "收到 \(pendingIncomingFiles.count) 個文件，訓練結束後處理",
                        "\(pendingIncomingFiles.count) file(s) received — will process after this session"
                    ))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.C.textHi)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(DS.C.surface, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: importStatus == nil)
        .onOpenURL { url in
            Task.detached(priority: .userInitiated) {
                let kind = Self.classifyIncomingFile(url)
                await MainActor.run {
                    pendingIncomingFiles.append(IncomingFile(url: url, kind: kind))
                    processNextPendingIncomingFileIfPossible()
                }
            }
        }
        .onChange(of: draftStore.isActive) { _, isActive in
            if !isActive { processNextPendingIncomingFileIfPossible() }
        }
        .sheet(isPresented: $showingExchangeImportFlow, onDismiss: {
            currentExchangeImportURL = nil
            processNextPendingIncomingFileIfPossible()
        }) {
            if let currentExchangeImportURL {
                ExchangeImportFlow(pendingURL: currentExchangeImportURL) { status in
                    switch status {
                    case .success(let result):
                        var message = language.t("已匯入 \(result.sessionsWritten) 個課次", "Imported \(result.sessionsWritten) session(s)")
                        if result.sessionsSkippedIdempotent > 0 || result.sessionsSkippedContentChanged > 0 {
                            message += language.t(
                                "，跳過 \(result.sessionsSkippedIdempotent + result.sessionsSkippedContentChanged) 個",
                                ", skipped \(result.sessionsSkippedIdempotent + result.sessionsSkippedContentChanged)"
                            )
                        }
                        exchangeImportResultMessage = message
                    case .failure(let message):
                        exchangeImportErrorMessage = message
                    case .cancelled:
                        break
                    }
                }
            }
        }
        .sheet(isPresented: $showingBackupRestoreFlow, onDismiss: {
            currentBackupRestoreURL = nil
            processNextPendingIncomingFileIfPossible()
        }) {
            if let currentBackupRestoreURL {
                BackupRestoreFlow(pendingURL: currentBackupRestoreURL) { status in
                    switch status {
                    case .success(let result):
                        backupRestoreResultMessage = language.t(
                            "已恢復 \(result.clientsWritten) 位學員、\(result.sessionsWritten) 個課次",
                            "Restored \(result.clientsWritten) client(s), \(result.sessionsWritten) session(s)"
                        )
                    case .failure(let message):
                        backupRestoreErrorMessage = message
                    }
                }
            }
        }
        .alert(language.t("匯入完成", "Import Complete"), isPresented: Binding(get: { exchangeImportResultMessage != nil }, set: { if !$0 { exchangeImportResultMessage = nil } })) {
            Button(language.t("好", "OK"), role: .cancel) {}
        } message: {
            Text(exchangeImportResultMessage ?? "")
        }
        .alert(language.t("匯入失敗", "Import Failed"), isPresented: Binding(get: { exchangeImportErrorMessage != nil }, set: { if !$0 { exchangeImportErrorMessage = nil } })) {
            Button(language.t("好", "OK"), role: .cancel) {}
        } message: {
            Text(exchangeImportErrorMessage ?? "")
        }
        .alert(language.t("恢復完成", "Restore Complete"), isPresented: Binding(get: { backupRestoreResultMessage != nil }, set: { if !$0 { backupRestoreResultMessage = nil } })) {
            Button(language.t("好", "OK"), role: .cancel) {}
        } message: {
            Text(backupRestoreResultMessage ?? "")
        }
        .alert(language.t("恢復失敗", "Restore Failed"), isPresented: Binding(get: { backupRestoreErrorMessage != nil }, set: { if !$0 { backupRestoreErrorMessage = nil } })) {
            Button(language.t("好", "OK"), role: .cancel) {}
        } message: {
            Text(backupRestoreErrorMessage ?? "")
        }
        .task {
            await importFixtureIfNeeded()
            applyExerciseLibraryReview202609IfNeeded()
            applyExerciseLibraryAdditions20260904IfNeeded()
            applyExerciseLibraryAdditions20260907IfNeeded()
            applyExerciseLibraryAdditions20260909IfNeeded()
            applyExerciseDisciplineClassification20260909IfNeeded()
            applyExerciseLibraryAdditions20260916IfNeeded()
            applyExerciseLibraryAliasAdditions20260916IfNeeded()
            await importTemplateSeedIfNeeded()
            await applyTemplateLibraryAdditions20260916IfNeeded()
            await applyTemplateLibraryAdditions20260917IfNeeded()
            exportExerciseLibraryIfRequested()
        }
    }

    /// 队列里下一个待处理的文件（分享或备份）——训练中（`draftStore.isActive`）
    /// 或已经有一个预览面板开着时都先不动，等条件满足再弹。两种文件共用一个
    /// 队列，按各自的 `kind` 分别弹对应的面板，这样任一面板关闭都能正确唤醒
    /// 队列里的下一项，不管它是哪一种。
    private func processNextPendingIncomingFileIfPossible() {
        guard currentExchangeImportURL == nil, !showingExchangeImportFlow else { return }
        guard currentBackupRestoreURL == nil, !showingBackupRestoreFlow else { return }
        guard !draftStore.isActive else { return }
        guard !pendingIncomingFiles.isEmpty else { return }
        let next = pendingIncomingFiles.removeFirst()
        switch next.kind {
        case .exchange:
            currentExchangeImportURL = next.url
            showingExchangeImportFlow = true
        case .backup:
            currentBackupRestoreURL = next.url
            showingBackupRestoreFlow = true
        }
    }

    /// 单次分享 `.gymlogshare`/`.txt` 一定走 `ExchangeImportFlow`；`.json` 则
    /// 两种文件都可能是，靠窥探最外层 JSON key 区分——`BackupFile`（`Sources/
    /// Export/BackupDTO.swift`）顶层有 `schemaVersion`/`clients`，
    /// `ExchangePackage`（`Sources/Exchange/ExchangeDTO.swift`）没有。窥探
    /// 前先用文件大小把不可能是备份的超大文件（备份本身有 50MB 上限，见
    /// `BackupRestoreFlow.maxFileSize`）挡掉，避免为了区分类型而把一个巨大
    /// 文件整个读进内存；读取或解析失败一律当作分享文件处理，保持原有行为。
    private static func classifyIncomingFile(_ url: URL) -> IncomingFile.Kind {
        guard url.pathExtension.lowercased() == "json" else { return .exchange }
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard fileSize > 0, fileSize <= 50_000_000 else { return .exchange }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .exchange
        }
        return (object["schemaVersion"] != nil && object["clients"] != nil) ? .backup : .exchange
    }

    /// One-time heal for installs that seeded their exercise library before
    /// the 2026-09 review (工程记录.md 十八) shipped -- i.e. every real
    /// device that's been TestFlight-upgraded across builds rather than
    /// freshly installed. `importFixtureIfNeeded` above only ever imports
    /// `exercise_library_seed.json` into a completely empty library, so an
    /// already-populated device never otherwise sees the corrected
    /// classification, the merged/deleted duplicates, or `nameZh`/`notes`.
    /// Gated on a `UserDefaults` flag (not on exercise count, which this
    /// call itself changes) so it runs exactly once per install and never
    /// fights a coach's own edits made afterward through
    /// `ExerciseLibraryView` -- see `SeedImporter.applyExerciseLibraryReview202609`
    /// for what it actually does and why it's safe to run unconditionally
    /// once.
    private func applyExerciseLibraryReview202609IfNeeded() {
        let flagKey = "appliedExerciseLibraryReview202609"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        guard let url = Bundle.main.url(forResource: "exercise_library_seed", withExtension: "json") else { return }
        do {
            try SeedImporter.applyExerciseLibraryReview202609(seedURL: url, context: modelContext)
            UserDefaults.standard.set(true, forKey: flagKey)
        } catch {
            print("[GymLog] Exercise library review pass failed: \(error.localizedDescription)")
        }
    }

    /// Second one-time heal, same shape and same reason as the review pass
    /// above: `Resources/exercise_library_seed.json` grew two rows on
    /// 2026-09-04 (器械反向飛鳥 / 坐姿繩索臉拉, the two the coach had added by
    /// hand), and a device that already has a populated library never
    /// re-reads that file. Unlike the review pass this one does NOT re-upsert
    /// the whole file — see `SeedImporter.applyExerciseLibraryAdditions20260904`
    /// — so it cannot undo classification the coach fixed by hand in 動作庫.
    private func applyExerciseLibraryAdditions20260904IfNeeded() {
        let flagKey = "appliedExerciseLibraryAdditions20260904"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        guard let url = Bundle.main.url(forResource: "exercise_library_seed", withExtension: "json") else { return }
        do {
            let inserted = try SeedImporter.applyExerciseLibraryAdditions20260904(seedURL: url, context: modelContext)
            print("[GymLog] Exercise library additions 2026-09-04: inserted \(inserted).")
            UserDefaults.standard.set(true, forKey: flagKey)
        } catch {
            print("[GymLog] Exercise library additions pass failed: \(error.localizedDescription)")
        }
    }

    /// Third one-time heal: `Resources/exercise_library_seed.json` grew 56
    /// CrossFit-oriented rows on 2026-09-07 (`output/review-2026-09-07/CrossFit
    /// 动作目录候选.csv`'s "新增" rows). Same shape as the 2026-09-04 pass
    /// above -- see `SeedImporter.applyExerciseLibraryAdditions20260907`.
    private func applyExerciseLibraryAdditions20260907IfNeeded() {
        let flagKey = "appliedExerciseLibraryAdditions20260907"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        guard let url = Bundle.main.url(forResource: "exercise_library_seed", withExtension: "json") else { return }
        do {
            let inserted = try SeedImporter.applyExerciseLibraryAdditions20260907(seedURL: url, context: modelContext)
            print("[GymLog] Exercise library additions 2026-09-07: inserted \(inserted).")
            UserDefaults.standard.set(true, forKey: flagKey)
        } catch {
            print("[GymLog] Exercise library additions (2026-09-07) pass failed: \(error.localizedDescription)")
        }
    }

    /// Fourth one-time heal, same shape as the 2026-09-07 pass above: 16
    /// mainstream CrossFit movements the library was still missing on
    /// 2026-09-09 (Devil Press / Turkish Get-up / L-sit Hold / Man Maker …).
    private func applyExerciseLibraryAdditions20260909IfNeeded() {
        let flagKey = "appliedExerciseLibraryAdditions20260909"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        guard let url = Bundle.main.url(forResource: "exercise_library_seed", withExtension: "json") else { return }
        do {
            let inserted = try SeedImporter.applyExerciseLibraryAdditions20260909(seedURL: url, context: modelContext)
            print("[GymLog] Exercise library additions 2026-09-09: inserted \(inserted).")
            UserDefaults.standard.set(true, forKey: flagKey)
        } catch {
            print("[GymLog] Exercise library additions (2026-09-09) pass failed: \(error.localizedDescription)")
        }
    }

    /// 回填「訓練體系」分类。与上面几支「补行」的 heal 不同，这一支改的是已有行
    /// 的一个新字段——没有它，升级上来的设备里每个动作都是默认的「力量」，
    /// WOD 选动作面板的 CrossFit 筛选会是空的。只写 `discipline`，不碰教练手工
    /// 改过的任何其他字段（见 `SeedImporter` 里的说明）。
    ///
    /// 必须排在上面那支「补行」之后：新插入的 16 行在插入时就带着正确的
    /// discipline，这一支只是顺带确认一遍。
    private func applyExerciseDisciplineClassification20260909IfNeeded() {
        let flagKey = "appliedExerciseDiscipline20260909"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        guard let url = Bundle.main.url(forResource: "exercise_library_seed", withExtension: "json") else { return }
        do {
            let changed = try SeedImporter.applyExerciseDisciplineClassification20260909(seedURL: url, context: modelContext)
            print("[GymLog] Exercise discipline classification 2026-09-09: updated \(changed).")
            UserDefaults.standard.set(true, forKey: flagKey)
        } catch {
            print("[GymLog] Exercise discipline classification pass failed: \(error.localizedDescription)")
        }
    }

    /// Fifth one-time heal, same shape as the 2026-09-09 pass above: 58
    /// exercise names seen in coach Excel workout logs that the library was
    /// still missing (names only; no athlete data is bundled).
    private func applyExerciseLibraryAdditions20260916IfNeeded() {
        let flagKey = "appliedExerciseLibraryAdditions20260916"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        guard let url = Bundle.main.url(forResource: "exercise_library_seed", withExtension: "json") else { return }
        do {
            let inserted = try SeedImporter.applyExerciseLibraryAdditions20260916(seedURL: url, context: modelContext)
            print("[GymLog] Exercise library additions 2026-09-16: inserted \(inserted).")
            UserDefaults.standard.set(true, forKey: flagKey)
        } catch {
            print("[GymLog] Exercise library additions (2026-09-16) pass failed: \(error.localizedDescription)")
        }
    }

    /// Companion to the heal above: 8 more names from the same two Excel
    /// files turned out to already exist under a slightly different
    /// wording (e.g. "Barbell squat" == existing "Back Squat") -- these
    /// only add search aliases to already-existing rows, never a new row
    /// and never overwrite anything the coach edited by hand. See
    /// `SeedImporter.applyExerciseLibraryAliasAdditions20260916`.
    private func applyExerciseLibraryAliasAdditions20260916IfNeeded() {
        let flagKey = "appliedExerciseLibraryAliasAdditions20260916"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        do {
            let changed = try SeedImporter.applyExerciseLibraryAliasAdditions20260916(context: modelContext)
            print("[GymLog] Exercise library alias additions 2026-09-16: updated \(changed).")
            UserDefaults.standard.set(true, forKey: flagKey)
        } catch {
            print("[GymLog] Exercise library alias additions (2026-09-16) pass failed: \(error.localizedDescription)")
        }
    }

    /// One-time heal for devices whose `SessionTemplate` table was already
    /// non-empty by the time `importTemplateSeedIfNeeded()` below first ran
    /// (i.e. every real device, which imported the single 示範訓練 demo
    /// template on an earlier build) -- that guard only ever fires once per
    /// install, so a `template_seed.json` that grows new templates later
    /// (2026-09-16: 4 characteristic split-day templates + 17 superset
    /// templates extracted from real coach Excel logs) is otherwise never
    /// re-read. Safe to call `importTemplateSeed` again unconditionally:
    /// per its own doc comment, `SessionTemplate`/`TemplateBlock`/
    /// `TemplateExerciseSlot` ids are deterministic and `@Attribute(.unique)`,
    /// so re-importing the existing demo template coalesces into the same
    /// row instead of duplicating it -- only the genuinely new template ids
    /// actually insert.
    private func applyTemplateLibraryAdditions20260916IfNeeded() async {
        let flagKey = "appliedTemplateLibraryAdditions20260916"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        guard let url = Bundle.main.url(forResource: "template_seed", withExtension: "json") else { return }
        do {
            let count = try SeedImporter.importTemplateSeed(from: url, into: modelContext)
            print("[GymLog] Template library additions 2026-09-16: re-processed \(count) templates.")
            UserDefaults.standard.set(true, forKey: flagKey)
        } catch {
            print("[GymLog] Template library additions (2026-09-16) pass failed: \(error.localizedDescription)")
        }
    }

    /// 2026-09-17：跟上面那支 20260916 heal 同一個理由的第二支——
    /// `template_seed.json` 這次又長出 14 個 WOD 模板（網上最知名的
    /// CrossFit 基準 WOD：Fran/Grace/Helen/…/Murph/DT/Jackie），
    /// `importTemplateSeedIfNeeded` 的 guard 早就因為 20260916 那批而失效
    /// 了，需要自己的 flag 再補跑一次 `importTemplateSeed`（一樣安全：見
    /// `applyTemplateLibraryAdditions20260916IfNeeded` 的說明，唯一 id 讓
    /// 重複匯入自然合併，不會產生重複列）。
    private func applyTemplateLibraryAdditions20260917IfNeeded() async {
        let flagKey = "appliedTemplateLibraryAdditions20260917"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        guard let url = Bundle.main.url(forResource: "template_seed", withExtension: "json") else { return }
        do {
            let count = try SeedImporter.importTemplateSeed(from: url, into: modelContext)
            print("[GymLog] Template library additions 2026-09-17: re-processed \(count) templates.")
            UserDefaults.standard.set(true, forKey: flagKey)
        } catch {
            print("[GymLog] Template library additions (2026-09-17) pass failed: \(error.localizedDescription)")
        }
    }

    /// Auto-imports the approved exercise library on first launch if the
    /// library is empty, so opening the app has something to build a
    /// training session or template around without the coach re-entering
    /// 177 exercises by hand. Deliberately contains NO client and NO
    /// session history (工程记录.md 十二之三: "一个完整的安装版的文件应该不包含
    /// 历史记录，仅包含...基础动作库") -- a coach's real training data must
    /// never ship inside an installable build, TestFlight or otherwise.
    /// `Resources/exercise_library_seed.json` is generated from a live,
    /// already-corrected app store (see `ContentView.exportExerciseLibraryIfRequested`
    /// below and 工程记录.md), NOT from the frozen migration output --
    /// unlike the old combined seed, it needs no `applyKnownExerciseCorrections`
    /// pass afterward, because those corrections are already baked into every
    /// exercise this file contains. Only the exercise library and generic
    /// templates ship in the app. Synthetic fixtures belong to the test target.
    private func importFixtureIfNeeded() async {
        // Verification-only escape hatch (same family as `GYMLOG_INITIAL_TAB`):
        // testing "does re-importing an Excel file correctly repopulate an
        // EMPTY app" needs a launch where the store is genuinely empty and
        // STAYS that way, but this method's whole job is to refill an empty
        // store -- without this, every such launch would auto-reseed before
        // the Excel-import test ever got to run. No effect unless set.
        guard ProcessInfo.processInfo.environment["GYMLOG_SKIP_SEED_IMPORT"] != "1" else { return }
        let existingCount = (try? modelContext.fetchCount(FetchDescriptor<Exercise>())) ?? 0
        guard existingCount == 0 else { return }
        guard let url = Bundle.main.url(forResource: "exercise_library_seed", withExtension: "json") else {
            importStatus = .failure(language.t("未找到 Resources/exercise_library_seed.json", "Resources/exercise_library_seed.json not found"))
            return
        }
        do {
            let start = Date()
            let result = try SeedImporter.importSeed(from: url, into: modelContext)
            let elapsed = Date().timeIntervalSince(start)
            // Measured, not hidden: this import runs synchronously on the
            // task tied to this view's body, so a slow import is a slow
            // first frame, not something a spinner quietly absorbs.
            print("[GymLog] Exercise library seed import took \(elapsed)s (exercises=\(result.exerciseCount))")
            importStatus = .success(result, elapsedSeconds: elapsed)
            // The banner overlays the top of the screen, including the
            // 今天 tab's nav bar (where the client switcher lives) -- auto-
            // dismiss a *success* banner after a few seconds so it doesn't
            // sit there indefinitely blocking that toolbar. A *failure*
            // banner deliberately does NOT auto-dismiss: CONTRACT-UI.md's
            // "不得静默吞掉" discipline for save failures extends to import
            // failures too -- those should stay visible until the coach
            // acts, not disappear on a timer.
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if case .success = importStatus {
                importStatus = nil
            }
        } catch {
            importStatus = .failure(language.t("导入失败：\(error.localizedDescription)", "Import failed: \(error.localizedDescription)"))
        }
    }

    /// CONTRACT-M5.md §4.2: auto-imports the 5 hand-picked session templates
    /// from `Resources/template_seed.json` on first launch. Runs AFTER
    /// `importFixtureIfNeeded()` above -- template exercise-name resolution
    /// (`SeedImporter.importTemplateSeed`) depends on `Exercise` rows already
    /// existing. Idempotency guard lives here, not inside the importer, per
    /// §4.2 point 3 (mirrors the guard shape of `importFixtureIfNeeded`
    /// above, keyed on `SessionTemplate` count instead of `WorkoutSession`).
    private func importTemplateSeedIfNeeded() async {
        let existingCount = (try? modelContext.fetchCount(FetchDescriptor<SessionTemplate>())) ?? 0
        guard existingCount == 0 else { return }
        guard let url = Bundle.main.url(forResource: "template_seed", withExtension: "json") else {
            print("[GymLog] template_seed.json not found in bundle, skipped template import.")
            return
        }
        do {
            let count = try SeedImporter.importTemplateSeed(from: url, into: modelContext)
            print("[GymLog] Template seed import: \(count) templates.")
        } catch {
            print("[GymLog] Template seed import failed: \(error.localizedDescription)")
        }
    }

    /// Verification-only launch hook (same family as `GYMLOG_INITIAL_TAB`
    /// above): `GYMLOG_EXPORT_EXERCISES=1` dumps the CURRENT, LIVE exercise
    /// library -- with every coach correction already applied by
    /// `applyKnownExerciseCorrections` (Ball plank -> bodyweight equipment,
    /// Dips w/leg merged into Dips w/legs, etc., 工程记录.md 十二节) -- to
    /// `<app Documents>/exercise_library_export.json`, in the exact same
    /// shape as `gymlog_seed.json`'s `exercises` array so it can be dropped
    /// straight in as a future version's baked-in default (rather than
    /// re-deriving the corrected state at runtime every first launch). No
    /// effect unless that env var is explicitly set.
    private func exportExerciseLibraryIfRequested() {
        guard ProcessInfo.processInfo.environment["GYMLOG_EXPORT_EXERCISES"] == "1" else { return }
        let exercises = (try? modelContext.fetch(FetchDescriptor<Exercise>(sortBy: [SortDescriptor(\.canonicalName)]))) ?? []
        struct ExportedExercise: Encodable {
            let id: String
            let canonicalName: String
            let aliases: [String]
            let movementPattern: String
            let equipment: String
            let loadDirection: String
            let isUnilateral: Bool
            let occurrenceCount: Int
            let needsReview: Bool
            let reviewReason: String?
            let recordingMetric: String
            let discipline: String
            let nameZh: String
            let notes: String
        }
        let exported = exercises.map {
            ExportedExercise(
                id: $0.id, canonicalName: $0.canonicalName, aliases: $0.aliases,
                movementPattern: $0.movementPattern.rawValue, equipment: $0.equipment.rawValue,
                loadDirection: $0.loadDirection.rawValue, isUnilateral: $0.isUnilateral,
                occurrenceCount: $0.occurrenceCount, needsReview: $0.needsReview,
                reviewReason: $0.reviewReason, recordingMetric: $0.recordingMetric.rawValue,
                discipline: $0.discipline.rawValue, nameZh: $0.nameZh, notes: $0.notes
            )
        }
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let fileURL = documentsURL.appendingPathComponent("exercise_library_export.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(exported)
            try data.write(to: fileURL)
            print("[GymLog] Exported \(exported.count) exercises to \(fileURL.path)")
        } catch {
            print("[GymLog] Exercise export failed: \(error.localizedDescription)")
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [
            Client.self, BodyMetric.self, Assessment.self, WorkoutSession.self,
            SessionBlock.self, ExerciseEntry.self, SetLog.self, Exercise.self,
            SessionTemplate.self, TemplateBlock.self, TemplateExerciseSlot.self,
        ], inMemory: true)
}
