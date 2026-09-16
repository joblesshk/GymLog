import SwiftUI
import SwiftData
import GymLogKit

/// M1 acceptance criterion: "page through all sessions in the app".
/// CONTRACT-M4.md §1: filtered to the current client -- "选定一个学员名字后，
/// 下方所有信息全部对应这个学员" applies to 历史 same as every other tab.
/// Filtered in-memory (mirrors ExerciseHistoryView's approach, same
/// SwiftData predicate-limitation reasoning noted there) rather than via a
/// dynamic `@Query` predicate.
struct HistoryListView: View {
    @Bindable var clientStore: CurrentClientStore
    let switchCoordinator: ClientSwitchCoordinator
    // 2026-09-09：从歷史把一节课载回「今天」继续录 / 完整编辑，需要拿到那份
    // 草稿和 tab 选择。两个都可选，`nil` 时这些入口不显示——`#Preview` 之类
    // 不带这套状态的挂载点照样编译。
    var draft: TodayDraftStore? = nil
    var tabSelection: TabSelectionStore? = nil

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutSession.date, order: .reverse)
    private var allSessions: [WorkoutSession]
    @Query(sort: \Client.name) private var clients: [Client]
    // 载入课次到「今天」时用来把 `exerciseIdRef` 解析回真的 `Exercise`
    // （`SessionDraftLoader`）。
    @Query(sort: \Exercise.canonicalName) private var allExercises: [Exercise]
    @State private var path: [String] = []
    // Deleting a whole session (all its blocks/entries/set logs, via the
    // model's existing cascade rules -- see WorkoutSession.blocks) is
    // destructive enough to want a confirmation, unlike a plain
    // `.onDelete` straight to `modelContext.delete`.
    @State private var pendingDeleteSession: WorkoutSession?
    @State private var deleteErrorMessage: String?
    // Bulk clear -- added for local testing of the Excel re-import flow
    // (does it correctly rebuild a client's history from scratch), same
    // destructive-confirmation pattern as the single-session delete above,
    // just scoped to every session for the current client instead of one.
    @State private var showingClearAllConfirmation = false
    // CONTRACT-UI.md §4.3: "历史 Tab 提供...独立的单项查询页（选动作 + 选时间
    //范围）". Presented as a sheet rather than folded into `path` (which is
    // typed for session-id push navigation) to keep the two entry points
    // (course timeline vs. single-exercise query) independent.
    @State private var showingExerciseQuery = false
    // M7 §5.2: Excel history import entry point + its local success/failure
    // banner. Kept local to this view rather than routed through
    // `ContentView`'s existing `importStatus` (that one is scoped to the
    // app-launch seed import specifically) -- History owns this feature,
    // so it owns showing its own result.
    @State private var showingExcelImport = false
    @State private var excelImportStatus: ImportStatusBanner.Status?
    // 历史导出（CSV）: generated on demand into a temp file, then handed to
    // the system share sheet. `exportedFileURL` doubles as the `.sheet`
    // presentation trigger (non-nil -> shown) and the file to share.
    @State private var exportedFileURL: URL?
    @State private var exportErrorMessage: String?
    // P2 (2026-09-11)：「分享結果」——先在 `ShareResultsSheet` 里多选，确认
    // 后生成 Exchange 包文件，`sharedResultsURL` 同样兼做 `.sheet` 触发条件。
    @State private var showingShareResults = false
    @State private var sharedResultsURL: URL?
    @State private var shareResultsErrorMessage: String?
    // 「今天」里还开着另一份没暫存/結束的草稿时，不能直接把这节课载进去覆盖它。
    @State private var showingOpenDraftConflict = false
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    private var currentClient: Client? {
        clientStore.currentClient(in: clients)
    }

    private var sessions: [WorkoutSession] {
        guard let clientID = currentClient?.id else { return [] }
        return allSessions.filter { $0.client?.id == clientID }
    }

    /// P2「分享結果」只列已結束課次——進行中的課次還不是最終結果，跟
    /// `copyLastSession`/`mostRecentSession` 对"已完成"的既有过滤规则一致。
    private var completedSessions: [WorkoutSession] {
        sessions.filter { !$0.isInProgress }
    }

    /// 依週 sticky 分組（GymLog 改版設計 §6）。按各組最新一節課的日期排序，
    /// 不是直接按 `weekNumber` 數字排序——`weekNumber` 沒有年份，跨年份的資料
    /// 用數字排序會在年底/年初交界處錯序，用實際日期排就不會。
    private struct WeekGroup: Identifiable {
        let weekNumber: Int
        let sessions: [WorkoutSession]
        var id: Int { weekNumber }
        var startDate: Date? { sessions.map(\.date).min() }
    }

    private var weekGroups: [WeekGroup] {
        let grouped = Dictionary(grouping: sessions, by: \.weekNumber)
        return grouped.keys
            .map { week in WeekGroup(weekNumber: week, sessions: grouped[week]!.sorted { $0.date > $1.date }) }
            .sorted { ($0.sessions.first?.date ?? .distantPast) > ($1.sessions.first?.date ?? .distantPast) }
    }

    // MARK: - 訓練強度概覽 (GymLog 改版設計 §6：「頂部加入…本週／本月訓練頻率
    // 概覽」)

    /// 本月至今每一天的訓練量（kg），沒有練的日子是 0——顏色深淺直接映射這個
    /// 數字，同一天多節課次疊加。復用 `SessionSummaryMetrics`（與課次卡片、
    /// 課次詳情同一套口徑），WOD-only 的日子沒有力量訓練量會是 0，跟真的沒練
    /// 目前無法區分，屬於這個概覽本身的已知限制，不影響下方逐堂課次列表。
    private var monthlyIntensity: [(day: Date, volumeKg: Double)] {
        let calendar = Calendar.current
        let today = Date()
        guard let monthStart = calendar.dateInterval(of: .month, for: today)?.start else { return [] }
        let dayCount = (calendar.dateComponents([.day], from: monthStart, to: today).day ?? 0) + 1
        var volumeByDay: [Date: Double] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.date)
            guard day >= monthStart, day <= today else { continue }
            let volume = SessionSummaryMetrics.compute(for: session).totalVolumeKg ?? 0
            volumeByDay[day, default: 0] += volume
        }
        return (0..<max(dayCount, 1)).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: monthStart) else { return nil }
            return (day, volumeByDay[calendar.startOfDay(for: day)] ?? 0)
        }
    }

    private var thisMonthSessionCount: Int {
        let calendar = Calendar.current
        guard let monthStart = calendar.dateInterval(of: .month, for: Date())?.start else { return 0 }
        return sessions.filter { $0.date >= monthStart }.count
    }

    private var monthLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .zhHant ? "zh_Hant" : "en_US")
        formatter.setLocalizedDateFormatFromTemplate(language == .zhHant ? "yyyyMMMM" : "MMMM yyyy")
        return formatter.string(from: Date())
    }

    @ViewBuilder
    private var trainingIntensityStrip: some View {
        let days = monthlyIntensity
        if !days.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .lastTextBaseline) {
                    Text(language.t("\(monthLabel) · \(thisMonthSessionCount) 堂", "\(monthLabel) · \(thisMonthSessionCount) sessions"))
                        .sectionLabelStyle()
                    Spacer()
                    Text(language.t("共 \(sessions.count) 堂", "\(sessions.count) total"))
                        .font(.system(size: 11))
                        .foregroundStyle(DS.C.textLow)
                }
                HStack(spacing: 4) {
                    ForEach(Array(days.enumerated()), id: \.offset) { _, entry in
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(intensityColor(volumeKg: entry.volumeKg, maxVolumeKg: days.map(\.volumeKg).max() ?? 0))
                            .frame(height: 30)
                    }
                }
                HStack {
                    Text(SessionDateFormat.display.string(from: days.first?.day ?? Date()))
                    Spacer()
                    Text(language.t("頻率概覽 · 顏色深淺 = 訓練量", "Frequency · color depth = volume"))
                    Spacer()
                    Text(SessionDateFormat.display.string(from: days.last?.day ?? Date()))
                }
                .font(.system(size: 10))
                .foregroundStyle(DS.C.textLow)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .gymCard()
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    /// 沒練＝`inset` 底色；有練的日子按當月最高單日訓練量分四階漸深，最高的
    /// 那天（或那幾天並列）直接用實心 `accent`，呼應設計稿 §6 的漸層深淺。
    private func intensityColor(volumeKg: Double, maxVolumeKg: Double) -> Color {
        guard volumeKg > 0, maxVolumeKg > 0 else { return DS.C.inset }
        let ratio = volumeKg / maxVolumeKg
        if ratio >= 0.999 { return DS.C.accent }
        if ratio >= 0.66 { return DS.C.accent.opacity(0.85) }
        if ratio >= 0.33 { return DS.C.accent.opacity(0.55) }
        return DS.C.accent.opacity(0.28)
    }

    private func weekHeader(_ group: WeekGroup) -> some View {
        HStack(spacing: 8) {
            Text(language.t("第 \(group.weekNumber) 週", "Week \(group.weekNumber)"))
            if let start = group.startDate {
                Text(language.t("· \(SessionDateFormat.display.string(from: start))起", "· from \(SessionDateFormat.display.string(from: start))"))
            }
        }
        .sectionLabelStyle()
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if currentClient == nil {
                    ContentUnavailableView {
                        Label(language.t("暫無學員", "No Clients"), systemImage: "person.crop.circle.badge.exclamationmark")
                    } description: {
                        Text(language.t("新增一位學員開始使用，或導入 Excel 訓練記錄", "Add a client to get started, or import Excel history"))
                    } actions: {
                        Button(language.t("新增學員", "Add Client")) { createFirstClient() }
                            .buttonStyle(.borderedProminent)
                    }
                } else if sessions.isEmpty {
                    ContentUnavailableView(
                        language.t("暫無訓練記錄", "No Sessions"),
                        systemImage: "clock.arrow.circlepath",
                        description: Text(language.t(
                            "該學員還沒有訓練課歷史。可以從右上角導入 Excel 訓練記錄。",
                            "This client has no session history yet. You can import Excel history from the top-right menu."
                        ))
                    )
                } else {
                    List {
                        trainingIntensityStrip

                        ForEach(weekGroups) { group in
                            Section {
                                ForEach(group.sessions) { session in
                                    NavigationLink(value: session.id) {
                                        SessionRow(session: session)
                                    }
                                    .listRowBackground(DS.C.surface)
                                    .listRowSeparatorTint(DS.C.hairlineSoft)
                                    // 「進行中」的课次左滑就能回到「今天」接着录——这是
                                    // 「暫時保存」之后最常走的那一步，不该埋在详情页里。
                                    .swipeActions(edge: .leading) {
                                        if session.isInProgress, draft != nil {
                                            Button {
                                                openInToday(session)
                                            } label: {
                                                Label(language.t("繼續記錄", "Continue"), systemImage: "play.fill")
                                            }
                                            .tint(DS.C.accent)
                                        }
                                    }
                                }
                                .onDelete { offsets in
                                    if let index = offsets.first {
                                        pendingDeleteSession = group.sessions[index]
                                    }
                                }
                            } header: {
                                weekHeader(group)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(DS.C.canvas)
                }
            }
            .reserveFloatingTabBarSpace()
            .navigationTitle(language.t("歷史 (\(sessions.count))", "History (\(sessions.count))"))
            .navigationDestination(for: String.self) { sessionId in
                if let session = sessions.first(where: { $0.id == sessionId }) {
                    SessionDetailView(session: session, onEditInToday: draft == nil ? nil : { openInToday(session) })
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if let client = currentClient {
                        ClientSwitcherButton(currentClient: client, coordinator: switchCoordinator)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    // A `Menu` rather than a second bare button: the nav bar's
                    // `.principal` slot already holds the client switcher, and
                    // two icons crowd the trailing edge on narrower screens.
                    Menu {
                        Button {
                            showingExerciseQuery = true
                        } label: {
                            Label(language.t("單項查詢", "Query"), systemImage: "magnifyingglass")
                        }
                        Button {
                            showingExcelImport = true
                        } label: {
                            Label(language.t("導入 Excel 歷史", "Import Excel History"), systemImage: "square.and.arrow.down")
                        }
                        .disabled(currentClient == nil)
                        Button {
                            exportHistory()
                        } label: {
                            Label(language.t("導出歷史", "Export History"), systemImage: "square.and.arrow.up")
                        }
                        .disabled(currentClient == nil || sessions.isEmpty)
                        Button {
                            showingShareResults = true
                        } label: {
                            Label(language.t("分享結果", "Share Results"), systemImage: "person.2.wave.2")
                        }
                        .disabled(currentClient == nil || completedSessions.isEmpty)
                        Button(role: .destructive) {
                            showingClearAllConfirmation = true
                        } label: {
                            Label(language.t("清空全部歷史", "Clear All History"), systemImage: "trash")
                        }
                        .disabled(currentClient == nil || sessions.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingExerciseQuery) {
                ExerciseQueryView(preselectedClientID: currentClient?.id)
            }
            .sheet(isPresented: $showingExcelImport) {
                if let client = currentClient {
                    ExcelImportFlow(client: client) { status in
                        excelImportStatus = status
                    }
                }
            }
            .sheet(isPresented: Binding(get: { exportedFileURL != nil }, set: { if !$0 { exportedFileURL = nil } })) {
                if let exportedFileURL {
                    ActivityShareSheet(activityItems: [exportedFileURL])
                }
            }
            .alert(language.t("導出失敗", "Export Failed"), isPresented: Binding(get: { exportErrorMessage != nil }, set: { if !$0 { exportErrorMessage = nil } })) {
                Button(language.t("好", "OK"), role: .cancel) {}
            } message: {
                Text(exportErrorMessage ?? "")
            }
            .sheet(isPresented: $showingShareResults) {
                ShareResultsSheet(sessions: completedSessions) { selected in
                    shareResults(selected)
                }
            }
            .sheet(isPresented: Binding(get: { sharedResultsURL != nil }, set: { if !$0 { sharedResultsURL = nil } })) {
                if let sharedResultsURL {
                    ActivityShareSheet(activityItems: [sharedResultsURL, ExchangeExporter.shareReminderText(payloadKind: .results, language: language)])
                }
            }
            .alert(language.t("分享失敗", "Share Failed"), isPresented: Binding(get: { shareResultsErrorMessage != nil }, set: { if !$0 { shareResultsErrorMessage = nil } })) {
                Button(language.t("好", "OK"), role: .cancel) {}
            } message: {
                Text(shareResultsErrorMessage ?? "")
            }
            .alert(
                language.t("確認刪除", "Confirm Delete"),
                isPresented: Binding(get: { pendingDeleteSession != nil }, set: { if !$0 { pendingDeleteSession = nil } }),
                presenting: pendingDeleteSession
            ) { session in
                Button(language.t("取消", "Cancel"), role: .cancel) { pendingDeleteSession = nil }
                Button(language.t("刪除", "Delete"), role: .destructive) { deleteSession(session) }
            } message: { session in
                Text(deleteConfirmationMessage(session))
            }
            .alert(language.t("「今天」還有未完成的課次", "An Unfinished Session Is Open"), isPresented: $showingOpenDraftConflict) {
                Button(language.t("好", "OK"), role: .cancel) {}
            } message: {
                Text(language.t(
                    "「今天」裡還開著另一堂沒有暫存或結束的訓練。請先回到「今天」把它暫存或結束，再回來編輯這一節。",
                    "Another session is still open in Today without being saved or finished. Save or finish it there first, then come back to edit this one."
                ))
            }
            .alert(language.t("刪除失敗", "Delete Failed"), isPresented: Binding(get: { deleteErrorMessage != nil }, set: { if !$0 { deleteErrorMessage = nil } })) {
                Button(language.t("好", "OK"), role: .cancel) {}
            } message: {
                Text(deleteErrorMessage ?? "")
            }
            .alert(
                language.t("確認清空全部歷史", "Confirm Clear All History"),
                isPresented: $showingClearAllConfirmation
            ) {
                Button(language.t("取消", "Cancel"), role: .cancel) {}
                Button(language.t("清空全部 \(sessions.count) 節", "Clear All \(sessions.count)"), role: .destructive) { clearAllSessions() }
            } message: {
                Text(language.t(
                    "確定刪除「\(currentClient?.displayName ?? "")」的全部 \(sessions.count) 節訓練課嗎？其中的所有動作記錄與組數都會一併刪除，此操作無法撤銷。",
                    "Delete all \(sessions.count) sessions for \"\(currentClient?.displayName ?? "")\"? Every exercise entry and set inside them will be deleted too. This cannot be undone."
                ))
            }
            .overlay(alignment: .top) {
                if let status = excelImportStatus {
                    ImportStatusBanner(status: status)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onTapGesture { excelImportStatus = nil }
                }
            }
            .animation(.default, value: excelImportStatus == nil)
        }
        // Verification-only hook, mirrors ContentView's GYMLOG_INITIAL_TAB:
        // launching with GYMLOG_INITIAL_SESSION_ID=<id> pushes straight into
        // that session's detail so the superset-grouping UI can be
        // screenshotted without live touch input. No effect otherwise.
        .task {
            if path.isEmpty,
               let targetId = ProcessInfo.processInfo.environment["GYMLOG_INITIAL_SESSION_ID"] {
                path = [targetId]
            }
        }
    }

    /// 导出当前学员的完整训练历史为 CSV，写入临时文件后交给系统分享面板
    /// （存到"文件" App / AirDrop / 郵件等）。同步生成 -- `HistoryCSVExporter` 是
    /// 纯 String 拼接，即使教练历史很长也是毫秒级，不需要 Task/loading 状态。
    /// Same "blank local client" convention as `ClientSwitcherButton.createBlankClient`/
    /// `TodayView.createFirstClient` -- needed here too since a genuinely
    /// fresh install (only the approved exercise library, no client, see
    /// `ContentView.importFixtureIfNeeded`) has no `currentClient` for the
    /// nav bar's own "+" button to attach to.
    /// 把这节课载入「今天」继续编辑。「今天」还开着别的草稿时不覆盖，只提示。
    private func openInToday(_ session: WorkoutSession) {
        guard let draft else { return }
        switch SessionEditingCoordinator.open(session, exercises: allExercises, into: draft, tabSelection: tabSelection) {
        case .opened:
            // 详情页可能正被推着；退回列表根，免得教练切回歷史时看到的还是那一页。
            path.removeAll()
        case .blockedByOpenDraft:
            showingOpenDraftConflict = true
        }
    }

    private func createFirstClient() {
        let client = Client(id: "cl-local-\(UUID().uuidString)", name: "")
        modelContext.insert(client)
        do {
            try modelContext.save()
            clientStore.currentClientID = client.id
        } catch {
            modelContext.rollback()
            deleteErrorMessage = error.localizedDescription
        }
    }

    private func exportHistory() {
        guard let client = currentClient else { return }
        do {
            exportedFileURL = try HistoryCSVExporter.writeTempFile(for: client)
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    private func shareResults(_ selected: [WorkoutSession]) {
        guard let client = currentClient, !selected.isEmpty else { return }
        let package = ExchangeExporter.buildResultsPackage(sessions: selected, client: client)
        do {
            sharedResultsURL = try ExchangeExporter.writeTempFile(package, suggestedFileName: ExchangeExporter.suggestedFileName(clientName: client.displayName, payloadKind: .results))
        } catch {
            shareResultsErrorMessage = error.localizedDescription
        }
    }

    /// `WorkoutSession.blocks` (and blocks->entries->setLogs beneath it) are
    /// all `deleteRule: .cascade`, so deleting the session here removes the
    /// whole course -- every block, exercise entry, and set log -- in one
    /// go. Unlike deleting an `Exercise` (which only nullifies references
    /// and keeps history intact), this is genuinely irreversible, hence the
    /// confirmation dialog.
    private func deleteConfirmationMessage(_ session: WorkoutSession) -> String {
        let dateText = SessionDateFormat.display.string(from: session.date)
        return language.t(
            "確定刪除 \(dateText)（第 \(session.weekNumber) 週）這節訓練課嗎？其中的所有動作記錄與組數都會一併刪除，此操作無法撤銷。",
            "Delete the session on \(dateText) (Week \(session.weekNumber))? All of its exercise entries and sets will be deleted too. This cannot be undone."
        )
    }

    private func deleteSession(_ session: WorkoutSession) {
        pendingDeleteSession = nil
        modelContext.delete(session)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            deleteErrorMessage = language.t("刪除失敗：\(error.localizedDescription)", "Delete failed: \(error.localizedDescription)")
        }
    }

    /// Deletes every session for the CURRENT client only (never a
    /// cross-client bulk action -- matches how every other operation on
    /// this tab, and in this app generally, is scoped). `sessions` is
    /// already the in-memory-filtered array this view renders from, so
    /// looping over it (rather than a `ModelContext.delete(model:where:)`
    /// batch delete) reuses the exact same client-scoping this view already
    /// depends on instead of re-expressing it as a SwiftData predicate --
    /// this codebase already avoids client-scoped predicates elsewhere over
    /// documented SwiftData predicate limitations (see the type's own
    /// `sessions` doc comment above).
    private func clearAllSessions() {
        for session in sessions {
            modelContext.delete(session)
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            deleteErrorMessage = language.t("清空失敗：\(error.localizedDescription)", "Clear failed: \(error.localizedDescription)")
        }
    }
}

/// 課次卡片——回答兩件事：練了什麼（模式色標 + 主要動作名）、練得多重
/// （總量／最大／消耗）（GymLog 改版設計 §6）。PR 沒有現成的「這堂課共幾個
/// PR」彙總可用，這裡只升級既有的「進行中」「日期已還原」徽章與 WOD 摘要行
/// 的視覺權重，不新增 PR 計數（避免另外拼一套跨動作 PR 判斷邏輯）。
private struct SessionRow: View {
    let session: WorkoutSession
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    private var nonWODEntries: [ExerciseEntry] {
        session.orderedBlocks.filter { $0.sectionKind != .wod }.flatMap(\.orderedEntries)
    }

    private var wodBlocks: [SessionBlock] {
        session.orderedBlocks.filter { $0.sectionKind == .wod }
    }

    private var movementPatterns: [MovementPattern] {
        var seen: [MovementPattern] = []
        for entry in nonWODEntries {
            guard let pattern = entry.exercise?.movementPattern, !seen.contains(pattern) else { continue }
            seen.append(pattern)
            if seen.count >= 3 { break }
        }
        return seen
    }

    private var exerciseSummaryText: String {
        let names = nonWODEntries.map(\.displayName)
        guard !names.isEmpty else { return "" }
        let shown = Array(names.prefix(2))
        let extra = names.count - shown.count
        let joined = shown.joined(separator: " · ")
        return extra > 0 ? "\(joined) · +\(extra)" : joined
    }

    private var weekdayText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .zhHant ? "zh_Hant" : "en_US")
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: session.date)
    }

    private var energy: EnergyReport { TrainingInsights.report(session) }
    private var metrics: SessionSummaryMetrics { SessionSummaryMetrics.compute(for: session) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(SessionDateFormat.display.string(from: session.date))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(DS.C.textHi)
                Text(weekdayText)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.C.textLow)
                if session.isInProgress { DataTagView(kind: .inProgress) }
                if session.dateOrigin == .reconstructed { DataTagView(kind: .restored) }
            }

            if !movementPatterns.isEmpty {
                HStack(spacing: 6) {
                    ForEach(movementPatterns, id: \.self) { pattern in
                        MovementPatternBadge(pattern: pattern, size: 22)
                    }
                    Text(exerciseSummaryText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.C.textHi)
                        .lineLimit(1)
                }
            }

            // 2026-09-07 M2 CrossFit extension，改版後升為主要動作行（原本是
            // 卡片底部的 accent 小字）：一行一個 WOD 區塊。
            ForEach(Array(wodBlocks.enumerated()), id: \.offset) { _, block in
                if let payload = block.wodPayload {
                    Text(WODSummaryFormatter.compactSummary(payload))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.C.accent)
                }
            }

            statsRow

            if let archive = TrainingInsights.decode(session), let review = archive.review {
                Text(archive.reviewFingerprint == TrainingInsights.reviewKey(session) ? review.summary : L("記錄已更新，AI 評價待更新", "Records changed; AI review needs updating"))
                    .font(.system(size: 11))
                    .foregroundStyle(DS.C.textLow)
                    .lineLimit(2)
            }

            // 「完成後估算」退為卡片最後一行灰字——原本佔主位的「資料不足」不
            // 該是教練一眼看到的第一件事（GymLog 改版設計 §6）。
            Text(L("完成後估算：", "Completed estimate: ") + EnergyReport.display(energy.actual) + (energy.isPartial ? L("（部分）", " (partial)") : ""))
                .font(.system(size: 11))
                .foregroundStyle(DS.C.textLow)
        }
        .padding(.vertical, 4)
    }

    private var statsRow: some View {
        HStack(spacing: 6) {
            statCell(language.t("總量", "Volume"), metrics.totalVolumeKg, unit: "kg")
            statCell(language.t("最大", "Top"), metrics.maxLoadKg, unit: "kg")
            statCell(language.t("消耗", "Burn"), energy.actual, unit: "kcal")
        }
    }

    private func statCell(_ title: String, _ value: Double?, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(DS.C.textLow)
                .textCase(.uppercase)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value.map { Self.fmt($0) } ?? "—")
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(value == nil ? DS.C.textLow : DS.C.textHi)
                Text(unit).font(.system(size: 10)).foregroundStyle(DS.C.textLow)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(DS.C.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(value == nil ? 0.6 : 1)
    }

    private static func fmt(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.05 {
            return Int(rounded).formatted(.number.grouping(.automatic))
        }
        return String(format: "%.1f", value)
    }
}

// WorkoutSession's Identifiable conformance (needed for List(sessions)
// sugar) is declared in GymLogKit alongside the type itself, not here.
