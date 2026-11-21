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
        for i in 1...8 {
            app.typeKey("\(i)", modifierFlags: .command); sleep(3); shot("c\(i)-tab")
        }
        app.typeKey("1", modifierFlags: .command); sleep(1)
        if app.buttons["theasa-pill"].firstMatch.exists { app.buttons["theasa-pill"].firstMatch.tap(); sleep(3); shot("d-theasa-pill") }
    }

    private func shot(_ name: String) {
        guard let dir else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}
