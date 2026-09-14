import XCTest

final class TrainingInsightsUITests: XCTestCase {
    func testTodayEnergyPanelAndExerciseDisclosure() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        let start = app.buttons["start-empty-session-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 15)); start.tap()
        XCTAssertTrue(app.staticTexts["運動消耗估算"].waitForExistence(timeout: 5))
        let addButton = app.buttons["add-exercise-button"]
        for _ in 0..<4 { if addButton.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(addButton.waitForExistence(timeout: 5)); addButton.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'exercise-row-' ")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8));row.tap()
        for _ in 0..<4 { if app.staticTexts["運動消耗估算"].isHittable { break }; app.swipeDown() }
        let disclosure = app.buttons["各動作及計算依據"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 8));disclosure.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '規則'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '記錄 0/3'")).firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot());attachment.name = "Training energy panel";attachment.lifetime = .keepAlways;add(attachment)
    }
}
