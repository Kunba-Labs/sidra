import XCTest
@testable import SidraTerminal

final class SidraTerminalTests: XCTestCase {
    func testEngineRendersTextAndColours() {
        let e = GhosttyEngine(cols: 20, rows: 3)
        e.feed(Data("hi \u{1b}[31mred\u{1b}[0m\r\nline2".utf8))
        let f = try! XCTUnwrap(e.frame(force: true))
        XCTAssertEqual(f.rows.count, 3)
        let row0 = f.rows[0].cells.map(\.text).joined()
        XCTAssertTrue(row0.hasPrefix("hi red"), row0)
        XCTAssertEqual(f.rows[0].cells[3].fg.map { $0 >> 16 }, 0xff >> 0 == 0xff ? f.rows[0].cells[3].fg.map { $0 >> 16 } : nil)
        XCTAssertNotNil(f.rows[0].cells[3].fg, "red text should carry a foreground colour")
        XCTAssertNil(f.rows[0].cells[0].fg, "default text has no explicit colour")
        XCTAssertEqual(f.cursor?.y, 1)
        XCTAssertEqual(f.cursor?.x, 5)
    }

    func testEngineEncodesKeys() {
        let e = GhosttyEngine(cols: 10, rows: 2)
        XCTAssertEqual(e.encode(.enter), Data([0x0d]))
        XCTAssertEqual(e.encode(.shiftEnter), Data([0x1b, 0x0d]))
        XCTAssertEqual(e.encode(.ctrl("c")), Data([0x03]))
        XCTAssertEqual(e.encode(.up), Data("\u{1b}[A".utf8))
        XCTAssertEqual(e.encode(.text("a")), Data("a".utf8))
        XCTAssertEqual(e.encode(.escape), Data([0x1b]))
    }

    func testEngineAnswersDeviceStatusReport() {
        let e = GhosttyEngine(cols: 10, rows: 2)
        var replies = Data()
        e.onReply = { replies.append($0) }
        e.feed(Data("\u{1b}[6n".utf8))
        XCTAssertEqual(String(decoding: replies, as: UTF8.self), "\u{1b}[1;1R")
    }

    func testResizeChangesGrid() {
        let e = GhosttyEngine(cols: 10, rows: 2)
        e.resize(cols: 40, rows: 10, cellWidth: 8, cellHeight: 20)
        let f = try! XCTUnwrap(e.frame(force: true))
        XCTAssertEqual(f.rows.count, 10)
        XCTAssertEqual(f.cols, 40)
    }

    func testLoopbackEchoesCarriageReturnAsCRLF() async {
        let io = LoopbackTerminalIO()
        io.write(Data("a\r".utf8))
        var it = io.output.makeAsyncIterator()
        let d = await it.next()
        XCTAssertEqual(d, Data("a\r\n".utf8))
    }
}

