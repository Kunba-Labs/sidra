import XCTest

/// HackerTab against the live Hacker News APIs.
final class HackerTabUITests: XCTestCase {
    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-sidra.noAutoFocus", "-sidra.onboarded", "YES"] + extra
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testKeysInThePane() throws {
        let app = launch(["-sidra.freshWorkspace", "-hackertab.open", "YES", "-hackertab.demo", "discussion"])
        let counter = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Thread '")).firstMatch
        XCTAssertTrue(counter.waitForExistence(timeout: 40), "the discussion did not load")
        sleep(2)
        func selected(_ pattern: String) -> String? {
            let q = app.buttons.matching(NSPredicate(format: "selected == true AND label MATCHES %@", pattern)).firstMatch
            return q.exists ? q.label : nil
        }
        let comment = { selected(".* ago, .*") }
        let story = { selected("[0-9]{2}, .*") }
        let thread = { app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Thread '")).firstMatch.label }
        shot(app, "hackertab-start")

        app.typeKey("j", modifierFlags: []); let first = comment()
        app.typeKey("j", modifierFlags: [])
        XCTAssertNotNil(first, "j did not put the cursor on a comment")
        XCTAssertNotEqual(comment(), first, "the second j did not move the cursor")
        let t0 = thread()
        app.typeKey("n", modifierFlags: [])
        XCTAssertNotEqual(thread(), t0, "n did not go to the next thread")
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(comment()?.contains("collapsed") == true, "space did not collapse the comment")
        app.typeKey(" ", modifierFlags: []); app.typeKey("f", modifierFlags: [])
        XCTAssertTrue(app.buttons["all threads"].exists, "f did not focus the thread")
        // f again leaves focus. (Esc does the same, but XCUI's Esc does not reach the app in the Simulator.)
        app.typeKey("f", modifierFlags: [])
        XCTAssertFalse(app.buttons["all threads"].exists, "f did not leave focus")
        shot(app, "hackertab-discussion")

        let before = story()
        XCTAssertNotNil(before, "no story selected")
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        XCTAssertNotEqual(story(), before, "↓ did not select the next story")
        app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [])
        XCTAssertEqual(story(), before, "↑ did not go back to the story")

        app.typeKey("/", modifierFlags: [])
        let find = app.textFields["find in thread"]
        XCTAssertTrue(find.waitForExistence(timeout: 5), "/ did not open find")
        app.typeKey("j", modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        XCTAssertEqual(find.value as? String, "j", "j did not go into the find field")
        XCTAssertEqual(story(), before, "↓ changed the story while typing in find")
        shot(app, "hackertab-find")
    }

}
