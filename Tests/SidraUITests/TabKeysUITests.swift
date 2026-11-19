import XCTest

/// Ctrl-Tab / Ctrl-Shift-Tab and Cmd-[ / Cmd-] walk the window's tabs from a terminal (2026-11-18).
/// In a herdr pane Cmd-[ and Cmd-] walk herdr's own tabs instead, so this starts on the demo's plain shell.
final class TabKeysUITests: XCTestCase {
    private func launchOnShell() -> (XCUIApplication, XCUIElementQuery) {
        let app = XCUIApplication()
        app.launchArguments = ["-sidra.demo", "-sidra.freshWorkspace", "-sidra.noAutoFocus", "-sidra.onboarded", "YES"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(4)
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])   // the Simulator drops the first hardware key after launch
        app.typeKey("2", modifierFlags: .command)                        // the demo's SSH shell
        sleep(2)
        return (app, app.buttons.matching(NSPredicate(format: "isSelected == true")))
    }

    func testCtrlTabWalksTabs() {
        let (app, tabs) = launchOnShell()
        let start = tabs.firstMatch.label
        XCTAssertFalse(start.isEmpty)
        app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: .control)
        sleep(1)
        XCTAssertNotEqual(tabs.firstMatch.label, start, "Ctrl-Tab moves to another tab")
        app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [.control, .shift])
        sleep(1)
        XCTAssertEqual(tabs.firstMatch.label, start, "Ctrl-Shift-Tab comes back")
    }

    func testCmdBracketsWalkTabsFromATerminal() {
        let (app, tabs) = launchOnShell()
        let start = tabs.firstMatch.label
        XCTAssertFalse(start.isEmpty)
        // Right first: tab 1 is herdr, where Cmd-] would walk herdr's tabs instead.
        app.typeKey("]", modifierFlags: .command)
        sleep(1)
        XCTAssertNotEqual(tabs.firstMatch.label, start, "Cmd-] leaves the terminal's tab")
        app.typeKey("[", modifierFlags: .command)
        sleep(1)
        XCTAssertEqual(tabs.firstMatch.label, start, "Cmd-[ comes back")
    }
}
