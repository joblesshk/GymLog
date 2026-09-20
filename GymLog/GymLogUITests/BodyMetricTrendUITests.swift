import XCTest
import CoreGraphics

final class BodyMetricTrendUITests: XCTestCase {
    func testRecentTrendSwitchesAcrossAllBodyMetrics() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestingBodyMetrics"]
        app.launch()

        let profileTab = app.buttons["個人信息"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 15))
        profileTab.tap()

        let latestTitle = app.staticTexts["最近 8 次量測"]
        let historyTitle = app.staticTexts["歷史記錄 · 8"]
        // Discover the lower history section itself. The trend title can
        // enter the accessibility tree one viewport before the history
        // heading, so it is not a sufficient stop condition here.
        for _ in 0..<6 where !historyTitle.exists {
            app.swipeUp()
        }
        if !historyTitle.exists {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Trend discover failure"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(historyTitle.waitForExistence(timeout: 8))
        XCTAssertTrue(latestTitle.waitForExistence(timeout: 8))

        let chart = trendChart(in: app)
        XCTAssertTrue(chart.waitForExistence(timeout: 8))
        let visibleChart = scrollChartAboveBottomTab(tab: profileTab, in: app)
        XCTAssertGreaterThan(profileTab.frame.minY, visibleChart.frame.maxY, "trend chart and date axis must be above the floating tab")

        let metrics = [("體重", "Weight trend"), ("體脂率", "Body-fat trend"), ("骨骼肌量", "Skeletal-muscle trend")]
        for (label, attachmentName) in metrics {
            let button = app.buttons[label]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "missing body metric switch (label)")
            button.tap()
            XCTAssertTrue(app.staticTexts["最近 8 次量測"].exists)
            let visibleChart = scrollChartAboveBottomTab(tab: profileTab, in: app)
            XCTAssertGreaterThan(profileTab.frame.minY, visibleChart.frame.maxY, "trend chart and date axis must be above the floating tab")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = attachmentName
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testSelectionAndHorizontalHistoryScrolling() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestingBodyMetrics", "-uiTestingBodyMetricHistory"]
        app.launch()
        let profile = app.buttons["個人信息"]
        XCTAssertTrue(profile.waitForExistence(timeout: 15))
        profile.tap()
        for _ in 0..<7 where !trendChart(in: app).exists { app.swipeUp() }
        let chart = scrollChartAboveBottomTab(tab: profile, in: app)
        XCTAssertTrue(app.staticTexts["最近 12 次量測"].exists)
        XCTAssertTrue(app.staticTexts["body-metric-axis-unit"].exists)
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        let selection = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "body-metric-selected-ui-bm-")).firstMatch
        XCTAssertTrue(selection.waitForExistence(timeout: 5))
        XCTAssertNotEqual(selection.identifier, "body-metric-selected-ui-bm-16")
        let index = Int(selection.identifier.suffix(2))!
        if index >= 9 {
            XCTAssertEqual(app.staticTexts["body-metric-selected-weight"].label, "\(60 + index).0 kg")
            XCTAssertEqual(app.staticTexts["body-metric-selected-fat"].label, "\(10 + index).0 %")
            XCTAssertEqual(app.staticTexts["body-metric-selected-muscle"].label, "\(20 + index).0 kg")
        }
        let before = selection.identifier
        // Earlier records lie to the left: drag the plot towards the right.
        chart.swipeRight()
        let title = app.staticTexts["body-metric-window-label"]
        let moved = NSPredicate(format: "label != %@", "最近 12 次量測")
        expectation(for: moved, evaluatedWith: title)
        waitForExpectations(timeout: 5)
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.45)).tap()
        XCTAssertNotEqual(selection.identifier, before)
        XCTAssertLessThanOrEqual(Int(selection.identifier.suffix(2))!, 5)
        let historicalID = selection.identifier
        for name in ["體脂率", "骨骼肌量"] {
            app.buttons[name].tap()
            XCTAssertTrue(selection.exists)
            XCTAssertEqual(selection.identifier, historicalID)
        }
        if historicalID == "body-metric-selected-ui-bm-03" {
            XCTAssertEqual(app.staticTexts["body-metric-selected-weight"].label, "69.0 kg")
            XCTAssertEqual(app.staticTexts["body-metric-selected-fat"].label, "21.5 %")
            XCTAssertEqual(app.staticTexts["body-metric-selected-muscle"].label, "—")
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Historical selection with numeric axis"
        attachment.lifetime = .keepAlways
        add(attachment)
        chart.swipeLeft()
        expectation(for: NSPredicate(format: "label == %@", "最近 12 次量測"), evaluatedWith: title)
        waitForExpectations(timeout: 5)
    }

    private func trendChart(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "body-metric-trend-chart")
            .firstMatch
    }

    @discardableResult
    private func scrollChartAboveBottomTab(tab: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        var lastMoveWasUp = true
        for _ in 0..<10 {
            let chart = trendChart(in: app)
            guard chart.exists else {
                // A previous small drag can still move an accessibility node
                // out of the tree during SwiftUI re-layout. Reverse once and
                // reacquire it instead of issuing another full-screen swipe.
                drag(app: app, upwards: !lastMoveWasUp, distance: 80)
                lastMoveWasUp.toggle()
                continue
            }

            let chartFrame = chart.frame
            let tabTop = tab.frame.minY
            if chartFrame.minY >= 0, chartFrame.maxY + 8 < tabTop {
                return chart
            }

            let upwards = chartFrame.maxY >= tabTop
            let distance = upwards
                ? min(max(chartFrame.maxY - tabTop + 20, 20), 150)
                : min(max(-chartFrame.minY + 20, 20), 150)
            drag(app: app, upwards: upwards, distance: distance)
            lastMoveWasUp = upwards
        }
        return trendChart(in: app)
    }

    private func drag(app: XCUIApplication, upwards: Bool, distance: CGFloat) {
        let window = app.windows.firstMatch
        let frame = window.frame
        let halfDistance = min(distance / 2, frame.height * 0.25)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let startY = upwards ? center.y + halfDistance : center.y - halfDistance
        let endY = upwards ? center.y - halfDistance : center.y + halfDistance
        let start = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.5,
            dy: (startY - frame.minY) / frame.height
        ))
        let end = window.coordinate(withNormalizedOffset: CGVector(
            dx: 0.5,
            dy: (endY - frame.minY) / frame.height
        ))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
}
