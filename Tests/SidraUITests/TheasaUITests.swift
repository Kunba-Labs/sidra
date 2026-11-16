import XCTest

/// Theasa (the title-bar pill and its tab) against the live server on the Mac (127.0.0.1:4747). Writes need the token:
/// `TEST_RUNNER_THEASA_TOKEN=$(theasa token) xcodebuild test …`. Nothing here answers a real agent:
/// the answer goes to a demo pane id herdr does not have, and the watch item is toggled back.
final class TheasaUITests: XCTestCase {
    let server = "http://127.0.0.1:4747"

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-sidra.noAutoFocus", "-sidra.freshWorkspace", "-sidra.onboarded", "YES"] + extra
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        return app
    }

    private func reachable() throws {
        guard (try? Data(contentsOf: URL(string: server + "/health")!)) != nil else { throw XCTSkip("Theasa does not run on \(server)") }
    }

    private var token: String {
        get throws {
            guard let t = ProcessInfo.processInfo.environment["THEASA_TOKEN"], !t.isEmpty else { throw XCTSkip("set TEST_RUNNER_THEASA_TOKEN") }
            return t
        }
    }

    func testConnectSheetTestsTheServer() throws {
        try reachable()
        // The pill selects the Theasa tab, which the tab strip never lists; ⌥⌘K opens the connections sheet.
        let app = launch(["-sidra.theasa", server, "-sidra.theasaClosed", "YES"])
        let pill = app.buttons["theasa-pill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 20), "no Theasa pill in the title bar")
        XCTAssertFalse(app.buttons["New tab"].exists && app.buttons["Theasa…"].exists)
        XCTAssertFalse(pill.isSelected)
        XCTAssertFalse(pill.label.contains("working"), "the pill counts working agents; the title bar's working pill does that")
        pill.tap()
        XCTAssertTrue(app.buttons["Pulse"].waitForExistence(timeout: 10), "the pill did not open Theasa")
        XCTAssertTrue(pill.isSelected, "the pill is not active while its tab shows")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Theasa ")).allElementsBoundByIndex.contains { $0.identifier != "theasa-pill" && $0.frame.minY < 120 },
                       "a Theasa tab shows in the tab strip")
        app.typeKey("k", modifierFlags: [.command, .option])
        XCTAssertTrue(app.staticTexts["Connect to Theasa"].waitForExistence(timeout: 5))
        app.buttons["theasa-test"].tap()
        XCTAssertTrue(app.otherElements["theasa-health"].waitForExistence(timeout: 10) || app.staticTexts["turns"].waitForExistence(timeout: 2))
        shot("theasa-connect")
        app.buttons["Cancel"].tap()
    }

    func testAnswerReachesTheAPI() throws {
        try reachable()
        let app = launch(["-sidra.theasa", server, "-sidra.theasaToken", try token, "-sidra.theasaRoute", "agents", "-sidra.theasaDemoAgents", "YES"])
        // Pulse stays under the pushed Agents screen with its own copy of the cards: use the ones on screen.
        func visible(_ q: XCUIElementQuery) -> XCUIElement { q.allElementsBoundByIndex.first { $0.isHittable } ?? q.firstMatch }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "SQLite")).firstMatch.waitForExistence(timeout: 15))
        sleep(1)
        let sqlite = visible(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "SQLite")))
        // Two questions, one per page: the chips show both, Next goes to the second, where Send is.
        let askCard = app.descendants(matching: .any)["theasa-agent-demo:ask"].firstMatch
        XCTAssertTrue(askCard.buttons["theasa-ask-page-1"].exists, "a chip per question")
        XCTAssertFalse(askCard.buttons["theasa-send-answers"].exists, "Send waits for the last page")
        shot("theasa-ask-page-1")
        askCard.buttons["theasa-ask-next"].tap()
        // Nothing answered: nothing is sent, and the card goes back to the first open question.
        askCard.buttons["theasa-send-answers"].tap()
        XCTAssertTrue(app.staticTexts["Answer questions 1, 2 first."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Pick an option or type an answer."].exists)
        sqlite.tap()
        askCard.buttons["theasa-ask-next"].tap()
        let own = visible(app.textFields.matching(identifier: "Your own answer to: Which targets need it?"))
        own.tap(); own.typeText("all three")
        shot("theasa-ask-filled")
        sleep(4)   // the first toast goes
        askCard.buttons["theasa-send-answers"].tap()
        // The server got the bearer token (no 401) and looked the pane up: herdr has no "demo:ask".
        XCTAssertTrue(app.staticTexts["that agent is gone"].waitForExistence(timeout: 10))
        shot("theasa-ask-sent")
        // A failed send keeps what was typed.
        XCTAssertEqual(own.value as? String, "all three")
    }

    func testWatchItemDoneAndOpenAgain() throws {
        try reachable()
        let detail = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(string: server + "/api/projects/48?range=month")!)) as! [String: Any]
        guard let item = (detail["watch"] as! [[String: Any]]).first(where: { $0["status"] as? String == "open" }), let id = item["id"] as? Int,
              let turn = item["turn_id"] as? Int else { throw XCTSkip("no open watch item in project 48") }
        let app = launch(["-sidra.theasa", server, "-sidra.theasaToken", try token, "-sidra.theasaRoute", "turn:\(turn)"])
        let toggle = app.buttons["theasa-watch-toggle-\(id)"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        sleep(2)
        for _ in 0..<6 where !toggle.isHittable { app.swipeUp() }
        shot("theasa-turn")
        toggle.tap()
        XCTAssertTrue(waitStatus(id, turn: turn, "done"))
        let reopened = expectation(for: NSPredicate(format: "label == %@", "Open again"), evaluatedWith: app.buttons["theasa-watch-toggle-\(id)"])
        wait(for: [reopened], timeout: 15)   // the live refetch redraws the item
        app.buttons["theasa-watch-toggle-\(id)"].tap()
        XCTAssertTrue(waitStatus(id, turn: turn, "open"), "toggled back")
    }

    func testDiffOpensAndRawLog() throws {
        try reachable()
        let app = launch(["-sidra.theasa", server, "-sidra.theasaRoute", "turn:9557"])
        let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "src/live.ts")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 15))
        file.tap()
        XCTAssertTrue(file.isSelected || app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "@@")).firstMatch.waitForExistence(timeout: 5))
        shot("theasa-turn-diff")
    }

    /// The item's status from its turn (a project's watch list holds only the first 100, open first).
    private func waitStatus(_ id: Int, turn: Int, _ want: String) -> Bool {
        for _ in 0..<20 {
            if let d = try? Data(contentsOf: URL(string: server + "/api/turns/\(turn)")!),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               (j["watch"] as? [[String: Any]])?.first(where: { $0["id"] as? Int == id })?["status"] as? String == want { return true }
            usleep(500_000)
        }
        return false
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = ProcessInfo.processInfo.environment["SIDRA_SHOT_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
