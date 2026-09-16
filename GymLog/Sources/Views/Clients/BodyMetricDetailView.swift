import SwiftUI
import SwiftData
import UIKit
import GymLogKit

/// One InBody record, opened from the list on `ClientProfileView`.
///
/// The list row is a deliberately dense summary -- eight values on two
/// lines at 12pt -- which is fine for scanning the history but not for
/// actually reading one measurement, and it offered no way to correct or
/// remove a record once saved. That gap matters more than it looks: the
/// photo scanner can put a wrong value into a record (or miss one), and
/// until now the only remedy was to leave it there.
///
/// So this page shows every field `BodyMetric` carries, at a readable size,
/// INCLUDING the ones that are empty -- rendered as "—" rather than hidden.
/// Which fields a scan failed to capture is exactly what the coach needs to
/// see when checking a scanned record against the paper report; hiding the
/// gaps (as the summary row does, out of necessity) makes a partial scan
/// look complete.
struct BodyMetricDetailView: View {
    let client: Client
    let metric: BodyMetric

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    @State private var showEditSheet = false
    @State private var showDeleteConfirmation = false
    @State private var deleteErrorMessage: String?
    /// Set before `dismiss()` so the body stops reading `metric` the moment
    /// deletion starts -- a SwiftData object that has been deleted is not
    /// safe to keep rendering, and the pop is not instantaneous.
    @State private var isDeleting = false

    var body: some View {
        Group {
            if isDeleting {
                Color.clear
            } else {
                content
            }
        }
    }

