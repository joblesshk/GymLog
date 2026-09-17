import SwiftUI
import SwiftData
import GymLogKit

/// Manual "new InBody record" entry form (CONTRACT-M4.md §4.3: "手动录入表单
/// ...不必做报告照片 OCR 或自动识别，手动填字段即可").
///
/// M7 §2.5: extracted out of `ClientProfileView.swift` (was a private nested
/// struct there) so `InBodyScanFlow` can also present it, pre-filled from an
/// OCR'd photo via the `prefill:` initializer below.
struct AddBodyMetricSheet: View {
    let client: Client
    let prefill: InBodyScanResult?
    /// Optional only for the scan review flow. Manual add/edit forms keep
    /// their original fields and toolbar unchanged.
    private let diagnosticsAction: (() -> Void)?
    /// Non-nil when this sheet is editing an EXISTING record rather than
    /// creating one. Kept as the model object (not a copy) so `save()` can
    /// write straight back to it; the staged `@State` strings below are
    /// still the buffer, so a half-typed value never reaches the store
    /// until 保存 is tapped -- same rule `ClientProfileView` follows for
    /// the profile form.
    private let editing: BodyMetric?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var weightKg = ""
    @State private var bodyFatPercent = ""
    @State private var bodyFatMassKg = ""
    @State private var skeletalMuscleKg = ""
    @State private var bmi = ""
    @State private var visceralFatLevel = ""
    @State private var bmr = ""
    @State private var tdee = ""
    @State private var notes = ""
    @State private var saveErrorMessage: String?
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    init(client: Client, prefill: InBodyScanResult? = nil, diagnosticsAction: (() -> Void)? = nil) {
        self.client = client
        self.prefill = prefill
        self.editing = nil
        self.diagnosticsAction = diagnosticsAction
        if let prefill {
            _date = State(initialValue: prefill.date ?? Date())
            _weightKg = State(initialValue: Self.format(prefill.weightKg))
            _bodyFatPercent = State(initialValue: Self.format(prefill.bodyFatPercent))
            _bodyFatMassKg = State(initialValue: Self.format(prefill.bodyFatMassKg))
            _skeletalMuscleKg = State(initialValue: Self.format(prefill.skeletalMuscleKg))
            _bmi = State(initialValue: Self.format(prefill.bmi))
            _visceralFatLevel = State(initialValue: prefill.visceralFatLevel.map(String.init) ?? "")
            _bmr = State(initialValue: Self.format(prefill.bmr))
            _notes = State(initialValue: prefill.notes ?? "")
        }
    }

    /// Edit an existing record.
    init(client: Client, metric: BodyMetric) {
        self.client = client
        self.prefill = nil
        self.editing = metric
        self.diagnosticsAction = nil
        _date = State(initialValue: metric.date)
        _weightKg = State(initialValue: Self.format(metric.weightKg))
        _bodyFatPercent = State(initialValue: Self.format(metric.bodyFatPercent))
        _bodyFatMassKg = State(initialValue: Self.format(metric.bodyFatMassKg))
        _skeletalMuscleKg = State(initialValue: Self.format(metric.skeletalMuscleKg))
        _bmi = State(initialValue: Self.format(metric.bmi))
        _visceralFatLevel = State(initialValue: metric.visceralFatLevel.map(String.init) ?? "")
        _bmr = State(initialValue: Self.format(metric.bmr))
        _tdee = State(initialValue: Self.format(metric.tdee))
        _notes = State(initialValue: metric.notes ?? "")
    }

    private static func format(_ value: Double?) -> String {
        guard let value else { return "" }
        if value == value.rounded() { return String(format: "%.0f", value) }
        return String(format: "%g", value)
    }

