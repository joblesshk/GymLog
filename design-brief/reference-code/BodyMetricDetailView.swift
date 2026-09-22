import SwiftUI
import SwiftData
import GymLogKit

/// One InBody record, opened from the list on `ClientProfileView`.
///
/// The list row is a deliberately dense summary -- eight values on two
/// lines at 12pt -- which is fine for scanning the history but not for
/// actually reading one measurement, and it offered no way to correct or
/// remove a record once saved. That gap matters more than it looks: the
/// photo scanner can put a wrong value into a record (or miss one), and
/// until now the only remedy was to leave it there.
///
/// So this page shows every field `BodyMetric` carries, at a readable size,
/// INCLUDING the ones that are empty -- rendered as "—" rather than hidden.
/// Which fields a scan failed to capture is exactly what the coach needs to
/// see when checking a scanned record against the paper report; hiding the
/// gaps (as the summary row does, out of necessity) makes a partial scan
/// look complete.
struct BodyMetricDetailView: View {
    let client: Client
    let metric: BodyMetric

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    @State private var showEditSheet = false
    @State private var showDeleteConfirmation = false
    @State private var deleteErrorMessage: String?
    /// Set before `dismiss()` so the body stops reading `metric` the moment
    /// deletion starts -- a SwiftData object that has been deleted is not
    /// safe to keep rendering, and the pop is not instantaneous.
    @State private var isDeleting = false

    var body: some View {
        Group {
            if isDeleting {
                Color.clear
            } else {
                content
            }
        }
    }

    private var content: some View {
        List {
            Section {
                LabeledContent {
                    Text(SessionDateFormat.display.string(from: metric.date))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DS.C.textHi)
                } label: {
                    Text(language.t("測量日期", "Measured"))
                        .font(DS.F.listRow)
                        .foregroundStyle(DS.C.textLow)
                }
                .listRowBackground(DS.C.surface)
            }

            Section {
                valueRow(language.t("體重", "Weight"), metric.weightKg, unit: "kg")
                valueRow(language.t("體脂率", "Body Fat"), metric.bodyFatPercent, unit: "%")
                valueRow(language.t("體脂重", "Fat Mass"), metric.bodyFatMassKg, unit: "kg")
                valueRow(language.t("骨骼肌量", "Skeletal Muscle Mass"), metric.skeletalMuscleKg, unit: "kg")
            } header: {
                Text(language.t("身體組成", "Body Composition")).sectionLabelStyle()
            }

            Section {
                valueRow("BMI", metric.bmi, unit: "")
                valueRow(
                    language.t("內臟脂肪等級", "Visceral Fat Level"),
                    metric.visceralFatLevel.map(Double.init),
                    unit: "",
                    integer: true
                )
                valueRow("BMR", metric.bmr, unit: "kcal")
                valueRow("TDEE", metric.tdee, unit: "kcal")
            } header: {
                Text(language.t("指標", "Indices")).sectionLabelStyle()
            }

            Section {
                if let notes = metric.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(notes)
                        .font(.system(size: 15))
                        .foregroundStyle(DS.C.textHi)
                        .textSelection(.enabled)
                } else {
                    Text(language.t("無", "None"))
                        .font(.system(size: 15))
                        .foregroundStyle(DS.C.textLow)
                }
            } header: {
                Text(language.t("備註", "Notes")).sectionLabelStyle()
            }
            .listRowBackground(DS.C.surface)

            Section {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Text(language.t("刪除這條記錄", "Delete This Record"))
                        .font(.system(size: 15, weight: .semibold))
                }
                .listRowBackground(DS.C.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.C.canvas)
        // Without this the floating tab bar sits on top of the last
        // section, and the delete button ends up permanently unreachable --
        // the list has nothing left to scroll. Every other screen in the
        // app that owns a scroll view does the same.
        .reserveFloatingTabBarSpace()
        .navigationTitle(language.t("InBody 記錄", "InBody Record"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(language.t("編輯", "Edit")) { showEditSheet = true }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.C.accent)
            }
        }
        .sheet(isPresented: $showEditSheet) {
            AddBodyMetricSheet(client: client, metric: metric)
        }
        .confirmationDialog(
            language.t("刪除這條 InBody 記錄？", "Delete this InBody record?"),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.t("刪除", "Delete"), role: .destructive) { performDelete() }
            Button(language.t("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(language.t("刪除後無法復原。", "This cannot be undone."))
        }
        .alert(
            language.t("刪除失敗", "Delete Failed"),
            isPresented: Binding(get: { deleteErrorMessage != nil }, set: { if !$0 { deleteErrorMessage = nil } })
        ) {
            Button(language.t("好", "OK"), role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "")
        }
    }

    /// Renders an absent value as "—" instead of dropping the row, so a
    /// partially-captured scan reads as partial.
    @ViewBuilder
    private func valueRow(_ label: String, _ value: Double?, unit: String, integer: Bool = false) -> some View {
        LabeledContent {
            if let value {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(integer ? String(Int(value)) : Self.format(value))
                        .font(.system(size: 17, weight: .semibold).monospacedDigit())
                        .foregroundStyle(DS.C.textHi)
                    if !unit.isEmpty {
                        Text(unit)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DS.C.textLow)
                    }
                }
            } else {
                Text("—")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(DS.C.textLow)
            }
        } label: {
            Text(label)
                .font(DS.F.listRow)
                .foregroundStyle(DS.C.textLow)
        }
        .listRowBackground(DS.C.surface)
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private func performDelete() {
        isDeleting = true
        dismiss()
        modelContext.delete(metric)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            isDeleting = false
            deleteErrorMessage = error.localizedDescription
        }
    }
}
