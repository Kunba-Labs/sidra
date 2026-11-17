#if os(macOS)
import AppKit
import CoreText
import SidraDesign

/// The Mac face of a `GhosttyEngine`: the same Core Text grid as the iOS `GhosttyTerminalView`, with
/// AppKit keyboard and mouse input. Click a link with ⌘ to open it; drag, double- or triple-click selects.
/// Text goes through NSTextInputClient, so dead keys and input methods compose before reaching the shell.
public final class GhosttyMacView: NSView, NSMenuItemValidation, NSTextInputClient {
    public let engine: GhosttyEngine
    private let io: TerminalIO
    private var readTask: Task<Void, Never>?
    private let redrawGate = RedrawGate()
    private var frame_: TerminalFrame?
    private var linkGrid: [[Character]] = [], linkCellsCache: Set<Int> = []
    private var cellSize = CGSize(width: 8, height: 20)
    private var font: NSFont
    private var boldFont: NSFont
    private var fontObserver: NSObjectProtocol?
    public var onTitle: ((String) -> Void)?
    public var onFind: (() -> Void)?
    public var onOpenLink: ((URL) -> Void)?
    public var onSearchResult: ((Int, Int?) -> Void)?
    public var onPasteImage: ((Data) async -> String?)?
    private var selectionAnchor: (x: Int, y: Int)?
    private var searchMatches: [GhosttyEngine.Match] = []
    private var searching = false
    private var scrollResidual: CGFloat = 0
    /// The current left-button drag belongs to the program (mouse tracking), not to Sidra's selection.
    private var toProgram = false
    /// A program may fill the clipboard on its own only right after a copy-shaped gesture (see iOS).
    private var copyGrant: Date?

