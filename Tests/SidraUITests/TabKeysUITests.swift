import XCTest

/// Ctrl-Tab and Ctrl-Shift-Tab walk the window's tabs, wrapping at both ends (2026-11-18).
final class TabKeysUITests: XCTestCase {
    func testCtrlTabWalksTabs() {
        let app = XCUIApplication()
        app.launchArguments = ["-sidra.noAutoFocus", "-sidra.freshWorkspace"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let first = app.buttons["blinky-rs code"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let selected = NSPredicate(format: "isSelected == true")
        let tabs = app.buttons.matching(selected)
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])   // the Simulator drops the first hardware key after launch (any key, not just Ctrl-Tab)
        sleep(2)
        let start = tabs.firstMatch.label
        app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: .control)
        sleep(1)
        XCTAssertNotEqual(tabs.firstMatch.label, start, "Ctrl-Tab moves to another tab")
        app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [.control, .shift])
        sleep(1)
        XCTAssertEqual(tabs.firstMatch.label, start, "Ctrl-Shift-Tab comes back")

        // With the editor's text view focused: its own key commands must not take Ctrl-Tab.
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        sleep(1)
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])   // dropped too: the first key after the keyboard comes up
        app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: .control)
        sleep(1)
        XCTAssertNotEqual(tabs.firstMatch.label, start, "Ctrl-Tab leaves the editor's tab")
        }

    /// Cmd-[ and Cmd-] walk the tabs from a focused terminal too (in an editor they indent).
    func testCmdBracketsWalkTabsFromATerminal() {
        let app = XCUIApplication()
        app.launchArguments = ["-sidra.noAutoFocus", "-sidra.freshWorkspace"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["blinky-rs code"].waitForExistence(timeout: 10))
        let tabs = app.buttons.matching(NSPredicate(format: "isSelected == true"))
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])   // the Simulator drops the first key after launch
        app.typeKey("t", modifierFlags: .command)   // a VM terminal tab, focused
        sleep(4)
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        let term = tabs.firstMatch.label
        app.typeKey("[", modifierFlags: .command)
        sleep(1)
        XCTAssertNotEqual(tabs.firstMatch.label, term, "Cmd-[ leaves the terminal's tab")
        app.typeKey("]", modifierFlags: .command)
        sleep(1)
        XCTAssertEqual(tabs.firstMatch.label, term, "Cmd-] comes back")
    }
}
