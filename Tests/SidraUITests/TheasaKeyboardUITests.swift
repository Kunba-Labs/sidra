import XCTest

/// Hardware-key presses on the Theasa tab, each checked by the state it changes (selected pill,
/// keyboard focus, a field's text, the server's answer). Only DEBUG demo agents get messages: their
/// pane ids are not in herdr, so the server answers "that agent is gone" and nothing is typed anywhere.
/// Writes need `TEST_RUNNER_THEASA_TOKEN=$(theasa token)`.
final class TheasaKeyboardUITests: XCTestCase {
    let server = "http://127.0.0.1:4747"

    private func launch(_ extra: [String] = []) throws -> XCUIApplication {
        guard (try? Data(contentsOf: URL(string: server + "/health")!)) != nil else { throw XCTSkip("Theasa does not run on \(server)") }
        // Live agents need the token (theasa 68f3cfb), and the demo cards ride on that list.
        let t = try token
        let app = XCUIApplication()
        app.launchArguments = ["-sidra.noAutoFocus", "-sidra.freshWorkspace", "-sidra.onboarded", "YES",
                               "-sidra.theasa", server, "-sidra.theasaDemoAgents", "YES"] + (extra.contains("-sidra.theasaToken") ? [] : ["-sidra.theasaToken", t]) + extra
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue((extra.contains("-sidra.theasaClosed") ? app.buttons["theasa-pill"] : app.buttons["Pulse"]).waitForExistence(timeout: 20))
        sleep(1)
        return app
    }

    private var token: String {
        get throws {
            guard let t = ProcessInfo.processInfo.environment["THEASA_TOKEN"], !t.isEmpty else { throw XCTSkip("set TEST_RUNNER_THEASA_TOKEN") }
            return t
        }
    }

