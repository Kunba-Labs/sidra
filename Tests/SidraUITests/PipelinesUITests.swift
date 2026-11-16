import XCTest

/// Against a real GitLab: SIDRA_GITLAB_URL and SIDRA_GITLAB_TOKEN in the test runner's environment
/// (TEST_RUNNER_ prefix); skipped without them. Opens Pipelines, which picks the newest failure and
/// opens its failing log section at the error.
final class PipelinesUITests: XCTestCase {
    func testListRunAndFailingLog() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["SIDRA_GITLAB_URL"], let token = env["SIDRA_GITLAB_TOKEN"] else { throw XCTSkip("no GitLab in the environment") }
        let app = XCUIApplication()
        app.launchArguments = ["-sidra.noAutoFocus", "-sidra.freshWorkspace", "-sidra.onboarded", "YES", "-sidra.gitlab", url]
        app.launchEnvironment["SIDRA_GITLAB_TOKEN"] = token
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["New tab"].waitForExistence(timeout: 20))
        app.buttons["New tab"].tap()
        app.buttons["newtab-pipelines"].firstMatch.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pipeline-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the list shows pipelines")
        sleep(8)   // jobs, log and avatars
        shot("pipelines")
        XCTAssertTrue(app.buttons["Open in GitLab"].exists, "a run is shown")

        // The title bar's dropdown lists recent pipelines, finished ones too, under its Pipelines tab.
        let pill = app.buttons["mux-agents"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "a connected GitLab keeps the pill in the title bar")
        pill.tap()
        app.buttons["section-pipelines"].tap()
        let listed = app.buttons.matching(NSPredicate(format: "label ENDSWITH 'open in Pipelines'")).firstMatch
        XCTAssertTrue(listed.waitForExistence(timeout: 5), "the dropdown lists pipelines")
        shot("pipelines-dropdown")
        listed.tap()
        sleep(2)

        // Narrow: split twice; the run shows alone with a way back to the list.
        app.buttons["Split right"].firstMatch.tap()
        sleep(1)
        app.buttons["Split right"].firstMatch.tap()
        sleep(3)
        shot("pipelines-narrow")
        XCTAssertTrue(app.buttons["Pipelines"].firstMatch.exists, "a narrow pane offers the list")
    }

    private func shot(_ name: String) {
        if let dir = ProcessInfo.processInfo.environment["SIDRA_SHOT_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
