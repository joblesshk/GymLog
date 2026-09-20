import SwiftUI
import GymLogKit

/// CONTRACT-M8.md: the Round table's 時間 column (time-held exercises like
/// plank/wall sit/hollow hold) needs a picker producing an exact seconds
/// count. A flat 5s-stepped list from 5 to 1800 (`RepTargetCustomSheet`'s
/// Stepper range) would be 360 rows in a single wheel -- unwieldy -- so this
/// is a two-column 分:秒 picker instead, the standard iOS timer-picker shape.
/// Binds directly to total seconds so callers (`RoundRow`) don't need to know
/// about the two-column split.
struct TimeQuantityWheel: View {
    @Binding var seconds: Int

    // Widened from 0-30 to 0-60 to cover longer timed holds/conditioning sets.
    private static let minutes = Array(0...60)
    private static let secondSteps = Array(stride(from: 0, to: 60, by: 5))

    private var minutesBinding: Binding<Int> {
        Binding(
            get: { seconds / 60 },
            set: { seconds = $0 * 60 + (seconds % 60) }
        )
    }

    private var secondsBinding: Binding<Int> {
        Binding(
            get: {
                let s = seconds % 60
                return Self.secondSteps.min(by: { abs($0 - s) < abs($1 - s) }) ?? 0
            },
            set: { seconds = (seconds / 60) * 60 + $0 }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            Picker(L("分", "min"), selection: minutesBinding) {
                ForEach(Self.minutes, id: \.self) { m in
                    Text(L("\(m) 分", "\(m) min")).tag(m)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()

            Picker(L("秒", "sec"), selection: secondsBinding) {
                ForEach(Self.secondSteps, id: \.self) { s in
                    Text(L("\(s) 秒", "\(s) sec")).tag(s)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
        }
    }
}

#Preview {
    TimeQuantityWheel(seconds: .constant(45))
        .frame(height: 120)
}
