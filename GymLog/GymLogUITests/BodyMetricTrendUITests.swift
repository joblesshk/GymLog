import XCTest
import CoreGraphics

final class BodyMetricTrendUITests: XCTestCase {
    func testRecentSixTrendSwitchesAcrossAllBodyMetrics() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestingBodyMetrics"]
        app.launch()

        let profileTab = app.buttons["個人信息"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 15))
        profileTab.tap()

        let latestTitle = app.staticTexts["最近 6 次量測"]
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
            XCTAssertTrue(app.staticTexts["最近 6 次量測"].exists)
            let visibleChart = scrollChartAboveBottomTab(tab: profileTab, in: app)
            XCTAssertGreaterThan(profileTab.frame.minY, visibleChart.frame.maxY, "trend chart and date axis must be above the floating tab")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = attachmentName
            attachment.lifetime = .keepAlways
            add(attachment)
        }
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