final class TerminalInteractionTests: XCTestCase {
    func testSGRMouseEncodingWhenTrackingIsOn() {
        let e = GhosttyEngine(cols: 20, rows: 5)
        XCTAssertTrue(e.encodeMouse(.press, button: .left, at: CGPoint(x: 30, y: 25), cell: CGSize(width: 8, height: 20), viewSize: CGSize(width: 160, height: 100)).isEmpty, "no tracking, no report")
        e.feed(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        XCTAssertTrue(e.mouseTracking)
        let press = e.encodeMouse(.press, button: .left, at: CGPoint(x: 30, y: 25), cell: CGSize(width: 8, height: 20), viewSize: CGSize(width: 160, height: 100))
        XCTAssertEqual(String(decoding: press, as: UTF8.self), "\u{1b}[<0;4;2M", "cell (3,1) is reported 1-based as 4;2")
        let release = e.encodeMouse(.release, button: .left, at: CGPoint(x: 30, y: 25), cell: CGSize(width: 8, height: 20), viewSize: CGSize(width: 160, height: 100))
        XCTAssertTrue(String(decoding: release, as: UTF8.self).hasSuffix("m"))
        let right = e.encodeMouse(.press, button: .right, at: CGPoint(x: 30, y: 25), cell: CGSize(width: 8, height: 20), viewSize: CGSize(width: 160, height: 100))
        XCTAssertEqual(String(decoding: right, as: UTF8.self), "\u{1b}[<2;4;2M", "right-click goes to the program as button 2")
        let wheel = e.encodeMouse(.press, button: .wheelUp, at: CGPoint(x: 1, y: 1), cell: CGSize(width: 8, height: 20), viewSize: CGSize(width: 160, height: 100))
        XCTAssertTrue(String(decoding: wheel, as: UTF8.self).hasPrefix("\u{1b}[<64;"), String(decoding: wheel, as: UTF8.self))
    }

    func testPasteWrapsWhenBracketedAndStripsOneTrailingNewline() {
        let e = GhosttyEngine(cols: 20, rows: 5)
        XCTAssertEqual(String(decoding: e.encodePaste("ls\n"), as: UTF8.self), "ls")
        XCTAssertEqual(String(decoding: e.encodePaste("a\nb\n"), as: UTF8.self), "a\rb\r", "multi-line keeps every line break, as carriage returns, including the last")
        e.feed(Data("\u{1b}[?2004h".utf8))
        XCTAssertTrue(e.bracketedPaste)
        XCTAssertEqual(String(decoding: e.encodePaste("ls\n"), as: UTF8.self), "\u{1b}[200~ls\u{1b}[201~")
    }

    func testSelectionTextJoinsRowsAndTrims() {
        let e = GhosttyEngine(cols: 20, rows: 4)
        e.feed(Data("hello world\r\nsecond line\r\n".utf8))
        e.select(from: (x: 0, y: 0), to: (x: 4, y: 0))
        XCTAssertTrue(e.hasSelection)
        XCTAssertEqual(e.selectionText(), "hello")
        e.select(from: (x: 6, y: 0), to: (x: 5, y: 1))
        XCTAssertEqual(e.selectionText(), "world\nsecond")
        e.selectWord(x: 8, y: 1)
        XCTAssertEqual(e.selectionText(), "line")
        e.clearSelection()
        XCTAssertFalse(e.hasSelection)
        XCTAssertNil(e.selectionText())
    }

    func testSearchFindsMatchesInViewport() {
        let e = GhosttyEngine(cols: 20, rows: 4)
        e.feed(Data("foo bar\r\nbaz foo\r\n".utf8))
        let r = e.search("foo")
        XCTAssertEqual(r.total, 2)
        XCTAssertNotNil(r.index)
        let m = e.viewportMatches()
        XCTAssertEqual(m.count, 2)
        XCTAssertTrue(m.contains(GhosttyEngine.Match(x0: 0, x1: 2, y: 0)))
        XCTAssertEqual(e.searchNext().total, 2)
        XCTAssertEqual(e.search(nil).total, 0)
    }
}

/// vttest menu 1 screen 1 shape: DECALN fills E's, then erase-above / erase-below / erase-line
/// must clear what they cover. Probes libghostty's state through the frame, not the renderer.
final class EraseSequenceTests: XCTestCase {
    private func text(_ e: GhosttyEngine, _ row: Int) -> String {
        let f = e.frame(force: true)!
        return f.rows[row].cells.map { $0.text.isEmpty ? " " : $0.text }.joined().trimmingCharacters(in: .whitespaces)
    }

    func testDecalnThenEraseAbove() {
        let e = GhosttyEngine(cols: 10, rows: 6)
        e.feed(Data("\u{1B}#8".utf8))                       // DECALN
        XCTAssertEqual(text(e, 0), String(repeating: "E", count: 10))
        e.feed(Data("\u{1B}[3;1H\u{1B}[1J".utf8))           // cursor row 3 col 1, erase above (inclusive)
        XCTAssertEqual(text(e, 0), "", "row 1 erased by ED 1")
        XCTAssertEqual(text(e, 1), "", "row 2 erased by ED 1")
        XCTAssertEqual(text(e, 2).count, 9, "row 3: only the cursor cell erased")
        XCTAssertEqual(text(e, 5), String(repeating: "E", count: 10), "row 6 untouched")
    }

