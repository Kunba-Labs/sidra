import XCTest

/// New tab › Chess, a round as White at Beginner, one move by tapping, and the engine's answer.
final class ChessUITests: XCTestCase {
    func testPlayAMoveAndTheEngineAnswers() throws {
        let app = XCUIApplication()
        // Sidra's floating keyboard can sit over the round card's buttons in the Simulator: off for this test.
        app.launchArguments = ["-sidra.noAutoFocus", "-sidra.freshWorkspace", "-sidra.onboarded", "YES", "-chess.reset", "YES", "-sidra.floatingKeyboard", "NO"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["New tab"].waitForExistence(timeout: 20))
        app.buttons["New tab"].tap()
        app.buttons["newtab-chess"].firstMatch.tap()

        let start = app.buttons["Start round 1"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "the round card shows")
        app.buttons["Beginner 800"].tap()
        app.buttons["White"].tap()
        shot("chess-card")
        start.tap()

        app.descendants(matching: .any)["square-e2"].tap()
        sleep(1)
        shot("chess-selected")
        app.descendants(matching: .any)["square-e4"].tap()
        let moves = app.descendants(matching: .any)["chess.moves"]
        let answered = NSPredicate(format: "label MATCHES 'Moves: e4 [^ ]+'")
        expectation(for: answered, evaluatedWith: moves)
        waitForExpectations(timeout: 20)
        sleep(1)
        shot("chess-answered")

        // Drag and drop: d2 to d4 (legal after any reply here), then the engine answers again after its pause.
        let d2 = app.descendants(matching: .any)["square-d2"], d4 = app.descendants(matching: .any)["square-d4"]
        d2.press(forDuration: 0.1, thenDragTo: d4)
        let dragged = NSPredicate(format: "label MATCHES 'Moves: e4 [^ ]+ d4 [^ ]+'")
        expectation(for: dragged, evaluatedWith: moves)
        waitForExpectations(timeout: 20)
        shot("chess-dragged")

        // The column collapses and the board takes the width.
        app.buttons["Hide the side panel"].tap()
        sleep(1)
        shot("chess-collapsed")
        XCTAssertTrue(app.buttons["Show the side panel"].exists)
        app.buttons["Show the side panel"].tap()
    }

    private func shot(_ name: String) {
        if let dir = ProcessInfo.processInfo.environment["SIDRA_SHOT_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
