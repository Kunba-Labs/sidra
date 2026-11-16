import Foundation
import GhosttyVt

/// One rendered cell. Colors are 0xRRGGBB; nil means the terminal default.
public struct TerminalCell: Equatable {
    public var text: String
    public var fg: UInt32?
    public var bg: UInt32?
    public var bold = false
    public var italic = false
    public var faint = false
    public var inverse = false
    public var underline = false
    public var strikethrough = false
    public var wide = false
    public var skip = false   // spacer tail of a wide glyph
    public var selected = false
}

public struct TerminalRow: Equatable {
    public var id: UInt64
    public var cells: [TerminalCell]
}

public struct TerminalCursor: Equatable {
    public enum Style { case bar, block, underline, hollow }
    public var x: Int
    public var y: Int
    public var style: Style
    public var visible: Bool
}

public struct TerminalFrame {
    public var cols: Int
    public var rows: [TerminalRow]
    public var cursor: TerminalCursor?
    public var background: UInt32
    public var foreground: UInt32
}

public enum TerminalKey {
    case text(String)
    case enter, shiftEnter, tab, backspace, escape, delete, insert
    case up, down, left, right, home, end, pageUp, pageDown
    case function(Int)
    case ctrl(Character)
    case alt(Character)
}

/// libghostty-vt behind a small Swift API. Not thread safe: call from one queue (the view's).
public final class GhosttyEngine {
    private var term: GhosttyTerminal?
    var rawTerminal: GhosttyTerminal? { term }
    var searchHandle: GhosttySearch?
    private var render: GhosttyRenderState?
    private var rowIterator: GhosttyRenderStateRowIterator?
    private var cells: GhosttyRenderStateRowCells?
    private var keyEvent: GhosttyKeyEvent?
    private var encoder: GhosttyKeyEncoder?
    private var codepoints = [UInt32](repeating: 0, count: 32)
    public private(set) var cols: Int
    public private(set) var rows: Int
    /// Bytes the terminal wants sent back to the host (DSR replies and friends).
    public var onReply: ((Data) -> Void)?
    /// A program copied text (OSC 52: herdr, tmux, vim, Claude Code); nil asks to clear. iPadOS has one clipboard,
    /// so every destination lands there. Return false to refuse the write.
    public var onCopy: ((String?) -> Bool)?
    public var onTitle: ((String) -> Void)?
    public var onBell: (() -> Void)?

    public init(cols: Int, rows: Int) {
        self.cols = max(cols, 2)
        self.rows = max(rows, 1)
        var t: GhosttyTerminal?
        _ = ghostty_terminal_new(nil, &t, UInt16(self.cols), UInt16(self.rows))
        term = t
        var r: GhosttyRenderState?
        _ = ghostty_render_state_new(nil, &r)
        render = r
        var it: GhosttyRenderStateRowIterator?
        _ = ghostty_render_state_row_iterator_new(nil, &it)
        rowIterator = it
        var c: GhosttyRenderStateRowCells?
        _ = ghostty_render_state_row_cells_new(nil, &c)
        cells = c
        var e: GhosttyKeyEvent?
        _ = ghostty_key_event_new(nil, &e)
        keyEvent = e
        var k: GhosttyKeyEncoder?
        _ = ghostty_key_encoder_new(nil, &k)
        encoder = k
        installCallbacks()
    }

    deinit {
        if let searchHandle { ghostty_search_free(searchHandle) }
        if let encoder { ghostty_key_encoder_free(encoder) }
        if let keyEvent { ghostty_key_event_free(keyEvent) }
        if let cells { ghostty_render_state_row_cells_free(cells) }
        if let rowIterator { ghostty_render_state_row_iterator_free(rowIterator) }
        if let render { ghostty_render_state_free(render) }
        if let term { ghostty_terminal_free(term) }
    }

