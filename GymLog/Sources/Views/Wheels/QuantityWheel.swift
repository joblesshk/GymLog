import SwiftUI
import GymLogKit

/// CONTRACT-M8.md: a generic single-column stepped-value wheel for the Round
/// table's 距離/輪次 columns (distance-based exercises like rowing/ski, and
/// rounds-based ones like farmer walk/sled push). Parametrized rather than
/// duplicated per metric since both are "pick a number from a stepped range,
/// with a unit label" -- the same shape as `SetsCountWheel`/`RepsCountWheel`,
/// just with a configurable range/step/unit instead of each hardcoding one.
struct QuantityWheel: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unitLabel: (Int) -> String

    private var values: [Int] {
        Array(stride(from: range.lowerBound, through: range.upperBound, by: step))
    }

    /// Snaps `value` onto the nearest representable step so a historical
    /// value that predates this picker's range/step (or was recorded with a
    /// different metric before an exercise got reclassified) still shows
    /// *something* selected instead of an empty wheel.
    private var selection: Binding<Int> {
        Binding(
            get: { values.min(by: { abs($0 - value) < abs($1 - value) }) ?? range.lowerBound },
            set: { value = $0 }
        )
    }

    var body: some View {
        Picker("", selection: selection) {
            ForEach(values, id: \.self) { n in
                Text(unitLabel(n)).tag(n)
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
    }
}

#Preview {
    QuantityWheel(value: .constant(200), range: 50...10000, step: 50) { L("\($0) 米", "\($0) m") }
        .frame(height: 120)
}
