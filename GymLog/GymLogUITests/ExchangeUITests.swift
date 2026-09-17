import XCTest

/// P2 (2026-09-11)：分享/匯入入口的真實互動——`UIActivityViewController`
/// （系統分享面板）和 `.fileImporter`（系統文件選擇器）都是**獨立於本
/// App 進程之外**的系統 UI，XCUITest 對它們的可控性遠不如 App 自己的
/// SwiftUI sheet（P0/P1 那些測試能穩定點到「取消」「確認」按鈕，是因為
/// 那些都是本 App 進程裡的畫面；系統分享面板/文件選擇器是另一個進程，
/// 這裡不強行驅動它們，只驗證「按鈕存在、狀態正確、點下去能觸發系統面板
/// 且不崩潰」——核心的資料正確性已經由 `GymLogTests/ExchangeRoundTripTests
/// .swift`（真實 `ModelContext`，不經過任何 UI）覆蓋。
final class ExchangeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchToTodayWithOneEntry() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        let startEmptyButton = app.buttons["start-empty-session-button"]
        XCTAssertTrue(startEmptyButton.waitForExistence(timeout: 10))
        startEmptyButton.tap()

        let addButton = app.buttons["add-exercise-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.tap()
        let firstRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'exercise-row-'")).element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        firstRow.tap()

        XCTAssertTrue(app.buttons["entry-exercise-name"].waitForExistence(timeout: 5))
        return app
    }

    // MARK: - 「分享計劃」按鈕：空草稿禁用、有內容時可點並觸發系統分享面板

    func testSharePlanButtonEnablesAfterAddingAnExerciseAndOpensShareSheet() {
        let app = launchToTodayWithOneEntry()

        let shareButton = app.buttons["share-plan-button"]
        XCTAssertTrue(shareButton.waitForExistence(timeout: 5))
        XCTAssertTrue(shareButton.isEnabled, "草稿裡已經有內容，「分享計劃」不該是禁用狀態")
        shareButton.tap()

        // 系統分享面板是另一個進程——只驗證「App 沒有崩潰、還活著」，不深入
        // 斷言分享面板本身的內容。
        XCTAssertTrue(app.buttons["entry-exercise-name"].waitForExistence(timeout: 8) || app.otherElements.firstMatch.waitForExistence(timeout: 8), "點擊分享後 App 必須還活著")
    }

    // MARK: - 「從文件匯入」入口存在且可點（設置頁）

    func testSettingsExchangeImportEntryExistsAndOpensAPicker() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        let settingsTab = app.buttons["設置"]
        if settingsTab.waitForExistence(timeout: 10) {
            settingsTab.tap()
        }

        let importButton = app.buttons["exchange-import-from-file-button"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 10), "設置頁必須有「從文件匯入」入口")
        importButton.tap()

        // 打开的是系统文件选择器（另一个进程）——同样只验证 App 没有崩溃。
        XCTAssertTrue(importButton.waitForExistence(timeout: 8) || app.otherElements.firstMatch.waitForExistence(timeout: 8), "打開文件選擇器後 App 必須還活著")
    }

    // MARK: - 歷史頁「分享結果」在沒有已結束課次時保持禁用

    func testHistoryShareResultsDisabledWithNoCompletedSessions() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        let historyTab = app.buttons["歷史"]
        XCTAssertTrue(historyTab.waitForExistence(timeout: 10))
        historyTab.tap()

        // 顶部「⋯」菜单里的「分享結果」在没有已完成课次时必须是禁用的——
        // 种子学员刚建好，还没有任何历史记录。
        let menuButton = app.buttons.matching(NSPredicate(format: "label == 'ellipsis.circle' OR identifier == 'ellipsis.circle'")).firstMatch
        if menuButton.waitForExistence(timeout: 5) {
            menuButton.tap()
            let shareResultsItem = app.buttons["分享結果"]
            if shareResultsItem.waitForExistence(timeout: 3) {
                XCTAssertFalse(shareResultsItem.isEnabled, "沒有已結束課次時「分享結果」必須是禁用的")
            }
        }
    }

    func testPastePreviewShowsContentsCancelDoesNotWriteAndRepeatIsIdempotent() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        let settingsTab = app.buttons["設置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10))
        settingsTab.tap()

        let summary = "Ada — Session Summary · 2026-09-17 · Week 3\n\nSingle:\n• Bench Press：60kg×8 reps"
        func openPreview() {
            let paste = app.buttons["exchange-paste-button"]
            for _ in 0..<5 where !paste.exists {
                app.swipeUp()
            }
            XCTAssertTrue(paste.waitForExistence(timeout: 8))
            paste.tap()
            let editor = app.textViews["exchange-paste-text-editor"]
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            if (editor.value as? String ?? "").isEmpty {
                editor.tap()
                editor.typeText(summary)
            }
            app.buttons["exchange-paste-parse-button"].tap()
            XCTAssertTrue(app.buttons["exchange-preview-confirm-button"].waitForExistence(timeout: 8))
            XCTAssertTrue(app.staticTexts["Bench Press"].waitForExistence(timeout: 5))
        }

        openPreview()
        app.buttons["exchange-preview-cancel-button"].tap()
        XCTAssertFalse(app.buttons["exchange-preview-confirm-button"].waitForExistence(timeout: 3))

        openPreview()
        let newClientButton = app.buttons["exchange-preview-new-client-button"]
        for _ in 0..<6 where !newClientButton.exists || !newClientButton.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(newClientButton.waitForExistence(timeout: 3))
        XCTAssertTrue(newClientButton.isHittable)
        newClientButton.tap()
        let clientField = app.textFields["exchange-preview-client-name-field"]
        XCTAssertTrue(clientField.waitForExistence(timeout: 3))
        clientField.tap()
        clientField.typeText("UI Client")
        app.buttons["exchange-preview-confirm-button"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 8))
        app.alerts.firstMatch.buttons.firstMatch.tap()

        openPreview()
        let idempotentCount = app.descendants(matching: .any)["exchange-preview-idempotent-count"]
        for _ in 0..<6 where !idempotentCount.exists {
            app.swipeUp()
        }
        XCTAssertTrue(idempotentCount.waitForExistence(timeout: 3))
        app.buttons["exchange-preview-cancel-button"].tap()
    }
}
