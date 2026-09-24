import SwiftUI
import GymLogKit

/// Compact, contextual load selection with numeric overrides and preservation
/// of existing load semantics. Custom band details stay collapsed by default.
struct LoadPickerSheet: View {
    @Binding private var load: LoadValue
    @State private var draft: LoadSelectionDraft
    private let colors: [String]
    private let supportsBand: Bool
    private let kind: LoadWheelKind
    private let originalMode: LoadSelectionDraft.Mode
    @State private var editingBand = false
    @State private var pendingOutlierConfirmation: String?
    @Environment(\.dismiss) private var dismiss
    @AppStorage("customLoadWeights.v1") private var savedKg = "[]"
    @AppStorage("customLoadWeights.lb.v1") private var savedLb = "[]"

    init(load: Binding<LoadValue>, kind: LoadWheelKind, historicalBandColors: [String] = []) {
        self.kind = kind
        supportsBand = LoadWheelResolver.supportsBand(kind: kind, load: load.wrappedValue, historicalBandColors: historicalBandColors)
        originalMode = LoadSelectionDraft(load: load.wrappedValue, suggested: kind).mode
        _load = load
        _draft = State(initialValue: LoadSelectionDraft(load: load.wrappedValue, suggested: kind))
        if case .band(let values) = kind { colors = values + historicalBandColors }
        else { colors = historicalBandColors + LoadWheelResolver.fallbackBandColors }
    }

    private var rows: [Double] {
        let presets = stride(from: 2.5, through: 300.0, by: 2.5).map { $0 }
        return [0] + CustomLoadWeights.rows(presets: presets,
            saved: draft.unit == .kg ? savedKg : savedLb,
            current: LoadSelectionDraft.parseNumber(draft.number) ?? 20)
    }

    private var bandColors: [String] {
        var result = [String]()
        for color in [draft.bandColor] + colors + LoadWheelResolver.fallbackBandColors {
            let key = BandColorName.canonical(color) ?? color
            if !key.isEmpty && !result.contains(key) { result.append(key) }
        }
        return result
    }

    private var specialMode: LoadSelectionDraft.Mode? {
        if supportsBand { return .band }
        return [.custom, .machineStack].contains(originalMode) ? originalMode : nil
    }

    private var numericMode: LoadSelectionDraft.Mode {
        originalMode.isNumeric ? originalMode : .absolute
    }

    private var showsNumber: Bool { draft.mode.isNumeric || draft.mode == .bodyweight }

    private func selectNumber(_ text: String) {
        draft.number = text
        if kind == .bodyweightPlus && [.absolute, .bodyweight].contains(draft.mode) {
            draft.mode = LoadSelectionDraft.parseNumber(text) == 0 ? .bodyweight : .absolute
        } else if draft.mode == .bodyweight {
            draft.mode = .absolute
        }
    }

