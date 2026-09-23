import XCTest

/// Deterministic UI transport fixture; live providers are tested separately in the evidence report.
final class VoiceCommandTextEntryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    func launch() -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["-uiTesting", "-cloudVoiceUITesting"]
        app.launch(); XCTAssertTrue(app.buttons["start-empty-session-button"].waitForExistence(timeout: 15))
        return app
    }
    func open(_ app: XCUIApplication) {
        app.buttons["global-voice-button"].tap()
        XCTAssertTrue(app.buttons["voice-command-mic-button"].waitForExistence(timeout: 5))
    }
    func textField(_ app: XCUIApplication) -> XCUIElement {
        if app.buttons["cloud-voice-show-text"].exists { app.buttons["cloud-voice-show-text"].tap() }
        let view = app.textViews["voice-command-text-field"]
        return view.exists ? view : app.textFields["voice-command-text-field"]
    }
    func testCloudPanelAvailableBeforeSessionAndTextIsSecondary() {
        let app = launch(); open(app)
        XCTAssertTrue(app.staticTexts["voice-command-target-bar"].exists)
        XCTAssertTrue(app.buttons["cloud-voice-show-text"].exists)
        XCTAssertFalse(app.textViews["voice-command-text-field"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Cloud voice initial panel"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testMultiExercisePlanAndWholeUtteranceUndo() {
        let app = launch(); open(app)
        let field = textField(app); field.tap(); field.typeText("Create test plan")
        app.buttons["voice-command-submit-button"].tap()
        XCTAssertTrue(app.buttons["voice-command-undo-button"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "已完成 3")).firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Cloud voice applied plan"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["voice-command-undo-button"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "已撤銷上一句")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["start-empty-session-button"].waitForExistence(timeout: 5))
    }
    func testAmbiguityAppliesInferredPlanWithUndo() {
        let app = launch(); open(app)
        let field = textField(app); field.tap(); field.typeText("Which row")
        app.buttons["voice-command-submit-button"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "推斷：")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.segmentedControls["voice-language-mode-picker"].exists)
        XCTAssertTrue(app.buttons["voice-command-undo-button"].exists)
        app.buttons["voice-command-undo-button"].tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["start-empty-session-button"].waitForExistence(timeout: 5))
    }
    func testVoiceEntryShownOnlyOnToday() {
        let app = launch()
        app.buttons["動作庫"].tap()
        XCTAssertTrue(app.textFields["library-search-field"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["global-voice-button"].exists)
        app.buttons["今天"].tap(); open(app)
        XCTAssertTrue(app.buttons["voice-command-mic-button"].exists)
    }
    func testSettingsNeedsNoProviderCredentials() {
        let app = launch(); open(app)
        let link = app.buttons["cloud-voice-settings-link"]
        app.swipeUp(); XCTAssertTrue(link.waitForExistence(timeout: 5)); link.tap()
        XCTAssertTrue(app.buttons["cloud-voice-check-connection"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.secureTextFields["Access Token"].exists)
        XCTAssertFalse(app.secureTextFields["API Key"].exists)
    }
}
