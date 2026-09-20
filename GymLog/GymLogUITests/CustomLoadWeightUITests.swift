import XCTest

final class CustomLoadWeightUITests: XCTestCase {
    func testDBRowManual21KgAndReselectAfterPreset() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        XCTAssertTrue(app.buttons["start-empty-session-button"].waitForExistence(timeout: 10))
        app.buttons["start-empty-session-button"].tap()
        app.buttons["add-exercise-button"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("DB row")
        let row = app.buttons["exercise-row-ex-96deeca2"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let load = app.buttons["entry-load-button"].firstMatch
        XCTAssertTrue(load.waitForExistence(timeout: 5))
        load.tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Expanded wheel and compact inline input"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let input = app.textFields["custom-load-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(input.isHittable)
        input.tap()
        input.typeText("21")
        app.buttons["picker-sheet-done-button"].tap()
        XCTAssertTrue(load.label.contains("21"))
        load.tap()
        let wheel = app.pickerWheels.firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        XCTAssertEqual(wheel.value as? String, "21kg")
        wheel.adjust(toPickerWheelValue: "20kg")
        app.buttons["picker-sheet-done-button"].tap()
        load.tap()
        wheel.adjust(toPickerWheelValue: "21kg")
        XCTAssertEqual(wheel.value as? String, "21kg")
        app.buttons["picker-sheet-done-button"].tap()
        XCTAssertTrue(load.label.contains("21"))
    }
}
