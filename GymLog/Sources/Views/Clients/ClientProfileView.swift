import SwiftUI
import SwiftData
import Charts
import GymLogKit

/// 身體組成趨勢圖可切換的三個指標（GymLog 改版設計 §5：「單一折線 + 指標
/// 切換，最穩且好實作」）。
enum BodyMetricTrend: CaseIterable, Hashable {
    case weight, bodyFat, muscle

    var label: String {
        switch self {
        case .weight: return L("體重", "Weight")
        case .bodyFat: return L("體脂率", "Body Fat")
        case .muscle: return L("骨骼肌量", "Muscle")
        }
    }

    func value(of metric: BodyMetric) -> Double? {
        switch self {
        case .weight: return metric.weightKg
        case .bodyFat: return metric.bodyFatPercent
        case .muscle: return metric.skeletalMuscleKg
        }
    }

    func value(of point: BodyMetricTrendPoint) -> Double? {
        switch self {
        case .weight: return point.weightKg
        case .bodyFat: return point.bodyFatPercent
        case .muscle: return point.skeletalMuscleKg
        }
    }
}

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
    @State private var profileEditorSection: ProfileEditorSection?
    @State private var showAddBodyMetric = false
    // M7 §5.1: InBody report photo scan entry point.
    @State private var showInBodyScan = false
    @State private var showsAllBodyMetrics = false
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
                        profileSummarySection(for: client)
                        inBodySection(for: client)
                        profileDetailsSection
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
                    .onChange(of: client.id) { showsAllBodyMetrics = false; loadForm(client: client) }
                    // R05 (2026-09-16): every edit to the local buffer
                    // re-syncs `coordinator.hasAdditionalUnsavedWork` so a
                    // client switch started from anywhere (nav-bar switcher,
                    // any tab) goes through the same unsaved-work
                    // confirmation the training draft already gets, instead
                    // of `loadForm` silently overwriting an in-progress edit.
                    .onChange(of: form) { syncDirtyState(against: client) }
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
            .sheet(item: $profileEditorSection) { section in
                if let client = currentClient { profileEditor(for: client, section: section) }
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

    private func profileSummarySection(for client: Client) -> some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(client.stableColor.opacity(0.16))
                    Text(client.displayName.prefix(1).uppercased())
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(client.stableColor)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 4) {
                    Text(client.displayName)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(DS.C.textHi)
                    Text(language.t("學員檔案 · 個人資料", "Client profile · Personal details"))
                        .font(.system(size: 12))
                        .foregroundStyle(DS.C.textLow)
                }
                Spacer(minLength: 8)
                Button(language.t("編輯", "Edit")) { profileEditorSection = .basic }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.C.accent)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("profile-edit-button")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .gymCard()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("profile-summary-card")
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)
        }
    }

    private var profileDetailsSection: some View {
        Section {
            Button { profileEditorSection = .basic } label: {
                profileDetailRow(language.t("基本信息", "Basic Info"), systemImage: "person.text.rectangle")
            }
            .accessibilityIdentifier("profile-basic-info-button")
            Button { profileEditorSection = .training } label: {
                profileDetailRow(language.t("訓練目標", "Training Goals"), systemImage: "target")
            }
            .accessibilityIdentifier("profile-training-goals-button")
            Button { profileEditorSection = .habits } label: {
                profileDetailRow(language.t("習慣與病史", "Habits & Medical History"), systemImage: "heart.text.square")
            }
            .accessibilityIdentifier("profile-habits-medical-button")
        } header: {
            Text(language.t("檔案資料", "PROFILE DETAILS")).sectionLabelStyle()
        }
        .listRowBackground(DS.C.surface)
    }

    private func profileDetailRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(DS.C.accent)
                .frame(width: 24)
            Text(title).foregroundStyle(DS.C.textHi)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.C.textLow)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private enum ProfileEditorSection: String, Identifiable {
        case basic, training, habits
        var id: String { rawValue }
    }

    private func editorTitle(_ section: ProfileEditorSection) -> String {
        switch section {
        case .basic: return language.t("基本信息", "Basic Info")
        case .training: return language.t("訓練目標", "Training Goals")
        case .habits: return language.t("習慣與病史", "Habits & Medical History")
        }
    }

    @ViewBuilder
    private func editorSection(_ section: ProfileEditorSection) -> some View {
        switch section {
        case .basic: basicInfoSection
        case .training: trainingInfoSection
        case .habits: habitsSection
        }
    }

    private func profileEditor(for client: Client, section: ProfileEditorSection) -> some View {
        NavigationStack {
            Form {
                editorSection(section)
                saveSection(for: client)
            }
            .scrollContentBackground(.hidden)
            .background(DS.C.canvas)
            .font(DS.F.listRow)
            .foregroundStyle(DS.C.textHi)
            .navigationTitle(editorTitle(section))
            .accessibilityIdentifier("profile-\(section.rawValue)-editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("關閉", "Close")) { profileEditorSection = nil }
                }
            }
        }
        .presentationDetents([.large])
    }

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
            let metrics = Array(BodyMetricTrendSeries.sorted(client.bodyMetrics ?? []).reversed())
            if !metrics.isEmpty {
                overviewCard(metrics: metrics)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                BodyMetricTrendCard(metrics: metrics)
                    .id(client.id)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if !metrics.isEmpty {
                HStack {
                    Text(language.t("歷史記錄 · \(metrics.count)", "History · \(metrics.count)"))
                        .sectionLabelStyle()
                    Spacer()
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 0, trailing: 16))
                .listRowBackground(Color.clear)
            }

            if metrics.isEmpty {
                inBodyEmptyState
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(showsAllBodyMetrics ? metrics : Array(metrics.prefix(3)), id: \.id) { metric in
                    // Tappable: the row itself is a dense summary, and a
                    // saved record previously had no way to be read in
                    // full, corrected, or removed.
                    NavigationLink {
                        BodyMetricDetailView(client: client, metric: metric)
                    } label: {
                        BodyMetricRow(metric: metric)
                    }
                    .accessibilityIdentifier("profile-body-history-row-\(metric.id)")
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                }
                if metrics.count > 3 {
                    Button {
                        withAnimation { showsAllBodyMetrics.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Text(showsAllBodyMetrics
                                 ? language.t("收起", "Show Less")
                                 : language.t("展開其餘 \(metrics.count - 3) 條", "Show \(metrics.count - 3) More"))
                            Image(systemName: showsAllBodyMetrics ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.C.accent)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(DS.C.accent.opacity(0.10), in: Capsule())
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("profile-body-history-toggle")
                    .accessibilityValue("\(showsAllBodyMetrics ? metrics.count : min(metrics.count, 3))")
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                }
            }

            if !metrics.isEmpty {
                HStack(spacing: 8) {
                    Button {
                        showAddBodyMetric = true
                    } label: {
                        Text(language.t("新增記錄", "Add Record"))
                    }
                    .buttonStyle(.gymPrimary)
                    .accessibilityIdentifier("profile-add-body-metric-button")

                    Button {
                        showInBodyScan = true
                    } label: {
                        Label(language.t("掃描報告", "Scan Report"), systemImage: "doc.viewfinder")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.gymSecondary)
                    .accessibilityIdentifier("profile-scan-report-button")
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)
            }
        } header: {
            Text(language.t("身體組成 · BODY COMPOSITION", "BODY COMPOSITION")).sectionLabelStyle()
        } footer: {
            Text(language.t(
                "支持體測報告照片識別，不限機型（全程本機處理，不聯網）。識別後仍需逐項核對。",
                "Reads body-composition report photos from any analyser (processed entirely on-device). Review every value before saving."
            ))
            .foregroundStyle(DS.C.textLow)
        }
    }

    private var inBodyEmptyState: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "figure.stand")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(DS.C.accent)
                    .frame(width: 52, height: 52)
                    .background(DS.C.accentSoft, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                    Text(language.t("記錄第一次身體測量", "Your first body measurement"))
                        .font(DS.F.cardTitle)
                        .foregroundStyle(DS.C.textHi)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(language.t(
                        "加入 InBody 報告，開始追蹤體重、體脂與肌肉的變化。",
                        "Add an InBody report to start tracking changes in weight, body fat and muscle."
                    ))
                    .font(.system(size: 13))
                    .foregroundStyle(DS.C.textMid)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 8) {
                Button {
                    showInBodyScan = true
                } label: {
                    Label(language.t("掃描報告", "Scan Report"), systemImage: "doc.viewfinder")
                }
                .buttonStyle(.gymPrimary)
                .accessibilityIdentifier("profile-scan-report-button")
                Button {
                    showAddBodyMetric = true
                } label: {
                    Text(language.t("或手動新增記錄", "Or add a record manually"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.C.textMid)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("profile-add-body-metric-button")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.C.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.card)
                .strokeBorder(DS.C.hairlineSoft, lineWidth: 1)
        }
    }

    // MARK: - InBody overview + trend (GymLog 改版設計 §5)

    private func overviewCard(metrics: [BodyMetric]) -> some View {
        let latest = metrics[0]
        let previous = metrics.count > 1 ? metrics[1] : nil
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(language.t(
                    "最新 · \(SessionDateFormat.display.string(from: latest.date))",
                    "Latest · \(SessionDateFormat.display.string(from: latest.date))"
                ))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(DS.C.textHi)
                Spacer()
                if let previous, let days = Calendar.current.dateComponents([.day], from: previous.date, to: latest.date).day {
                    Text(language.t("距上次 \(days) 天", "\(days) days since last"))
                        .font(.system(size: 11))
                        .foregroundStyle(DS.C.textLow)
                }
            }
            HStack(spacing: 8) {
                bodyMetricStatCell(
                    title: language.t("體重", "Weight"), unit: "kg",
                    value: latest.weightKg, previous: previous?.weightKg
                )
                bodyMetricStatCell(
                    title: language.t("體脂率", "Body Fat"), unit: "%",
                    value: latest.bodyFatPercent, previous: previous?.bodyFatPercent
                )
                bodyMetricStatCell(
                    title: language.t("骨骼肌", "Muscle"), unit: "kg",
                    value: latest.skeletalMuscleKg, previous: previous?.skeletalMuscleKg
                )
            }
            Text(language.t(
                "相較上一筆 · 數值變化僅供核對，不判定好壞",
                "Compared with the previous record · changes are neutral and do not indicate good or bad"
            ))
            .font(.system(size: 11))
            .foregroundStyle(DS.C.textLow)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gymCard()
        .padding(.horizontal, DS.Space.pageMargin)
    }

    private func bodyMetricStatCell(title: String, unit: String, value: Double?, previous: Double?) -> some View {
        let delta = (value != nil && previous != nil) ? value! - previous! : nil
        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DS.C.textLow)
            if let value {
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text(Self.fmt(value))
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundStyle(DS.C.textHi)
                    Text(unit).font(.system(size: 11)).foregroundStyle(DS.C.textLow)
                }
            } else {
                Text("—")
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DS.C.textLow)
            }
            if let delta {
                HStack(spacing: 2) {
                    Text(delta >= 0 ? "↑" : "↓")
                    Text(Self.fmt(abs(delta)))
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.C.textMid)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(DS.C.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    fileprivate static func fmt(_ d: Double) -> String {
        d == d.rounded() ? String(format: "%.0f", d) : String(format: "%.1f", d)
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
        syncDirtyState(against: client)
    }

    /// R05 (2026-09-16): the buffer is dirty exactly when it differs from
    /// what `client`'s own fields would produce right now -- comparing
    /// against a freshly-built `ClientProfileFormState`, not a separately
    /// cached "as-loaded" snapshot, so this can't drift out of sync with
    /// `client` if something else mutates it. `loadedClientID != client.id`
    /// guards the one render frame where `client` has already switched but
    /// `loadForm` for it hasn't run yet.
    private func syncDirtyState(against client: Client) {
        coordinator.hasAdditionalUnsavedWork = loadedClientID == client.id && form != ClientProfileFormState(client: client)
    }

    private func save(client: Client) {
        form.apply(to: client)
        do {
            try modelContext.save()
            showSavedConfirmation = true
            syncDirtyState(against: client) // now clean -- `client` matches `form`
        } catch {
            // CONTRACT-M4.md's own risk callout: a save bug here corrupts
            // the real coach's profile, so a failure must surface, never be
            // swallowed (same discipline as TodayView's session save path,
            // CONTRACT-UI.md §3.6).
            //
            // R05 (2026-09-16): does NOT re-run `loadForm` here anymore --
            // that used to rebuild `form` from the just-rolled-back `client`,
            // silently replacing whatever the coach had just typed with the
            // pre-edit values. `form` already holds exactly what they typed
            // (rollback only reverted `client`, never touched `form`), so
            // leaving it alone is what keeps 保存資料 usable as a retry button.
            modelContext.rollback()
            saveErrorMessage = error.localizedDescription
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

    /// 缺欄位時只排有值的欄位並標「僅體重」，不留空洞（GymLog 改版設計 §5）。
    private var isWeightOnly: Bool {
        metric.weightKg != nil
            && metric.bodyFatPercent == nil
            && metric.bodyFatMassKg == nil
            && metric.skeletalMuscleKg == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(SessionDateFormat.display.string(from: metric.date))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(DS.C.textHi)
                if isWeightOnly {
                    Text(language.t("僅體重", "Weight only"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.C.textLow)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(DS.C.inset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            HStack(spacing: 12) {
                if let w = metric.weightKg { field(Self.fmt(w), "kg") }
                if let bf = metric.bodyFatPercent { field(Self.fmt(bf), "%") }
                if let smm = metric.skeletalMuscleKg { field(Self.fmt(smm), language.t("kg 肌", "kg muscle")) }
            }
            // 2026-09-16：備註、BMI、內臟脂肪、代謝等其餘欄位只在詳情頁顯示
            // （GymLog 改版設計 §5：「小字網格改成三層資訊…歷史卡片」只留最
            // 重要的體重／體脂率／骨骼肌，其餘「點進去再看」）——這裡不再把
            // 備註原文整段排進列表卡片。
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gymCard()
    }

    private func field(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(DS.C.textHi)
            Text(unit).font(.system(size: 12)).foregroundStyle(DS.C.textMid)
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
