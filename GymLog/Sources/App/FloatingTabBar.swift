import SwiftUI

/// 悬浮胶囊 Tab Bar（HANDOFF.md §3）。替换系统 Tab Bar 的外观，交互（5 个 Tab、
/// 选中态）完全不变，只是把系统底栏换成一个悬浮的圆角胶囊：左右 margin 10、
/// 底部 margin 8、内 padding 7/6，圆角 26；图标 21pt / 标签 10pt SemiBold；
/// 选中项加 `accentSoft` 药丸底（圆角 18）+ `accent` 前景。
struct FloatingTabBarItem {
    let title: String
    let systemImage: String
}

/// Reports the floating tab bar's actual rendered height (including its own
/// bottom margin) so `ContentView` can reserve exactly that much space at
/// the bottom of every tab's content via `.safeAreaInset` -- rather than a
/// hand-measured magic number that would silently drift out of sync if this
/// view's padding/font sizes ever change. See `ContentView.swift`'s
/// `.safeAreaInset(edge: .bottom)` for the consumer.
struct TabBarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    // NOT `value = nextValue()`: a `PreferenceKey`'s `defaultValue` is
    // implicitly contributed by every view in the tree that doesn't set it
    // explicitly, not just by `FloatingTabBar`'s own `GeometryReader`. With
    // a blind overwrite, whichever sibling `reduce` visits *last* wins --
    // and across a whole `TabView`'s worth of content, that's essentially
    // never guaranteed to be the one real measurement. Confirmed on-device:
    // this was silently reducing to 0 every time, which is why every prior
    // attempt at reserving space above the floating tab bar had no visible
    // effect at all. Keeping the max non-zero contribution sidesteps the
    // ordering dependency entirely.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

/// Broadcasts the floating tab bar's measured height down through
/// `.environment(\.floatingTabBarHeight, ...)` (set once in `ContentView`)
/// rather than passing it as an explicit parameter to all 5 tab root views.
/// Environment values cross `TabView`/`NavigationStack` boundaries reliably;
/// `.safeAreaInset` does not (see `reserveFloatingTabBarSpace` below for why
/// that matters here). Default matches `ContentView`'s pre-measurement
/// fallback so a view previewed in isolation still reserves a sane gap.
private struct FloatingTabBarHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 78
}

extension EnvironmentValues {
    var floatingTabBarHeight: CGFloat {
        get { self[FloatingTabBarHeightKey.self] }
        set { self[FloatingTabBarHeightKey.self] = newValue }
    }
}

extension View {
    /// Reserves bottom safe area (read from `\.floatingTabBarHeight`) so
    /// this view's own scrollable content -- and any bottom-anchored
    /// buttons inside it, e.g. 今天's "保存课次"/"放弃", 个人信息's "保存資料"
    /// -- never renders underneath the floating tab bar.
    ///
    /// MUST be applied *inside* each tab's own `NavigationStack` (on the
    /// content that stack pushes), not on the tab's root view from
    /// `ContentView`, and not on the parent `TabView` either. Both of those
    /// outer placements were tried first and both failed on-device: a
    /// `NavigationStack` -- like `TabView` -- manages its own internal
    /// layout region and does not reliably inherit a `.safeAreaInset`
    /// applied from *outside* it. Attaching it to the content actually
    /// living inside the stack is what SwiftUI actually honors.
    func reserveFloatingTabBarSpace() -> some View {
        modifier(FloatingTabBarSpaceReservation())
    }
}

private struct FloatingTabBarSpaceReservation: ViewModifier {
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: tabBarHeight)
        }
    }
}

struct FloatingTabBar: View {
    @Binding var selection: Int
    let items: [FloatingTabBarItem]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let isSelected = selection == index
                Button {
                    selection = index
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 21))
                        Text(item.title)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(isSelected ? DS.C.accent : DS.C.textLow)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        isSelected ? DS.C.accentSoft : Color.clear,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .background(DS.C.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(DS.C.hairline, lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: TabBarHeightKey.self, value: proxy.size.height)
            }
        )
    }
}
