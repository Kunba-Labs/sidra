import XCTest
@testable import SidraTerminal

final class TerminalNoteTests: XCTestCase {
    func testHeadsUpNote() throws {
        let rows = ["⏺ Done. Tests pass.", "", "  Heads up · The backend now returns at most 500 pitches per list,", "  and the app doesn't page yet.", "",
                    "  1: Learn more   2: Knew this already   0: Dismiss", "", "──────────", "❯ "]
        let n = try XCTUnwrap(TerminalNote.find(in: rows))
        XCTAssertEqual(n.tag, "Heads up")
        XCTAssertEqual(n.text, "The backend now returns at most 500 pitches per list, and the app doesn't page yet.")
        XCTAssertEqual(n.choices.map(\.key), ["1", "2", "0"])
        XCTAssertEqual(n.choices[1].label, "Knew this already")
    }

    func testOtherRowsAreNotNotes() {
        XCTAssertNil(TerminalNote.find(in: ["1: Yes  2: No"]))                         // no Dismiss
        XCTAssertNil(TerminalNote.find(in: ["see 1: Learn more  0: Dismiss above"]))   // prose, not a row
        XCTAssertNil(TerminalNote.find(in: ["  1: Learn more   0: Dismiss"] + Array(repeating: "x", count: 30)))   // scrolled away
        XCTAssertEqual(TerminalNote.find(in: ["How is Claude doing this session? (optional)", "1: Bad    2: Fine   3: Good   0: Dismiss"])?.choices.count, 4)
    }
}
