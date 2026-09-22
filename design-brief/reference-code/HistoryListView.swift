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
                        ForEach(sessions) { session in
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
                                pendingDeleteSession = sessions[index]
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

private struct SessionRow: View {
    let session: WorkoutSession
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(SessionDateFormat.display.string(from: session.date))
                    .font(DS.F.cardTitle)
                    .foregroundStyle(DS.C.textHi)
                Spacer()
                Text(language.t("第 \(session.weekNumber) 週", "Week \(session.weekNumber)"))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(DS.C.textMid)
            }
            HStack(spacing: 8) {
                if let name = session.client?.displayName {
                    Text(language.t("\(name) · \(session.orderedBlocks.count) 個訓練塊", "\(name) · \(session.orderedBlocks.count) blocks"))
                        .font(DS.F.subtitle)
                        .foregroundStyle(DS.C.textLow)
                } else {
                    Text(language.t("\(session.orderedBlocks.count) 個訓練塊", "\(session.orderedBlocks.count) blocks"))
                        .font(DS.F.subtitle)
                        .foregroundStyle(DS.C.textLow)
                }
                if session.isInProgress {
                    DataTagView(kind: .inProgress)
                }
                if session.dateOrigin == .reconstructed {
                    DataTagView(kind: .restored)
                }
            }
            Text(L("完成後估算：", "Completed estimate: ") + EnergyReport.display(TrainingInsights.report(session).actual) + (TrainingInsights.report(session).isPartial ? L("（部分）", " (partial)") : ""))
                .font(.caption).foregroundStyle(.secondary)
            if let archive = TrainingInsights.decode(session), let review = archive.review {
                Text(archive.reviewFingerprint == TrainingInsights.reviewKey(session) ? review.summary : L("記錄已更新，AI 評價待更新", "Records changed; AI review needs updating"))
                    .font(.caption).lineLimit(2)
            }
            // 2026-09-07 M2 CrossFit extension: 工程审阅 §6's history-list
            // example ("力量 + AMRAP 12:00 · 5輪+12次 · Scaled") -- one line
            // per WOD block, appended after the existing block-count line.
            ForEach(Array(session.orderedBlocks.enumerated()), id: \.offset) { _, block in
                if block.sectionKind == .wod, let payload = block.wodPayload {
                    Text(WODSummaryFormatter.compactSummary(payload))
                        .font(DS.F.subtitle)
                        .foregroundStyle(DS.C.accent)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// WorkoutSession's Identifiable conformance (needed for List(sessions)
// sugar) is declared in GymLogKit alongside the type itself, not here.