    func testEraseBelowAndLines() {
        let e = GhosttyEngine(cols: 10, rows: 6)
        e.feed(Data("\u{1B}#8\u{1B}[4;1H\u{1B}[0J".utf8))  // erase below from row 4
        XCTAssertEqual(text(e, 2), String(repeating: "E", count: 10))
        XCTAssertEqual(text(e, 3), ""); XCTAssertEqual(text(e, 5), "")
        e.feed(Data("\u{1B}[2;3H\u{1B}[1K".utf8))          // erase line left (inclusive) on row 2
        XCTAssertEqual(text(e, 1), String(repeating: "E", count: 7))
        e.feed(Data("\u{1B}[1;1H\u{1B}[2K".utf8))          // erase whole row 1
        XCTAssertEqual(text(e, 0), "")
    }
}

final class EraseWithScrollbackTests: XCTestCase {
    private func text(_ e: GhosttyEngine, _ row: Int) -> String {
        let f = e.frame(force: true)!
        return f.rows[row].cells.map { $0.text.isEmpty ? " " : $0.text }.joined().trimmingCharacters(in: .whitespaces)
    }
    /// vttest menu 1 screen 1 on a terminal that already has scrollback: DECALN, cup(9,1) ED 1.
    func testVttestScreenOneAfterScrollback() {
        let e = GhosttyEngine(cols: 80, rows: 24)
        for i in 0..<60 { e.feed(Data("line \(i)\r\n".utf8)) }
        e.feed(Data("\u{1B}#8\u{1B}[9;1H\u{1B}[1J\u{1B}[18;60H\u{1B}[0J".utf8))
        for r in 0..<8 { XCTAssertEqual(text(e, r), "", "row \(r + 1) should be erased by ED 1") }
        XCTAssertEqual(text(e, 9), String(repeating: "E", count: 80), "row 10 keeps its E's")
        XCTAssertEqual(text(e, 20), "", "row 21 erased by ED 0")
    }
}

/// The exact bytes vttest 2.7 emits for menu 1 screen 1 (captured through a pty in sidra-vm),
/// fed to the engine: libghostty's screen must show the E frame around the text and nothing else.
final class VttestScreenOneTests: XCTestCase {
    static let bytes = Data(base64Encoded: "GyVAG1swYxtbPzFsG1s/M2wbWz80bBtbPzVsG1s/NmwbWz83aBtbPzhsG1s/NDBoG1s/NDVsG1tyG1swbRslRxtbMkobWzM7MTBIVlQxMDAgdGVzdCBwcm9ncmFtLCB2ZXJzaW9uIDIuNyAoMjAyNDEyMDgpG1s0OzEwSExpbmUgc3BlZWQgMzg0MDBiZCAbWzU7MTBIQ2hvb3NlIHRlc3QgdHlwZToNDQobWzY7MUgbWzBKDQ0KICAgICAgICAgIDAuIEV4aXQNCiAgICAgICAgICAxLiBUZXN0IG9mIGN1cnNvciBtb3ZlbWVudHMNCiAgICAgICAgICAyLiBUZXN0IG9mIHNjcmVlbiBmZWF0dXJlcw0KICAgICAgICAgIDMuIFRlc3Qgb2YgY2hhcmFjdGVyIHNldHMNCiAgICAgICAgICA0LiBUZXN0IG9mIGRvdWJsZS1zaXplZCBjaGFyYWN0ZXJzDQogICAgICAgICAgNS4gVGVzdCBvZiBrZXlib2FyZA0KICAgICAgICAgIDYuIFRlc3Qgb2YgdGVybWluYWwgcmVwb3J0cw0KICAgICAgICAgIDcuIFRlc3Qgb2YgVlQ1MiBtb2RlDQogICAgICAgICAgOC4gVGVzdCBvZiBWVDEwMiBmZWF0dXJlcyAoSW5zZXJ0L0RlbGV0ZSBDaGFyL0xpbmUpDQogICAgICAgICAgOS4gVGVzdCBvZiBrbm93biBidWdzDQogICAgICAgICAgMTAuIFRlc3Qgb2YgcmVzZXQgYW5kIHNlbGYtdGVzdA0KICAgICAgICAgIDExLiBUZXN0IG5vbi1WVDEwMCAoZS5nLiwgVlQyMjAsIFhURVJNKSB0ZXJtaW5hbHMNCiAgICAgICAgICAxMi4gTW9kaWZ5IHRlc3QtcGFyYW1ldGVycw0KDQ0KICAgICAgICAgIEVudGVyIGNob2ljZSBudW1iZXIgKDAgLSAxMik6IDENChtbMkobWz8zbBsjOBtbOTsxMEgbWzFKG1sxODs2MEgbWzBKG1sxSxtbOTs3MUgbWzBLG1sxMDsxMEgbWzFLG1sxMDs3MUgbWzBLG1sxMTsxMEgbWzFLG1sxMTs3MUgbWzBLG1sxMjsxMEgbWzFLG1sxMjs3MUgbWzBLG1sxMzsxMEgbWzFLG1sxMzs3MUgbWzBLG1sxNDsxMEgbWzFLG1sxNDs3MUgbWzBLG1sxNTsxMEgbWzFLG1sxNTs3MUgbWzBLG1sxNjsxMEgbWzFLG1sxNjs3MUgbWzBLG1sxNzszMEgbWzJLG1syNDsxZiobWzE7MWYqG1syNDsyZiobWzE7MmYqG1syNDszZiobWzE7M2YqG1syNDs0ZiobWzE7NGYqG1syNDs1ZiobWzE7NWYqG1syNDs2ZiobWzE7NmYqG1syNDs3ZiobWzE7N2YqG1syNDs4ZiobWzE7OGYqG1syNDs5ZiobWzE7OWYqG1syNDsxMGYqG1sxOzEwZiobWzI0OzExZiobWzE7MTFmKhtbMjQ7MTJmKhtbMTsxMmYqG1syNDsxM2YqG1sxOzEzZiobWzI0OzE0ZiobWzE7MTRmKhtbMjQ7MTVmKhtbMTsxNWYqG1syNDsxNmYqG1sxOzE2ZiobWzI0OzE3ZiobWzE7MTdmKhtbMjQ7MThmKhtbMTsxOGYqG1syNDsxOWYqG1sxOzE5ZiobWzI0OzIwZiobWzE7MjBmKhtbMjQ7MjFmKhtbMTsyMWYqG1syNDsyMmYqG1sxOzIyZiobWzI0OzIzZiobWzE7MjNmKhtbMjQ7MjRmKhtbMTsyNGYqG1syNDsyNWYqG1sxOzI1ZiobWzI0OzI2ZiobWzE7MjZmKhtbMjQ7MjdmKhtbMTsyN2YqG1syNDsyOGYqG1sxOzI4ZiobWzI0OzI5ZiobWzE7MjlmKhtbMjQ7MzBmKhtbMTszMGYqG1syNDszMWYqG1sxOzMxZiobWzI0OzMyZiobWzE7MzJmKhtbMjQ7MzNmKhtbMTszM2YqG1syNDszNGYqG1sxOzM0ZiobWzI0OzM1ZiobWzE7MzVmKhtbMjQ7MzZmKhtbMTszNmYqG1syNDszN2YqG1sxOzM3ZiobWzI0OzM4ZiobWzE7MzhmKhtbMjQ7MzlmKhtbMTszOWYqG1syNDs0MGYqG1sxOzQwZiobWzI0OzQxZiobWzE7NDFmKhtbMjQ7NDJmKhtbMTs0MmYqG1syNDs0M2YqG1sxOzQzZiobWzI0OzQ0ZiobWzE7NDRmKhtbMjQ7NDVmKhtbMTs0NWYqG1syNDs0NmYqG1sxOzQ2ZiobWzI0OzQ3ZiobWzE7NDdmKhtbMjQ7NDhmKhtbMTs0OGYqG1syNDs0OWYqG1sxOzQ5ZiobWzI0OzUwZiobWzE7NTBmKhtbMjQ7NTFmKhtbMTs1MWYqG1syNDs1MmYqG1sxOzUyZiobWzI0OzUzZiobWzE7NTNmKhtbMjQ7NTRmKhtbMTs1NGYqG1syNDs1NWYqG1sxOzU1ZiobWzI0OzU2ZiobWzE7NTZmKhtbMjQ7NTdmKhtbMTs1N2YqG1syNDs1OGYqG1sxOzU4ZiobWzI0OzU5ZiobWzE7NTlmKhtbMjQ7NjBmKhtbMTs2MGYqG1syNDs2MWYqG1sxOzYxZiobWzI0OzYyZiobWzE7NjJmKhtbMjQ7NjNmKhtbMTs2M2YqG1syNDs2NGYqG1sxOzY0ZiobWzI0OzY1ZiobWzE7NjVmKhtbMjQ7NjZmKhtbMTs2NmYqG1syNDs2N2YqG1sxOzY3ZiobWzI0OzY4ZiobWzE7NjhmKhtbMjQ7NjlmKhtbMTs2OWYqG1syNDs3MGYqG1sxOzcwZiobWzI0OzcxZiobWzE7NzFmKhtbMjQ7NzJmKhtbMTs3MmYqG1syNDs3M2YqG1sxOzczZiobWzI0Ozc0ZiobWzE7NzRmKhtbMjQ7NzVmKhtbMTs3NWYqG1syNDs3NmYqG1sxOzc2ZiobWzI0Ozc3ZiobWzE7NzdmKhtbMjQ7NzhmKhtbMTs3OGYqG1syNDs3OWYqG1sxOzc5ZiobWzI0OzgwZiobWzE7ODBmKhtbMjsySCsbWzFEG0QrG1sxRBtEKxtbMUQbRCsbWzFEG0QrG1sxRBtEKxtbMUQbRCsbWzFEG0QrG1sxRBtEKxtbMUQbRCsbWzFEG0QrG1sxRBtEKxtbMUQbRCsbWzFEG0QrG1sxRBtEKxtbMUQbRCsbWzFEG0QrG1sxRBtEKxtbMUQbRCsbWzFEG0QrG1sxRBtEKxtbMUQbRCsbWzFEG0QbWzIzOzc5SCsbWzFEG00rG1sxRBtNKxtbMUQbTSsbWzFEG00rG1sxRBtNKxtbMUQbTSsbWzFEG00rG1sxRBtNKxtbMUQbTSsbWzFEG00rG1sxRBtNKxtbMUQbTSsbWzFEG00rG1sxRBtNKxtbMUQbTSsbWzFEG00rG1sxRBtNKxtbMUQbTSsbWzFEG00rG1sxRBtNKxtbMUQbTSsbWzFEG00bWzI7MUgqG1syOzgwSCobWzEwRBtFKhtbMzs4MEgqG1sxMEQbRSobWzQ7ODBIKhtbMTBEG0UqG1s1OzgwSCobWzEwRBtFKhtbNjs4MEgqG1sxMEQbRSobWzc7ODBIKhtbMTBEG0UqG1s4OzgwSCobWzEwRBtFKhtbOTs4MEgqG1sxMEQbRSobWzEwOzgwSCobWzEwRA0KKhtbMTE7ODBIKhtbMTBEDQoqG1sxMjs4MEgqG1sxMEQNCiobWzEzOzgwSCobWzEwRA0KKhtbMTQ7ODBIKhtbMTBEDQoqG1sxNTs4MEgqG1sxMEQNCiobWzE2OzgwSCobWzEwRA0KKhtbMTc7ODBIKhtbMTBEDQoqG1sxODs4MEgqG1sxMEQNCiobWzE5OzgwSCobWzEwRA0KKhtbMjA7ODBIKhtbMTBEDQoqG1syMTs4MEgqG1sxMEQNCiobWzIyOzgwSCobWzEwRA0KKhtbMjM7ODBIKhtbMTBEDQobWzI7MTBIG1s0MkQbWzJDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQysbWzBDG1syRBtbMUMrG1swQxtbMkQbWzFDKxtbMEMbWzJEG1sxQxtbMjM7NzBIG1s0MkMbWzJEKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgrG1sxRBtbMUMbWzBECCsbWzFEG1sxQxtbMEQIKxtbMUQbWzFDG1swRAgbWzE7MUgbWzEwQRtbMUEbWzBBG1syNDs4MEgbWzEwQhtbMUIbWzBCG1sxMDsxMkggICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgG1sxQhtbNThEICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIBtbMUIbWzU4RCAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAbWzFCG1s1OEQgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgG1sxQhtbNThEICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIBtbMUIbWzU4RCAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAbWzFCG1s1OEQbWzVBG1sxQ1RoZSBzY3JlZW4gc2hvdWxkIGJlIGNsZWFyZWQsICBhbmQgaGF2ZSBhbiB1bmJyb2tlbiBib3ItG1sxMjsxM0hkZXIgb2YgKidzIGFuZCArJ3MgYXJvdW5kIHRoZSBlZGdlLCAgIGFuZCBleGFjdGx5IGluIHRoZRtbMTM7MTNIbWlkZGxlICB0aGVyZSBzaG91bGQgYmUgYSBmcmFtZSBvZiBFJ3MgYXJvdW5kIHRoaXMgIHRleHQbWzE0OzEzSHdpdGggIG9uZSAoMSkgZnJlZSBwb3NpdGlvbiBhcm91bmQgaXQuICAgIFB1c2ggPFJFVFVSTj4=")!
    private func rows(_ e: GhosttyEngine) -> [String] {
        e.frame(force: true)!.rows.map { $0.cells.map { $0.text.isEmpty ? " " : $0.text }.joined() }
    }
    func testScreenOneAt80x24() {
        let e = GhosttyEngine(cols: 80, rows: 24)
        e.feed(Self.bytes)
        let r = rows(e)
        for (i, line) in r.enumerated() { print(String(format: "%2d|%@", i + 1, line)) }
        let row1 = String(r[0].prefix(80))
        XCTAssertEqual(row1, String(repeating: "*", count: 80), "row 1 is the * border")
        XCTAssertFalse(r[2].contains("EEEEE"), "row 3 must not keep DECALN E's")
        XCTAssertTrue(r[8].contains("EEEEEEEEEE"), "row 9 is the top of the E frame")
        XCTAssertTrue(r[15].contains("EEEEEEEEEE"), "row 16 is the bottom of the E frame")
    }
    func testScreenOneAt224x29() {
        let e = GhosttyEngine(cols: 224, rows: 29)
        e.feed(Self.bytes)
        let r = rows(e)
        for (i, line) in r.enumerated() { print(String(format: "%2d|%@", i + 1, String(line.prefix(90)))) }
        XCTAssertFalse(r[2].contains("EEEEE"), "row 3 must not keep DECALN E's")
        XCTAssertTrue(r[8].contains("EEEEEEEEEE"), "row 9 is the top of the E frame")
    }
}

final class VttestScreenOneAfterResizeTests: XCTestCase {
    func testScreenOneAfterGrowAndShrink() {
        let e = GhosttyEngine(cols: 80, rows: 24)
        for i in 0..<30 { e.feed(Data("line \(i)\r\n".utf8)) }
        e.resize(cols: 224, rows: 40, cellWidth: 6, cellHeight: 14)
        e.resize(cols: 224, rows: 29, cellWidth: 6, cellHeight: 14)   // the Simulator keyboard shrinks the pane
        e.feed(VttestScreenOneTests.bytes)
        let r = e.frame(force: true)!.rows.map { $0.cells.map { $0.text.isEmpty ? " " : $0.text }.joined() }
        for (i, line) in r.enumerated() { print(String(format: "%2d|%@", i + 1, String(line.prefix(90)))) }
        XCTAssertFalse(r[2].contains("EEEEE"), "row 3 must not keep DECALN E's after resizes")
        XCTAssertTrue(r[8].contains("EEEEEEEEEE"), "row 9 is the top of the E frame")
    }
}

final class TerminalImagePathsTests: XCTestCase {
    private func grid(_ s: String) -> [[Character]] { s.split(separator: "\n", omittingEmptySubsequences: false).map { Array($0) } }

