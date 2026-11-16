import XCTest

/// App Store screenshots from the demo mode (`-sidra.demo`, Debug only): no real machine, server or account.
/// Writes PNGs to SIDRA_SHOT_DIR; tools/store-shots.sh runs it on an iPad and an iPhone simulator.
final class StoreScreenshotsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var phone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    func testStoreScreenshots() throws {
        guard ProcessInfo.processInfo.environment["SIDRA_SHOT_DIR"] != nil else { throw XCTSkip("store screenshots run from tools/store-shots.sh") }
        app = XCUIApplication()
        app.launchArguments = ["-sidra.demo", "-sidra.freshWorkspace", "-sidra.noAutoFocus", "-chess.reset", "YES"]
        app.launch()
        XCUIDevice.shared.orientation = phone ? .portrait : .landscapeLeft
        sleep(6)
        shot("01-herdr")

        app.buttons["theasa-pill"].firstMatch.tap()
        sleep(3)
        shot("02-theasa")
        dismissPopover()

        tab(3)   // Pipelines
        let failed = app.buttons["pipeline-9103"].firstMatch
        if failed.waitForExistence(timeout: 10) { failed.tap() }
        sleep(2)
        let unit = app.buttons["unit, failed"].firstMatch
        if unit.waitForExistence(timeout: 5) { unit.tap() }
        sleep(3)
        shot("03-pipelines")

        tab(2)   // the devbox shell
        sleep(2)
        shot("04-ssh")

        app.buttons["New tab"].firstMatch.tap()
        sleep(2)
        shot("05-new-tab")
        app.buttons["Cancel"].firstMatch.tap()
        sleep(1)

        tab(4)   // Chess
        let start = app.buttons["Start round 1"]
        if start.waitForExistence(timeout: 5) {
            app.buttons["White"].tap()
            start.tap()
            for (from, to) in [("e2", "e4"), ("g1", "f3")] {
                app.descendants(matching: .any)["square-\(from)"].tap()
                app.descendants(matching: .any)["square-\(to)"].tap()
                sleep(6)   // the engine answers after its pause
            }
        }
        shot("06-chess")
    }

    private func tab(_ n: Int) {
        app.typeKey(Character("\(n)").description, modifierFlags: .command)
        sleep(2)
    }

    private func dismissPopover() {
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        sleep(1)
        if app.buttons["theasa-pill"].firstMatch.isHittable == false { app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.98)).tap() }
        sleep(1)
    }

    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SIDRA_SHOT_DIR"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}