    public init(io: TerminalIO) {
        self.io = io
        (font, boldFont) = TerminalFont.faces(family: TerminalFont.family, size: TerminalFont.size)
        GhosttyEngine.defaultCursorBlink = TerminalFont.defaults.cursorBlink
        engine = GhosttyEngine(cols: 80, rows: 24)
        super.init(frame: .zero)
        measureCell()
        // Settings and ⌘+ ⌘− ⌘0 change the font for every pane at once.
        fontObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyFontSetting() }
        }
        engine.onReply = { [weak self] data in self?.io.write(data) }
        engine.onCopy = { [weak self] text in
            guard let self else { return false }
            if let grant = self.copyGrant, Date().timeIntervalSince(grant) < 5 {
                self.copyGrant = nil
                Platform.pasteString = text
                return true
            }
            if let text, !text.isEmpty { self.offerCopy(text) }
            return false
        }
        engine.onTitle = { [weak self] t in self?.onTitle?(t) }
        engine.onBell = { NSSound.beep() }
        readTask = Task { [weak self] in
            for await chunk in io.output {
                guard let self else { return }
                await MainActor.run {
                    if self.focusWatch.turnsOn(chunk) { self.reportedFocus = nil }
                    self.engine.feed(chunk)
                    self.outputArrived()
                    if self.searching { self.refreshSearch() } else { self.redrawGate.request { [weak self] in self?.needsDisplay = true } }
                }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit {
        readTask?.cancel(); rotTimer?.invalidate(); blinkTimer?.invalidate()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        fontObserver.map(NotificationCenter.default.removeObserver)
    }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The window installs this view as first responder only after this returns, so focus comes from the
    /// call's result and the window's key state, and the blink restarts once the change has landed.
    public override func becomeFirstResponder() -> Bool {
        let r = super.becomeFirstResponder()
        if r { reportFocus(window?.isKeyWindow == true) }
        DispatchQueue.main.async { [weak self] in self?.restartBlink() }
        return r
    }
    public override func resignFirstResponder() -> Bool {
        let r = super.resignFirstResponder()
        restartBlink(); reportFocus(false)
        return r
    }

    /// The last focus state the program heard, so a window change and a first-responder change do not both send it.
    private var reportedFocus: Bool?
    private var focusWatch = FocusModeWatch()
    private func reportFocus(_ on: Bool? = nil) {
        let focused = on ?? isFocused
        guard focused != reportedFocus, !lost else { return }
        let bytes = engine.encodeFocus(focused)
        guard !bytes.isEmpty else { return }   // mode off: nothing heard, so nothing recorded
        reportedFocus = focused
        io.write(bytes)
    }

    // MARK: Cursor blink

    /// Output may move the cursor: show it solid and start the blink phase over. (Whether to blink at
    /// all is read in draw, from the frame it already has: asking the engine here would clear its dirty flag.)
    private func outputArrived() {
        // Mode 1004 off: forget what was reported, so turning it on again hears the current focus.
        if !engine.focusReporting { reportedFocus = nil } else if reportedFocus == nil { reportFocus() }
        blinkOff = false
        blinkTimer?.fireDate = Date().addingTimeInterval(0.6)
    }

    /// Off half of a blink. Reset to on by every key, output and focus change, so a moving cursor shows.
    private var blinkOff = false
    private var blinkTimer: Timer?
    private var windowObservers: [NSObjectProtocol] = []

    /// The one rule restartBlink and draw share, so they cannot disagree and loop.
    private func shouldBlink(_ f: TerminalFrame) -> Bool {
        isFocused && f.cursor?.blinking == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Blinks only while focused and asked for by the program; otherwise the cursor stays on.
    private func restartBlink() {
        blinkTimer?.invalidate(); blinkTimer = nil
        blinkOff = false
        needsDisplay = true
        guard let f = frame_, shouldBlink(f) else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.blinkOff.toggle(); self.needsDisplay = true }
        }
    }

    /// The window's key state decides filled or hollow: redraw when it changes.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let window else { blinkTimer?.invalidate(); blinkTimer = nil; return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restartBlink(); self?.reportFocus() }
            })
        }
        restartBlink()
        if window != nil { DispatchQueue.main.async { [weak self] in self?.applyFocus() } }
    }
    private var isFocused: Bool { window?.firstResponder === self && window?.isKeyWindow == true }

    /// The pane has focus. Applied now if the view is in a window, else when it enters one.
    /// Hidden tabs stay built: an unfocused terminal gives the keys up instead of keeping them.
    public var wantsFocus = false
    public func applyFocus() {
        guard let window else { return }
        if wantsFocus, window.firstResponder !== self { window.makeFirstResponder(self) }
        else if !wantsFocus, window.firstResponder === self { window.makeFirstResponder(nil) }
    }


    /// The font's own line height, as Ghostty does, plus its adjust-cell-height when set there.
    private func measureCell() {
        let size = ("M" as NSString).size(withAttributes: [.font: font])
        // At least a point each way: a large negative adjust-cell-height must not make the grid divide by zero.
        cellSize = CGSize(width: max(1, ceil(size.width)), height: max(1, ceil(fontLineHeight + TerminalFont.defaults.extraLineHeight)))
    }

    private func applyFontSetting() {
        let family = TerminalFont.family, size = TerminalFont.size
        guard family != font.familyName || size != font.pointSize else { return }
        (font, boldFont) = TerminalFont.faces(family: family, size: size)
        measureCell()
        fitGrid(bounds.size, force: true)
    }
    private var fontLineHeight: CGFloat { font.ascender - font.descender + font.leading }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeCopyOffer()
        fitGrid(newSize)
    }

    /// Columns and rows that fit `size` at the current cell; the program hears of a change.
    private func fitGrid(_ size: NSSize, force: Bool = false) {
        let cols = max(Int(size.width / cellSize.width), 2), rows = max(Int(size.height / cellSize.height), 1)
        if force || cols != engine.cols || rows != engine.rows {
            engine.resize(cols: cols, rows: rows, cellWidth: Int(cellSize.width), cellHeight: Int(cellSize.height))
            io.resize(cols: cols, rows: rows)
        }
        needsDisplay = true
    }

    // MARK: Search

    public func search(_ needle: String?) {
        let r = engine.search(needle)
        searching = !(needle ?? "").isEmpty
        refreshSearch()
        onSearchResult?(r.total, r.index)
    }
    public func searchNext() { let r = engine.searchNext(); refreshSearch(); onSearchResult?(r.total, r.index) }
    public func searchPrevious() { let r = engine.searchPrevious(); refreshSearch(); onSearchResult?(r.total, r.index) }
    private func refreshSearch() { searchMatches = searching ? engine.viewportMatches() : []; needsDisplay = true }

    // MARK: Lost connection

    public var lost = false {
        didSet {
            guard lost != oldValue else { return }
            lostAt = lost ? Date() : nil
            rotTimer?.invalidate(); rotTimer = nil
            if lost, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                rotTimer = Timer.scheduledTimer(withTimeInterval: 1 / 15, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.needsDisplay = true }
                }
            }
            needsDisplay = true
        }
    }
    private var lostAt: Date?
    private var rotTimer: Timer?

    // MARK: Mouse

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
    private func cell(at p: CGPoint) -> (x: Int, y: Int) { (Int(p.x / cellSize.width), Int(p.y / cellSize.height)) }

    private func report(_ action: GhosttyEngine.MouseAction, _ button: GhosttyEngine.MouseButton, at p: CGPoint) -> Bool {
        let bytes = engine.encodeMouse(action, button: button, at: p, cell: cellSize, viewSize: bounds.size)
        guard !bytes.isEmpty else { return false }
        io.write(bytes)
        return true
    }

    private func link(at p: CGPoint) -> URL? {
        guard let rows = frame_?.rows else { return nil }
        let c = cell(at: p)
        let lines = rows.map { row in row.cells.map { $0.skip ? Character(" ") : ($0.text.first ?? " ") } }
        return TerminalLinks.url(atRow: c.y, col: c.x, in: lines)
    }

    public override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = point(e)
        if e.modifierFlags.contains(.command), let url = link(at: p) {
            if let onOpenLink { onOpenLink(url) } else { NSWorkspace.shared.open(url) }
            return
        }
        // Option forces a Sidra selection even when the program owns the mouse (herdr, Claude Code).
        // The route holds until mouseUp, so a press and its release always go to the same side.
        toProgram = engine.mouseTracking && !e.modifierFlags.contains(.option)
        if toProgram { _ = report(.press, .left, at: p); return }
        let c = cell(at: p)
        switch e.clickCount {
        case 2: copyGrant = Date(); engine.selectWord(x: c.x, y: c.y); selectionAnchor = nil
        case 3: copyGrant = Date(); engine.selectLine(x: c.x, y: c.y); selectionAnchor = nil
        default: engine.clearSelection(); selectionAnchor = c
        }
        needsDisplay = true
    }

    public override func mouseDragged(with e: NSEvent) {
        let p = point(e)
        if toProgram { _ = report(.motion, .left, at: p); return }
        guard let a = selectionAnchor else { return }
        copyGrant = Date()
        engine.select(from: a, to: cell(at: p))
        needsDisplay = true
    }

    public override func mouseUp(with e: NSEvent) {
        let p = point(e)
        if toProgram { toProgram = false; _ = report(.release, .left, at: p); return }
        selectionAnchor = nil
    }

    public override func rightMouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = point(e)
        if engine.mouseTracking { _ = report(.press, .right, at: p); _ = report(.release, .right, at: p); return }
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: e, for: self)
    }

    public override func scrollWheel(with e: NSEvent) {
        scrollResidual += e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * cellSize.height
        let lines = Int(scrollResidual / cellSize.height)
        guard lines != 0 else { return }
        scrollResidual -= CGFloat(lines) * cellSize.height
        if engine.mouseTracking {
            let p = point(e)
            for _ in 0..<abs(lines) { _ = report(.press, lines > 0 ? .wheelUp : .wheelDown, at: p) }
            return
        }
        engine.scroll(by: -lines)
        if searching { refreshSearch() }
        needsDisplay = true
    }

    public override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }

    // MARK: Keyboard

    /// ⌘C with a selection and ⌘V belong to the terminal even if a menu does not route them here.
    public override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: e) }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command else { return super.performKeyEquivalent(with: e) }
        switch e.charactersIgnoringModifiers {
        case "c" where engine.hasSelection: copy(nil); return true
        case "c" where offered != nil: takeOffer(); return true   // ⌘C accepts the host's copy offer
        case "v": paste(nil); return true
        default: return super.performKeyEquivalent(with: e)
        }
    }

    public override func keyDown(with e: NSEvent) {
        guard !lost else { return }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) { return super.keyDown(with: e) }   // menu shortcuts
        // While an input method composes, every key is its own (arrows pick, Return commits).
        if marked != nil { return interpretKeyEvents([e]) }
        let shift = mods.contains(.shift), ctrl = mods.contains(.control), alt = mods.contains(.option)
        let key: TerminalKey? = switch e.keyCode {
        case 126: .up
        case 125: .down
        case 123: .left
        case 124: .right
        case 53: .escape
        case 115: .home
        case 119: .end
        case 116: .pageUp
        case 121: .pageDown
        case 117: .delete
        case 51: .backspace
        case 36, 76: shift ? .shiftEnter : .enter
        case 48: shift ? .text("\u{1b}[Z") : .tab
        case 122: .function(1)
        case 120: .function(2)
        case 99: .function(3)
        case 118: .function(4)
        case 96: .function(5)
        case 97: .function(6)
        case 98: .function(7)
        case 100: .function(8)
        case 101: .function(9)
        case 109: .function(10)
        case 103: .function(11)
        case 111: .function(12)
        default: nil
        }
        // Named keys carry their modifiers (Option-Left, Ctrl-F5); the engine encodes them for the active mode.
        if let key {
            if case .shiftEnter = key { return send(key) }
            if case .text = key { return send(key) }
            return send(key, shift: shift, alt: alt, ctrl: ctrl)
        }
        let bare = e.charactersIgnoringModifiers ?? ""
        if ctrl, let c = bare.first, c.isLetter || "[]\\^_@ ".contains(c) { return send(.ctrl(c)) }
        // Option is Meta, as in the iPad app, except on a dead key (Option-E, Option-U…): an empty
        // `characters` marks one, and the input system composes it with the next key.
        if alt, let c = bare.first, !(e.characters ?? "").isEmpty { return send(.alt(c)) }
        interpretKeyEvents([e])   // → insertText, or setMarkedText while a dead key or IME composes
    }

    // MARK: NSTextInputClient

    /// Text an input method is composing; drawn at the cursor, sent only when committed.
    private var marked: String?

    public func insertText(_ string: Any, replacementRange: NSRange) {
        marked = nil
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if !text.isEmpty { send(.text(text)) }
        needsDisplay = true
    }
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = text.isEmpty ? nil : text
        needsDisplay = true
    }
    public func unmarkText() { marked = nil; needsDisplay = true }
    public func hasMarkedText() -> Bool { marked != nil }
    public func markedRange() -> NSRange { marked.map { NSRange(location: 0, length: ($0 as NSString).length) } ?? NSRange(location: NSNotFound, length: 0) }
    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    public func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    /// The cursor cell in screen coordinates: where the IME candidate window opens.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let c = frame_?.cursor
        let r = CGRect(x: CGFloat(c?.x ?? 0) * cellSize.width, y: CGFloat(c?.y ?? 0) * cellSize.height, width: cellSize.width, height: cellSize.height)
        return window?.convertToScreen(convert(r, to: nil)) ?? .zero
    }
    /// Keys the input system maps to editing commands (Return, arrows) were handled in keyDown already.
    public override func doCommand(by selector: Selector) {}

    public func send(_ key: TerminalKey, shift: Bool = false, alt: Bool = false, ctrl: Bool = false) {
        guard !lost else { return }
        let bytes = engine.encode(key, shift: shift, alt: alt, ctrl: ctrl)
        guard !bytes.isEmpty else { return }
        io.write(bytes)
        engine.scrollToBottom()
        if blinkTimer != nil { restartBlink() }   // typing holds the cursor on
    }

    public func pasteText(_ text: String) {
        guard !lost else { return }
        let bytes = engine.encodePaste(text)
        guard !bytes.isEmpty else { return }
        io.write(bytes)
        engine.scrollToBottom()
    }

    @objc public func copy(_ sender: Any?) {
        guard let text = engine.selectionText(), !text.isEmpty else { return }
        Platform.pasteString = text
    }

    @objc public func paste(_ sender: Any?) {
        if engine.hasSelection { engine.clearSelection(); needsDisplay = true }
        if let s = Platform.pasteString { return pasteText(s) }
        guard let upload = onPasteImage, let data = Platform.pasteImagePNG else { return }
        Task { @MainActor [weak self] in
            guard let path = await upload(data) else { return }
            if let self, self.window?.firstResponder === self { self.pasteText(path) } else { Platform.pasteString = path }
        }
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): engine.hasSelection
        case #selector(paste(_:)): Platform.pasteString != nil || (onPasteImage != nil && Platform.pasteboardHasImage)
        default: true
        }
    }

    // MARK: Copy offer

    private var offered: String?
    private lazy var copyOffer: NSButton = {
        // Sidra's raised pill: raised surface, text colour, hairline border.
        let b = NSButton(title: "", target: self, action: #selector(takeOffer))
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = NSColor(SidraColor.raised).cgColor
        b.layer?.borderColor = NSColor(SidraColor.hairline2).cgColor
        b.layer?.borderWidth = 1
        b.contentTintColor = NSColor(SidraColor.text)
        b.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        b.imagePosition = .imageLeading
        b.isHidden = true
        addSubview(b)
        return b
    }()
    /// Top right, never wider than the pane: a narrow split truncates the label instead.
    private func placeCopyOffer() {
        guard !copyOffer.isHidden else { return }
        copyOffer.sizeToFit()
        let w = min(copyOffer.frame.width + 24, max(0, bounds.width - 2 * SidraSpace.gap))
        copyOffer.frame = CGRect(x: bounds.width - w - SidraSpace.gap, y: SidraSpace.gap, width: w, height: 28)
    }

    @objc private func takeOffer() { Platform.pasteString = offered; offered = nil; copyOffer.isHidden = true }

    /// The host asked to copy without a gesture that grants it: one click puts the text on the clipboard.
    private func offerCopy(_ text: String) {
        offered = text
        copyOffer.attributedTitle = NSAttributedString(string: " Copy \(text.count) characters from the host (⌘C)",
            attributes: [.font: NSFont(name: "Inter-Regular", size: 13) ?? .systemFont(ofSize: 13), .foregroundColor: NSColor(SidraColor.text)])
        (copyOffer.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        copyOffer.layer?.cornerRadius = 14
        copyOffer.isHidden = false
        placeCopyOffer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.offered == text else { return }
            self.offered = nil
            self.copyOffer.isHidden = true
        }
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if let f = engine.frame(force: frame_ == nil) { frame_ = f } else { frame_?.cursor = engine.cursor() }   // a cursor-only move
        guard let frame = frame_ else { NSColor(SidraColor.pane).setFill(); bounds.fill(); return }
        // The program turned blinking on or off (DECSCUSR): start or stop the timer after this pass.
        if shouldBlink(frame) != (blinkTimer != nil) {
            DispatchQueue.main.async { [weak self] in self?.restartBlink() }
        }
        ctx.setFillColor(NSColor(rgb: frame.background).cgColor)
        ctx.fill(bounds)
        let defaultFg = NSColor(rgb: frame.foreground)
        let selectionBg = NSColor(rgb: 0x2a3340)   // as on iPad; no token for terminal selection yet
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let rotT = lostAt.map { Date().timeIntervalSince($0) + (reduceMotion ? 3 : 0) }
        let rotK = rotT.map { min(1, $0 / 0.6) } ?? 0
        let rotFg = NSColor(SidraColor.muted).greyed(0.4), rotGold = NSColor(SidraColor.gold).greyed(0.2)
        let grid = frame.rows.map { row in row.cells.map { $0.skip ? Character(" ") : ($0.text.first ?? " ") } }
        if grid != linkGrid {
            linkGrid = grid
            linkCellsCache = TerminalLinks.spans(in: grid).reduce(into: Set<Int>()) { $0.formUnion($1.cells) }
        }
        let baselineOffset = (cellSize.height - fontLineHeight) / 2 + font.ascender

        for (y, row) in frame.rows.enumerated() {
            let top = CGFloat(y) * cellSize.height
            var x = 0
            for cell in row.cells {
                defer { x += 1 }
                if cell.skip { continue }
                let cellRect = CGRect(x: CGFloat(x) * cellSize.width, y: top, width: cellSize.width * (cell.wide ? 2 : 1), height: cellSize.height)
                var fg = cell.fg.map(NSColor.init(rgb:)) ?? defaultFg
                var bg = cell.bg.map(NSColor.init(rgb:))
                if cell.inverse { let t = fg; fg = bg ?? NSColor(rgb: frame.background); bg = t }
                if cell.selected { bg = selectionBg }
                if let bg { ctx.setFillColor(bg.cgColor); ctx.fill(cellRect) }
                let blank = cell.text.isEmpty || cell.text == " "
                var text = cell.text
                if let rotT {
                    if let block = GhosttyMacView.rot(x: x, y: y, t: rotT, k: rotK, blank: blank) {
                        text = String(block)
                        fg = block == "█" && (x * 7 + y * 13) % 11 == 0 ? rotGold : rotFg
                    } else {
                        fg = fg.greyed(rotK * 0.85)
                    }
                }
                guard !text.isEmpty, text != " " else { continue }
                let link = linkCellsCache.contains(y * 10_000 + x)
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: (cell.bold || link ? boldFont : font) as CTFont,
                    .foregroundColor: (cell.faint ? fg.withAlphaComponent(0.6) : fg).cgColor,
                ]
                if cell.italic { attrs[.obliqueness] = 0.2 }
                if cell.underline || link { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue; attrs[.underlineColor] = fg.cgColor }
                if cell.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                drawText(terminalTextPresentation(text), attrs, at: CGPoint(x: cellRect.minX, y: top + baselineOffset), in: ctx)
            }
        }

        for m in searchMatches where m.y < frame.rows.count {
            let r = CGRect(x: CGFloat(m.x0) * cellSize.width, y: CGFloat(m.y) * cellSize.height,
                           width: CGFloat(m.x1 - m.x0 + 1) * cellSize.width, height: cellSize.height)
            ctx.setStrokeColor(NSColor(SidraColor.gold).cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(r.insetBy(dx: 0.75, dy: 0.75))
        }

        if lostAt == nil, !blinkOff, let cur = frame.cursor, cur.visible, cur.y >= 0, cur.y < frame.rows.count {
            let r = CGRect(x: CGFloat(cur.x) * cellSize.width, y: CGFloat(cur.y) * cellSize.height, width: cellSize.width, height: cellSize.height)
            let color = NSColor(SidraColor.text).cgColor
            ctx.setFillColor(color); ctx.setStrokeColor(color)
            switch (cur.style, isFocused) {
            case (_, false), (.hollow, _): ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
            case (.bar, _): ctx.fill(CGRect(x: r.minX, y: r.minY, width: 2, height: r.height))
            case (.underline, _): ctx.fill(CGRect(x: r.minX, y: r.maxY - 2, width: r.width, height: 2))
            case (.block, _):
                ctx.fill(r)
                if let cell = frame.rows[cur.y].cells[safe: cur.x], !cell.text.isEmpty {
                    drawText(cell.text, [.font: font as CTFont, .foregroundColor: NSColor(rgb: frame.background).cgColor],
                             at: CGPoint(x: r.minX, y: r.minY + baselineOffset), in: ctx)
                }
            }
        }
        drawMarked(in: ctx, baseline: baselineOffset)
    }

    /// Composing text sits over the cursor on the raised colour, underlined, until the IME commits it.
    private func drawMarked(in ctx: CGContext, baseline: CGFloat) {
        guard let marked, let cur = frame_?.cursor else { return }
        let w = CGFloat(marked.count) * cellSize.width
        let r = CGRect(x: CGFloat(cur.x) * cellSize.width, y: CGFloat(cur.y) * cellSize.height, width: w, height: cellSize.height)
        ctx.setFillColor(NSColor(SidraColor.raised).cgColor)
        ctx.fill(r)
        let fg = NSColor(SidraColor.text).cgColor
        drawText(marked, [.font: font as CTFont, .foregroundColor: fg, .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: fg],
                 at: CGPoint(x: r.minX, y: r.minY + baseline), in: ctx)
    }

    private func drawText(_ s: String, _ attrs: [NSAttributedString.Key: Any], at p: CGPoint, in ctx: CGContext) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)   // the view is flipped; glyphs are not
        ctx.textPosition = p
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// Dither rot at cell (x, y); the same field as the iOS view.
    static func rot(x: Int, y: Int, t: Double, k: Double, blank: Bool) -> Character? {
        let f = (sin(Double(x) * 0.18 + t * 0.9) + sin(Double(y) * 0.35 - t * 0.7) + sin(Double(x + y) * 0.11 + t * 0.5)) / 3
        let v = (f + 1) / 2 * k * 1.05 - 0.3
        guard v > 0, !blank || v > 0.35 else { return nil }
        return Array("░▒▓█")[min(3, Int(v * 5))]
    }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255, blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
    /// Toward a dim grey of the same lightness by `amount` (0…1).
    func greyed(_ amount: CGFloat) -> NSColor {
        guard let c = usingColorSpace(.sRGB) else { return self }
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        let l = (r * 0.3 + g * 0.59 + b * 0.11) * 0.62
        return NSColor(srgbRed: r + (l - r) * amount, green: g + (l - g) * amount, blue: b + (l - b) * amount, alpha: c.alphaComponent)
    }
}
#endif