    var body: some View {
        NavigationStack {
            Form {
                if prefill != nil {
                    Section {
                        Text(language.t(
                            "掃描結果僅供參考，請逐項核對後再保存。",
                            "Scan results are a starting point — check every value before saving."
                        ))
                        .font(DS.F.subtitle)
                        .foregroundStyle(DS.C.textLow)
                    }
                    .listRowBackground(DS.C.canvas)
                }

                if let diagnosticsAction {
                    Section {
                        Button {
                            diagnosticsAction()
                        } label: {
                            Label(
                                language.t("查看本機診斷", "View Local Diagnostics"),
                                systemImage: "info.circle"
                            )
                        }
                    }
                }

                DatePicker(language.t("日期", "Date"), selection: $date, displayedComponents: .date)
                    .listRowBackground(rowBackground(for: prefill?.dateConfidence))
                fieldRow(language.t("體重 (kg)", "Weight (kg)"), text: $weightKg, confidence: prefill?.weightConfidence, keyboard: .decimalPad)
                fieldRow(language.t("體脂率 (%)", "Body Fat (%)"), text: $bodyFatPercent, confidence: prefill?.bodyFatConfidence, keyboard: .decimalPad)
                fieldRow(language.t("體脂重 (kg)", "Fat Mass (kg)"), text: $bodyFatMassKg, confidence: prefill?.bodyFatMassConfidence, keyboard: .decimalPad)
                fieldRow(language.t("骨骼肌量 (kg)", "Muscle Mass (kg)"), text: $skeletalMuscleKg, confidence: prefill?.skeletalMuscleConfidence, keyboard: .decimalPad)
                fieldRow("BMI", text: $bmi, confidence: prefill?.bmiConfidence, keyboard: .decimalPad)
                fieldRow(language.t("內臟脂肪等級", "Visceral Fat Level"), text: $visceralFatLevel, confidence: prefill?.visceralFatConfidence, keyboard: .numberPad)
                fieldRow("BMR", text: $bmr, confidence: prefill?.bmrConfidence, keyboard: .decimalPad)
                LabeledContent("TDEE") { TextField("", text: $tdee).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                Section(language.t("備註", "Notes")) {
                    TextEditor(text: $notes).frame(minHeight: 60)
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.C.canvas)
            .font(DS.F.listRow)
            .foregroundStyle(DS.C.textHi)
            .navigationTitle(navigationTitleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.t("取消", "Cancel")) { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.C.textHi)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.t("保存", "Save")) { save() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.C.accent)
                }
            }
            .alert(language.t("保存失敗", "Save Failed"), isPresented: Binding(get: { saveErrorMessage != nil }, set: { if !$0 { saveErrorMessage = nil } })) {
                Button(language.t("好", "OK"), role: .cancel) {}
            } message: {
                Text(saveErrorMessage ?? "")
            }
        }
    }

    private var navigationTitleText: String {
        if prefill != nil { return language.t("核對 InBody 掃描結果", "Review Scanned InBody") }
        if editing != nil { return language.t("編輯 InBody 記錄", "Edit InBody Record") }
        return language.t("新增 InBody 記錄", "Add InBody Record")
    }

    @ViewBuilder
    private func fieldRow(_ label: String, text: Binding<String>, confidence: FieldConfidence?, keyboard: UIKeyboardType) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                if confidence == .uncertain {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.C.review)
                }
                TextField("", text: text)
                    .keyboardType(keyboard)
                    .multilineTextAlignment(.trailing)
            }
        }
        .listRowBackground(rowBackground(for: confidence))
    }

    private func rowBackground(for confidence: FieldConfidence?) -> Color {
        confidence == .uncertain ? DS.C.reviewBg : DS.C.surface
    }

    private func save() {
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editing {
            // Every field is overwritten, blanks included: clearing a value
            // in the form has to be able to clear it in the record, which
            // matters most for a field OCR filled in wrongly.
            editing.date = date
            editing.weightKg = Double(weightKg)
            editing.bodyFatPercent = Double(bodyFatPercent)
            editing.skeletalMuscleKg = Double(skeletalMuscleKg)
            editing.bmi = Double(bmi)
            editing.visceralFatLevel = Int(visceralFatLevel)
            editing.bmr = Double(bmr)
            editing.tdee = Double(tdee)
            editing.bodyFatMassKg = Double(bodyFatMassKg)
            editing.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        } else {
            let metric = BodyMetric(
                id: prefill != nil ? "bm-scan-\(UUID().uuidString)" : "bm-local-\(UUID().uuidString)",
                date: date,
                weightKg: Double(weightKg),
                bodyFatPercent: Double(bodyFatPercent),
                skeletalMuscleKg: Double(skeletalMuscleKg),
                bmi: Double(bmi),
                visceralFatLevel: Int(visceralFatLevel),
                bmr: Double(bmr),
                tdee: Double(tdee),
                bodyFatMassKg: Double(bodyFatMassKg),
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes
            )
            metric.client = client
            modelContext.insert(metric)
        }
        do {
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            saveErrorMessage = error.localizedDescription
        }
    }
}
