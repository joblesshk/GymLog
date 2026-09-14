import SwiftUI
import SwiftData
import GymLogKit

/// CONTRACT-UI.md §3.4: "全局当前学员置于导航栏，一次点击切换，不需退回列表."
/// Meant to sit in a `NavigationStack`'s `.principal` or trailing toolbar
/// slot on every tab's screen.
///
/// CONTRACT-M5.md §1 additions on top of the M2 original:
/// - a "+" button beside the switcher that creates a blank `Client` and
///   switches to it immediately (§1.1);
/// - the switch menu gained a leading "编辑「{displayName}」资料" entry that
///   jumps to the 个人信息 tab (§1.2) -- this doubles as the fix for "点击
///   默认用户后可以修改" (§1.3), since any client, blank-named or not, reaches
///   the same edit entry point, no special-casing needed;
/// - every displayed name (button label, menu rows) reads `displayName`
///   instead of `name`, so an empty-named client shows "默认用户" everywhere
///   consistently (§1.3).
///
/// `tabSelection` is optional and defaults to `nil` so the three call sites
/// this switcher already has outside M5-A's owned paths (`SettingsView`,
/// `HistoryListView`, `Sources/Views/Exercises/ExerciseLibraryView` -- the
/// last one explicitly off-limits this round) keep compiling unchanged; only
/// the two owned call sites (`TodayView`, `ClientProfileView`) pass a real
/// store, so "编辑「...」资料" only navigates from those two tabs. See
/// VERIFICATION-M5A.md for this scope note.
struct ClientSwitcherButton: View {
    let currentClient: Client
    let coordinator: ClientSwitchCoordinator
    var tabSelection: TabSelectionStore? = nil

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Client.name) private var clients: [Client]
    @State private var saveErrorMessage: String?
    @State private var showDeleteConfirmation = false
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button {
                    tabSelection?.select(tab: 1)
                } label: {
                    Label(language.t("編輯「\(currentClient.displayName)」資料", "Edit \"\(currentClient.displayName)\""), systemImage: "square.and.pencil")
                }

                let others = clients.filter { $0.id != currentClient.id }
                if !others.isEmpty {
                    Divider()
                    ForEach(others, id: \.id) { client in
                        Button {
                            coordinator.requestSwitch(to: client.id)
                        } label: {
                            Text(language.t("切換到 \(client.displayName)", "Switch to \(client.displayName)"))
                        }
                    }
                }

                Divider()
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label(language.t("刪除「\(currentClient.displayName)」資料", "Delete \"\(currentClient.displayName)\""), systemImage: "trash")
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(DS.C.accent)
                        .frame(width: 9, height: 9)
                    Text(currentClient.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.C.textHi)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.C.textLow)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(DS.C.surface, in: Capsule())
                .overlay(Capsule().stroke(DS.C.hairline, lineWidth: 1))
            }

            Button {
                createBlankClient()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.C.textMid)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().stroke(DS.C.hairline, lineWidth: 1))
            }
            .accessibilityLabel(language.t("新增學員", "Add Client"))
        }
        .alert(language.t("保存失敗", "Save Failed"), isPresented: Binding(get: { saveErrorMessage != nil }, set: { if !$0 { saveErrorMessage = nil } })) {
            Button(language.t("好", "OK"), role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "")
        }
        .alert(
            language.t("刪除「\(currentClient.displayName)」？", "Delete \"\(currentClient.displayName)\"?"),
            isPresented: $showDeleteConfirmation
        ) {
            Button(language.t("取消", "Cancel"), role: .cancel) {}
            Button(language.t("刪除", "Delete"), role: .destructive) { deleteCurrentClient() }
        } message: {
            Text(language.t("該學員的全部訓練記錄、檔案與 InBody 記錄都會一併永久刪除，且無法撤銷。", "This client's entire training history, profile, and InBody records will be permanently deleted along with them. This cannot be undone."))
        }
    }

    /// CONTRACT-M5.md §1.1: `id` via the existing local-id convention,
    /// `name = ""` (so it immediately reads as "默认用户" via `displayName`
    /// everywhere), every other field left `nil`. Routed through the
    /// coordinator (not a direct `clientStore.currentClientID` write) so the
    /// existing unsaved-work guard (CONTRACT-UI.md §3.4) still applies if the
    /// coach happens to have an in-progress 今天 draft open for someone else.
    private func createBlankClient() {
        let client = Client(id: "cl-local-\(UUID().uuidString)", name: "")
        modelContext.insert(client)
        do {
            try modelContext.save()
            coordinator.requestSwitch(to: client.id)
        } catch {
            modelContext.rollback()
            saveErrorMessage = error.localizedDescription
        }
    }

    /// `Client.assessments`/`bodyMetrics`/`sessions` are all `deleteRule:
    /// .cascade` (see `Client.swift`), so deleting the `Client` row also
    /// deletes their entire training history -- that's the whole point of
    /// "删除学员", not an accidental side effect. Any in-progress draft is
    /// discarded outright rather than routed through
    /// `ClientSwitchCoordinator`'s unsaved-work guard: the client it belongs
    /// to is about to stop existing either way, so there is nothing left to
    /// preserve it for. Clearing `currentClientID` (rather than picking a
    /// specific replacement here) lets `CurrentClientStore.currentClient(in:)`
    /// fall back to the first remaining client -- or to `nil`, handled by
    /// every screen's existing "暂无学员" empty state, if this was the last one.
    private func deleteCurrentClient() {
        coordinator.draftStore.reset()
        modelContext.delete(currentClient)
        do {
            try modelContext.save()
            coordinator.clientStore.currentClientID = nil
        } catch {
            modelContext.rollback()
            saveErrorMessage = error.localizedDescription
        }
    }
}
