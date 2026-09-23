import XCTest

final class TrainingInsightsUITests: XCTestCase {
    func testEnglishExerciseLibraryKeepsChineseOnlyAsNameSubtitle() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-appLanguage", "en"]
        app.launch()

        XCTAssertTrue(app.buttons["Exercises"].waitForExistence(timeout: 15))
        app.buttons["Exercises"].tap()
        let primary = app.staticTexts["library-exercise-name-primary"].firstMatch
        let secondary = app.staticTexts["library-exercise-name-secondary"].firstMatch
        let metadata = app.staticTexts["library-exercise-metadata"].firstMatch
        XCTAssertTrue(primary.waitForExistence(timeout: 8))
        XCTAssertTrue(secondary.exists)
        XCTAssertTrue(metadata.exists)
        XCTAssertLessThan(primary.frame.minY, secondary.frame.minY)
        XCTAssertFalse(metadata.label.range(of: "[\\u{3400}-\\u{9FFF}]", options: .regularExpression) != nil)
        let descriptions = app.staticTexts.matching(identifier: "library-exercise-notes").allElementsBoundByIndex
        XCTAssertFalse(descriptions.isEmpty)
        XCTAssertTrue(descriptions.allSatisfy { !$0.label.isEmpty })
        XCTAssertFalse(descriptions.contains { $0.label.range(of: "[\\u{3400}-\\u{9FFF}]", options: .regularExpression) != nil })
    }

    func testApprovedProfileHistoryAndLibraryHierarchyRemainsReachable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestingReviewedSession", "-uiTestingBodyMetrics", "-appLanguage", "zhHant"]
        app.launch()

        let profileTab = app.buttons["個人信息"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 15)); profileTab.tap()
        XCTAssertFalse(app.buttons["global-voice-button"].exists)
        XCTAssertTrue(app.otherElements["profile-summary-card"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["profile-edit-button"].exists)
        let bodyHistoryToggle = app.buttons["profile-body-history-toggle"]
        for _ in 0..<6 where !bodyHistoryToggle.exists { app.swipeUp() }
        XCTAssertTrue(bodyHistoryToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(bodyHistoryToggle.value as? String, "3")
        bodyHistoryToggle.tap()
        // 展開後按鈕被 8 條記錄推到畫面外，懶加載列表需要先滾回可見範圍。
        for _ in 0..<6 where !bodyHistoryToggle.exists || !bodyHistoryToggle.isHittable { app.swipeUp() }
        XCTAssertEqual(bodyHistoryToggle.label, "收起")
        XCTAssertEqual(bodyHistoryToggle.value as? String, "8")
        bodyHistoryToggle.tap()
        for _ in 0..<6 where !bodyHistoryToggle.exists { app.swipeDown() }
        XCTAssertEqual(bodyHistoryToggle.value as? String, "3")
        let profileShot = XCTAttachment(screenshot: app.screenshot()); profileShot.name = "Astra profile page"; profileShot.lifetime = .keepAlways; add(profileShot)

        let editors = [
            ("profile-basic-info-button", "profile-basic-editor", "基本信息"),
            ("profile-training-goals-button", "profile-training-editor", "訓練目標"),
            ("profile-habits-medical-button", "profile-habits-editor", "習慣與病史")
        ]
        for (buttonID, editorID, title) in editors {
            for _ in 0..<6 where !app.buttons[buttonID].exists { app.swipeUp() }
            XCTAssertTrue(app.buttons[buttonID].waitForExistence(timeout: 5))
            // The floating tab bar covers the bottom of the list; a tap there
            // lands on a tab instead of the button.
            for _ in 0..<6 where app.buttons[buttonID].frame.maxY > app.frame.height * 0.8 {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
            }
            app.buttons[buttonID].tap()
            XCTAssertTrue(app.descendants(matching: .any)[editorID].waitForExistence(timeout: 5))
            XCTAssertTrue(app.navigationBars[title].exists)
            XCTAssertTrue(app.buttons["保存資料"].exists)
            app.buttons["關閉"].tap()
            XCTAssertTrue(app.buttons[buttonID].waitForExistence(timeout: 5))
        }

        let historyTab = app.buttons["歷史"]
        XCTAssertTrue(historyTab.exists); historyTab.tap()
        XCTAssertFalse(app.buttons["global-voice-button"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["history-scroll-content"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["history-page-header"].exists)
        XCTAssertTrue(app.otherElements["history-monthly-volume-card"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["history-tools-menu"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history-session-'")).firstMatch.exists)

        XCTAssertTrue(app.staticTexts["history-session-primary-title"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["history-session-metadata"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["history-session-secondary-metrics"].firstMatch.exists)

        let historyShot = XCTAttachment(screenshot: app.screenshot()); historyShot.name = "Astra history session card hierarchy"; historyShot.lifetime = .keepAlways; add(historyShot)

        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history-session-'" )).firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["session-detail-scroll"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["session-detail-header"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["session-detail-summary"].exists)
        let detailShot = XCTAttachment(screenshot: app.screenshot()); detailShot.name = "Astra session detail summary and sets"; detailShot.lifetime = .keepAlways; add(detailShot)

        for _ in 0..<5 where !app.staticTexts["槓鈴背蹲"].exists {
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["槓鈴背蹲"].exists)
        let chinesePrimary = app.staticTexts["session-detail-exercise-primary"].firstMatch
        let englishSecondary = app.staticTexts["session-detail-exercise-secondary"].firstMatch
        XCTAssertEqual(chinesePrimary.label, "槓鈴背蹲")
        XCTAssertEqual(englishSecondary.label, "Back squat")
        XCTAssertLessThan(chinesePrimary.frame.minY, englishSecondary.frame.minY)
        XCTAssertTrue(app.staticTexts["第 1 組"].firstMatch.exists)
        for _ in 0..<5 where !app.staticTexts["— 未記錄"].exists {
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["— 未記錄"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["history-tools-menu"].waitForExistence(timeout: 5))

        let libraryTab = app.buttons["動作庫"]
        XCTAssertTrue(libraryTab.exists); libraryTab.tap()
        XCTAssertFalse(app.buttons["global-voice-button"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["library-mode-picker"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["library-scroll-content"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["library-page-header"].exists)
        XCTAssertTrue(app.textFields["library-search-field"].exists)
        XCTAssertTrue(app.scrollViews["library-filter-chips"].exists)
        XCTAssertTrue(app.buttons["library-add-exercise-button"].exists)
        XCTAssertTrue(app.buttons["library-filter-menu"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library-exercise-'")).firstMatch.exists)
        let libraryShot = XCTAttachment(screenshot: app.screenshot()); libraryShot.name = "Astra library page"; libraryShot.lifetime = .keepAlways; add(libraryShot)
    }

    func testEnglishExerciseNamesLeadTodayPickerAndHistoryDetail() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestingReviewedSession", "-appLanguage", "en"]
        app.launch()

        XCTAssertTrue(app.buttons["History"].waitForExistence(timeout: 15)); app.buttons["History"].tap()
        let session = app.buttons["history-session-ui-test-reviewed"]
        XCTAssertTrue(session.waitForExistence(timeout: 5)); session.tap()
        let detailPrimary = app.staticTexts["session-detail-exercise-primary"].firstMatch
        let detailSecondary = app.staticTexts["session-detail-exercise-secondary"].firstMatch
        for _ in 0..<4 where !detailPrimary.exists { app.swipeUp() }
        XCTAssertTrue(detailPrimary.waitForExistence(timeout: 5))
        XCTAssertEqual(detailPrimary.label, "Back squat")
        XCTAssertEqual(detailSecondary.label, "槓鈴背蹲")
        XCTAssertLessThan(detailPrimary.frame.minY, detailSecondary.frame.minY)

        app.buttons["Today"].tap()
        let start = app.buttons["start-empty-session-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 5)); start.tap()
        let add = app.buttons["add-exercise-button"]
        XCTAssertTrue(add.waitForExistence(timeout: 5)); add.tap()
        let pickerPrimary = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'exercise-picker-name-primary-'" )).firstMatch
        let pickerSecondary = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'exercise-picker-name-secondary-'" )).firstMatch
        XCTAssertTrue(pickerPrimary.waitForExistence(timeout: 8))
        XCTAssertTrue(pickerSecondary.exists)
        XCTAssertLessThan(pickerPrimary.frame.minY, pickerSecondary.frame.minY)
        let selectedPrimary = pickerPrimary.label
        let selectedSecondary = pickerSecondary.label
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'exercise-row-'" )).firstMatch.tap()
        let entryPrimary = app.staticTexts["entry-exercise-name-primary"]
        let entrySecondary = app.staticTexts["entry-exercise-name-secondary"]
        XCTAssertTrue(entryPrimary.waitForExistence(timeout: 5))
        XCTAssertEqual(entryPrimary.label, selectedPrimary)
        XCTAssertEqual(entrySecondary.label, selectedSecondary)
        XCTAssertLessThan(entryPrimary.frame.minY, entrySecondary.frame.minY)
    }

    func testTodayKeepsSessionControlsAndBalancesSecondaryActions() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        XCTAssertTrue(app.buttons["global-voice-button"].waitForExistence(timeout: 15))
        let start = app.buttons["start-empty-session-button"]
        XCTAssertTrue(start.waitForExistence(timeout: 15)); start.tap()

        XCTAssertTrue(app.buttons["rest-timer-pill"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["heart-rate-control"].waitForExistence(timeout: 5))

        let finish = app.buttons["finish-session-button"]
        let save = app.buttons["save-draft-button"]
        let discard = app.buttons["discard-session-button"]
        for _ in 0..<6 where !finish.exists || !save.exists || !discard.exists {
            app.swipeUp()
        }
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        XCTAssertEqual(save.frame.width, discard.frame.width, accuracy: 1.0)
        XCTAssertEqual(save.frame.midY, discard.frame.midY, accuracy: 1.0)
        XCTAssertLessThan(save.frame.maxX, discard.frame.minX)
        XCTAssertEqual(save.frame.midX + discard.frame.midX, finish.frame.midX * 2, accuracy: 2.0)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Today balanced session actions"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSettingsRetainsThemeTextAndPreviewGraphics() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        let settings = app.buttons["設置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15)); settings.tap()
        XCTAssertFalse(app.buttons["global-voice-button"].exists)

        for label in ["跟隨系統", "淺色", "深色"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 5), "missing theme text option: \(label)")
        }
        XCTAssertTrue(app.otherElements["淺色外觀預覽"].exists)
        XCTAssertTrue(app.otherElements["深色外觀預覽"].exists)

        app.buttons["深色"].tap()
        XCTAssertEqual(app.otherElements["深色外觀預覽"].value as? String, "已選取")
        let dark = XCTAttachment(screenshot: app.screenshot())
        dark.name = "Settings dark appearance with previews"
        dark.lifetime = .keepAlways
        add(dark)

        app.buttons["淺色"].tap()
        XCTAssertEqual(app.otherElements["淺色外觀預覽"].value as? String, "已選取")
        let light = XCTAttachment(screenshot: app.screenshot())
        light.name = "Settings light appearance with previews"
        light.lifetime = .keepAlways
        add(light)
    }

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

        XCTAssertTrue(app.staticTexts["entry-exercise-name-primary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["entry-exercise-name-secondary"].exists, "seeded bilingual exercises should use a stacked secondary English name")
        XCTAssertFalse(app.staticTexts["entry-summary-line"].exists, "the old round/rest/kcal summary line should be removed")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'entry-round-field-'" )).firstMatch.waitForExistence(timeout: 5))

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
        app.launchArguments = ["-uiTesting", "-uiTestingReviewedSession", "-uiTestingBodyMetrics", "-uiTestingBodyMetricHistory"]
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
        // 用哪個體重取決於測試當天與種子體測日期的先後，只檢查卡片有說明來源。
        let weightSource = app.staticTexts["energy-weight-source"]
        XCTAssertTrue(weightSource.exists && weightSource.label.hasPrefix("按體重"), "energy card should say which body weight it used")
        XCTAssertNil(weightSource.label.range(of: "[A-Za-z]{3} \\d", options: .regularExpression), "Chinese UI must not show an English date: \(weightSource.label)")
        app.buttons["energy-breakdown-toggle"].tap()
        XCTAssertTrue(app.staticTexts["Bench press"].waitForExistence(timeout: 3))
        let lower = XCTAttachment(screenshot: app.screenshot()); lower.name = "History insight cards expanded"; lower.lifetime = .keepAlways; add(lower)
    }
}
