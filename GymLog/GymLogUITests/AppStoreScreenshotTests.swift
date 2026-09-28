import XCTest

/// App Store screenshots from the synthetic `-screenshotShowcase` seed. Runs only when asked:
/// `TEST_RUNNER_GYMLOG_SCREENSHOTS=1 xcodebuild test -only-testing:GymLogUITests/AppStoreScreenshotTests ...`
final class AppStoreScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GYMLOG_SCREENSHOTS"] == "1", "screenshots are generated on request only")
        continueAfterFailure = false
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        sleep(1)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testCaptureAppStoreScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-screenshotShowcase", "-appLanguage", "zhHant"]
        app.launch()

        let copy = app.buttons["copy-from-history-button"]
        XCTAssertTrue(copy.waitForExistence(timeout: 15))
        shoot(app, "00-today-start")
        copy.tap()
        let latest = app.buttons.matching(NSPredicate(format: "label CONTAINS '槓鈴硬舉' OR label CONTAINS '個動作'")).firstMatch
        if latest.waitForExistence(timeout: 5) { latest.tap() } else { app.cells.firstMatch.tap() }
        sleep(2)
        shoot(app, "01-today-plan")

        app.buttons["歷史"].tap()
        sleep(2)
        shoot(app, "02-history")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS '槓鈴背蹲' OR label CONTAINS '槓鈴硬舉' OR label CONTAINS '個動作'")).firstMatch
        if row.waitForExistence(timeout: 5) { row.tap() } else { app.cells.firstMatch.tap() }
        XCTAssertTrue(app.otherElements["training-energy-report"].waitForExistence(timeout: 8) || app.staticTexts["運動消耗"].waitForExistence(timeout: 2))
        shoot(app, "03-session-detail")
        app.swipeUp()
        shoot(app, "04-session-detail-lower")

        app.buttons["個人信息"].tap()
        sleep(2)
        shoot(app, "05-profile")
        app.swipeUp()
        shoot(app, "06-profile-lower")

        app.buttons["動作庫"].tap()
        sleep(2)
        shoot(app, "07-library")
    }
}
