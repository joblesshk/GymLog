import SwiftUI
import GymLogKit

/// CONTRACT-UI.md §3.1 / §3.3: 重量 wheel. Content switches by
/// `LoadWheelResolver.kind(for:historicalBandColors:)` -- absolute kg,
/// per-side kg, assisted kg (with the "数值越小越强" hint), band color, or
/// hidden entirely for bodyweight exercises.
struct LoadWheel: View {
    @Binding var load: LoadValue
    let kind: LoadWheelKind

    var body: some View {
        switch kind {
        case .bodyweightPlus:
            VStack(spacing: 2) {
                Text(L("自重，可加配重", "Bodyweight, can add weight")).font(.caption2).foregroundStyle(DS.C.textMid)
                BodyweightPlusWheel(load: $load)
            }
        case .absolute:
            KgStepWheel(load: $load, mode: .absolute)
        case .perSide:
            VStack(spacing: 2) {
                Text(L("單側", "Per Side")).font(.caption2).foregroundStyle(DS.C.textMid)
                KgStepWheel(load: $load, mode: .perSide)
            }
        case .assisted:
            VStack(spacing: 2) {
                Text(L("數值越小越強", "Lower Is Stronger")).font(.caption2).foregroundStyle(DS.C.textMid)
                KgStepWheel(load: $load, mode: .assisted)
            }
        case .band(let colors):
            BandColorWheel(load: $load, colors: colors)
        }
    }
}

/// Shared kg-step list and formatting for the two weight wheels below, so
/// the wheel and its "自定義…" keypad sheet always agree on how a value is
/// rounded and displayed.
private enum KgFormat {
    /// Widened from the original 2.5-200kg range (CONTRACT-UI.md §3.1) to
    /// 2.5-300kg: strength-standard data (strengthlevel.com) puts an
    /// "elite" raw deadlift at roughly 2x bodyweight, i.e. ~200kg for a
    /// ~100kg lifter -- the old ceiling was already there. As the app
    /// reaches lifters beyond the single original user, the wheel itself
    /// needs headroom, not just an escape hatch. Genuine outliers past
    /// 300kg still go through "自定義…" below rather than bloating the
    /// wheel further.
    static let maxKg: Double = 300
    static let steps: [Double] = stride(from: 2.5, through: maxKg, by: 2.5).map { $0 }

    /// Whole numbers show with no decimal; anything else shows the fewest
    /// decimal digits that round-trip (so a 2.5-stepped value reads "22.5"
    /// but a manually typed "21.25" isn't truncated to "21.3").
    static func format(_ kg: Double) -> String {
        if kg == kg.rounded() { return String(format: "%.0f", kg) }
        let rounded2 = (kg * 100).rounded() / 100
        if (rounded2 * 10).truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.1f", rounded2)
        }
        return String(format: "%.2f", rounded2)
    }
}

/// Shared implementation for the three kg-based wheel modes: 2.5kg steps,
/// 2.5-300kg range (CONTRACT-UI.md §3.1, widened -- see `KgFormat.maxKg`),
/// differing only in which `LoadValue` case gets written back. A trailing
/// "自定義…" row opens `LoadCustomWeightSheet` for values that fall between
/// (or beyond) the 2.5kg steps -- e.g. 22kg between the 20/22.5 rows -- so
/// exact manual entry doesn't require widening the step size for everyone
/// else. Same wheel-plus-sheet split as `RepTargetWheel`/`RepTargetCustomSheet`.
private struct KgStepWheel: View {
    enum Mode { case absolute, perSide, assisted }

    @Binding var load: LoadValue
    let mode: Mode
    @State private var showCustomSheet = false

    private static let customTag = "custom"

    private var rawKg: Double {
        switch load {
        case .absolute(let kg, _), .perSide(let kg, _), .assisted(let kg, _), .sled(let kg, _):
            return kg
        default:
            return 20 // CONTRACT-UI.md §3.2 default weight
        }
    }

    private var isOnStep: Bool {
        KgFormat.steps.contains { abs($0 - rawKg) < 0.001 }
    }

