import XCTest

/// Adds a mosh-compatible host through Settings and opens a pane on it. Needs a container on
/// localhost:2223 with udp 60100-60110 published; skips when the host key step never comes.
final class SSHMoshUITests: XCTestCase {
    func testMoshPaneOpensAndShowsItsChip() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-sidra.noAutoFocus", "-sidra.freshWorkspace"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Sidra menu"].waitForExistence(timeout: 20))
        app.buttons["Sidra menu"].tap()
        app.buttons["Settings…"].tap()
        let add = app.buttons["Add host"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()

        func type(_ field: XCUIElement, _ text: String) { XCTAssertTrue(field.waitForExistence(timeout: 3)); field.tap(); field.typeText(text) }
        type(app.textFields["Alias"], "moshtest")
        type(app.textFields["Host"], "localhost")
        let port = app.textFields["Port"]
        port.tap(); port.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "2222")
        type(app.textFields["User"], "sidra")
        app.buttons["Password"].firstMatch.tap()
        type(app.secureTextFields.firstMatch, "sidra")
        let toggle = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Use a mosh-compatible'")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        toggle.tap()
        let ports = app.textFields["UDP ports"]
        XCTAssertTrue(ports.waitForExistence(timeout: 3))
        ports.tap(); ports.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 11) + "60000:60010")
        app.buttons["Save"].tap()
        sleep(1)
        app.buttons["Done"].firstMatch.tap()
        sleep(1)

        app.buttons["New tab"].tap()
        app.buttons["newtab-ssh"].firstMatch.tap()
        let entry = app.buttons["newtab-host-moshtest"]
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.tap()
        let trust = app.buttons["Trust this host"]
        if trust.waitForExistence(timeout: 8) { trust.tap() }
        let chip = app.staticTexts["mosh-compatible"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "footer says what this pane is")
        sleep(4)
        XCTAssertFalse(app.staticTexts["Connection lost"].exists, "the UDP path answered")
        let h = app.staticTexts["moshtest"].firstMatch.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: h.minX + 120, dy: h.maxY + 80)).tap()
        sleep(1)
        app.typeText("echo mosh$((40+2)) && stty size\n")
        sleep(3)
        if let base = ProcessInfo.processInfo.environment["SIDRA_SHOT_PATH"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: base).deletingPathExtension().appendingPathExtension("mosh.png"))
        }
    }
}
