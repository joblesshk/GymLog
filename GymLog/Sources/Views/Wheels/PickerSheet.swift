import SwiftUI
import GymLogKit

/// CONTRACT-M5.md §3.2: "点击展开、选完收起" -- every selectable value in an
/// entry row (动作/组数/重量/次数) is plain text until tapped, then opens this
/// as a `.sheet` wrapping the relevant wheel, with an explicit 完成 button to
/// collapse back to text. One generic wrapper replaces M4's two single-
/// purpose sheets (`SetLoadEditSheet`/`SetTargetEditSheet` in the now-deleted
/// `SetValueEditSheet.swift`) since every field this round wraps a different
/// wheel but needs the exact same chrome (title, 完成 button, compact detent).
struct PickerSheet<Content: View>: View {
    let title: String
    var contentHeight: CGFloat = 150
    var onConfirm: () -> Void = {}
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack {
                Spacer(minLength: 4)
                content()
                    .frame(height: contentHeight)
                Spacer(minLength: 4)
            }
            .padding()
            .background(DS.C.canvas)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("完成", "Done")) {
                        onConfirm()
                        dismiss()
                    }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(DS.C.accent)
                        .accessibilityIdentifier("picker-sheet-done-button")
                }
            }
        }
        .presentationDetents([.height(contentHeight + 110)])
    }
}