    private func installCallbacks() {
        guard let term else { return }
        // Option values are passed as the pointer itself, not a pointer to the value.
        let me = Unmanaged.passUnretained(self).toOpaque()
        _ = ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_USERDATA, UnsafeRawPointer(me))
        let writePty: GhosttyTerminalWritePtyFn = { _, userdata, data, len in
            guard let userdata, let data else { return }
            let engine = Unmanaged<GhosttyEngine>.fromOpaque(userdata).takeUnretainedValue()
            engine.onReply?(Data(bytes: data, count: len))
        }
        _ = ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(writePty, to: UnsafeRawPointer.self))
        let copy: GhosttyTerminalClipboardWriteFn = { _, userdata, write in
            guard let userdata, let write else { return }
            let w = write.pointee
            let engine = Unmanaged<GhosttyEngine>.fromOpaque(userdata).takeUnretainedValue()
            let string = { (s: GhosttyString) in String(decoding: UnsafeBufferPointer(start: s.ptr, count: s.len), as: UTF8.self) }
            let text = (0..<w.contents_len).map { w.contents[$0] }.first { string($0.mime).hasPrefix("text/plain") }.map { string($0.data) }
            let result: GhosttyClipboardWriteResult =
                w.contents_len > 0 && text == nil ? GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED   // only text reaches the clipboard
                : engine.onCopy?(text) == true ? GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS : GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED
            var reply = GhosttyClipboardWriteReply(size: MemoryLayout<GhosttyClipboardWriteReply>.size, result: result, remember: false)
            w.reply(write, &reply)
        }
        _ = ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, unsafeBitCast(copy, to: UnsafeRawPointer.self))
    }

    public func feed(_ data: Data) {
        guard let term else { return }
        data.withUnsafeBytes { buf in
            guard let base = buf.bindMemory(to: UInt8.self).baseAddress else { return }
            ghostty_terminal_vt_write(term, base, buf.count)
        }
    }

    public func resize(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        guard let term else { return }
        self.cols = max(cols, 2)
        self.rows = max(rows, 1)
        _ = ghostty_terminal_resize(term, UInt16(self.cols), UInt16(self.rows), UInt32(cellWidth), UInt32(cellHeight))
    }

    public func scroll(by delta: Int) {
        guard let term else { return }
        var b = GhosttyTerminalScrollViewport()
        b.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA
        b.value.delta = Int(delta)
        _ = ghostty_terminal_scroll_viewport(term, b)
    }

    public func scrollToBottom() {
        guard let term else { return }
        var b = GhosttyTerminalScrollViewport()
        b.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM
        _ = ghostty_terminal_scroll_viewport(term, b)
    }

    /// Snapshot of the viewport. Returns nil when nothing changed since the last call.
    public func frame(force: Bool = false) -> TerminalFrame? {
        guard let term, let render, let rowIterator, let cells else { return nil }
        _ = ghostty_render_state_update(render, term)
        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        _ = ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
        if dirty == GHOSTTY_RENDER_STATE_DIRTY_FALSE && !force {
            return nil
        }

        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        _ = ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors)
        let bg = pack(colors.background), fg = pack(colors.foreground)

        var it: GhosttyRenderStateRowIterator? = rowIterator
        _ = ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &it)
        var outRows: [TerminalRow] = []
        outRows.reserveCapacity(rows)
        while ghostty_render_state_row_iterator_next(rowIterator) {
            var rowID: UInt64 = 0
            _ = ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_ID, &rowID)
            var sel = GhosttyRenderStateRowSelection()
            sel.size = MemoryLayout<GhosttyRenderStateRowSelection>.size
            let hasSel = ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &sel) == GHOSTTY_SUCCESS
            var c: GhosttyRenderStateRowCells? = cells
            _ = ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &c)
            var rowCells: [TerminalCell] = []
            rowCells.reserveCapacity(cols)
            var x = 0
            while ghostty_render_state_row_cells_next(cells) {
                var cell = TerminalCell(text: "")
                var len: Int = 0
                _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &len)
                if len > 0 {
                    codepoints.withUnsafeMutableBufferPointer { buf in
                        var cb = GhosttyCodepointBuffer(ptr: buf.baseAddress, cap: buf.count, len: 0)
                        _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &cb)
                        var s = String.UnicodeScalarView()
                        for i in 0..<min(cb.len, buf.count) {
                            if let u = Unicode.Scalar(buf[i]) { s.append(u) }
                        }
                        cell.text = String(s)
                    }
                }
                var rgb = GhosttyColorRgb()
                if ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &rgb) == GHOSTTY_SUCCESS {
                    cell.fg = pack(rgb)
                }
                if ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &rgb) == GHOSTTY_SUCCESS {
                    cell.bg = pack(rgb)
                }
                var styled = false
                _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &styled)
                if styled {
                    var style = GhosttyStyle()
                    if ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style) == GHOSTTY_SUCCESS {
                        let f = UInt32(style.flags)
                        cell.bold = f & (1 << 0) != 0
                        cell.italic = f & (1 << 1) != 0
                        cell.faint = f & (1 << 2) != 0
                        cell.inverse = f & (1 << 4) != 0
                        cell.strikethrough = f & (1 << 6) != 0
                        cell.underline = (f >> 8) & 0x7 != 0
                    }
                }
                var raw: GhosttyCell = 0
                if ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw) == GHOSTTY_SUCCESS {
                    var wide = GHOSTTY_CELL_WIDE_NARROW
                    _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
                    cell.wide = wide == GHOSTTY_CELL_WIDE_WIDE
                    cell.skip = wide == GHOSTTY_CELL_WIDE_SPACER_TAIL
                }
                if hasSel, x >= Int(sel.start_x), x <= Int(sel.end_x) { cell.selected = true }
                rowCells.append(cell)
                x += 1
            }
            outRows.append(TerminalRow(id: rowID, cells: rowCells))
        }

        var cursor: TerminalCursor?
        var cur = GhosttyRenderStateCursor()
        cur.size = MemoryLayout<GhosttyRenderStateCursor>.size
        if ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cur) == GHOSTTY_SUCCESS, cur.viewport_has_value {
            let style: TerminalCursor.Style
            switch cur.visual_style {
            case GHOSTTY_CURSOR_STYLE_BAR: style = .bar
            case GHOSTTY_CURSOR_STYLE_UNDERLINE: style = .underline
            case GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW: style = .hollow
            default: style = .block
            }
            cursor = TerminalCursor(x: Int(cur.viewport_x), y: Int(cur.viewport_y), style: style, visible: cur.visible)
        }
        _ = ghostty_render_state_clean(render)
        return TerminalFrame(cols: cols, rows: outRows, cursor: cursor, background: bg, foreground: fg)
    }

    /// Encodes a key for the host, honouring the terminal's current key modes.
    public func encode(_ key: TerminalKey) -> Data {
        guard let term, let keyEvent, let encoder else { return Data() }
        _ = ghostty_key_encoder_set_from_terminal(encoder, term)
        _ = ghostty_key_event_set_action(keyEvent, GHOSTTY_KEY_ACTION_PRESS)
        var mods: GhosttyMods = 0
        var ghosttyKey = GHOSTTY_KEY_UNIDENTIFIED
        var utf8 = Data()
        switch key {
        case .text(let s): utf8 = Data(s.utf8)
        case .enter: ghosttyKey = GHOSTTY_KEY_ENTER
        case .shiftEnter: ghosttyKey = GHOSTTY_KEY_ENTER; mods = GhosttyMods(GHOSTTY_MODS_SHIFT)
        case .tab: ghosttyKey = GHOSTTY_KEY_TAB
        case .backspace: ghosttyKey = GHOSTTY_KEY_BACKSPACE
        case .escape: ghosttyKey = GHOSTTY_KEY_ESCAPE
        case .delete: ghosttyKey = GHOSTTY_KEY_DELETE
        case .insert: ghosttyKey = GHOSTTY_KEY_INSERT
        case .up: ghosttyKey = GHOSTTY_KEY_ARROW_UP
        case .down: ghosttyKey = GHOSTTY_KEY_ARROW_DOWN
        case .left: ghosttyKey = GHOSTTY_KEY_ARROW_LEFT
        case .right: ghosttyKey = GHOSTTY_KEY_ARROW_RIGHT
        case .home: ghosttyKey = GHOSTTY_KEY_HOME
        case .end: ghosttyKey = GHOSTTY_KEY_END
        case .pageUp: ghosttyKey = GHOSTTY_KEY_PAGE_UP
        case .pageDown: ghosttyKey = GHOSTTY_KEY_PAGE_DOWN
        case .function(let n): ghosttyKey = GhosttyKey(GHOSTTY_KEY_F1.rawValue + UInt32(max(0, min(n - 1, 11))))
        case .ctrl(let c):
            mods = GhosttyMods(GHOSTTY_MODS_CTRL)
            utf8 = Data(String(c).lowercased().utf8)
            ghosttyKey = letterKey(c)
        case .alt(let c):
            mods = GhosttyMods(GHOSTTY_MODS_ALT)
            utf8 = Data(String(c).utf8)
            ghosttyKey = letterKey(c)
        }
        _ = ghostty_key_event_set_key(keyEvent, ghosttyKey)
        _ = ghostty_key_event_set_mods(keyEvent, mods)
        if let scalar = utf8.isEmpty ? nil : String(decoding: utf8, as: UTF8.self).unicodeScalars.first {
            _ = ghostty_key_event_set_unshifted_codepoint(keyEvent, scalar.value)
        }
        var out = [UInt8](repeating: 0, count: 64)
        var written = 0
        let result: GhosttyResult = utf8.withUnsafeBytes { buf in
            let s = GhosttyString(ptr: buf.bindMemory(to: UInt8.self).baseAddress, len: buf.count)
            _ = ghostty_key_event_set_utf8(keyEvent, s)
            return ghostty_key_encoder_encode(encoder, keyEvent, &out, out.count, &written)
        }
        if result == GHOSTTY_SUCCESS, written > 0 {
            // Without the kitty protocol (CSI … u) Shift-Return comes out as xterm's CSI 27;2;13~,
            // which Claude Code under herdr does not read. Send ESC CR, the newline Claude Code and
            // most line editors accept (what Claude Code's /terminal-setup configures).
            if case .shiftEnter = key, out[written - 1] != UInt8(ascii: "u") { return Data([0x1b, 0x0d]) }
            return Data(out[0..<written])
        }
        // Fall back to the raw text for anything the encoder declined.
        if case .text = key { return utf8 }
        return Data()
    }

    private func letterKey(_ c: Character) -> GhosttyKey {
        guard let ascii = c.lowercased().unicodeScalars.first?.value, ascii >= 97, ascii <= 122 else {
            return GHOSTTY_KEY_UNIDENTIFIED
        }
        return GhosttyKey(GHOSTTY_KEY_A.rawValue + (ascii - 97))
    }

    private func pack(_ c: GhosttyColorRgb) -> UInt32 {
        (UInt32(c.r) << 16) | (UInt32(c.g) << 8) | UInt32(c.b)
    }
}
