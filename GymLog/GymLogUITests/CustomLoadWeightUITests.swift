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
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (input.value as? String ?? "").count) + "21")
        app.buttons["picker-sheet-done-button"].tap()
        XCTAssertTrue(load.label.contains("21"))
        load.tap()
        let wheel = app.pickerWheels.firstMatch
        XCTAssertTrue(wheel.waitForExistence(timeout: 5))
        XCTAssertEqual(wheel.value as? String, "21")
        wheel.adjust(toPickerWheelValue: "20")
        app.buttons["picker-sheet-done-button"].tap()
        load.tap()
        wheel.adjust(toPickerWheelValue: "21")
        XCTAssertEqual(wheel.value as? String, "21")
        app.buttons["picker-sheet-done-button"].tap()
        XCTAssertTrue(load.label.contains("21"))
    }
    func testBandCanUsePoundsAndCancelPreservesSelection() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        XCTAssertTrue(app.buttons["start-empty-session-button"].waitForExistence(timeout: 10))
        app.buttons["start-empty-session-button"].tap()
        app.buttons["add-exercise-button"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Chin up w/band")
        let row = app.buttons["exercise-row-ex-5eacc80a"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        let load = app.buttons["entry-load-button"].firstMatch
        XCTAssertTrue(load.waitForExistence(timeout: 5)); load.tap()
        app.segmentedControls["load-kind-switch"].buttons.element(boundBy: 1).tap()
        XCTAssertEqual(app.pickerWheels.count, 2)
        app.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: "lb")
        let input = app.textFields["custom-load-input"]
        input.tap()
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (input.value as? String ?? "").count) + "21.25")
        app.buttons["picker-sheet-done-button"].tap()
        XCTAssertTrue(load.label.contains("21.25lb"), load.label)
        load.tap()
        XCTAssertEqual(app.pickerWheels.element(boundBy: 1).value as? String, "lb")
        XCTAssertEqual(app.pickerWheels.firstMatch.value as? String, "21.25")
        app.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: "kg")
        app.buttons["load-picker-cancel"].tap()
        XCTAssertTrue(load.label.contains("21.25lb"), load.label)
        load.tap()
        app.segmentedControls["load-kind-switch"].buttons.element(boundBy: 0).tap()
        app.buttons["custom-band-button"].tap()
        let color = app.textFields["custom-band-color"]
        color.tap()
        color.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (color.value as? String ?? "").count) + "orange")
        app.buttons["picker-sheet-done-button"].tap()
        XCTAssertTrue(load.label.contains("Orange") || load.label.contains("橙"))
    }

    func testTraditionalChineseBandLabelsAndNumericShortcut() {
        verifyBandLanguage("zhHant", expectedColor: "藍＋綠", expectedLoad: "藍＋綠彈力帶")
    }

    func testEnglishBandLabelsAndNumericShortcut() {
        verifyBandLanguage("en", expectedColor: "Blue + Green", expectedLoad: "Blue + Green Band")
    }

    private func verifyBandLanguage(_ language: String, expectedColor: String, expectedLoad: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-appLanguage", language, "-appTheme", language == "en" ? "dark" : "light"]
        app.launch()
        XCTAssertTrue(app.buttons["start-empty-session-button"].waitForExistence(timeout: 10))
        app.buttons["start-empty-session-button"].tap()
        app.buttons["add-exercise-button"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Pull up w/band")
        let row = app.buttons["exercise-row-ex-3f78b44b"]
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        let load = app.buttons["entry-load-button"].firstMatch
        XCTAssertTrue(load.waitForExistence(timeout: 5)); load.tap()
        app.segmentedControls["load-kind-switch"].buttons.element(boundBy: 0).tap()
        app.buttons["custom-band-button"].tap()
        let field = app.textFields["custom-band-color"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count) + "blue+green")
        // Preserve in-progress keystrokes; localization is checked after commit/reopen.
        app.buttons["picker-sheet-done-button"].tap()
        XCTAssertEqual(load.label, expectedLoad)
        load.tap()
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Compact band wheel \(language)"; preview.lifetime = .keepAlways; add(preview)
        XCTAssertFalse(app.buttons["load-type-picker"].exists)
        XCTAssertFalse(app.textFields["custom-band-color"].exists)
        app.buttons["custom-band-button"].tap()
        XCTAssertEqual(app.textFields["custom-band-color"].value as? String, expectedColor)
        let wheelValue = app.pickerWheels.firstMatch.value as? String ?? ""
        if language == "zhHant" {
            XCTAssertNil(wheelValue.range(of: "[A-Za-z]", options: .regularExpression))
        } else {
            XCTAssertNil(wheelValue.range(of: "[一-鿿]", options: .regularExpression))
        }
        app.segmentedControls["load-kind-switch"].buttons.element(boundBy: 1).tap()
        XCTAssertEqual(app.pickerWheels.count, 2)
        let numericPreview = XCTAttachment(screenshot: app.screenshot())
        numericPreview.name = "Precision numeric wheel \(language)"; numericPreview.lifetime = .keepAlways; add(numericPreview)
        app.pickerWheels.firstMatch.adjust(toPickerWheelValue: "30")
        app.buttons["picker-sheet-done-button"].tap()
        XCTAssertEqual(load.label, "30kg")
    }

    func testBodyweightUsesSmallNumericWheelAndReturnsToBodyweight() {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["-uiTesting", "-appLanguage", "en"]; app.launch()
        XCTAssertTrue(app.buttons["start-empty-session-button"].waitForExistence(timeout: 10))
        app.buttons["start-empty-session-button"].tap(); app.buttons["add-exercise-button"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Weighted chin-up")
        let exercise = app.buttons["exercise-row-ex-ab63a873"]
        XCTAssertTrue(exercise.waitForExistence(timeout: 5)); exercise.tap()
        let load = app.buttons["entry-load-button"].firstMatch
        XCTAssertTrue(load.waitForExistence(timeout: 5)); load.tap()
        XCTAssertFalse(app.buttons["load-type-picker"].exists)
        XCTAssertEqual(app.pickerWheels.count, 2)
        app.pickerWheels.firstMatch.adjust(toPickerWheelValue: "10")
        app.buttons["picker-sheet-done-button"].tap()
        XCTAssertEqual(load.label, "10kg")
        load.tap(); app.pickerWheels.firstMatch.adjust(toPickerWheelValue: "Bodyweight")
        app.buttons["picker-sheet-done-button"].tap()
        XCTAssertEqual(load.label, "Bodyweight")
    }

}
