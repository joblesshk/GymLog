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

/// Shared implementation for the three kg-based wheel modes: 2.5kg steps,
/// 2.5-200kg range (CONTRACT-UI.md §3.1), differing only in which
/// `LoadValue` case gets written back.
private struct KgStepWheel: View {
    enum Mode { case absolute, perSide, assisted }

    @Binding var load: LoadValue
    let mode: Mode

    private static let steps: [Double] = stride(from: 2.5, through: 200, by: 2.5).map { $0 }

    private var currentKg: Double {
        let raw: Double
        switch load {
        case .absolute(let kg, _), .perSide(let kg, _), .assisted(let kg, _), .sled(let kg, _):
            raw = kg
        default:
            raw = 20 // CONTRACT-UI.md §3.2 default weight
        }
        return Self.nearestStep(raw)
    }

    private static func nearestStep(_ kg: Double) -> Double {
        let snapped = (kg / 2.5).rounded() * 2.5
        return min(max(snapped, 2.5), 200)
    }

    private static func formatKg(_ kg: Double) -> String {
        kg == kg.rounded() ? String(format: "%.0f", kg) : String(format: "%.1f", kg)
    }

    var body: some View {
        Picker(L("重量", "Load"), selection: Binding<Double>(
            get: { currentKg },
            set: { newKg in
                let raw = Self.formatKg(newKg)
                switch mode {
                case .absolute: load = .absolute(kg: newKg, raw: raw)
                case .perSide: load = .perSide(kg: newKg, raw: raw)
                case .assisted: load = .assisted(kg: newKg, raw: raw)
                }
            }
        )) {
            ForEach(Self.steps, id: \.self) { kg in
                // `.assisted` is stored as a positive kg (the assistance
                // amount) but shown with a leading "-" -- the coach's own
                // ask: assistance reads as negative load (e.g. "-10kg") so
                // it can't be mistaken for weight actually lifted, even
                // though `LoadValue.assisted`'s underlying number and its
                // "lower is stronger" PR/trend direction are unchanged.
                Text(mode == .assisted ? "-\(Self.formatKg(kg))kg" : "\(Self.formatKg(kg))kg").tag(kg)
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
    }
}

/// `.bodyweightPlus` wheel: step 0 is "自重" (writes back `LoadValue
/// .bodyweight`), the rest are 2.5kg-stepped added weight on top of
/// bodyweight (writes back `.absolute`, same encoding an actual loaded plate
/// would use elsewhere in the app -- there's no separate "added weight"
/// `LoadValue` case, nor does one need to exist).
private struct BodyweightPlusWheel: View {
    @Binding var load: LoadValue

    private static let addedSteps: [Double] = stride(from: 2.5, through: 200, by: 2.5).map { $0 }

    private static func nearestStep(_ kg: Double) -> Double {
        let snapped = (kg / 2.5).rounded() * 2.5
        return min(max(snapped, 0), 200)
    }

    private static func formatKg(_ kg: Double) -> String {
        kg == kg.rounded() ? String(format: "%.0f", kg) : String(format: "%.1f", kg)
    }

    private var currentValue: Double {
        switch load {
        case .absolute(let kg, _), .sled(let kg, _):
            return Self.nearestStep(kg)
        default:
            return 0
        }
    }

    var body: some View {
        Picker(L("重量", "Load"), selection: Binding<Double>(
            get: { currentValue },
            set: { newValue in
                load = newValue == 0
                    ? .bodyweight(raw: "BW")
                    : .absolute(kg: newValue, raw: Self.formatKg(newValue))
            }
        )) {
            Text(L("自重", "Bodyweight")).tag(0.0)
            ForEach(Self.addedSteps, id: \.self) { kg in
                Text("+\(Self.formatKg(kg))kg").tag(kg)
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
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