    private func commit(confirmed: Bool = false) {
        guard let value = draft.resolved() else { return }
        if !confirmed, let warning = draft.outlierConfirmation {
            pendingOutlierConfirmation = warning
            return
        }
        // Re-assigning an equal value still fires the round's didSet, which
        // would clear its inferred/unrecorded provenance without any edit.
        if value != load { load = value }
        if draft.mode.isNumeric, let number = LoadSelectionDraft.parseNumber(draft.number) {
            if draft.unit == .kg { savedKg = CustomLoadWeights.adding(number, to: savedKg) }
            else { savedLb = CustomLoadWeights.adding(number, to: savedLb) }
        }
        dismiss()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 4) {
                    if let special = specialMode {
                        Picker(L("負重", "Load"), selection: Binding(
                            get: { draft.mode == special },
                            set: { draft.mode = $0 ? special : numericMode; editingBand = false }
                        )) {
                            Text(special == .band ? L("彈力帶", "Band") : L("原有設定", "Original")).tag(true)
                            Text(L("重量", "Weight")).tag(false)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 230)
                        .accessibilityIdentifier("load-kind-switch")
                    }
                    if showsNumber {
                        HStack(spacing: 0) {
                            Picker(L("重量數字", "Weight value"), selection: Binding(
                                get: { draft.mode == .bodyweight ? "0" : SetEditDraft.formatNumber(LoadSelectionDraft.parseNumber(draft.number) ?? 20) },
                                set: selectNumber
                            )) {
                                ForEach(rows, id: \.self) { value in
                                    Text(value == 0 && kind == .bodyweightPlus ? L("自重", "Bodyweight") : SetEditDraft.formatNumber(value)).tag(SetEditDraft.formatNumber(value))
                                }
                            }
                            .accessibilityIdentifier("load-number-wheel")
                            Picker(L("重量單位", "Weight unit"), selection: $draft.unit) {
                                ForEach(LoadWeightUnit.allCases, id: \.self) { unit in
                                    Text(unit.rawValue).tag(unit)
                                }
                            }
                            .frame(width: 80)
                            .accessibilityIdentifier("load-unit-wheel")
                        }
                        .pickerStyle(.wheel)
                        .labelsHidden()
                        .frame(width: 260, height: 140)
                        .modifier(PrecisionLoadWheelStyle())
                        HStack {
                            TextField(L("手動輸入重量", "Enter a custom weight"), text: Binding(
                                get: { draft.mode == .bodyweight ? "0" : draft.number },
                                set: selectNumber
                            ))
                                .keyboardType(.decimalPad)
                                .accessibilityIdentifier("custom-load-input")
                            Text(draft.unit.rawValue)
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 10)
                        .frame(width: 230, height: 34)
                        .background(DS.C.inset, in: RoundedRectangle(cornerRadius: 9))
                        if draft.mode == .assisted || draft.mode == .perSide {
                            Text(draft.mode == .assisted ? L("輔助重量", "Assistance") : L("單側重量", "Per side"))
                                .font(.caption2).foregroundStyle(DS.C.textLow)
                        }
                    } else if draft.mode == .band {
                        Picker(L("彈力帶", "Band"), selection: Binding(
                            get: { BandColorName.canonical(draft.bandColor) ?? draft.bandColor },
                            set: { draft.bandColor = $0 }
                        )) {
                            ForEach(bandColors, id: \.self) { color in
                                Text(LoadValue.band(color: color, count: 1, raw: color).displayText).tag(color)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(width: 260, height: 130)
                        .modifier(PrecisionLoadWheelStyle())
                        if editingBand {
                            HStack(spacing: 6) {
                                TextField(L("顏色／型號", "Color / model"), text: Binding(
                                    get: { BandColorName.display(draft.bandColor, language: LanguageContext.current) },
                                    set: { draft.bandColor = BandColorName.canonical($0) ?? $0 }
                                ))
                                .accessibilityIdentifier("custom-band-color")
                                Text("×")
                                TextField("1", text: $draft.bandCount).keyboardType(.numberPad)
                                    .frame(width: 35)
                                    .accessibilityIdentifier("custom-band-count")
                            }
                            .font(.system(size: 13))
                            .frame(width: 230, height: 34)
                        } else {
                            Button(L("自訂", "Custom")) { editingBand = true }
                                .font(.system(size: 13))
                                .accessibilityIdentifier("custom-band-button")
                                .frame(height: 34)
                        }
                    } else {
                        TextField(L("負重描述", "Load description"), text: $draft.detail)
                            .accessibilityIdentifier("custom-load-description")
                            .frame(width: 260, height: 140)
                    }
                    if let error = draft.validationError {
                        Text(error).font(.caption).foregroundStyle(DS.C.danger)
                            .accessibilityIdentifier("load-validation-error")
                    }
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.C.canvas)
            .navigationTitle(L("重量", "Load"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消", "Cancel")) { dismiss() }
                        .accessibilityIdentifier("load-picker-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("完成", "Done")) { commit() }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(DS.C.accent)
                    .disabled(draft.validationError != nil)
                    .accessibilityIdentifier("picker-sheet-done-button")
                }
            }
        }
        .presentationDetents([.height(specialMode == nil ? 310 : 350)])
        .alert(L("確認重量", "Confirm Load"), isPresented: Binding(
            get: { pendingOutlierConfirmation != nil },
            set: { if !$0 { pendingOutlierConfirmation = nil } }
        )) {
            Button(L("返回修改", "Edit"), role: .cancel) {}
            Button(L("確定", "Confirm")) { commit(confirmed: true) }
                .accessibilityIdentifier("load-outlier-confirm")
        } message: {
            Text(pendingOutlierConfirmation ?? "")
        }
    }
}

/// Decorative layers never intercept the native wheel's gestures or accessibility.
/// Uses the sheet palette, without a separate colored panel or rim.
private struct PrecisionLoadWheelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(DS.C.canvas)
            .overlay {
                Canvas { context, size in
                    let middle = size.height / 2
                    // Major/minor ticks remain legible without a separate background panel.
                    for step in -6...6 where step != 0 {
                        let y = middle + CGFloat(step) * 9
                        var tick = Path()
                        tick.move(to: CGPoint(x: 8, y: y))
                        tick.addLine(to: CGPoint(x: step.isMultiple(of: 3) ? 19 : 14, y: y))
                        context.stroke(tick, with: .color(DS.C.textMid.opacity(step.isMultiple(of: 3) ? 0.85 : 0.65)), lineWidth: step.isMultiple(of: 3) ? 1.5 : 1)
                    }
                    for y in [middle - 17, middle + 17] {
                        var rule = Path()
                        rule.move(to: CGPoint(x: 21, y: y))
                        rule.addLine(to: CGPoint(x: size.width - 14, y: y))
                        context.stroke(rule, with: .color(DS.C.textMid.opacity(0.45)), lineWidth: 1)
                    }
                    let marker = Path(roundedRect: CGRect(x: 6, y: middle - 3, width: 12, height: 6), cornerRadius: 1)
                    context.fill(marker, with: .color(DS.C.accent))
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .padding(.vertical, 6)
    }
}
