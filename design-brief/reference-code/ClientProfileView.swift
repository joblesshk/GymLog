import SwiftUI
import SwiftData
import GymLogKit

/// 学员 tab (CONTRACT-M4.md §4.3), replacing the switcher-list role
/// `ClientListView` used to play under M2. Switching now lives entirely in
/// the global `ClientSwitcherButton` (every tab's nav bar, already wired up
/// by the coordinator) -- this page's job is a full editable profile for
/// the *current* client: the `Client` fields CONTRACT.md §4 has carried
/// since M1 but that never surfaced in any UI, plus a browse/add InBody
/// (`BodyMetric`) section, plus "新增学员" since the real data currently has
/// only Example Athlete and the coach will add more.
///
/// Field edits are staged in a local `ClientProfileFormState` buffer, not bound
/// directly to the live `Client` object's properties -- CONTRACT-M4.md's own
/// risk callout is that a save bug here corrupts the coach's *real* profile,
/// not test fixture data, so partial in-progress edits (a half-typed phone
/// number) never touch the persisted `Client` until an explicit 保存 tap
/// writes the whole buffer back and calls `ModelContext.save()`.
struct ClientProfileView: View {
    let clientStore: CurrentClientStore
    let coordinator: ClientSwitchCoordinator
    // CONTRACT-M5.md §1.2: threaded through so ClientSwitcherButton's
    // "编辑「...」资料" entry has somewhere to jump when tapped from this
    // screen too (a no-op in practice, since we're already here, but keeps
    // the switcher's behavior consistent regardless of which owned tab it's
    // mounted on).
    var tabSelection: TabSelectionStore? = nil

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Client.name) private var clients: [Client]

    @State private var form = ClientProfileFormState()
    @State private var loadedClientID: String?
    @State private var showAddClient = false
    @State private var showAddBodyMetric = false
    // M7 §5.1: InBody report photo scan entry point.
    @State private var showInBodyScan = false
    @State private var saveErrorMessage: String?
    @State private var showSavedConfirmation = false
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    private var currentClient: Client? {
        clientStore.currentClient(in: clients)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let client = currentClient {
                    Form {
                        basicInfoSection
                        trainingInfoSection
                        habitsSection
                        inBodySection(for: client)
                        saveSection(for: client)
                    }
                    .scrollContentBackground(.hidden)
                    .background(DS.C.canvas)
                    .reserveFloatingTabBarSpace()
                    .tint(DS.C.accent)
                    // Form rows had no explicit typography anywhere in this
                    // screen, so every LabeledContent/TextField/Picker/Toggle
                    // fell back to the system's default Form text size --
                    // visibly larger than the 15pt used for the equivalent
                    // rows in Settings, and inconsistent with this same
                    // screen's own smaller InBody/habits captions. One
                    // environment default here fixes both: rows that already
                    // set their own explicit (smaller) font keep it, since an
                    // explicit font always wins over an inherited one.
                    .font(DS.F.listRow)
                    .foregroundStyle(DS.C.textHi)
                    .onAppear { loadFormIfNeeded(client: client) }
                    .onChange(of: client.id) { loadForm(client: client) }
                } else {
                    ContentUnavailableView {
                        Label(language.t("暫無學員", "No Clients"), systemImage: "person.crop.circle.badge.exclamationmark")
                    } description: {
                        Text(language.t("新增一位學員開始使用", "Add a client to get started"))
                    } actions: {
                        Button(language.t("新增學員", "Add Client")) { createFirstClient() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle(language.t("學員檔案", "Client Profile"))
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if let client = currentClient {
                        ClientSwitcherButton(currentClient: client, coordinator: coordinator, tabSelection: tabSelection)
                    }
                }
                // Only shown when there's no current client to attach a
                // `ClientSwitcherButton` (and its own "+") to at all -- once
                // a client exists, adding a new one goes exclusively through
                // that switcher's "+", not a second button here. Without
                // this fallback, deleting every client would leave no way
                // to add a first one back.
                if currentClient == nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showAddClient = true
                        } label: {
                            Image(systemName: "person.badge.plus")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(DS.C.onAccent)
                                .frame(width: 32, height: 32)
                                .background(DS.C.accent, in: Circle())
                        }
                        .accessibilityLabel(language.t("新增學員", "Add Client"))
                    }
                }
            }
            .sheet(isPresented: $showAddClient) {
                AddClientSheet(coordinator: coordinator)
            }
            .sheet(isPresented: $showAddBodyMetric) {
                if let client = currentClient {
                    AddBodyMetricSheet(client: client)
                }
            }
            .sheet(isPresented: $showInBodyScan) {
                if let client = currentClient {
                    InBodyScanFlow(client: client)
                }
            }
            .alert(language.t("保存失敗", "Save Failed"), isPresented: Binding(get: { saveErrorMessage != nil }, set: { if !$0 { saveErrorMessage = nil } })) {
                Button(language.t("好", "OK"), role: .cancel) {}
            } message: {
                Text(saveErrorMessage ?? "")
            }
            .alert(language.t("已保存", "Saved"), isPresented: $showSavedConfirmation) {
                Button(language.t("好", "OK"), role: .cancel) {}
            }
        }
    }

    // MARK: - Form sections

    private var basicInfoSection: some View {
        Section {
            LabeledContent(language.t("姓名", "Name")) {
                TextField(language.t("姓名", "Name"), text: $form.name)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent(language.t("電話", "Phone")) {
                TextField(language.t("未填寫", "Not filled in"), text: $form.phone)
                    .keyboardType(.phonePad)
                    .multilineTextAlignment(.trailing)
            }
            Picker(language.t("性別", "Gender"), selection: $form.gender) {
                Text(language.t("未設置", "Not set")).tag("")
                Text(language.t("男", "Male")).tag("男")
                Text(language.t("女", "Female")).tag("女")
                Text(language.t("其他", "Other")).tag("其他")
            }
            LabeledContent(language.t("年齡", "Age")) {
                TextField(language.t("未填寫", "Not filled in"), text: $form.age)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent(language.t("身高 (cm)", "Height (cm)")) {
                TextField(language.t("未填寫", "Not filled in"), text: $form.heightCm)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent(language.t("起始體重 (kg)", "Starting Weight (kg)")) {
                TextField(language.t("未填寫", "Not filled in"), text: $form.startWeightKg)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text(language.t("基本信息", "Basic Info")).sectionLabelStyle()
        }
        .listRowBackground(DS.C.surface)
    }

    private var trainingInfoSection: some View {
        Section {
            LabeledContent(language.t("目標", "Goal")) {
                TextField(language.t("未填寫", "Not filled in"), text: $form.goal)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent(language.t("訓練頻率", "Frequency")) {
                TextField(language.t("如：每週3次", "e.g. 3x/week"), text: $form.frequency)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("BMR") {
                TextField(language.t("未填寫", "Not filled in"), text: $form.bmr)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("TDEE") {
                TextField(language.t("未填寫", "Not filled in"), text: $form.tdee)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text(language.t("訓練目標", "Training Goals")).sectionLabelStyle()
        }
        .listRowBackground(DS.C.surface)
    }

    private var habitsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(language.t("習慣", "Habits")).font(.system(size: 11)).foregroundStyle(DS.C.textLow)
                TextEditor(text: $form.habits)
                    .frame(minHeight: 60)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(language.t("病史", "Medical History")).font(.system(size: 11)).foregroundStyle(DS.C.textLow)
                TextEditor(text: $form.medicalHistory)
                    .frame(minHeight: 60)
            }
        } header: {
            Text(language.t("習慣與病史", "Habits & Medical History")).sectionLabelStyle()
        }
        .listRowBackground(DS.C.surface)
    }

    /// Same "blank local client" convention as `ClientSwitcherButton.createBlankClient`/
    /// `TodayView.createFirstClient` -- needed here too since a genuinely
    /// fresh install (only the approved exercise library, no client, see
    /// `ContentView.importFixtureIfNeeded`) has no `currentClient` for the
    /// nav bar's own "+" button to attach to.
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

    @ViewBuilder
    private func inBodySection(for client: Client) -> some View {
        Section {
            let metrics = (client.bodyMetrics ?? []).sorted { $0.date > $1.date }
            if metrics.isEmpty {
                Text(language.t("暫無 InBody 記錄", "No InBody records yet"))
                    .font(.system(size: 13))
                    .foregroundStyle(DS.C.textLow)
            } else {
                ForEach(metrics, id: \.id) { metric in
                    // Tappable: the row itself is a dense summary, and a
                    // saved record previously had no way to be read in
                    // full, corrected, or removed.
                    NavigationLink {
                        BodyMetricDetailView(client: client, metric: metric)
                    } label: {
                        BodyMetricRow(metric: metric)
                    }
                }
            }
            Button {
                showAddBodyMetric = true
            } label: {
                Text(language.t("新增一條 InBody 記錄", "Add InBody Record"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.C.accent)
            }
            Button {
                showInBodyScan = true
            } label: {
                Label(language.t("掃描報告照片", "Scan Report Photo"), systemImage: "doc.viewfinder")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.C.accent)
            }
        } header: {
            Text("InBody").sectionLabelStyle()
        } footer: {
            Text(language.t(
                "支持體測報告照片識別，不限機型（全程本機處理，不聯網）。識別後仍需逐項核對。",
                "Reads body-composition report photos from any analyser (processed entirely on-device). Review every value before saving."
            ))
            .foregroundStyle(DS.C.textLow)
        }
        .listRowBackground(DS.C.surface)
    }

    private func saveSection(for client: Client) -> some View {
        Section {
            Button {
                save(client: client)
            } label: {
                Text(language.t("保存資料", "Save Profile"))
            }
            .buttonStyle(.gymPrimary)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    // MARK: - Load / save

    private func loadFormIfNeeded(client: Client) {
        guard loadedClientID != client.id else { return }
        loadForm(client: client)
    }

    private func loadForm(client: Client) {
        form = ClientProfileFormState(client: client)
        loadedClientID = client.id
    }

    private func save(client: Client) {
        form.apply(to: client)
        do {
            try modelContext.save()
            showSavedConfirmation = true
        } catch {
            // CONTRACT-M4.md's own risk callout: a save bug here corrupts
            // the real coach's profile, so a failure must surface, never be
            // swallowed (same discipline as TodayView's session save path,
            // CONTRACT-UI.md §3.6).
            modelContext.rollback()
            saveErrorMessage = error.localizedDescription
            loadForm(client: client) // re-sync the buffer with the rolled-back object
        }
    }
}

/// One InBody history row -- shows every field `BodyMetric` actually has
/// (CONTRACT.md §4's model does not carry segmental readings or a report
/// photo field, only date/weight/body-fat%/skeletal-muscle/BMI/visceral-fat/
/// BMR/TDEE/notes -- see VERIFICATION-M4A.md for this flagged as a
/// contract-vs-model gap).
private struct BodyMetricRow: View {
    let metric: BodyMetric
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(SessionDateFormat.display.string(from: metric.date))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.C.textHi)
            HStack(spacing: 12) {
                if let w = metric.weightKg { field(language.t("體重", "Weight"), "\(Self.fmt(w))kg") }
                if let bf = metric.bodyFatPercent { field(language.t("體脂率", "Body Fat"), "\(Self.fmt(bf))%") }
                if let bfm = metric.bodyFatMassKg { field(language.t("體脂重", "Fat Mass"), "\(Self.fmt(bfm))kg") }
                if let smm = metric.skeletalMuscleKg { field(language.t("骨骼肌", "Muscle"), "\(Self.fmt(smm))kg") }
            }
            HStack(spacing: 12) {
                if let bmi = metric.bmi { field("BMI", Self.fmt(bmi)) }
                if let vfl = metric.visceralFatLevel { field(language.t("內臟脂肪", "Visceral Fat"), "\(vfl)") }
                if let bmr = metric.bmr { field("BMR", Self.fmt(bmr)) }
                if let tdee = metric.tdee { field("TDEE", Self.fmt(tdee)) }
            }
            if let notes = metric.notes, !notes.isEmpty {
                Text(notes).font(.system(size: 12)).foregroundStyle(DS.C.textLow)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(DS.C.textLow)
            Text(value).font(.system(size: 12)).foregroundStyle(DS.C.textHi)
        }
    }

    private static func fmt(_ d: Double) -> String {
        d == d.rounded() ? String(format: "%.0f", d) : String(format: "%.1f", d)
    }
}

/// "新增学员" (CONTRACT-M4.md §4.3: "教练未来会加学员"). Only `name` is
/// required -- every other `Client` field is legitimately nullable per
/// CONTRACT.md §4's own real-data baseline (Example Athlete's own profile is all-
/// null except `name`), so this stays a minimal creation form; the rest gets
/// filled in later via the profile form this same view provides.
private struct AddClientSheet: View {
    let coordinator: ClientSwitchCoordinator

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var saveErrorMessage: String?
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    var body: some View {
        NavigationStack {
            Form {
                TextField(language.t("學員姓名", "Client Name"), text: $name)
            }
            .scrollContentBackground(.hidden)
            .background(DS.C.canvas)
            .font(DS.F.listRow)
            .foregroundStyle(DS.C.textHi)
            .navigationTitle(language.t("新增學員", "Add Client"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("取消", "Cancel")) { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.C.textHi)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.t("創建", "Create")) { create() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.C.accent)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert(language.t("保存失敗", "Save Failed"), isPresented: Binding(get: { saveErrorMessage != nil }, set: { if !$0 { saveErrorMessage = nil } })) {
                Button(language.t("好", "OK"), role: .cancel) {}
            } message: {
                Text(saveErrorMessage ?? "")
            }
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let client = Client(id: "cl-local-\(UUID().uuidString)", name: trimmed)
        modelContext.insert(client)
        do {
            try modelContext.save()
            // Route through the coordinator, same as any other switch, so
            // the unsaved-work guard still applies if the coach happened to
            // have an in-progress 今天 draft open for someone else.
            coordinator.requestSwitch(to: client.id)
            dismiss()
        } catch {
            modelContext.rollback()
            saveErrorMessage = error.localizedDescription
        }
    }
}
