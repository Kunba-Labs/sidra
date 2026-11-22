import XCTest

/// A screenshot of every first-run screen and every demo tab, for a layout check at phone width.
/// Writes PNGs to SIDRA_SHOT_DIR; skipped without it.
final class PhoneTourUITests: XCTestCase {
    private var app: XCUIApplication!
    private var dir: String? { ProcessInfo.processInfo.environment["SIDRA_SHOT_DIR"] }

    func testTour() throws {
        guard dir != nil else { throw XCTSkip("set SIDRA_SHOT_DIR") }
        app = XCUIApplication()
        app.launchArguments = ["-sidra.noAutoFocus", "-sidra.freshWorkspace"]
        app.launch()
        sleep(3); shot("a0-empty")
        for kind in ["herdr", "ssh", "theasa", "pipelines", "substrate", "hackertab"] {
            let card = app.buttons["newtab-\(kind)"].firstMatch
            if !card.waitForExistence(timeout: 3) { app.buttons["New tab"].firstMatch.tap(); sleep(1); shot("a1-newtab") }
            guard card.waitForExistence(timeout: 3) else { continue }
            if !card.isHittable { app.swipeUp(); sleep(1) }
            guard card.isHittable else { shot("x-\(kind)-unreachable"); continue }
            card.tap(); sleep(2); shot("b-\(kind)")
            if let b = ["Cancel", "Close", "Done"].first(where: { app.buttons[$0].firstMatch.exists }) { app.buttons[b].firstMatch.tap() }
            else { app.swipeDown(velocity: .fast) }
            sleep(1)
        }

        app.terminate()
        app.launchArguments = ["-sidra.demo", "-sidra.freshWorkspace", "-sidra.noAutoFocus"]
        app.launch()
        sleep(6); shot("c0-herdr")
        let drawer = app.buttons["herdr-drawer"].firstMatch
        if drawer.waitForExistence(timeout: 5) {
            drawer.tap(); sleep(1); shot("c0-herdr-drawer")
            let more = app.buttons["Show mobile's 2 tabs"].firstMatch
            if more.exists { more.tap(); sleep(1); shot("c0-herdr-drawer-tabs") }
            app.buttons["Close"].firstMatch.tap(); sleep(1)
        }
        for i in 1...8 {
            app.typeKey("\(i)", modifierFlags: .command); sleep(3); shot("c\(i)-tab")
        }
        app.typeKey("1", modifierFlags: .command); sleep(1)
        // The herdr sheet with a machine found (the demo's devbox): its chips must fit the phone.
        app.buttons["New tab"].firstMatch.tap(); sleep(1)
        if app.buttons["newtab-herdr"].firstMatch.waitForExistence(timeout: 3) {
            app.buttons["newtab-herdr"].firstMatch.tap(); sleep(4); shot("e-herdr-found")
            if app.buttons["Cancel"].firstMatch.exists { app.buttons["Cancel"].firstMatch.tap(); sleep(1) }
        }
        if app.buttons["theasa-pill"].firstMatch.exists { app.buttons["theasa-pill"].firstMatch.tap(); sleep(3); shot("d-theasa-pill") }
    }

    /// The Send screenshot card and the floating keyboard with a typed line, at phone width.
    func testPhoneScreenshotAndKeyboard() throws {
        guard dir != nil else { throw XCTSkip("set SIDRA_SHOT_DIR") }
        app = XCUIApplication()
        app.launchArguments = ["-sidra.demo", "-sidra.freshWorkspace", "-sidra.noAutoFocus", "-sidra.demoScreenshot",
                               "-sidra.softKeyboard", "-sidra.floatingKeyboard", "YES", "-sidra.floatingKeyboardCollapsed", "NO"]
        app.launch()
        sleep(5); shot("f-screenshot")
        app.buttons["Cancel"].firstMatch.tap(); sleep(1)
        app.typeKey("2", modifierFlags: .command); sleep(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        if app.buttons["return"].waitForExistence(timeout: 5) {
            for k in ["l", "s", " ", "-", "l", "a"] { (k == " " ? app.buttons["space"] : app.buttons[k]).firstMatch.tap() }
            shot("g-keyboard-typed")
            // A swipe across the letters: its suggestions float above the keyboard, clear of the typed line.
            app.buttons["t"].firstMatch.press(forDuration: 0.05, thenDragTo: app.buttons["o"].firstMatch)
            sleep(1); shot("g-keyboard-swipe")
        }
    }

    /// The space key in a herdr tab: it types a space and keeps the typed line.
    func testPhoneSpaceInHerdr() throws {
        guard dir != nil else { throw XCTSkip("set SIDRA_SHOT_DIR") }
        app = XCUIApplication()
        app.launchArguments = ["-sidra.demo", "-sidra.freshWorkspace", "-sidra.noAutoFocus",
                               "-sidra.softKeyboard", "-sidra.floatingKeyboard", "YES", "-sidra.floatingKeyboardCollapsed", "NO"]
        app.launch()
        sleep(5)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        if app.buttons["return"].waitForExistence(timeout: 5) {
            for k in ["h", "i", " ", "y", "o"] { (k == " " ? app.buttons["space"] : app.buttons[k]).firstMatch.tap(); sleep(1) }
            shot("h-herdr-space")
            for k in [" ", "u", "p"] { app.typeKey(k, modifierFlags: []) }   // a hardware keyboard adds to the same line
            sleep(1); shot("h-herdr-hardware")
        }
    }

    /// A finger drag scrolls; a long press or the footer's Select starts select mode, Done ends it (2026-11-22).
    func testDragScrollsAndSelectIsAMode() throws {
        app = XCUIApplication()
        app.launchArguments = ["-sidra.demo", "-sidra.freshWorkspace", "-sidra.noAutoFocus", "-sidra.floatingKeyboard", "NO"]
        app.launch()
        sleep(4)
        app.typeKey("2", modifierFlags: .command); sleep(2)   // the demo's SSH shell
        let done = app.buttons["Done selecting"]
        let mid = app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.3))
        mid.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)))
        sleep(1)
        XCTAssertFalse(done.exists, "a finger drag scrolls; it does not start selecting")
        mid.press(forDuration: 1.2); sleep(1)
        XCTAssertTrue(done.waitForExistence(timeout: 3), "a long press starts select mode")
        shot("i-select-mode")
        done.tap(); sleep(1)
        XCTAssertFalse(done.exists, "Done ends select mode")
        app.buttons["Select text"].firstMatch.tap(); sleep(1)
        XCTAssertTrue(done.waitForExistence(timeout: 3), "the footer's Select starts select mode")
    }

    private func shot(_ name: String) {
        guard let dir else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}
