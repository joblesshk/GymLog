import Observation

/// CONTRACT-M5.md §1.2: the nav bar's new "编辑「...」资料" menu entry
/// (`ClientSwitcherButton`) needs to jump to the "个人信息" tab, but the
/// switcher is mounted deep inside each tab's own root view, with no direct
/// access to `ContentView`'s `TabView` selection. Rather than thread a
/// closure through every intermediate view, `ContentView` owns one instance
/// of this tiny shared `@Observable` and hands it to the screens that need
/// to read or drive tab selection -- the minimal-diff option the contract
/// explicitly calls out ("回调闭包...或者共享 @Observable 状态，执行方自行选择
/// 最小实现").
@MainActor
@Observable
public final class TabSelectionStore {
    public var selectedTab: Int

    public init(selectedTab: Int = 0) {
        self.selectedTab = selectedTab
    }

    public func select(tab: Int) {
        selectedTab = tab
    }
}
