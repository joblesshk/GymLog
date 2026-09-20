import SwiftUI
import GymLogKit

/// CONTRACT-UI.md §3.1: 「自定义…」二级选择, covering `.time` / `.distance` /
/// `.rounds` / `.perSide` / any `.range` / any `.fixed` -- the branches not
/// covered by the 14 fixed presets.
struct RepTargetCustomSheet: View {
    @Binding var target: RepTarget
    @Environment(\.dismiss) private var dismiss

    private enum Kind: CaseIterable, Identifiable {
        case fixed, range, time, distance, rounds, perSide
        var id: Self { self }
        var label: String {
            switch self {
            case .fixed: return L("次數", "Fixed")
            case .range: return L("區間", "Range")
            case .time: return L("時間", "Time")
            case .distance: return L("距離", "Distance")
            case .rounds: return L("輪次", "Rounds")
            case .perSide: return L("左右分側", "Per Side")
            }
        }
    }

    @State private var kind: Kind = .fixed
    @State private var fixedValue = 10
    @State private var rangeLow = 8
    @State private var rangeHigh = 12
    @State private var timeSeconds = 30
    @State private var distanceMeters = 200
    @State private var roundsCount = 3
    @State private var perSideLeft = 10
    @State private var perSideRight = 10

    var body: some View {
        NavigationStack {
            Form {
                Picker(L("類型", "Type"), selection: $kind) {
                    ForEach(Kind.allCases) { k in Text(k.label).tag(k) }
                }
                .pickerStyle(.segmented)

                // Ranges widened a bit beyond the contract's original figures
                // (100 reps / 30min / 10km / 20 rounds) to leave headroom for
                // real outliers before falling back to raw text elsewhere.
                switch kind {
                case .fixed:
                    Stepper(L("固定 \(fixedValue) 次", "Fixed \(fixedValue) reps"), value: $fixedValue, in: 1...150)
                case .range:
                    Stepper(L("下限 \(rangeLow) 次", "Min \(rangeLow) reps"), value: $rangeLow, in: 1...150)
                    Stepper(L("上限 \(rangeHigh) 次", "Max \(rangeHigh) reps"), value: $rangeHigh, in: rangeLow...150)
                case .time:
                    Stepper(timeLabel, value: $timeSeconds, in: 5...3600, step: 5)
                case .distance:
                    Stepper(L("\(distanceMeters) 米", "\(distanceMeters) m"), value: $distanceMeters, in: 50...50000, step: 50)
                case .rounds:
                    Stepper(L("\(roundsCount) 輪", "\(roundsCount) rounds"), value: $roundsCount, in: 1...30)
                case .perSide:
                    Stepper(L("左 \(perSideLeft) 次", "Left \(perSideLeft) reps"), value: $perSideLeft, in: 1...150)
                    Stepper(L("右 \(perSideRight) 次", "Right \(perSideRight) reps"), value: $perSideRight, in: 1...150)
                }
            }
            .scrollContentBackground(.hidden)
            .background(DS.C.canvas)
            .font(DS.F.listRow)
            .foregroundStyle(DS.C.textHi)
            .navigationTitle(L("自定義次數目標", "Custom Reps Target"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消", "Cancel")) { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.C.textHi)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("確定", "OK")) { apply(); dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.C.accent)
                }
            }
        }
        .onAppear { seedFromCurrentTarget() }
    }

    private var timeLabel: String {
        let m = timeSeconds / 60
        let s = timeSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    private func seedFromCurrentTarget() {
        switch target {
        case .fixed(let value, _): kind = .fixed; fixedValue = value
        case .range(let low, let high, _): kind = .range; rangeLow = low; rangeHigh = high
        case .time(let seconds, _): kind = .time; timeSeconds = seconds
        case .distance(let meters, _): kind = .distance; distanceMeters = meters
        case .rounds(let count, _): kind = .rounds; roundsCount = count
        case .perSide(let left, let right, _): kind = .perSide; perSideLeft = left; perSideRight = right
        case .unknown: break
        }
    }

    private func apply() {
        switch kind {
        case .fixed:
            target = .fixed(value: fixedValue, raw: "\(fixedValue)")
        case .range:
            target = .range(low: rangeLow, high: rangeHigh, raw: "\(rangeLow)-\(rangeHigh)")
        case .time:
            target = .time(seconds: timeSeconds, raw: timeLabel)
        case .distance:
            target = .distance(meters: distanceMeters, raw: "\(distanceMeters)m")
        case .rounds:
            target = .rounds(count: roundsCount, raw: "\(roundsCount)round")
        case .perSide:
            target = .perSide(left: perSideLeft, right: perSideRight, raw: "\(perSideLeft),\(perSideRight)")
        }
    }
}

#Preview {
    RepTargetCustomSheet(target: .constant(.fixed(value: 10, raw: "10")))
}