    /// The fixed steps, plus -- only when `rawKg` doesn't land exactly on
    /// one -- a synthetic row for that exact value, inserted in sorted
    /// numeric position (unlike `RepTargetWheel`'s frequency-ordered
    /// presets, these rows are already numerically sorted, so the natural
    /// place for "22" is between "20" and "22.5", not off at the end).
    private var kgRows: [Double] {
        guard !isOnStep, rawKg > 0, rawKg.isFinite, rawKg <= 999 else { return KgFormat.steps }
        var rows = KgFormat.steps
        let insertAt = rows.firstIndex { $0 > rawKg } ?? rows.count
        rows.insert(rawKg, at: insertAt)
        return rows
    }

    private func label(for kg: Double) -> String {
        // `.assisted` is stored as a positive kg (the assistance amount) but
        // shown with a leading "-" -- the coach's own ask: assistance reads
        // as negative load (e.g. "-10kg") so it can't be mistaken for weight
        // actually lifted, even though `LoadValue.assisted`'s underlying
        // number and its "lower is stronger" PR/trend direction are unchanged.
        mode == .assisted ? "-\(KgFormat.format(kg))kg" : "\(KgFormat.format(kg))kg"
    }

    private func apply(kg: Double) {
        let raw = KgFormat.format(kg)
        switch mode {
        case .absolute: load = .absolute(kg: kg, raw: raw)
        case .perSide: load = .perSide(kg: kg, raw: raw)
        case .assisted: load = .assisted(kg: kg, raw: raw)
        }
    }

    private var selection: Binding<String> {
        Binding(
            get: {
                if let match = kgRows.first(where: { abs($0 - rawKg) < 0.001 }) {
                    return KgFormat.format(match)
                }
                return Self.customTag
            },
            set: { newID in
                if newID == Self.customTag {
                    showCustomSheet = true
                } else if let kg = kgRows.first(where: { KgFormat.format($0) == newID }) {
                    apply(kg: kg)
                }
            }
        )
    }

    var body: some View {
        Picker(L("重量", "Load"), selection: selection) {
            ForEach(kgRows, id: \.self) { kg in
                Text(label(for: kg)).tag(KgFormat.format(kg))
            }
            Text(L("自定義…", "Custom…")).tag(Self.customTag)
        }
        .pickerStyle(.wheel)
        .labelsHidden()
        .sheet(isPresented: $showCustomSheet) {
            LoadCustomWeightSheet(
                title: L("自定義重量", "Custom Weight"),
                initialKg: rawKg,
                allowsZero: false,
                onApply: { apply(kg: $0) }
            )
        }
    }
}

/// `.bodyweightPlus` wheel: step 0 is "自重" (writes back `LoadValue
/// .bodyweight`), the rest are 2.5kg-stepped added weight on top of
/// bodyweight (writes back `.absolute`, same encoding an actual loaded plate
/// would use elsewhere in the app -- there's no separate "added weight"
/// `LoadValue` case, nor does one need to exist). Also gets a "自定義…" row,
/// same rationale as `KgStepWheel` above.
private struct BodyweightPlusWheel: View {
    @Binding var load: LoadValue
    @State private var showCustomSheet = false

    private static let customTag = "custom"
    private static let bodyweightTag = "bw"

    private var currentAdded: Double {
        switch load {
        case .absolute(let kg, _), .sled(let kg, _):
            return kg
        default:
            return 0
        }
    }

    private var isOnStep: Bool {
        KgFormat.steps.contains { abs($0 - currentAdded) < 0.001 }
    }

    private var addedRows: [Double] {
        guard !isOnStep, currentAdded > 0, currentAdded.isFinite, currentAdded <= 999 else { return KgFormat.steps }
        var rows = KgFormat.steps
        let insertAt = rows.firstIndex { $0 > currentAdded } ?? rows.count
        rows.insert(currentAdded, at: insertAt)
        return rows
    }

    private func apply(added: Double) {
        load = added == 0
            ? .bodyweight(raw: "BW")
            : .absolute(kg: added, raw: KgFormat.format(added))
    }

