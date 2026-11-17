import Foundation
import CoreGraphics
import GhosttyVt

/// Selection, paste, mouse reporting and scrollback search on top of the libghostty-vt core.
/// Everything here is called from the view's thread, like the rest of the engine.
public extension GhosttyEngine {
    struct Match: Equatable { public var x0: Int, x1: Int, y: Int }

    // MARK: Modes

    /// Current value of a DEC private mode (ansi == false) or ANSI mode.
    func mode(_ value: UInt16, ansi: Bool = false) -> Bool {
        guard let term = rawTerminal else { return false }
        var cfg = GhosttyTerminalModeConfig(mode: ghostty_mode_new(value, ansi), value: false)
        return ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_MODE, &cfg) == GHOSTTY_SUCCESS && cfg.value
    }
    var bracketedPaste: Bool { mode(2004) }
    /// The program asked for mouse events (X10, normal, button or any-event tracking).
    var mouseTracking: Bool { mode(9) || mode(1000) || mode(1002) || mode(1003) }

    /// Focus in or out, as CSI I / CSI O, when the program turned on focus reporting (mode 1004).
    /// herdr and tmux use it to redraw, and herdr to make the focused client the one panes are sized
    /// for; without it a second client only counted once it sent a key or a click.
    var focusReporting: Bool { mode(1004) }

    func encodeFocus(_ focused: Bool) -> Data {
        mode(1004) ? Data((focused ? "\u{1b}[I" : "\u{1b}[O").utf8) : Data()
    }

    // MARK: Selection

    private func gridRef(x: Int, y: Int) -> GhosttyGridRef? {
        guard let term = rawTerminal else { return nil }
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(max(0, min(x, cols - 1))), y: UInt32(max(0, min(y, rows - 1))))
        var ref = GhosttyGridRef()
        return ghostty_terminal_grid_ref(term, point, &ref) == GHOSTTY_SUCCESS ? ref : nil
    }

    private func apply(_ sel: GhosttySelection?) {
        guard let term = rawTerminal else { return }
        if var s = sel { _ = ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SELECTION, &s) }
        else { _ = ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SELECTION, nil) }
    }

    /// Selects the cells between two viewport coordinates, inclusive.
    func select(from a: (x: Int, y: Int), to b: (x: Int, y: Int)) {
        guard let s = gridRef(x: a.x, y: a.y), let e = gridRef(x: b.x, y: b.y) else { return }
        apply(GhosttySelection(start: s, end: e, rectangle: false))
    }

    /// Selects the word at a cell; returns it so a drag can extend from its edges.
    @discardableResult
    func selectWord(x: Int, y: Int) -> GhosttySelection? {
        guard let term = rawTerminal, let ref = gridRef(x: x, y: y) else { return nil }
        var opts = GhosttyTerminalSelectWordOptions()
        opts.size = MemoryLayout<GhosttyTerminalSelectWordOptions>.size
        opts.ref = ref
        var sel = GhosttySelection()
        guard ghostty_terminal_select_word(term, &opts, &sel) == GHOSTTY_SUCCESS else { return nil }
        apply(sel)
        return sel
    }

    /// Drag after a long press: the whole held word stays selected, the far end follows the finger.
    /// The word is found again each move: grid refs from earlier can be stale once output scrolls.
    func extend(heldAt a: (x: Int, y: Int), to b: (x: Int, y: Int)) {
        guard let word = selectWord(x: a.x, y: a.y), let e = gridRef(x: b.x, y: b.y) else { return }
        apply((b.y, b.x) >= (a.y, a.x) ? GhosttySelection(start: word.start, end: e, rectangle: false)
                                       : GhosttySelection(start: e, end: word.end, rectangle: false))
    }

    func selectLine(x: Int, y: Int) {
        guard let term = rawTerminal, let ref = gridRef(x: x, y: y) else { return }
        var opts = GhosttyTerminalSelectLineOptions()
        opts.size = MemoryLayout<GhosttyTerminalSelectLineOptions>.size
        opts.ref = ref
        var sel = GhosttySelection()
        if ghostty_terminal_select_line(term, &opts, &sel) == GHOSTTY_SUCCESS { apply(sel) }
    }

    func clearSelection() { apply(nil) }

    var hasSelection: Bool {
        guard let term = rawTerminal else { return false }
        var sel = GhosttySelection()
        return ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_SELECTION, &sel) == GHOSTTY_SUCCESS
    }

    /// Plain text of the selection: wrapped lines joined, trailing spaces trimmed (what Ghostty copies).
    func selectionText() -> String? {
        guard let term = rawTerminal else { return nil }
        var sel = GhosttySelection()
        guard ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_SELECTION, &sel) == GHOSTTY_SUCCESS else { return nil }
        var fmt: GhosttyFormatter?
        guard ghostty_formatter_terminal_new(nil, &fmt, term) == GHOSTTY_SUCCESS, let fmt else { return nil }
        defer { ghostty_formatter_free(fmt) }
        var yes = true
        _ = ghostty_formatter_set(fmt, GHOSTTY_FORMATTER_OPT_TRIM, &yes)
        _ = ghostty_formatter_set(fmt, GHOSTTY_FORMATTER_OPT_UNWRAP, &yes)
        _ = ghostty_formatter_set(fmt, GHOSTTY_FORMATTER_OPT_SELECTION, &sel)
        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard ghostty_formatter_format_alloc(fmt, nil, &ptr, &len) == GHOSTTY_SUCCESS, let ptr else { return nil }
        defer { free(ptr) }  // default allocator is malloc
        return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
    }

    // MARK: Paste

    /// Bytes to write for a paste: bracketed when the program asked for it (mode 2004), control
    /// bytes stripped, newlines turned into carriage returns otherwise. A single trailing newline is
    /// dropped so pasting one line does not also press Enter.
    func encodePaste(_ text: String) -> Data {
        var t = text
        if t.hasSuffix("\n"), !t.dropLast().contains("\n") { t.removeLast() }
        if t.hasSuffix("\r\n"), !t.dropLast(2).contains("\n") { t.removeLast(2) }
        var bytes = Array(t.utf8)
        let bracketed = bracketedPaste
        var needed = 0
        let probe = bytes.withUnsafeMutableBufferPointer { buf in
            ghostty_paste_encode(UnsafeMutableRawPointer(buf.baseAddress).map { $0.assumingMemoryBound(to: CChar.self) }, buf.count, bracketed, nil, 0, &needed)
        }
        guard probe == GHOSTTY_OUT_OF_SPACE || probe == GHOSTTY_SUCCESS else { return Data(t.utf8) }
        if needed == 0 { return Data() }
        var out = [UInt8](repeating: 0, count: needed)
        var written = 0
        let r = bytes.withUnsafeMutableBufferPointer { buf in
            ghostty_paste_encode(UnsafeMutableRawPointer(buf.baseAddress).map { $0.assumingMemoryBound(to: CChar.self) }, buf.count, bracketed, &out, out.count, &written)
        }
        return r == GHOSTTY_SUCCESS ? Data(out[0..<written]) : Data(t.utf8)
    }

    // MARK: Mouse

    enum MouseAction { case press, release, motion }
    enum MouseButton { case left, right, middle, wheelUp, wheelDown, none }

    /// Encodes a pointer event for the program in the format it asked for (X10, UTF-8, SGR…).
    /// Returns empty data when mouse tracking is off. Coordinates are view points.
    func encodeMouse(_ action: MouseAction, button: MouseButton, at point: CGPoint, cell: CGSize, viewSize: CGSize) -> Data {
        guard let term = rawTerminal, mouseTracking else { return Data() }
        var enc: GhosttyMouseEncoder?
        var ev: GhosttyMouseEvent?
        guard ghostty_mouse_encoder_new(nil, &enc) == GHOSTTY_SUCCESS, let enc,
              ghostty_mouse_event_new(nil, &ev) == GHOSTTY_SUCCESS, let ev else { return Data() }
        defer { ghostty_mouse_encoder_free(enc); ghostty_mouse_event_free(ev) }
        _ = ghostty_mouse_encoder_set_from_terminal(enc, term)
        var size = GhosttyMouseEncoderSize()
        size.size = MemoryLayout<GhosttyMouseEncoderSize>.size
        size.screen_width = UInt32(max(1, viewSize.width)); size.screen_height = UInt32(max(1, viewSize.height))
        size.cell_width = UInt32(max(1, cell.width)); size.cell_height = UInt32(max(1, cell.height))
        _ = ghostty_mouse_encoder_set(enc, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
        var pressed = action == .motion && button != .none
        _ = ghostty_mouse_encoder_set(enc, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed)
        let ghosttyAction: GhosttyMouseAction = switch action { case .press: GHOSTTY_MOUSE_ACTION_PRESS; case .release: GHOSTTY_MOUSE_ACTION_RELEASE; case .motion: GHOSTTY_MOUSE_ACTION_MOTION }
        _ = ghostty_mouse_event_set_action(ev, ghosttyAction)
        switch button {
        case .left: _ = ghostty_mouse_event_set_button(ev, GHOSTTY_MOUSE_BUTTON_LEFT)
        case .right: _ = ghostty_mouse_event_set_button(ev, GHOSTTY_MOUSE_BUTTON_RIGHT)
        case .middle: _ = ghostty_mouse_event_set_button(ev, GHOSTTY_MOUSE_BUTTON_MIDDLE)
        case .wheelUp: _ = ghostty_mouse_event_set_button(ev, GHOSTTY_MOUSE_BUTTON_FOUR)
        case .wheelDown: _ = ghostty_mouse_event_set_button(ev, GHOSTTY_MOUSE_BUTTON_FIVE)
        case .none: _ = ghostty_mouse_event_clear_button(ev)
        }
        _ = ghostty_mouse_event_set_position(ev, GhosttyMousePosition(x: Float(point.x), y: Float(point.y)))
        var out = [UInt8](repeating: 0, count: 64)
        var written = 0
        guard ghostty_mouse_encoder_encode(enc, ev, &out, out.count, &written) == GHOSTTY_SUCCESS, written > 0 else { return Data() }
        return Data(out[0..<written])
    }

    // MARK: Search

    /// Starts or updates a scrollback search. Nil or empty clears it. Returns (total, selected index).
    /// ponytail: `ghostty_search_run` blocks until the scrollback is scanned; fine for the 10k-line
    /// scrollback a pane keeps, drive tick/feed from a timer if this ever stalls.
    @discardableResult
    func search(_ needle: String?) -> (total: Int, index: Int?) {
        guard let term = rawTerminal else { return (0, nil) }
        if searchHandle == nil {
            var s: GhosttySearch?
            guard ghostty_search_new(nil, &s, term) == GHOSTTY_SUCCESS else { return (0, nil) }
            searchHandle = s
        }
        guard let s = searchHandle else { return (0, nil) }
        guard let needle, !needle.isEmpty else {
            _ = ghostty_search_set(s, GHOSTTY_SEARCH_OPT_NEEDLE, nil)
            return (0, nil)
        }
        let bytes = Array(needle.utf8)
        bytes.withUnsafeBufferPointer { buf in
            var str = GhosttyString(ptr: buf.baseAddress, len: buf.count)
            _ = ghostty_search_set(s, GHOSTTY_SEARCH_OPT_NEEDLE, &str)
        }
        _ = ghostty_search_run(s)
        if searchSelectedIndex() == nil { _ = ghostty_search_select_next(s) }
        return (searchTotal(), searchSelectedIndex())
    }

    func searchNext() -> (total: Int, index: Int?) {
        guard let s = searchHandle else { return (0, nil) }
        _ = ghostty_search_feed(s)
        _ = ghostty_search_select_next(s)
        return (searchTotal(), searchSelectedIndex())
    }

    func searchPrevious() -> (total: Int, index: Int?) {
        guard let s = searchHandle else { return (0, nil) }
        _ = ghostty_search_feed(s)
        _ = ghostty_search_select_prev(s)
        return (searchTotal(), searchSelectedIndex())
    }

    private func searchTotal() -> Int {
        guard let s = searchHandle else { return 0 }
        var n = 0
        _ = ghostty_search_get(s, GHOSTTY_SEARCH_DATA_TOTAL_MATCHES, &n)
        return n
    }

    private func searchSelectedIndex() -> Int? {
        guard let s = searchHandle else { return nil }
        var i = 0
        return ghostty_search_get(s, GHOSTTY_SEARCH_DATA_SELECTED_INDEX, &i) == GHOSTTY_SUCCESS ? i : nil
    }

    /// Matches on the visible rows, as viewport cell ranges, for drawing highlights.
    func viewportMatches() -> [Match] {
        guard let s = searchHandle, let term = rawTerminal else { return [] }
        _ = ghostty_search_feed(s)
        var buf = GhosttySelectionBuffer(ptr: nil, cap: 0, len: 0)
        _ = ghostty_search_get(s, GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &buf)
        guard buf.len > 0 else { return [] }
        var sels = [GhosttySelection](repeating: GhosttySelection(), count: buf.len)
        let got: Bool = sels.withUnsafeMutableBufferPointer { p in
            var b = GhosttySelectionBuffer(ptr: p.baseAddress, cap: p.count, len: 0)
            let r = ghostty_search_get(s, GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &b)
            return r == GHOSTTY_SUCCESS
        }
        guard got else { return [] }
        var out: [Match] = []
        for var sel in sels {
            var a = GhosttyPointCoordinate(), b = GhosttyPointCoordinate()
            guard ghostty_terminal_point_from_grid_ref(term, &sel.start, GHOSTTY_POINT_TAG_VIEWPORT, &a) == GHOSTTY_SUCCESS,
                  ghostty_terminal_point_from_grid_ref(term, &sel.end, GHOSTTY_POINT_TAG_VIEWPORT, &b) == GHOSTTY_SUCCESS,
                  a.y == b.y, Int(a.y) < rows else { continue }  // ponytail: multi-row matches highlight their first row only
            out.append(Match(x0: Int(a.x), x1: Int(b.x), y: Int(a.y)))
        }
        return out
    }
}

/// Sees output turn focus reporting on (CSI ? … 1004 … h, grouped modes too), even when the sequence is
/// split across chunks: the program then wants a fresh focus report, though the mode may never have
/// read as off between two checks.
struct FocusModeWatch {
    private var tail = Data()
    private static let pattern = try! NSRegularExpression(pattern: "\u{1b}\\[\\?(?:[0-9]+;)*1004(?:;[0-9]+)*h")

    mutating func turnsOn(_ chunk: Data) -> Bool {
        let joined = tail + chunk
        let text = String(decoding: joined, as: UTF8.self)
        // Carry over only an unfinished CSI at the end (ESC [ and parameters, no final letter yet),
        // so a sequence seen whole is never matched twice.
        if let esc = joined.lastIndex(of: 0x1b) {
            let rest = joined[esc...]
            let done = rest.dropFirst().contains { (0x40...0x7e).contains($0) && $0 != 0x5b }   // a final byte after ESC [
            tail = done || rest.count > 32 ? Data() : Data(rest)
        } else { tail = Data() }
        return Self.pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
