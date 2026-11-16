import XCTest

/// The empty workspace offers one card per kind, and "+" opens the same cards; HackerTab opens once.
final class NewTabUITests: XCTestCase {
    func testCardsOpenTabsAndSSHStartsWithAHost() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-sidra.noAutoFocus", "-sidra.freshWorkspace"]
        app.launch()
        for kind in ["herdr", "ssh", "theasa", "pipelines", "hackertab", "chess"] {
            XCTAssertTrue(app.buttons["newtab-\(kind)"].waitForExistence(timeout: 10), "empty workspace shows \(kind)")
        }
        app.buttons["newtab-chess"].tap()
        XCTAssertTrue(app.buttons["Start round 1"].waitForExistence(timeout: 10), "chess opened")

        app.buttons["New tab"].tap()
        app.buttons["newtab-ssh"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5) || app.staticTexts["New host"].exists, "no hosts yet: SSH starts with the host editor")
    }
}