    private var selection: Binding<String> {
        Binding(
            get: {
                if currentAdded == 0 { return Self.bodyweightTag }
                if let match = addedRows.first(where: { abs($0 - currentAdded) < 0.001 }) {
                    return KgFormat.format(match)
                }
                return Self.customTag
            },
            set: { newID in
                if newID == Self.customTag {
                    showCustomSheet = true
                } else if newID == Self.bodyweightTag {
                    apply(added: 0)
                } else if let kg = addedRows.first(where: { KgFormat.format($0) == newID }) {
                    apply(added: kg)
                }
            }
        )
    }

    var body: some View {
        Picker(L("重量", "Load"), selection: selection) {
            Text(L("自重", "Bodyweight")).tag(Self.bodyweightTag)
            ForEach(addedRows, id: \.self) { kg in
                Text("+\(KgFormat.format(kg))kg").tag(KgFormat.format(kg))
            }
            Text(L("自定義…", "Custom…")).tag(Self.customTag)
        }
        .pickerStyle(.wheel)
        .labelsHidden()
        .sheet(isPresented: $showCustomSheet) {
            LoadCustomWeightSheet(
                title: L("自定義加重", "Custom Added Weight"),
                initialKg: currentAdded,
                allowsZero: true,
                onApply: { apply(added: $0) }
            )
        }
    }
}

/// "自定義…" 二級輸入 for 重量: a plain decimal keypad so any exact value --
/// between the wheel's 2.5kg steps, or beyond its range entirely -- can be
/// recorded without needing to widen the step size (which would make the
/// wheel unwieldy) or the range (which can't cover every possible outlier)
/// for everyone else. Mirrors `RepTargetCustomSheet`'s wheel-plus-sheet split.
private struct LoadCustomWeightSheet: View {
    let title: String
    let initialKg: Double
    /// `BodyweightPlusWheel`'s custom entry allows 0 (= "自重", no added
    /// weight); the three `KgStepWheel` modes never should -- 0kg isn't a
    /// representable absolute/per-side/assisted load.
    let allowsZero: Bool
    let onApply: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var parsedKg: Double? {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite, value <= 999 else { return nil }
        return (allowsZero ? value >= 0 : value > 0) ? value : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                HStack {
                    TextField(L("重量", "Weight"), text: $text)
                        .keyboardType(.decimalPad)
                    Text("kg").foregroundStyle(DS.C.textMid)
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.C.canvas)
            .font(DS.F.listRow)
            .foregroundStyle(DS.C.textHi)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消", "Cancel")) { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.C.textHi)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("確定", "OK")) {
                        if let kg = parsedKg { onApply(kg) }
                        dismiss()
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.C.accent)
                    .disabled(parsedKg == nil)
                }
            }
        }
        .onAppear { text = initialKg > 0 ? KgFormat.format(initialKg) : "" }
    }
}

private struct BandColorWheel: View {
    @Binding var load: LoadValue
    let colors: [String]

    private static let colorNames: [String: (zh: String, en: String)] = [
        "purple": ("紫", "Purple"), "blue": ("藍", "Blue"), "green": ("綠", "Green"), "red": ("紅", "Red"),
        "black": ("黑", "Black"), "yellow": ("黃", "Yellow"), "orange": ("橙", "Orange"), "grey": ("灰", "Grey"), "gray": ("灰", "Grey"),
        "white": ("白", "White"), "pink": ("粉", "Pink"),
    ]

    private static func colorLabel(_ color: String) -> String {
        guard let names = colorNames[color] else { return color }
        return L(names.zh, names.en)
    }

    private var currentColor: String {
        if case .band(let color, _, _) = load, colors.contains(color.lowercased()) {
            return color.lowercased()
        }
        return colors.first ?? "black"
    }

    var body: some View {
        Picker(L("彈力帶", "Band"), selection: Binding<String>(
            get: { currentColor },
            set: { newColor in
                let count: Int
                if case .band(_, let existingCount, _) = load { count = max(existingCount, 1) } else { count = 1 }
                load = .band(color: newColor, count: count, raw: Self.colorLabel(newColor))
            }
        )) {
            ForEach(colors, id: \.self) { color in
                Text(Self.colorLabel(color)).tag(color)
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
    }
}

#Preview {
    LoadWheel(load: .constant(.absolute(kg: 35, raw: "35")), kind: .absolute)
        .frame(height: 120)
}
