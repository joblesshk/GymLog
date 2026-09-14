import SwiftUI
import GymLogKit

/// CONTRACT-M5.md §3.3.2: the Round table's 次数 column needs a picker that
/// can only produce an exact integer -- no ranges, no time/distance/rounds/
/// perSide branches. Deliberately a NEW, separate component from
/// `RepTargetWheel` (which stays untouched for `TemplateEditorView`'s
/// `defaultRepTarget`, a full `RepTarget`) -- the contract is explicit that
/// new-entry reps and template-default reps are different concepts now and
/// must not share a picker.
struct RepsCountWheel: View {
    @Binding var reps: Int

    // 1...100 -- matches `RepTargetCustomSheet`'s `.fixed` Stepper range, so
    // a value that already exists in the client's real history (e.g. a
    // historical `.fixed` rep count above the 1-50 the contract's own
    // example suggested) is still representable, not silently clamped.
    private static let values = Array(1...100)

    var body: some View {
        Picker(L("次數", "Reps"), selection: $reps) {
            ForEach(Self.values, id: \.self) { n in
                Text(L("\(n) 次", "\(n)")).tag(n)
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
    }
}

#Preview {
    RepsCountWheel(reps: .constant(10))
        .frame(height: 120)
}