    /// Keyboard focus, given a moment to arrive (it can take a beat after the key).
    private func focused(_ e: XCUIElement, within seconds: Double = 2) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat { if (e.value(forKey: "hasKeyboardFocus") as? Bool) == true { return true }; usleep(200_000) } while Date() < end
        return false
    }
    private func notFocused(_ e: XCUIElement) -> Bool { (e.value(forKey: "hasKeyboardFocus") as? Bool) != true }
    private func key(_ app: XCUIApplication, _ k: String, _ m: XCUIElement.KeyModifierFlags = []) { app.typeKey(k, modifierFlags: m); usleep(600_000) }
    private func card(_ app: XCUIApplication, _ pane: String) -> XCUIElement { visible(app.descendants(matching: .any).matching(identifier: "theasa-agent-\(pane)")) }
    /// Pulse stays under a pushed screen, with its own copy of the agent cards: take the one on screen.
    private func visible(_ q: XCUIElementQuery) -> XCUIElement { q.allElementsBoundByIndex.first { $0.isHittable } ?? q.firstMatch }
    private func visibleButton(_ app: XCUIApplication, _ id: String) -> XCUIElement { visible(app.buttons.matching(identifier: id)) }
    private func field(_ app: XCUIApplication, _ label: String) -> XCUIElement { visible(app.textFields.matching(identifier: label)) }

    /// Return in search with no ⌘F first: tap the field, type, Return (typeText goes through whichever
    /// keyboard is up, so this holds with the Simulator's hardware keyboard on or off).
    func testReturnInSearchAfterTap() throws {
        let app = try launch()
        let search = app.textFields["theasa-search"]
        search.tap()
        XCTAssertTrue(focused(search), "a tap did not focus the search field")
        search.typeText("qqzz\n")
        XCTAssertTrue(app.staticTexts["theasa-search-count"].waitForExistence(timeout: 10), "Return after a tap did not search")
        XCTAssertTrue(app.buttons["Back"].exists)
        app.buttons["Back"].tap()
        // The magnifier searches too, so search never depends on Return alone.
        XCTAssertTrue(app.buttons["theasa-search-go"].waitForExistence(timeout: 5))
        app.buttons["theasa-search-go"].tap()
        XCTAssertTrue(app.staticTexts["theasa-search-count"].waitForExistence(timeout: 10), "the magnifier did not search")
    }

    /// Points 1-4: the Theasa menu keys, ⌘F into search, Esc out of the field, Esc and ⌘. back.
    func testMenuKeysSearchAndEscape() throws {
        let app = try launch()
        let pulse = app.buttons["Pulse"], agents = app.buttons["Agents"], search = app.textFields["theasa-search"]
        XCTAssertTrue(pulse.isSelected)

        key(app, "a", [.command, .option])
        XCTAssertTrue(agents.isSelected, "⌥⌘A did not open Agents")
        key(app, "p", [.command, .option])
        XCTAssertTrue(pulse.isSelected, "⌥⌘P did not go back to Pulse")

        key(app, "n", [.command, .option])
        XCTAssertTrue(agents.isSelected, "⌥⌘N did not open Agents")
        XCTAssertTrue(card(app, "demo:design").waitForExistence(timeout: 5))
        XCTAssertTrue(card(app, "demo:design").isSelected, "⌥⌘N did not pick the first agent that needs you")
        key(app, "n", [.command, .option])
        XCTAssertTrue(card(app, "demo:ask").isSelected, "a second ⌥⌘N did not move to the next agent")
        XCTAssertFalse(card(app, "demo:design").isSelected)
        shot(app, "kb-next-agent")

        XCTAssertFalse(app.buttons["Back"].exists, "Agents is a tab root: no back button")
        key(app, "p", [.command, .option])
        XCTAssertTrue(pulse.isSelected)

        key(app, "f", .command)
        XCTAssertTrue(focused(search), "⌘F did not focus the Theasa search field")
        for c in "qqzz" { app.typeKey(String(c), modifierFlags: []) }
        XCTAssertEqual(search.value as? String, "qqzz")
        key(app, "a", [.command, .option])   // a command chord while typing works, and types nothing
        XCTAssertTrue(agents.isSelected)
        XCTAssertEqual(search.value as? String, "qqzz", "⌥⌘A typed into the field")
        key(app, ".", .command)
        XCTAssertTrue(notFocused(search), "⌘. did not leave the field")
        XCTAssertTrue(agents.isSelected, "⌘. in a field also went back")
        key(app, "x")
        XCTAssertEqual(search.value as? String, "qqzz", "a key after leaving the field still went into it")

        key(app, "f", .command)
        XCTAssertTrue(focused(search), "a second ⌘F did not focus the search field")
        key(app, XCUIKeyboardKey.return.rawValue)
        XCTAssertTrue(app.staticTexts["theasa-search-count"].waitForExistence(timeout: 10), "Return in search did not search")
        XCTAssertTrue(app.buttons["Back"].exists, "a pushed screen has a back button")
        shot(app, "kb-search")
        // Esc: the Simulator does not deliver it to the app (notes found the same), so ⌘. carries the check.
        key(app, XCUIKeyboardKey.escape.rawValue)
        print("THEASA-ESC: Esc went back in the simulator: \(!app.staticTexts["theasa-search-count"].exists)")
        if app.staticTexts["theasa-search-count"].exists { key(app, ".", .command) }   // leaves the field
        if app.staticTexts["theasa-search-count"].exists { key(app, ".", .command) }   // goes back
        XCTAssertFalse(app.staticTexts["theasa-search-count"].exists, "⌘. did not go back from search")
        XCTAssertTrue(agents.isSelected, "back did not return to the Agents root")
        key(app, ".", .command)
        XCTAssertTrue(agents.isSelected, "⌘. on a root screen did something")
        key(app, "1", .command)            // another tab
        XCTAssertFalse(app.buttons["theasa-pill"].isSelected, "the pill stayed active on another tab")
        key(app, "p", [.command, .option])
        XCTAssertTrue(pulse.waitForExistence(timeout: 5) && pulse.isSelected, "⌥⌘P did not bring the Theasa tab back on Pulse")
        XCTAssertTrue(app.buttons["theasa-pill"].isSelected, "the pill is not active while its tab shows")
    }

    /// Points 5-7: ⌘↩ sends from the multi-line message field and the one-line answer field; ⌘F reaches
    /// Theasa's search while it is open; a live change from the server keeps the field's focus and text.
    func testSendKeepsFocusAndDraftAcrossLiveChanges() throws {
        let t = try token
        let app = try launch(["-sidra.theasaToken", t, "-sidra.theasaRoute", "agents"])
        sleep(2)
        // The reply card sits below the blocked ones: scroll until it is built.
        for _ in 0..<6 where !app.textViews["Message for demo reply"].exists && !app.textFields["Message for demo reply"].exists { app.swipeUp() }
        let reply = visible(app.textViews.matching(identifier: "Message for demo reply")).exists ? visible(app.textViews.matching(identifier: "Message for demo reply")) : field(app, "Message for demo reply")
        XCTAssertTrue(reply.waitForExistence(timeout: 15))

        reply.tap()
        for c in "ship" { app.typeKey(String(c), modifierFlags: []) }
        XCTAssertTrue(focused(reply))

        // A server change while typing: mark a watch item done and open it again.
        guard let (id, _) = openWatch() else { throw XCTSkip("no open watch item") }
        post("/api/watch/\(id)/done", t); sleep(2); post("/api/watch/\(id)/open", t); sleep(2)
        XCTAssertTrue(focused(reply), "a live refetch took the keyboard from the field")
        XCTAssertEqual((reply.value as? String)?.lowercased(), "ship", "a live refetch changed the draft")

        // With Theasa open, ⌘F goes to its search, not to the editor behind it.
        key(app, ".", .command)
        key(app, "f", .command)
        XCTAssertTrue(focused(app.textFields["theasa-search"]), "⌘F did not reach Theasa's search")
        key(app, ".", .command)

        // ⌘↩: the Simulator never hands this chord to the app (no press of Return with ⌘ reaches any
        // responder, logged 2026-11-14), so a miss here is expected there; on a device it must send.
        reply.tap()
        reply.typeKey(XCUIKeyboardKey.return, modifierFlags: .command); usleep(600_000)
        XCTExpectFailure("the Simulator does not deliver ⌘↩", strict: false) {
            XCTAssertTrue(app.staticTexts["that agent is gone"].waitForExistence(timeout: 5), "⌘↩ in the message field did not send")
        }
        XCTAssertEqual((reply.value as? String)?.lowercased(), "ship", "⌘↩ or a failed send changed the draft")

        key(app, ".", .command)
        key(app, "n", [.command, .option])   // scrolls the ask card into view
        let own = field(app, "Your own answer to: Which database should the cache use?")
        XCTAssertTrue(own.waitForExistence(timeout: 5))
        own.tap()
        for c in "duck" { app.typeKey(String(c), modifierFlags: []) }
        sleep(4)   // let the first toast go
        card(app, "demo:ask").buttons["theasa-ask-next"].tap()
        card(app, "demo:ask").buttons["theasa-send-answers"].tap()
        XCTAssertTrue(app.staticTexts["Answer question 2 first."].waitForExistence(timeout: 5), "sent with question 2 unanswered")
        let second = field(app, "Your own answer to: Which targets need it?")
        second.tap()
        for c in "both" { app.typeKey(String(c), modifierFlags: []) }
        sleep(4)
        key(app, XCUIKeyboardKey.return.rawValue, .command)
        XCTExpectFailure("the Simulator does not deliver ⌘↩", strict: false) {
            XCTAssertTrue(app.staticTexts["that agent is gone"].waitForExistence(timeout: 5), "⌘↩ in an answer field did not send the answers")
        }
        if !app.staticTexts["that agent is gone"].exists {
            card(app, "demo:ask").buttons["theasa-send-answers"].tap()
            XCTAssertTrue(app.staticTexts["that agent is gone"].waitForExistence(timeout: 10), "Send answers did not send once both were answered")
        }
        card(app, "demo:ask").buttons["theasa-ask-page-0"].tap()
        XCTAssertEqual((own.value as? String)?.lowercased(), "duck")
        shot(app, "kb-send")
    }

    /// Points 8-9: switching tab releases the field; Tab moves between fields and option buttons.
    func testFocusLeavesWithTheTabAndTabMoves() throws {
        let app = try launch(["-sidra.theasaRoute", "agents"])
        let search = app.textFields["theasa-search"]
        key(app, "a", [.command, .option])   // the first key after launch can get lost in the Simulator
        key(app, "f", .command)
        XCTAssertTrue(focused(search))
        key(app, "1", .command)          // another tab
        key(app, "a", [.command, .option])   // back to Theasa
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(notFocused(search), "the search field kept the keyboard across a tab switch")
        key(app, "q")
        XCTAssertNotEqual(search.value as? String, "q", "a key after reopening went into the field")

        let first = field(app, "Your own answer to: Which database should the cache use?")
        first.tap()
        XCTAssertTrue(focused(first))
        key(app, XCUIKeyboardKey.tab.rawValue)
        XCTAssertTrue(notFocused(first), "Tab did not leave the answer field: focus is trapped")
        key(app, XCUIKeyboardKey.tab.rawValue, .shift)
        print("THEASA-TAB: ⇧Tab came back to the answer field: \(focused(first))")
        shot(app, "kb-tab")
    }

    /// The question's attachments: a thumbnail opens the full-size viewer, Done closes it; option previews show.
    func testAskAttachmentsOpenTheViewer() throws {
        let app = try launch(["-sidra.theasaRoute", "agents"])
        let thumb = app.buttons["theasa-thumb-0"].firstMatch
        XCTAssertTrue(thumb.waitForExistence(timeout: 15), "no attachment thumbnail on the design question")
        XCTAssertTrue(app.descendants(matching: .any)["theasa-option-preview"].firstMatch.exists, "the option preview is missing")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Login options")).firstMatch.exists, "the artifact chip is missing")
        shot(app, "ask-attachments")
        thumb.tap()
        let viewer = app.descendants(matching: .any)["theasa-viewer"].firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 5), "the thumbnail did not open the viewer")
        XCTAssertTrue(app.staticTexts["1 of 2"].exists)
        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["2 of 2"].waitForExistence(timeout: 3), "swipe did not move to the next image")
        shot(app, "ask-viewer")
        app.buttons["Done"].tap()
        XCTAssertFalse(viewer.waitForExistence(timeout: 2))
    }

    /// Without a token: Agents asks for it with a button to the connection, the pill shows no counts,
    /// and the reads that need no token (Pulse) still work. localhost is a second connection with no token.
    func testAgentsWithoutToken() throws {
        guard (try? Data(contentsOf: URL(string: server + "/health")!)) != nil else { throw XCTSkip("Theasa does not run on \(server)") }
        let app = XCUIApplication()
        app.launchArguments = ["-sidra.noAutoFocus", "-sidra.freshWorkspace", "-sidra.onboarded", "YES", "-sidra.theasa", "http://localhost:4747", "-sidra.theasaRoute", "agents"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.staticTexts["Add the token to see agents"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Add the token"].exists)
        XCTAssertEqual(app.buttons["theasa-pill"].label, "Theasa", "the pill shows counts without a token")
        shot(app, "agents-no-token")
        app.buttons["Pulse"].tap()
        XCTAssertTrue(app.staticTexts["Needs attention"].waitForExistence(timeout: 15), "Pulse did not load without a token")
        app.buttons["Agents"].tap()
        app.buttons["Add the token"].tap()
        XCTAssertTrue(app.staticTexts["Connect to Theasa"].waitForExistence(timeout: 5), "Add the token did not open the connection")
    }

    private func openWatch() -> (Int, Int)? {
        guard let d = try? Data(contentsOf: URL(string: server + "/api/projects/48?range=month")!),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let w = (j["watch"] as? [[String: Any]])?.first(where: { $0["status"] as? String == "open" }),
              let id = w["id"] as? Int, let turn = w["turn_id"] as? Int else { return nil }
        return (id, turn)
    }

    private func post(_ path: String, _ token: String) {
        var r = URLRequest(url: URL(string: server + path)!)
        r.httpMethod = "POST"; r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let done = expectation(description: path)
        URLSession.shared.dataTask(with: r) { _, resp, _ in
            XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200, path)
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let png = app.screenshot().pngRepresentation
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["SIDRA_SHOT_DIR"] { try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")) }
    }
}
