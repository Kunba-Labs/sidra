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
