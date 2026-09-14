import XCTest

/// P1 (2026-09-11)：Superset 卡片的真實互動——`SupersetBlockDraftCard`/
/// `ComposeSupersetSheet` 的成員增刪/輪次同步/組成/自動轉普通動作都是這兩個
/// SwiftUI 檔案裡的私有方法，`GymLogTests/SupersetBlockDraftTests.swift`
/// 只驗證這些互動最終會產生的**資料形狀**能不能正確存取——這裡用 XCUITest
/// 驅動真實 App 進程走一遍互動本身。複用 P0
/// （`EntryExercisePickerCrashUITests.swift`）已經驗證有效的 `-uiTesting`
/// 啟動模式（清空草稿、種子唯一一位測試學員、純記憶體 SwiftData store）。
final class SupersetUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchToTodayEmptySession() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        let startEmptyButton = app.buttons["start-empty-session-button"]
        XCTAssertTrue(startEmptyButton.waitForExistence(timeout: 10), "種子學員就緒後應顯示「新建空課次」")
        startEmptyButton.tap()
        return app
    }

    /// 今天頁是可滾動列表，底部浮動標籤欄會蓋住靠下的按鈕；直接 `tap()` 會點到
    /// 標籤欄（SwiftUI 下 `isHittable` 仍回報 true）。先小幅上滑，直到元素
    /// 離開螢幕底部區域，再點擊。
    private func tapWhenHittable(_ element: XCUIElement, in app: XCUIApplication) {
        let safeMaxY = app.frame.height * 0.8
        for _ in 0..<8 where element.frame.maxY > safeMaxY {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        }
        element.tap()
    }

    /// 添加 Superset → 選第一個成員（走 `add-superset-button`，一次只選 1
    /// 個，卡片自己的「加入動作」補第二個——見 `TodayView.ExercisePickerTarget
    /// .newSuperset` 的註解：避免連續彈兩次選擇器的狀態機風險）。
    @discardableResult
    private func addSupersetWithTwoMembers(_ app: XCUIApplication) -> Bool {
        let addSupersetButton = app.buttons["add-superset-button"]
        guard addSupersetButton.waitForExistence(timeout: 10) else { return false }
        tapWhenHittable(addSupersetButton, in: app)

        let firstRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'exercise-row-'")).element(boundBy: 0)
        guard firstRow.waitForExistence(timeout: 10) else { return false }
        firstRow.tap()

        guard app.buttons["superset-member-name-0"].waitForExistence(timeout: 5) else { return false }

        let addMemberButton = app.buttons["superset-add-member-button"]
        guard addMemberButton.waitForExistence(timeout: 5) else { return false }
        tapWhenHittable(addMemberButton, in: app)

        let secondRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'exercise-row-'")).element(boundBy: 1)
        guard secondRow.waitForExistence(timeout: 10) else { return false }
        secondRow.tap()

        return app.buttons["superset-member-name-1"].waitForExistence(timeout: 5)
    }

    // MARK: - 添加 Superset：第一個成員之後補第二個，A1/A2 都要出現

    func testAddSupersetShowsBothMembersAfterAddingSecond() {
        let app = launchToTodayEmptySession()
        XCTAssertTrue(addSupersetWithTwoMembers(app), "添加 Superset 兩個成員都要能成功加入")
        XCTAssertTrue(app.buttons["superset-member-name-0"].exists)
        XCTAssertTrue(app.buttons["superset-member-name-1"].exists)
    }

    // MARK: - 加一輪：所有成員的輪次同步增加

    func testAddRoundAppearsAsNewRoundLabel() {
        let app = launchToTodayEmptySession()
        XCTAssertTrue(addSupersetWithTwoMembers(app))

        // 默認 3 輪，「R3」應已存在，「R4」還不存在。
        XCTAssertTrue(app.staticTexts["R3"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["R4"].exists)

        let addRoundButton = app.buttons["superset-add-round-button"]
        XCTAssertTrue(addRoundButton.waitForExistence(timeout: 5))
        tapWhenHittable(addRoundButton, in: app)

        XCTAssertTrue(app.staticTexts["R4"].waitForExistence(timeout: 5), "加一輪後每個成員都應該多出第 4 輪")
    }

    // MARK: - 移除成員到只剩 1 個：自動轉回普通動作

    func testRemovingMemberDownToOneConvertsToSingleExercise() {
        let app = launchToTodayEmptySession()
        XCTAssertTrue(addSupersetWithTwoMembers(app))

        let removeSecondMember = app.buttons["superset-remove-member-1"]
        XCTAssertTrue(removeSecondMember.waitForExistence(timeout: 5))
        tapWhenHittable(removeSecondMember, in: app)

        // 转普通动作后这一行改由 EntryRowView 渲染（P0 的
        // `entry-exercise-name` identifier），Superset 卡片自己的成员标识
        // 应该消失。
        XCTAssertTrue(app.buttons["entry-exercise-name"].waitForExistence(timeout: 5), "只剩 1 個成員後應該自動轉回普通動作的卡片")
        XCTAssertFalse(app.buttons["superset-member-name-0"].exists)
    }

    // MARK: - 組成 Superset：從兩個既有的獨立動作合併

    func testComposeSupersetFromTwoExistingSingleExercises() {
        let app = launchToTodayEmptySession()

        // 建两个独立的普通动作（各自一个 .single block）。
        for rowIndex in [0, 1] {
            let addButton = app.buttons["add-exercise-button"]
            XCTAssertTrue(addButton.waitForExistence(timeout: 10))
            tapWhenHittable(addButton, in: app)
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'exercise-row-'")).element(boundBy: rowIndex)
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.tap()
        }

        let composeButton = app.buttons["compose-superset-button"]
        XCTAssertTrue(composeButton.waitForExistence(timeout: 10), "有 2 個以上可組合的獨立動作時，「組成 Superset」應該可見")
        tapWhenHittable(composeButton, in: app)

        let composeRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'compose-row-'"))
        XCTAssertTrue(composeRows.element(boundBy: 0).waitForExistence(timeout: 10))
        composeRows.element(boundBy: 0).tap()
        composeRows.element(boundBy: 1).tap()

        let confirmButton = app.buttons["compose-confirm-button"]
        XCTAssertTrue(confirmButton.exists)
        confirmButton.tap()

        XCTAssertTrue(app.buttons["superset-member-name-0"].waitForExistence(timeout: 5), "確認組成後應該出現 Superset 卡片，兩個成員都在")
        XCTAssertTrue(app.buttons["superset-member-name-1"].waitForExistence(timeout: 5))
    }

    // MARK: - 解散為獨立動作

    func testDissolveSupersetBackToSeparateExercises() {
        let app = launchToTodayEmptySession()
        XCTAssertTrue(addSupersetWithTwoMembers(app))

        // Superset 卡片右上角的「⋯」菜单里有「解散為獨立動作」。
        // Target the menu's stable accessibility identifier, not its decorative SF Symbol.
        let menu = app.buttons["superset-menu-button"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "應該能找到 Superset 卡片的「⋯」選單")
        tapWhenHittable(menu, in: app)

        let dissolveItem = app.buttons["解散為獨立動作"]
        XCTAssertTrue(dissolveItem.waitForExistence(timeout: 5))
        dissolveItem.tap()

        // 解散後两个成员各自变成一张用 EntryRowView 渲染的普通卡片；今天页
        // 至少要有 2 个 `entry-exercise-name`。
        let entryNames = app.buttons.matching(identifier: "entry-exercise-name")
        XCTAssertTrue(entryNames.element(boundBy: 1).waitForExistence(timeout: 5), "解散後應該出現兩張獨立的普通動作卡片")
    }
}
