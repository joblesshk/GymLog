import SwiftUI
import GymLogKit

/// CONTRACT-UI.md §3.1: 组数 wheel, single column, 1-6, default 3.
struct SetsCountWheel: View {
    @Binding var sets: Int

    var body: some View {
        Picker(L("組數", "Sets"), selection: $sets) {
            ForEach(1...6, id: \.self) { n in
                Text(L("\(n) 組", "\(n)")).tag(n)
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
    }
}

#Preview {
    SetsCountWheel(sets: .constant(3))
        .frame(height: 120)
}
