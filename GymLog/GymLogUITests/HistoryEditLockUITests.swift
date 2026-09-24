import XCTest

/// A session open in Today is rebuilt from the draft on its next save, so
/// History must not quick-fix or delete it meanwhile.
final class HistoryEditLockUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSessionOpenInTodayCannotBeQuickFixedOrCleared() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        let start = app.buttons["start-empty-session-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 15)); start.tap()
        let add = app.buttons["add-exercise-button"]
        XCTAssertTrue(add.waitForExistence(timeout: 5)); add.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'exercise-row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8)); row.tap()

        let save = app.buttons["save-draft-button"]
        for _ in 0..<6 where !save.exists || save.frame.maxY > app.frame.height * 0.8 { app.swipeUp() }
        XCTAssertTrue(save.waitForExistence(timeout: 5)); save.tap()
        if app.alerts.firstMatch.waitForExistence(timeout: 3) { app.alerts.firstMatch.buttons.firstMatch.tap() }

        app.buttons["歷史"].tap()
        let tools = app.buttons["history-tools-menu"]
        XCTAssertTrue(tools.waitForExistence(timeout: 5)); tools.tap()
        let clearAll = app.buttons["清空全部歷史"]
        XCTAssertTrue(clearAll.waitForExistence(timeout: 3))
        XCTAssertFalse(clearAll.isEnabled, "clearing would delete the session still open in Today")
        app.tap() // dismiss the menu

        let session = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history-session-se-local'")).firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 5)); session.tap()
        XCTAssertTrue(app.descendants(matching: .any)["session-detail-scroll"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: app.navigationBars.buttons.count - 1).tap()
        let quickFix = app.buttons["session-detail-quick-fix"]
        XCTAssertTrue(quickFix.waitForExistence(timeout: 3))
        XCTAssertFalse(quickFix.isEnabled, "quick fixes would be overwritten by the Today draft")
        XCTAssertTrue(app.buttons["回到「今天」繼續編輯"].exists)
    }
}
