import XCTest
@testable import GymLogKit

/// CONTRACT-M5.md §1 -- the nav bar changes. `Client.displayName` and
/// `TabSelectionStore` are the two pieces of logic the nav bar UI
/// (`ClientSwitcherButton`, a SwiftUI view with no unit-test seam of its
/// own in this project) is actually built on: every place the button
/// *displays* a name reads `displayName`, and its new "编辑「...」资料" menu
/// entry drives tab selection through `TabSelectionStore`. These tests
/// cover that logic directly; the visual result (a blank client rendering
/// as "默认用户" in the nav bar) is additionally captured in
/// Screenshots/M5A/ per VERIFICATION-M5A.md.
@MainActor
final class M5ANavTests: XCTestCase {

    // MARK: - Client.displayName

    // Traditional Chinese: `displayName`'s fallback branches on
    // `LanguageContext.current`, which defaults to `.zhHant` with no
    // `appLanguage` preference set (as in this test process).
    func testDisplayNameFallsBackToDefaultUserForEmptyName() {
        let client = Client(id: "cl-blank", name: "")
        XCTAssertEqual(client.displayName, "默認用戶")
    }

    func testDisplayNameReturnsRealNameWhenPresent() {
        let client = Client(id: "cl-1", name: "Example Athlete")
        XCTAssertEqual(client.displayName, "Example Athlete")
    }

    /// `name` itself must stay untouched by `displayName` -- an edit form
    /// bound to `name` must never see "默认用户" as an actual value
    /// (CONTRACT-M5.md §1.3: "不要把 displayName 的默认用户回填进 TextField").
    func testDisplayNameDoesNotMutateUnderlyingName() {
        let client = Client(id: "cl-blank", name: "")
        _ = client.displayName
        XCTAssertEqual(client.name, "", "reading displayName must never write back to name")
    }

    // MARK: - TabSelectionStore

    func testTabSelectionStoreDefaultsToTabZero() {
        let store = TabSelectionStore()
        XCTAssertEqual(store.selectedTab, 0)
    }

    func testTabSelectionStoreSelectUpdatesSelectedTab() {
        let store = TabSelectionStore()
        store.select(tab: 1)
        XCTAssertEqual(store.selectedTab, 1, "ClientSwitcherButton's 编辑资料 entry calls select(tab: 1) to jump to 个人信息")
    }

    func testTabSelectionStoreHonorsExplicitInitialTab() {
        // Mirrors ContentView's GYMLOG_INITIAL_TAB verification hook, which
        // constructs the store with a non-zero initial tab.
        let store = TabSelectionStore(selectedTab: 2)
        XCTAssertEqual(store.selectedTab, 2)
    }
}
