import XCTest

/// The top bar hides into the orb: tap lists tabs, tap-and-hold fans them out and the one let go on
/// opens, Show bar brings the bar back (so the next test starts with it).
final class FloatingOrbUITests: XCTestCase {
    func testHideTapHoldShow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-sidra.noAutoFocus", "-sidra.freshWorkspace", "-sidra.onboarded", "YES"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let hide = app.buttons["hide-bar"]
        let orb = app.descendants(matching: .any)["tab-orb"]
        // A run that failed midway leaves the bar hidden (it persists): bring it back first.
        if !hide.waitForExistence(timeout: 15), orb.exists { orb.tap(); app.buttons["show-bar"].tap() }
        XCTAssertTrue(hide.waitForExistence(timeout: 10))
        hide.tap()
        XCTAssertTrue(orb.waitForExistence(timeout: 5), "the bar collapses into the orb")
        XCTAssertFalse(hide.exists)
        shot("orb-rest")

        orb.tap()
        XCTAssertTrue(app.buttons["show-bar"].waitForExistence(timeout: 5), "tap opens the dropdown")
        shot("orb-tap")
        app.buttons["Add serial pattern switch"].firstMatch.tap()
        XCTAssertTrue(orb.label.contains("Add serial pattern switch"), "picking a tab shows it: \(orb.label)")

        // Hold and slide down-left along the fan to the first tab (90°, straight down from the orb).
        let start = orb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.6, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 170)))
        sleep(1)
        XCTAssertFalse(orb.label.contains("Add serial pattern switch"), "letting go on another tab shows it: \(orb.label)")

        orb.tap()
        app.buttons["show-bar"].tap()
        XCTAssertTrue(hide.waitForExistence(timeout: 5), "Show bar brings the bar back")
    }

    private func shot(_ name: String) {
        if let dir = ProcessInfo.processInfo.environment["SIDRA_SHOT_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
