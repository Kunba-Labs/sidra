import XCTest
@testable import SidraTerminal

final class FocusModeWatchTests: XCTestCase {
    func testSeesFocusModeOnPlainGroupedAndSplit() {
        var w = FocusModeWatch()
        XCTAssertTrue(w.turnsOn(Data("\u{1b}[?1004h".utf8)))
        XCTAssertTrue(w.turnsOn(Data("x\u{1b}[?1000;1004;1006hy".utf8)))
        XCTAssertFalse(w.turnsOn(Data("\u{1b}[?1004l".utf8)))
        XCTAssertFalse(w.turnsOn(Data("\u{1b}[?10".utf8)))
        XCTAssertTrue(w.turnsOn(Data("04h".utf8)))       // split across chunks
        XCTAssertFalse(w.turnsOn(Data("\u{1b}[?10045h".utf8)))
    }
}

final class CursorStateTests: XCTestCase {
    /// A cursor-only move (CSI D) leaves the render state clean; `cursor()` still sees it.
    func testCursorOnlyMoveIsSeen() {
        let e = GhosttyEngine(cols: 20, rows: 4)
        e.feed(Data("abc".utf8))
        _ = e.frame(force: true)
        XCTAssertEqual(e.cursor()?.x, 3)
        e.feed(Data("\u{1b}[D".utf8))
        XCTAssertEqual(e.cursor()?.x, 2)
    }

    /// Blinking by default, as in Ghostty; a steady DECSCUSR (CSI 2 q) turns it off.
    func testCursorBlinksUnlessAskedSteady() {
        let e = GhosttyEngine(cols: 20, rows: 4)
        XCTAssertEqual(e.cursor()?.blinking, true)
        e.feed(Data("\u{1b}[2 q".utf8))
        XCTAssertEqual(e.cursor()?.blinking, false)
        e.feed(Data("\u{1b}[0 q".utf8))   // a reset goes back to the default: blinking
        XCTAssertEqual(e.cursor()?.blinking, true)
    }
}
