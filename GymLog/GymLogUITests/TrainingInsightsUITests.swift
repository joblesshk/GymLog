import XCTest

final class TrainingInsightsUITests: XCTestCase {
    func testTodayShowsCompactRestTimerAndPerExerciseEnergy() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        let start = app.buttons["start-empty-session-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 15)); start.tap()

        let pill = app.buttons["rest-timer-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "rest timer should be a compact pill")
        XCTAssertFalse(app.staticTexts["運動消耗估算"].exists, "the session-level energy panel is gone")
        XCTAssertFalse(app.staticTexts["訓練時長："].exists, "the duration control is gone")

        let addButton = app.buttons["add-exercise-button"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5)); addButton.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'exercise-row-' ")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8)); row.tap()

        let summary = app.staticTexts["entry-summary-line"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.contains("kcal"), "entry subtitle should end with its energy estimate, got \(summary.label)")

        let idleLabel = pill.label
        pill.tap()
        let started = expectation(for: NSPredicate(format: "label != %@", idleLabel), evaluatedWith: pill)
        wait(for: [started], timeout: 3)
        pill.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["90s"].waitForExistence(timeout: 3), "long-press offers rest presets")
        app.buttons["90s"].tap()

        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Today compact layout"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testHistoryDetailShowsEnergyAndReviewCards() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestingReviewedSession"]
        app.launch()
        let historyTab = app.buttons["歷史"]
        XCTAssertTrue(historyTab.waitForExistence(timeout: 15)); historyTab.tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Back squat' OR label CONTAINS '深蹲' OR label CONTAINS '2 個訓練塊' OR label CONTAINS '個動作'")).firstMatch
        if row.waitForExistence(timeout: 5) { row.tap() } else { app.cells.firstMatch.tap() }

        XCTAssertTrue(app.otherElements["training-energy-report"].waitForExistence(timeout: 8) || app.staticTexts["運動消耗"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["AI 訓練評價"].exists)
        XCTAssertTrue(app.staticTexts["下次建議"].exists || app.staticTexts["下次建議".uppercased()].exists)
        XCTAssertFalse(app.staticTexts["需要更新"].exists, "a freshly stored review must not be flagged as outdated")
        let top = XCTAttachment(screenshot: app.screenshot()); top.name = "History insight cards"; top.lifetime = .keepAlways; add(top)

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'kcal'")).firstMatch.exists, "energy headline should show kcal")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '起始體重'")).firstMatch.exists, "energy card should say which body weight it used")
        app.buttons["energy-breakdown-toggle"].tap()
        XCTAssertTrue(app.staticTexts["Bench press"].waitForExistence(timeout: 3))
        let lower = XCTAttachment(screenshot: app.screenshot()); lower.name = "History insight cards expanded"; lower.lifetime = .keepAlways; add(lower)
    }
}
