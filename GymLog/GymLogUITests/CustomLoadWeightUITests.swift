import XCTest

final class CustomLoadWeightUITests: XCTestCase {
    func testDoneRecordsUnchangedActualAndClearKeepsItUnrecorded() {
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
        let exercise = app.buttons["exercise-row-ex-96deeca2"]
        XCTAssertTrue(exercise.waitForExistence(timeout: 5))
        exercise.tap()
        let unrecorded = app.buttons["entry-round-unrecorded-actual"].firstMatch
        XCTAssertTrue(unrecorded.waitForExistence(timeout: 5))
        unrecorded.tap()
        XCTAssertTrue(app.pickerWheels.firstMatch.waitForExistence(timeout: 5))
        // Do not move the wheel: confirming the displayed default must record it.
        app.buttons["picker-sheet-done-button"].tap()
        let actual = app.buttons["entry-round-field-actual"].firstMatch
        XCTAssertTrue(actual.waitForExistence(timeout: 5))
        actual.tap()
        let clear = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "清除實際成績", "Clear result")).firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertTrue(unrecorded.waitForExistence(timeout: 5))
    }

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
