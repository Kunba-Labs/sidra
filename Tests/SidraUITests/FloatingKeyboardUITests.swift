import XCTest

/// Sidra's floating keyboard (ported from sidra-full, 2026-11-19) replaces Apple's in a terminal, collapses
/// to a keyboard button beside the mic and comes back. -sidra.softKeyboard because the Simulator reports
/// the Mac's keyboard as a hardware keyboard, which hides the floating one.
final class FloatingKeyboardUITests: XCTestCase {
    func testKeyboardShowsHidesAndReturns() {
        let app = XCUIApplication()
        app.launchArguments = ["-sidra.demo", "-sidra.freshWorkspace", "-sidra.noAutoFocus", "-sidra.onboarded", "YES",
                               "-sidra.softKeyboard", "-sidra.floatingKeyboard", "YES", "-sidra.floatingKeyboardCollapsed", "NO"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(4)
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])   // the Simulator drops the first hardware key after launch
        app.typeKey("2", modifierFlags: .command)                        // the demo's SSH shell
        sleep(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4)).tap()   // focus the shell
        XCTAssertTrue(app.buttons["return"].waitForExistence(timeout: 5), "the floating keyboard appears instead of Apple's")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Apple's keyboard stays away")
        for k in ["l", "s"] { app.buttons[k].firstMatch.tap() }
        shot("floating-keyboard")
        app.buttons["⌄"].firstMatch.tap()   // the hide key
        let show = app.buttons["Show Sidra keyboard"]
        XCTAssertTrue(show.waitForExistence(timeout: 3), "collapsed: the keyboard button sits beside the mic")
        shot("floating-keyboard-collapsed")
        show.tap()
        XCTAssertTrue(app.buttons["return"].waitForExistence(timeout: 3), "the button brings the keys back")
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["SIDRA_SHOT_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
