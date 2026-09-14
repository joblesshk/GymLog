import SwiftUI
import GymLogKit

/// CONTRACT-UI.md §3.1: 次数目标 wheel. 14 client-frequency-ordered presets +
/// 「自定义…」. If the bound value doesn't match any preset (e.g. prefilled
/// from a historical `.time`/`.distance`/`.rounds`/`.perSide` record, or an
/// out-of-preset range), a synthetic row showing that exact value is
/// inserted just before 自定义… so the wheel always visibly reflects the
/// real bound value instead of silently snapping to something else.
struct RepTargetWheel: View {
    @Binding var target: RepTarget
    /// Client-frequency-ordered presets from `FrequencyAnalyzer.repTargetPresetOrder`.
    let presets: [RepTargetPreset]
    @State private var showCustomSheet = false

    private var rows: [RepTargetPreset] {
        if presets.contains(where: { $0.matches(target) }) {
            return presets
        }
        // Insert the current (non-preset) value right before 自定义…, which
        // is always last.
        var arr = presets
        let currentRow = RepTargetPreset(label: L("當前：\(target.displayText)", "Current: \(target.displayText)"), target: target)
        let insertIndex = max(0, arr.count - 1)
        arr.insert(currentRow, at: insertIndex)
        return arr
    }

    private var selection: Binding<String> {
        Binding(
            get: {
                rows.first(where: { $0.matches(target) })?.id ?? FrequencyAnalyzer.customPreset.id
            },
            set: { newID in
                if newID == FrequencyAnalyzer.customPreset.id {
                    showCustomSheet = true
                } else if let row = rows.first(where: { $0.id == newID }), let value = row.target {
                    target = value
                }
            }
        )
    }

    var body: some View {
        Picker(L("次數目標", "Reps Target"), selection: selection) {
            ForEach(rows) { row in
                Text(row.target?.displayText ?? row.label).tag(row.id)
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
        .sheet(isPresented: $showCustomSheet) {
            RepTargetCustomSheet(target: $target)
        }
    }
}

#Preview {
    RepTargetWheel(target: .constant(.fixed(value: 10, raw: "10")), presets: FrequencyAnalyzer.baseRepTargetPresets + [FrequencyAnalyzer.customPreset])
        .frame(height: 120)
}
