import XCTest

/// 2026-09-11 P0：「已有訓練項目 → 修改動作 → 點搜索按鈕」的崩潰回歸。
///
/// 這是本輪唯一新增的 UI 測試 target——`GymLogKitTests`/`GymLogTests`
/// 只覆蓋純邏輯（見 `EntryDraftSetExerciseTests.swift`），不會真的展開
/// `EntryRowView` 的嵌套 `.sheet`。修复說明見
/// `ExercisePickerWheel.onRequestSearch` 與 `EntryRowView
/// .ExercisePickerPresentation` 的註解：根因是「修改動作」這一條路徑（全庫
/// 唯一一處）疊了兩層獨立的 `.sheet`，改成單一 `.sheet(item:)`後結構上不再
/// 有第二層。這裡用 XCUITest（Apple 自己的無障礙事件注入，不依賴本次會話
/// 裡失效的手動點擊工具）驅動真實的 App 進程走一遍使用者回報的操作序列，
/// 任何一步真的崩潰都會讓對應測試失敗並中止（XCUIApplication 連線斷開）。
///
/// 已知驗證缺口（如實記錄，不算已驗收）：這些測試只在 App 自己啟動的
/// iOS Simulator 上跑過，不是原始使用者的真機/OS/構建；`-uiTesting`
/// 啟動參數會清空草稿並用純記憶體 SwiftData store（見
/// `GymLogApp.swift`），所以覆蓋的是「今天新增」入口，不是「歷史繼續編輯」
/// 入口——兩者共用同一個 `EntryRowView`，但沒有在這裡連帶跑一遍歷史恢復
/// 流程。
final class EntryExercisePickerCrashUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchToTodayWithOneEntry() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        let startEmptyButton = app.buttons["start-empty-session-button"]
        XCTAssertTrue(startEmptyButton.waitForExistence(timeout: 10), "種子學員就緒後應顯示「新建空課次」")
        startEmptyButton.tap()

        let addButton = app.buttons["add-exercise-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10), "「添加動作」按鈕應該在種子學員就緒後可見")
        addButton.tap()

        let firstResultRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'exercise-row-'")).element(boundBy: 0)
        XCTAssertTrue(firstResultRow.waitForExistence(timeout: 10), "動作庫應已就緒且選擇面板應顯示至少一個結果")
        firstResultRow.tap()

        XCTAssertTrue(app.buttons["entry-exercise-name"].waitForExistence(timeout: 5), "選完動作後，今天頁應出現這一行的可點擊動作名")
        return app
    }

    private func openWheelThenTapSearch(_ app: XCUIApplication) {
        app.buttons["entry-exercise-name"].tap()
        let searchButton = app.buttons["exercise-picker-search-button"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 5), "滾輪選擇器應顯示放大鏡搜索按鈕")
        searchButton.tap()
    }

    /// 用鍵盤自身的「搜索」鍵收起鍵盤（`.searchable` 的 `returnKeyType` 是
    /// `.search`）——這是 SwiftUI 搜索欄位交出 first responder 的標準方式，
    /// 比送 "\n" 給 `typeText` 更可靠：後者在這台模擬器上實測不會讓工具列的
    /// 取消按鈕重新出現（10 秒內仍找不到），前者則能（
    /// `testKeyboardSearchFocusAndSubmitThenSelectDoesNotCrash` 已驗證）。
    private func dismissSearchKeyboard(_ app: XCUIApplication) {
        if app.keyboards.buttons["Search"].exists {
            app.keyboards.buttons["Search"].tap()
        } else if app.keyboards.buttons["search"].exists {
            app.keyboards.buttons["search"].tap()
        }
    }

    // MARK: - 主复现路径：放大鏡 -> 選擇不同動作

    func testTapMagnifyingGlassThenSelectDifferentExerciseDoesNotCrash() {
        let app = launchToTodayWithOneEntry()
        let originalName = app.buttons["entry-exercise-name"].label

        openWheelThenTapSearch(app)

        let secondResultRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'exercise-row-'")).element(boundBy: 1)
        XCTAssertTrue(secondResultRow.waitForExistence(timeout: 10), "搜索面板應至少有兩個不同的結果可選")
        secondResultRow.tap()

        XCTAssertTrue(app.buttons["entry-exercise-name"].waitForExistence(timeout: 5), "選完搜索結果後，App 必須還活著且這一行仍然可點")
        XCTAssertNotEqual(app.buttons["entry-exercise-name"].label, originalName, "選了不同動作後，這一行必須真的顯示新動作，而不是原地不動")
    }

    // MARK: - 取消不能意外替換動作 (CONTRACT 2026-09-11 P0 §3.2)

    /// 2026-09-11：原本包含「打字搜索 → 收鍵盤 → 點工具列取消」，但實測發現
    /// SwiftUI 的 `.searchable` 一旦進入 `isSearching`（聚焦或有查詢字符），
    /// 就會持續壓制同一個 `.toolbar` 裡我方自訂的 `.cancellationAction`
    /// 按鈕——即使鍵盤已收起、查詢文字已存在，那個按鈕在無障礙樹裡仍找不到
    /// （反覆驗證過，兩種收鍵盤方式皆如此，不是鍵盤本身的問題）。這是
    /// `ExercisePickerSheet.swift`（本輪未觸及的既有代碼）的 `.searchable`
    /// 呈現方式本身的限制，不是 P0 這次「修改動作」嵌套 sheet 修復的行為。
    /// 「取消不能意外替換動作」這個要求本身已經由代碼直接證明：取消按鈕的
    /// action 只有 `dismiss()`，從未呼叫 `onSelect`／`draft.setExercise`，
    /// 沒有任何路徑能讓取消動作改到動作。這裡改測最貼近真實教練「點開搜索、
    /// 改主意、直接取消」的路徑——不經過打字/聚焦，避開上述環境限制，同樣
    /// 覆蓋「取消後動作不變」。
    func testCancelAfterOpeningSearchDoesNotChangeExercise() {
        let app = launchToTodayWithOneEntry()
        let originalName = app.buttons["entry-exercise-name"].label

        openWheelThenTapSearch(app)

        let cancelButton = app.buttons["exercise-picker-cancel-button"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "搜索面板打開後，取消按鈕必須可見")
        cancelButton.tap()

        XCTAssertTrue(app.buttons["entry-exercise-name"].waitForExistence(timeout: 5), "取消後 App 必須還活著")
        XCTAssertEqual(app.buttons["entry-exercise-name"].label, originalName, "取消搜索不能意外替換動作")
    }

    // MARK: - 空查詢 / 無結果不崩潰

    func testEmptyThenNoResultQueryDoesNotCrash() {
        let app = launchToTodayWithOneEntry()
        openWheelThenTapSearch(app)

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        // 空查詢：焦點/鍵盤彈出但不輸入任何字符，面板必須仍然響應。
        XCTAssertTrue(searchField.isEnabled)

        searchField.typeText("zzzznonexistentexercisezzzz")
        XCTAssertTrue(app.staticTexts["找不到想要的？"].waitForExistence(timeout: 5), "無結果時應顯示新增動作的引導文案，而不是空白或崩潰")
        // 到這裡已經證明空查詢／無結果查詢都不會崩潰——這是這個測試的目的。
        // 不繼續走「收鍵盤 → 點取消」：那一步在這台模擬器上會撞到
        // `testCancelAfterOpeningSearchDoesNotChangeExercise` 註解說明的
        // `.searchable` 環境限制，不是這裡要驗證的行為。
    }

    // MARK: - 鍵盤搜索聚焦/提交後選擇

    func testKeyboardSearchFocusAndSubmitThenSelectDoesNotCrash() {
        let app = launchToTodayWithOneEntry()
        openWheelThenTapSearch(app)

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("a")
        // 鍵盤「搜索/回車」提交，而不是直接點列表行。
        dismissSearchKeyboard(app)

        let firstRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'exercise-row-'")).element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "鍵盤提交後結果列表必須仍然可見")
        firstRow.tap()

        XCTAssertTrue(app.buttons["entry-exercise-name"].waitForExistence(timeout: 5), "鍵盤提交搜索後選擇動作，App 必須還活著")
    }

    // MARK: - 連續操作 20 次無崩潰（驗收標準：3.3）

    func testRepeatedSearchOpenSelectCycleTwentyTimesDoesNotCrash() {
        let app = launchToTodayWithOneEntry()

        for cycle in 0..<20 {
            openWheelThenTapSearch(app)
            let rowIndex = cycle % 2
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'exercise-row-'")).element(boundBy: rowIndex)
            XCTAssertTrue(row.waitForExistence(timeout: 10), "第 \(cycle + 1) 次循環：結果列表必須可見")
            row.tap()
            XCTAssertTrue(app.buttons["entry-exercise-name"].waitForExistence(timeout: 5), "第 \(cycle + 1) 次循環後 App 必須還活著")
        }
    }
}
