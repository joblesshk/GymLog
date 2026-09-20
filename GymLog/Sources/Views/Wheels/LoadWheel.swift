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
/// the wheel and inline input always agree on how a value is
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

/// Numeric wheels retain custom options and provide a compact inline input.
private struct KgStepWheel: View {
    enum Mode { case absolute, perSide, assisted }

    @Binding var load: LoadValue
    let mode: Mode
    @AppStorage("customLoadWeights.v1") private var savedWeights = "[]"


    private var rawKg: Double {
        switch load {
        case .absolute(let kg, _), .perSide(let kg, _), .assisted(let kg, _), .sled(let kg, _):
            return kg
        default:
            return 20 // CONTRACT-UI.md §3.2 default weight
        }
    }

    private var kgRows: [Double] {
        CustomLoadWeights.rows(presets: KgFormat.steps, saved: savedWeights, current: rawKg)
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
                return KgFormat.format(rawKg)
            },
            set: { newID in
                if let kg = kgRows.first(where: { KgFormat.format($0) == newID }) {
                    apply(kg: kg)
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(L("重量", "Load"), selection: selection) {
                ForEach(kgRows, id: \.self) { kg in
                    Text(label(for: kg)).tag(KgFormat.format(kg))
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .frame(maxHeight: .infinity)
            .clipped()
            InlineLoadInput(currentKg: rawKg, allowsZero: false) {
                apply(kg: $0)
            }
        }
    }
}

/// `.bodyweightPlus` wheel: step 0 is "自重" (writes back `LoadValue
/// .bodyweight`), the rest are 2.5kg-stepped added weight on top of
/// bodyweight (writes back `.absolute`, same encoding an actual loaded plate
/// would use elsewhere in the app -- there's no separate "added weight"
/// `LoadValue` case, nor does one need to exist). Also offers manual entry,
/// same rationale as `KgStepWheel` above.
private struct BodyweightPlusWheel: View {
    @Binding var load: LoadValue
    @AppStorage("customLoadWeights.v1") private var savedWeights = "[]"

    private static let bodyweightTag = "bw"

    private var currentAdded: Double {
        switch load {
        case .absolute(let kg, _), .sled(let kg, _):
            return kg
        default:
            return 0
        }
    }

    private var addedRows: [Double] {
        CustomLoadWeights.rows(presets: KgFormat.steps, saved: savedWeights, current: currentAdded)
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
                return KgFormat.format(currentAdded)
            },
            set: { newID in
                if newID == Self.bodyweightTag {
                    apply(added: 0)
                } else if let kg = addedRows.first(where: { KgFormat.format($0) == newID }) {
                    apply(added: kg)
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(L("重量", "Load"), selection: selection) {
                Text(L("自重", "Bodyweight")).tag(Self.bodyweightTag)
                ForEach(addedRows, id: \.self) { kg in
                    Text("+\(KgFormat.format(kg))kg").tag(KgFormat.format(kg))
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .frame(maxHeight: .infinity)
            .clipped()
            InlineLoadInput(currentKg: currentAdded, allowsZero: true) {
                apply(added: $0)
            }
        }
    }
}

/// Commit a valid entry on keyboard submission, focus loss, or closing the picker.
/// Persist only the completed value, never intermediate keystrokes such as "2" in "21".
private struct InlineLoadInput: View {
    let currentKg: Double
    let allowsZero: Bool
    let onApply: (Double) -> Void

    @AppStorage("customLoadWeights.v1") private var savedWeights = "[]"
    @State private var text = ""
    @FocusState private var inputFocused: Bool

    private func commit() {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite, value <= 999,
              allowsZero ? value >= 0 : value > 0 else { return }
        savedWeights = CustomLoadWeights.adding(value, to: savedWeights)
        text = ""
        onApply(value)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $text,
                      prompt: Text(L("可以手動輸入重量", "Enter a custom weight"))
                        .foregroundStyle(DS.C.textLow))
                .keyboardType(.decimalPad)
                .focused($inputFocused)
                .accessibilityLabel(L("可以手動輸入重量", "Enter a custom weight"))
                .accessibilityIdentifier("custom-load-input")
                .onSubmit { commit(); inputFocused = false }
            Text("kg").foregroundStyle(DS.C.textLow)
        }
        .font(.system(size: 13))
        .foregroundStyle(DS.C.textHi)
        .padding(.horizontal, 12)
        .frame(width: 230, height: 34)
        .background(DS.C.inset, in: RoundedRectangle(cornerRadius: 9))
        .padding(.vertical, 5)
        .onChange(of: inputFocused) { _, focused in
            if !focused { commit() }
        }
        .onChange(of: currentKg) { _, _ in
            // A wheel selection supersedes any unfinished manual entry.
            text = ""
            inputFocused = false
        }
        .onDisappear { commit() }
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