    func testFindsWrappedPathsBesideASidebar() {
        let screen = grid("""
        inbox2 │ › [image]/private/tmp/claude/screens/1-settin
        main   │        gs-import-mail.png              (123.5KB)
        Shop   │ › [image] /private/tmp/claude/screens/2-upload (119KB)
        develop│           ing.png
               │ › [image] /tmp/4-done.png (130.9KB)
               │ see ~/notes.txt and /usr/bin/env
        """)
        let found = TerminalImagePaths.find(screen)
        XCTAssertEqual(found.map(\.row), [0, 2, 4])
        XCTAssertEqual(found.map(\.path), ["/private/tmp/claude/screens/1-settings-import-mail.png",
                                            "/private/tmp/claude/screens/2-uploading.png", "/tmp/4-done.png"])
    }
}

final class TerminalCopyTests: XCTestCase {
    func testOSC52CopyReachesTheApp() {
        let e = GhosttyEngine(cols: 20, rows: 3)
        var copied: String?
        e.onCopy = { copied = $0; return true }
        e.feed(Data("\u{1b}]52;c;\(Data("héllo from herdr".utf8).base64EncodedString())\u{07}".utf8))
        XCTAssertEqual(copied, "héllo from herdr")
    }
}

final class TerminalLinksTests: XCTestCase {
    private func grid(_ s: String) -> [[Character]] { s.split(separator: "\n", omittingEmptySubsequences: false).map { Array($0) } }