    private var content: some View {
        List {
            Section {
                LabeledContent {
                    Text(SessionDateFormat.display.string(from: metric.date))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DS.C.textHi)
                } label: {
                    Text(language.t("測量日期", "Measured"))
                        .font(DS.F.listRow)
                        .foregroundStyle(DS.C.textLow)
                }
                .listRowBackground(DS.C.surface)
            }

            if let weight = metric.weightKg, let muscle = metric.skeletalMuscleKg, let fat = metric.bodyFatMassKg {
                Section {
                    compositionCard(totalWeight: weight, muscle: muscle, fat: fat)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } header: {
                    Text(language.t("身體組成", "Body Composition")).sectionLabelStyle()
                }
            } else {
                Section {
                    valueRow(language.t("體重", "Weight"), metric.weightKg, unit: "kg")
                    valueRow(language.t("體脂率", "Body Fat"), metric.bodyFatPercent, unit: "%")
                    valueRow(language.t("體脂重", "Fat Mass"), metric.bodyFatMassKg, unit: "kg")
                    valueRow(language.t("骨骼肌量", "Skeletal Muscle Mass"), metric.skeletalMuscleKg, unit: "kg")
                } header: {
                    Text(language.t("身體組成", "Body Composition")).sectionLabelStyle()
                }
            }

            Section {
                BMIRangeBar(value: metric.bmi)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                VisceralFatRangeBar(value: metric.visceralFatLevel)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } header: {
                Text(language.t("指標", "Indices")).sectionLabelStyle()
            }

            Section {
                HStack(spacing: 8) {
                    metabolismCell(language.t("BMR", "BMR"), metric.bmr)
                    metabolismCell(language.t("TDEE", "TDEE"), metric.tdee)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                Text(language.t("代謝", "Metabolism")).sectionLabelStyle()
            }

            Section {
                if let notes = metric.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(notes)
                        .font(.system(size: 15))
                        .foregroundStyle(DS.C.textHi)
                        .textSelection(.enabled)
                } else {
                    Text(language.t("無", "None"))
                        .font(.system(size: 15))
                        .foregroundStyle(DS.C.textLow)
                }
            } header: {
                Text(language.t("備註", "Notes")).sectionLabelStyle()
            }
            .listRowBackground(DS.C.surface)

            Section {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Text(language.t("刪除這條記錄", "Delete This Record"))
                        .font(.system(size: 15, weight: .semibold))
                }
                .listRowBackground(DS.C.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(DS.C.canvas)
        // Without this the floating tab bar sits on top of the last
        // section, and the delete button ends up permanently unreachable --
        // the list has nothing left to scroll. Every other screen in the
        // app that owns a scroll view does the same.
        .reserveFloatingTabBarSpace()
        .navigationTitle(language.t("InBody 記錄", "InBody Record"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(language.t("編輯", "Edit")) { showEditSheet = true }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.C.accent)
            }
        }
        .sheet(isPresented: $showEditSheet) {
            AddBodyMetricSheet(client: client, metric: metric)
        }
        .confirmationDialog(
            language.t("刪除這條 InBody 記錄？", "Delete this InBody record?"),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.t("刪除", "Delete"), role: .destructive) { performDelete() }
            Button(language.t("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(language.t("刪除後無法復原。", "This cannot be undone."))
        }
        .alert(
            language.t("刪除失敗", "Delete Failed"),
            isPresented: Binding(get: { deleteErrorMessage != nil }, set: { if !$0 { deleteErrorMessage = nil } })
        ) {
            Button(language.t("好", "OK"), role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "")
        }
    }

    /// Renders an absent value as "—" instead of dropping the row, so a
    /// partially-captured scan reads as partial.
    @ViewBuilder
    private func valueRow(_ label: String, _ value: Double?, unit: String, integer: Bool = false) -> some View {
        LabeledContent {
            if let value {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(integer ? String(Int(value)) : Self.format(value))
                        .font(.system(size: 17, weight: .semibold).monospacedDigit())
                        .foregroundStyle(DS.C.textHi)
                    if !unit.isEmpty {
                        Text(unit)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DS.C.textLow)
                    }
                }
            } else {
                Text("—")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(DS.C.textLow)
            }
        } label: {
            Text(label)
                .font(DS.F.listRow)
                .foregroundStyle(DS.C.textLow)
        }
        .listRowBackground(DS.C.surface)
    }

    fileprivate static func format(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    /// 構成比例條——肌肉／脂肪／其他佔總體重的比例（GymLog 改版設計 §5）。
    /// 只在三個數字都齊全時顯示，否則上層退回鍵值列表。
    private func compositionCard(totalWeight: Double, muscle: Double, fat: Double) -> some View {
        let other = max(0, totalWeight - muscle - fat)
        return VStack(alignment: .leading, spacing: 10) {
            Text(language.t("構成比例 · COMPOSITION", "COMPOSITION")).sectionLabelStyle()
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(Self.format(totalWeight))
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DS.C.textHi)
                Text(language.t("kg 總體重", "kg total"))
                    .font(.system(size: 12))
                    .foregroundStyle(DS.C.textLow)
            }
            // 2026-09-16 第二次修正：`GeometryReader` 和後來換上的自訂
            // `Layout` 這兩版都被教練實機確認過還是太窄——都是「讓 SwiftUI
            // 的佈局協商自己去量出容器寬度」這條路本身在這個 `List` row 情境
            // 裡不可靠。這次不再信任任何動態量測：直接用
            // `UIScreen.main.bounds.width` 減掉已知的外層 `.padding(.horizontal,
            // pageMargin)` 和這張卡片自己的 `.padding(14)`，在建構時就算出一
            // 個確定的寬度，三段用普通 `HStack` + 明確 `.frame(width:)`，不
            // 經過任何「詢問容器多寬」的環節。
            let barWidth = UIScreen.main.bounds.width - 2 * DS.Space.pageMargin - 2 * 14
            let total = max(0.001, muscle + fat + other)
            HStack(spacing: 2) {
                compositionSegment(language.t("肌 \(Self.format(muscle))", "Muscle \(Self.format(muscle))"), bg: DS.C.accent, fg: DS.C.onAccent)
                    .frame(width: Self.segmentWidth(muscle, total: total, barWidth: barWidth))
                compositionSegment(language.t("脂 \(Self.format(fat))", "Fat \(Self.format(fat))"), bg: DS.C.pr.opacity(0.5), fg: DS.C.textHi)
                    .frame(width: Self.segmentWidth(fat, total: total, barWidth: barWidth))
                compositionSegment(language.t("其他 \(Self.format(other))", "Other \(Self.format(other))"), bg: DS.C.inset, fg: DS.C.textLow)
                    .frame(width: Self.segmentWidth(other, total: total, barWidth: barWidth))
            }
            .frame(width: barWidth, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 14) {
                metricChip(metric.bodyFatPercent.map { (language.t("體脂率", "Body Fat"), Self.format($0), "%") })
                metricChip((language.t("骨骼肌量", "Skeletal Muscle"), Self.format(muscle), "kg"))
                metricChip((language.t("體脂重", "Fat Mass"), Self.format(fat), "kg"))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gymCard()
        .padding(.horizontal, DS.Space.pageMargin)
    }

    private func compositionSegment(_ label: String, bg: Color, fg: Color) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(fg)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(bg)
    }

    /// `weight` 佔 `total` 的比例，乘上扣掉段間距後的可用寬度。`total` 保證
    /// 由呼叫端傳入時已經是至少 0.001（不會是 0），這裡不用再防一次除以零。
    private static func segmentWidth(_ weight: Double, total: Double, barWidth: CGFloat) -> CGFloat {
        let spacing: CGFloat = 2
        let usable = max(0, barWidth - spacing * 2)
        return usable * (max(0, weight) / total)
    }

    @ViewBuilder
    private func metricChip(_ item: (label: String, value: String, unit: String)?) -> some View {
        if let item {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.C.textLow)
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text(item.value).font(.system(size: 19, weight: .semibold, design: .monospaced)).foregroundStyle(DS.C.textHi)
                    Text(item.unit).font(.system(size: 11)).foregroundStyle(DS.C.textLow)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(DS.C.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// 「本次未填 + ＋ 補填」的可點格子——點了開編輯表單，不在這頁直接輸入
    /// （BMR/TDEE 屬於整條記錄的一部分，改動走既有的「編輯」流程）。
    private func metabolismCell(_ label: String, _ value: Double?) -> some View {
        Button {
            showEditSheet = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.C.textMid)
                    Text("kcal").font(.system(size: 10)).foregroundStyle(DS.C.textLow)
                }
                Spacer()
                if let value {
                    Text(Self.format(value))
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DS.C.textHi)
                } else {
                    Text(language.t("＋ 補填", "+ Add"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.C.textLow)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(DS.C.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// R07 (2026-09-16): `dismiss()` used to fire before the save even
    /// started, so a failure's `deleteErrorMessage` was set on a view that
    /// had already been torn down -- nobody was left to show the `.alert`
    /// for it. `isDeleting = true` still comes first (unchanged) so `body`
    /// stops rendering `content`/`metric` for the duration of the delete,
    /// same as before; `dismiss()` itself now only happens once `save()`
    /// has actually succeeded. On failure the rollback restores `metric`
    /// and `isDeleting` flips back to `false`, so this still-alive view
    /// re-shows the (now-intact) record underneath the error alert.
    private func performDelete() {
        isDeleting = true
        modelContext.delete(metric)
        do {
            try modelContext.save()
            dismiss()
        } catch {
            modelContext.rollback()
            isDeleting = false
            deleteErrorMessage = error.localizedDescription
        }
    }
}


/// 區間條——BMI／內臟脂肪等級共用的視覺語彙（GymLog 改版設計 §5）：分段寬度
/// 對應各級距的實際數值跨度、指針依真實數值定位；沒有官方分級來源，門檻取
/// 自 BMI 的 WHO 通用標準與 InBody 常見的內臟脂肪等級說明，兩者都是與
/// GymLog 無關的通用參照，不是本 App 自訂的判斷。分段顏色借用既有語意
/// token 加透明度（review=正常、pr=偏高、inferred=過高），不新開資產。
private struct RangeBar: View {
    let title: String
    let value: Double?
    let integer: Bool
    /// 每段 (數值跨度, 顏色)，依序累加就是指針的定位軸。
    let segments: [(span: Double, color: Color)]
    /// 每段對應的區間文字；命中的那一段會加粗上色。
    let labels: [String]
    let normalIndex: Int
    /// 命中正常範圍時右上角的短徽章文字（跟軸標籤分開，軸標籤要帶數值範圍，
    /// 徽章只要一個詞，例如「標準範圍」而不是「標準 18.5–25」）。
    let normalBadgeText: String
    let outOfRangeLabel: (Double) -> (text: String, color: Color)?

    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    private var totalSpan: Double { segments.reduce(0) { $0 + $1.span } }

    private func activeSegmentIndex(for value: Double) -> Int {
        var cumulative: Double = 0
        for (index, segment) in segments.enumerated() {
            cumulative += segment.span
            if value <= cumulative || index == segments.count - 1 { return index }
        }
        return segments.count - 1
    }

    private func pointerFraction(for value: Double) -> CGFloat {
        CGFloat(min(1, max(0, value / totalSpan)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                Text(title).sectionLabelStyle()
                Spacer()
                HStack(alignment: .lastTextBaseline, spacing: 5) {
                    Text(value.map { integer ? String(Int($0)) : BodyMetricDetailView.format($0) } ?? "—")
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .foregroundStyle(value == nil ? DS.C.textLow : DS.C.textHi)
                    if let value {
                        let activeIndex = activeSegmentIndex(for: value)
                        let badge = outOfRangeLabel(value) ?? (activeIndex == normalIndex ? (normalBadgeText, DS.C.review) : nil)
                        if let badge {
                            Text(badge.text)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(badge.color)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(badge.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
            }
            GeometryReader { geo in
                let spacing: CGFloat = 2
                let usable = max(0, geo.size.width - spacing * CGFloat(segments.count - 1))
                ZStack(alignment: .topLeading) {
                    HStack(spacing: spacing) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                            Rectangle().fill(segment.color)
                                .frame(width: usable * CGFloat(segment.span / totalSpan))
                        }
                    }
                    .frame(height: 12)
                    .clipShape(Capsule())
                    .padding(.top, 16)

                    if let value {
                        Rectangle()
                            .fill(DS.C.textHi)
                            .frame(width: 4, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                            // Bar sits at top-padding 16 with height 12, so its
                            // vertical center is at 22 -- that's where the
                            // pointer's own center should land too.
                            .position(x: pointerFraction(for: value) * geo.size.width, y: 22)
                    }
                }
            }
            .frame(height: 44)
            HStack {
                ForEach(Array(labels.enumerated()), id: \.offset) { index, text in
                    Text(text)
                        .font(.system(size: 10, weight: index == normalIndex ? .semibold : .regular))
                        .foregroundStyle(index == normalIndex ? DS.C.review : DS.C.textLow)
                    if index < labels.count - 1 { Spacer(minLength: 0) }
                }
            }
            .padding(.top, 8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gymCard()
        .padding(.horizontal, DS.Space.pageMargin)
    }
}

private struct BMIRangeBar: View {
    let value: Double?
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    var body: some View {
        RangeBar(
            title: "BMI",
            value: value,
            integer: false,
            segments: [
                (18.5, DS.C.inset),
                (6.5, DS.C.review.opacity(0.35)),
                (5, DS.C.pr.opacity(0.35)),
                (5, DS.C.inferred.opacity(0.4)),
            ],
            labels: [
                language.t("偏低 <18.5", "Low <18.5"),
                language.t("標準 18.5–25", "Normal 18.5–25"),
                language.t("過重", "Overweight"),
                language.t("肥胖 >30", "Obese >30"),
            ],
            normalIndex: 1,
            normalBadgeText: language.t("標準範圍", "Normal range"),
            outOfRangeLabel: { v in
                if v < 18.5 { return (language.t("偏低", "Low"), DS.C.inferred) }
                if v >= 30 { return (language.t("肥胖", "Obese"), DS.C.danger) }
                if v >= 25 { return (language.t("過重", "Overweight"), DS.C.pr) }
                return nil
            }
        )
    }
}

private struct VisceralFatRangeBar: View {
    let value: Int?
    @AppStorage("appLanguage") private var language: AppLanguage = .zhHant

    var body: some View {
        RangeBar(
            title: language.t("內臟脂肪等級", "Visceral Fat Level"),
            value: value.map(Double.init),
            integer: true,
            segments: [
                (9, DS.C.review.opacity(0.35)),
                (5, DS.C.pr.opacity(0.35)),
                (6, DS.C.inferred.opacity(0.4)),
            ],
            labels: [
                language.t("正常 1–9", "Normal 1–9"),
                language.t("偏高 10–14", "High 10–14"),
                language.t("過高 15+", "Very High 15+"),
            ],
            normalIndex: 0,
            normalBadgeText: language.t("正常", "Normal"),
            outOfRangeLabel: { v in
                if v >= 15 { return (language.t("過高", "Very High"), DS.C.danger) }
                if v >= 10 { return (language.t("偏高", "High"), DS.C.pr) }
                return nil
            }
        )
    }
}
