#if os(macOS)
import XCTest
@testable import SidraTerminal

final class DropPathTests: XCTestCase {
    func testShellQuoting() {
        XCTAssertEqual(GhosttyMacView.shellQuoted("/Users/a/src/main.rs"), "/Users/a/src/main.rs")
        XCTAssertEqual(GhosttyMacView.shellQuoted("/Users/a/My Files/x.txt"), "'/Users/a/My Files/x.txt'")
        XCTAssertEqual(GhosttyMacView.shellQuoted("/tmp/it's"), "'/tmp/it'\\''s'")
        XCTAssertEqual(GhosttyMacView.shellQuoted("/tmp/$(rm)"), "'/tmp/$(rm)'")
    }
}
#endif