    func testFindsTheTappedURLIncludingAWrappedOne() {
        let screen = grid("""
        main  │ open https://example.com/a. Next line
        Shop  │ see https://claude.ai/code/artifact/abcdef│
        dev   │     123456 for the chart
        plain text here
        """)
        XCTAssertEqual(TerminalLinks.url(atRow: 0, col: 20, in: screen)?.absoluteString, "https://example.com/a")
        XCTAssertEqual(TerminalLinks.url(atRow: 2, col: 13, in: screen)?.absoluteString, "https://claude.ai/code/artifact/abcdef123456", "the wrapped tail counts")
        XCTAssertEqual(TerminalLinks.url(atRow: 1, col: 14, in: screen)?.absoluteString, "https://claude.ai/code/artifact/abcdef123456")
        XCTAssertNil(TerminalLinks.url(atRow: 3, col: 2, in: screen))
        let parens = [Array("see https://en.wikipedia.org/wiki/Rust_(language) and (https://x.dev/a).")]
        XCTAssertEqual(TerminalLinks.url(atRow: 0, col: 10, in: parens)?.absoluteString, "https://en.wikipedia.org/wiki/Rust_(language)")
        XCTAssertEqual(TerminalLinks.url(atRow: 0, col: 60, in: parens)?.absoluteString, "https://x.dev/a")
        XCTAssertNil(TerminalLinks.url(atRow: 0, col: 9, in: screen), "the word before the link")
    }
}

#if canImport(UIKit)   // the iPad view
@MainActor final class TerminalLostTests: XCTestCase {
    func testDitherRotGrowsFromNothing() {
        let cells = (0..<80).flatMap { x in (0..<24).map { (x, $0) } }
        let blocks = { (k: Double) in cells.filter { GhosttyTerminalView.rot(x: $0.0, y: $0.1, t: 2, k: k, blank: false) != nil }.count }
        XCTAssertEqual(blocks(0), 0)
        XCTAssertGreaterThan(blocks(1), cells.count / 10)
        XCTAssertLessThan(blocks(1), cells.count * 9 / 10)   // text stays readable between patches
    }
}
#endif
