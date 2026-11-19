#if os(iOS)   // macOS: MacTerminal.swift
import UIKit
import CoreText
import SidraDesign

/// Draws a `GhosttyEngine` grid with Core Text and feeds hardware keyboard input to a `TerminalIO`.
/// ponytail: CGContext text drawing, one pass per frame. Metal arrives when a 4K display or
/// 200-column pane makes this measurably slow.
public final class GhosttyTerminalView: UIView, UIKeyInput, UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate {
    public let engine: GhosttyEngine
    private let io: TerminalIO
    private var readTask: Task<Void, Never>?
    private var displayLink: CADisplayLink?
    private let redrawGate = RedrawGate()
    private var frame_: TerminalFrame?
    /// Link cells of the last drawn text; the link scan reruns only when the visible text changes.
    private var linkGrid: [[Character]] = [], linkCellsCache: Set<Int> = []
    private var cellSize = CGSize(width: 8, height: 20)
    private let font: UIFont
    private let boldFont: UIFont
    private var fontCache: [UInt8: CTFont] = [:]
    public var onTitle: ((String) -> Void)?
    public var onReady: ((Int, Int) -> Void)?
    /// Cmd-F in the terminal: the host shows its find bar.
    public var onFind: (() -> Void)?
    /// A tapped web link; Safari when unset.
    public var onOpenLink: ((URL) -> Void)?
    /// (total matches, selected index) after a search call.
    public var onSearchResult: ((Int, Int?) -> Void)?
    private var editMenu: UIEditMenuInteraction?
    private var selectionAnchor: (x: Int, y: Int)?
    /// Where a tap-and-hold selection started; set while the finger is down after the hold.
    private var holdAnchor: (x: Int, y: Int)?
    private var searchMatches: [GhosttyEngine.Match] = []
    private var searching = false
    private let keyRow = SidraKeyRow()
    /// -sidra.dumpVT (tests): every byte the PTY delivers is appended to tmp/sidra-vt.bin.
    static let dumpVT = CommandLine.arguments.contains("-sidra.dumpVT")
    static let dumpPath: String = {
        let p = NSTemporaryDirectory() + "sidra-vt.bin"; FileManager.default.createFile(atPath: p, contents: nil); return p
    }()
    public override var inputAccessoryView: UIView? { HardwareKeyboard.attached || FloatingKeyboard.shared.enabled ? nil : keyRow }
    /// With Sidra's floating keyboard on, an empty input view keeps typing focus (and hardware keys)
    /// without Apple's keyboard, and iOS reports no keyboard, so panes never shrink.
    private lazy var emptyInput = UIView(frame: .zero)
    public override var inputView: UIView? { FloatingKeyboard.shared.enabled ? emptyInput : nil }
    @objc private func keyboardChanged() { reloadInputViews() }

    public init(io: TerminalIO, fontSize: CGFloat = SidraFont.monoSize) {
        self.io = io
        font = UIFont(name: "JetBrainsMono-Regular", size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        boldFont = UIFont(name: "JetBrainsMonoRoman-Bold", size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .bold)
        engine = GhosttyEngine(cols: 80, rows: 24)
        super.init(frame: .zero)
        backgroundColor = UIColor(hex: 0x12151a)
        isOpaque = true
        contentMode = .redraw
        measureCell()
        engine.onReply = { [weak self] data in self?.io.write(data) }
        // A program fills the clipboard straight away once per copy-shaped gesture here (drag-select, double or triple
        // tap), within 5 s. Anything else, such as a copy key in tmux or vim, only offers a Copy button: a remote host
        // can never swap what you paste next on its own.
        engine.onCopy = { [weak self] text in
            guard let self else { return false }
            if let grant = self.copyGrant, Date().timeIntervalSince(grant) < 5 {
                self.copyGrant = nil
                if let text { UIPasteboard.general.string = text } else { UIPasteboard.general.items = [] }
                return true
            }
            if let text, !text.isEmpty { self.offerCopy(text) }
            return false
        }
        engine.onTitle = { [weak self] t in self?.onTitle?(t) }
        readTask = Task { [weak self] in
            for await chunk in io.output {
                guard let self else { return }
                await MainActor.run {
                    if GhosttyTerminalView.dumpVT { try? FileHandle(forWritingAtPath: GhosttyTerminalView.dumpPath).map { $0.seekToEndOfFile(); $0.write(chunk); try? $0.close() } }
                    if self.focusWatch.turnsOn(chunk) { self.reportedFocus = nil }
                    self.engine.feed(chunk)
                    // Mode 1004 off: forget what was reported, so turning it on again hears the current focus.
                    if !self.engine.focusReporting { self.reportedFocus = nil }
                    else if self.reportedFocus == nil { self.reportFocus(self.hasFocus) }
                    self.echoArrived()
                    if self.sendOffered { self.placeSendOffer() }   // follows the cursor as the paste echoes back
                    if self.searching { self.refreshSearch() } else { self.redrawGate.request { [weak self] in self?.setNeedsDisplay() } }
                }
            }
        }
        HardwareKeyboard.observe(self, #selector(keyboardChanged))
        // An app switch keeps first responder: the program hears focus out, and in again on return.
        for (name, active) in [(UIScene.willDeactivateNotification, false), (UIScene.didActivateNotification, true)] {
            sceneObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let scene = note.object as? UIScene, scene === self.window?.windowScene else { return }
                    self.reportFocus(active && self.isFirstResponder)
                }
            })
        }
        keyRow.onKey = { [weak self] key, ctrl, alt in
            guard let self else { return }
            switch key {
            case .esc: self.send(.escape)
            case .tab: self.send(.tab)
            case .up: self.send(.up)
            case .down: self.send(.down)
            case .left: self.send(.left)
            case .right: self.send(.right)
            case .ctrl, .alt: break
            case .paste: self.paste(nil)
            default:
                if let c = key.rawValue.first {
                    if ctrl { self.send(.ctrl(c)) } else if alt { self.send(.alt(c)) } else { self.send(.text(key.rawValue)) }
                }
            }
        }
        let triple = UITapGestureRecognizer(target: self, action: #selector(handleTripleTap(_:)))
        triple.numberOfTapsRequired = 3
        let double = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        double.numberOfTapsRequired = 2
        double.require(toFail: triple)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.require(toFail: double)
        [triple, double, tap].forEach(addGestureRecognizer)
        // One finger drags select (or report to the program); two fingers and the trackpad wheel scroll.
        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        drag.maximumNumberOfTouches = 1
        drag.allowedScrollTypesMask = []
        addGestureRecognizer(drag)
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        scroll.allowedScrollTypesMask = [.continuous, .discrete]
        scroll.minimumNumberOfTouches = 2
        addGestureRecognizer(scroll)
        // Tap and hold selects in Sidra, like a text view, even when the program owns the mouse (herdr,
        // Claude Code): the word under the finger, then up to wherever it slides; Copy and Paste on lift.
        // On a blank spot it offers Paste. Fingers only: a trackpad right-click is a click for the program.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        hold.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        addGestureRecognizer(hold)
        let rightClick = UITapGestureRecognizer(target: self, action: #selector(handleRightClick(_:)))
        rightClick.buttonMaskRequired = .secondary
        addGestureRecognizer(rightClick)
        // Each recognizer sees only its own button: a right-click is never also a left tap, drag or hold.
        rightClickRecognizer = rightClick
        for g in [triple, double, tap, drag, hold, rightClick] as [UIGestureRecognizer] { g.delegate = self }
    }

    // MARK: Selection and mouse gestures

    private func cell(at p: CGPoint) -> (x: Int, y: Int) {
        (Int(p.x / cellSize.width), Int(p.y / cellSize.height))
    }

    private func report(_ action: GhosttyEngine.MouseAction, _ button: GhosttyEngine.MouseButton, at p: CGPoint) -> Bool {
        let bytes = engine.encodeMouse(action, button: button, at: p, cell: cellSize, viewSize: bounds.size)
        guard !bytes.isEmpty else { return false }
        io.write(bytes)
        return true
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        // A web link opens (Safari, or a Sidra tab for claude.ai), even under a program that owns the mouse (herdr, Claude Code).
        if let rows = frame_?.rows {
            let c = cell(at: p)
            let lines = rows.map { row in row.cells.map { $0.skip ? Character(" ") : ($0.text.first ?? " ") } }
            if let url = TerminalLinks.url(atRow: c.y, col: c.x, in: lines) { if let onOpenLink { onOpenLink(url) } else { UIApplication.shared.open(url) }; return }
        }
        // A tap ends a held selection even when the program owns the mouse (herdr): it never sees Sidra's.
        if engine.hasSelection { engine.clearSelection(); setNeedsDisplay() }
        if engine.mouseTracking {
            FloatingKeyboard.shared.externalInput()   // a click can move the program's cursor
            _ = report(.press, .left, at: p); _ = report(.release, .left, at: p)
        }
        becomeFirstResponder()  // an explicit tap always focuses; only launch-time auto-focus honours -sidra.noAutoFocus
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        copyGrant = Date()   // selects a word, which programs like herdr copy
        guard !engine.mouseTracking else { return }
        let c = cell(at: g.location(in: self))
        engine.selectWord(x: c.x, y: c.y)
        setNeedsDisplay()
        showEditMenu(at: g.location(in: self))
    }

    @objc private func handleTripleTap(_ g: UITapGestureRecognizer) {
        copyGrant = Date()
        guard !engine.mouseTracking else { return }
        let c = cell(at: g.location(in: self))
        engine.selectLine(x: c.x, y: c.y)
        setNeedsDisplay()
        showEditMenu(at: g.location(in: self))
    }

    @objc private func handleDrag(_ g: UIPanGestureRecognizer) {
        copyGrant = Date()   // a drag-select copies on release, however long it took
        let p = g.location(in: self)
        if engine.mouseTracking {
            switch g.state {
            case .began: _ = report(.press, .left, at: p)
            case .changed: _ = report(.motion, .left, at: p)
            case .ended, .cancelled, .failed: _ = report(.release, .left, at: p)
            default: break
            }
            return
        }
        switch g.state {
        case .began:
            selectionAnchor = cell(at: p)
        case .changed:
            if let a = selectionAnchor { engine.select(from: a, to: cell(at: p)); setNeedsDisplay() }
        case .ended:
            if let a = selectionAnchor { engine.select(from: a, to: cell(at: p)); setNeedsDisplay(); showEditMenu(at: p) }
            selectionAnchor = nil
        default:
            selectionAnchor = nil
        }
    }

    @objc private func handleHold(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            _ = becomeFirstResponder()
            let c = cell(at: p)
            engine.selectWord(x: c.x, y: c.y)
            setNeedsDisplay()
            if engine.hasSelection { holdAnchor = c } else { presentMenu(at: p) }
        case .changed:
            // Past the first cell the selection runs from the held word's far edge to the finger.
            if let a = holdAnchor, cell(at: p) != a { engine.extend(heldAt: a, to: cell(at: p)); setNeedsDisplay() }
        case .ended:
            if holdAnchor != nil { holdAnchor = nil; showEditMenu(at: p) }
        default:
            holdAnchor = nil
        }
    }

    /// Right-click: to the program when it tracks the mouse (herdr, vim), else the Copy/Paste menu.
    @objc private func handleRightClick(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        _ = becomeFirstResponder()
        if engine.mouseTracking { _ = report(.press, .right, at: p); _ = report(.release, .right, at: p) } else { presentMenu(at: p) }
    }

    private func showEditMenu(at p: CGPoint) {
        guard engine.hasSelection else { return }
        presentMenu(at: p)
    }

    /// The edit menu interaction is attached only while Sidra shows its menu: attached for good, its
    /// built-in secondary-click trigger opens Paste on every right-click meant for the program.
    private func presentMenu(at p: CGPoint) {
        let menu = editMenu ?? UIEditMenuInteraction(delegate: self)
        if editMenu == nil { addInteraction(menu); editMenu = menu }
        menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: p))
    }

    public func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        UIMenu(children: suggestedActions)
    }

    public func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration, animator: any UIEditMenuInteractionAnimating) {
        animator.addCompletion { [weak self] in
            guard let self, let m = self.editMenu else { return }
            self.removeInteraction(m); self.editMenu = nil
        }
    }

    // MARK: Search

    /// Searches the scrollback; nil clears and removes the highlights.
    public func search(_ needle: String?) {
        let r = engine.search(needle)
        searching = !(needle ?? "").isEmpty
        refreshSearch()
        onSearchResult?(r.total, r.index)
    }

    public func searchNext() { let r = engine.searchNext(); refreshSearch(); onSearchResult?(r.total, r.index) }
    public func searchPrevious() { let r = engine.searchPrevious(); refreshSearch(); onSearchResult?(r.total, r.index) }

    private func refreshSearch() {
        searchMatches = searching ? engine.viewportMatches() : []
        setNeedsDisplay()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        sceneObservers.forEach(NotificationCenter.default.removeObserver)
        readTask?.cancel()
        displayLink?.invalidate()
        rotTimer?.invalidate()
    }

    /// The host is gone: patches of ░▒▓ drift over a greyed screen and keys go nowhere.
    public var lost = false {
        didSet {
            guard lost != oldValue else { return }
            lostAt = lost ? Date() : nil
            rotTimer?.invalidate(); rotTimer = nil
            if lost, !UIAccessibility.isReduceMotionEnabled {
                rotTimer = Timer.scheduledTimer(withTimeInterval: 1 / 15, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.setNeedsDisplay() }
                }
            }
            accessibilityValue = lost ? "Connection lost" : nil
            setNeedsDisplay()
        }
    }
    private var lostAt: Date?
    private var rotTimer: Timer?

    /// Dither rot at cell (x, y): the block to draw instead of the text, or nil to draw the text greyed.
    /// A slow noise field of three sine waves; `k` ramps 0→1 over 0.6 s after the loss.
    static func rot(x: Int, y: Int, t: Double, k: Double, blank: Bool) -> Character? {
        let f = (sin(Double(x) * 0.18 + t * 0.9) + sin(Double(y) * 0.35 - t * 0.7) + sin(Double(x + y) * 0.11 + t * 0.5)) / 3
        let v = (f + 1) / 2 * k * 1.05 - 0.3
        guard v > 0, !blank || v > 0.35 else { return nil }
        return Array("░▒▓█")[min(3, Int(v * 5))]
    }

    private func measureCell() {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let size = ("M" as NSString).size(withAttributes: attrs)
        // Line height scales with the font; 13 pt keeps the design token exactly. A fixed height
        // made `-sidra.fontSize 9` report a 9 pt column count with 13 pt rows (19 rows, not 25).
        let lineHeight = ceil(SidraFont.monoLineHeight * font.pointSize / SidraFont.monoSize)
        cellSize = CGSize(width: ceil(size.width), height: lineHeight)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let cols = max(Int(bounds.width / cellSize.width), 2)
        let rows = max(Int(bounds.height / cellSize.height), 1)
        if cols != engine.cols || rows != engine.rows {
            engine.resize(cols: cols, rows: rows, cellWidth: Int(cellSize.width), cellHeight: Int(cellSize.height))
            io.resize(cols: cols, rows: rows)
            onReady?(cols, rows)
            setNeedsDisplay()
        }
        placeSendOffer()   // a rotation or split resize moves the cursor
    }

    public override var canBecomeFirstResponder: Bool { true }
    public override var canBecomeFocused: Bool { true }

    @objc private func handleTap() {
        if !CommandLine.arguments.contains("-sidra.noAutoFocus") { becomeFirstResponder() }
    }

    private var panResidual: CGFloat = 0
    private weak var rightClickRecognizer: UIGestureRecognizer?

    /// Image paths on screen get a thumbnail at the right edge: `onFetchImage` reads the file from the far
    /// side, `onOpenImage` shows it full size.
    private var copyGrant: Date?
    private var offered: String?
    private lazy var copyOffer: UIButton = {
        var c = UIButton.Configuration.filled()
        c.baseBackgroundColor = UIColor(SidraColor.raised)
        c.baseForegroundColor = UIColor(SidraColor.text)
        c.image = UIImage(systemName: "doc.on.doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        c.imagePadding = 6
        c.cornerStyle = .capsule
        let b = UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in
            guard let self, let text = self.offered else { return }
            UIPasteboard.general.string = text
            self.offered = nil
            self.copyOffer.isHidden = true
        })
        b.isHidden = true
        addSubview(b)
        return b
    }()

    // MARK: Send after dictation
    // Dictated text is pasted without running it; a Send button floats right of it, at the cursor, until
    // it is tapped or anything else is typed (2026-11-14).
    private var sendOffered = false
    private lazy var sendOffer: UIButton = {
        var c = UIButton.Configuration.filled()
        c.baseBackgroundColor = UIColor(SidraColor.jade)
        c.baseForegroundColor = UIColor(SidraColor.ground)
        c.image = UIImage(systemName: "return", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        c.title = "Send"
        c.imagePadding = 5
        c.cornerStyle = .capsule
        c.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        let b = UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in self?.send(.enter) })
        b.accessibilityIdentifier = "terminal.send"
        b.isHidden = true
        addSubview(b)
        return b
    }()

    public func offerSend() {
        sendOffered = true
        placeSendOffer()
    }

    private func placeSendOffer() {
        guard sendOffered, let c = currentFrame()?.cursor else { return }
        sendOffer.sizeToFit()
        let s = sendOffer.bounds.size
        let x = min(CGFloat(c.x) * cellSize.width + 8, bounds.width - s.width - SidraSpace.gap)
        let y = min(max(0, CGFloat(c.y) * cellSize.height + (cellSize.height - s.height) / 2), bounds.height - s.height)
        sendOffer.frame.origin = CGPoint(x: x, y: y)
        sendOffer.isHidden = false
    }

    /// A fresh frame outside draw(). Taking one clears the engine's dirty flag, so it is kept for draw()
    /// to use; dropping it left the pasted dictation invisible until the next key redrew.
    private func currentFrame() -> TerminalFrame? {
        if let f = engine.frame(force: true) { frame_ = f; setNeedsDisplay() }
        return frame_
    }

    private func withdrawSend() {
        guard sendOffered else { return }
        sendOffered = false
        sendOffer.isHidden = true
    }

    /// The host asked to copy without a gesture that grants it: one tap puts the text on the clipboard.
    private func offerCopy(_ text: String) {
        offered = text
        copyOffer.configuration?.title = "Copy \(text.count) characters from the host"
        copyOffer.sizeToFit()
        copyOffer.frame.origin = CGPoint(x: bounds.width - copyOffer.bounds.width - SidraSpace.gap, y: SidraSpace.gap)   // top: the floating keyboard sits bottom right
        copyOffer.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.offered == text else { return }
            self.offered = nil
            self.copyOffer.isHidden = true
        }
    }

    // MARK: Waiting for the host
    // A key you type normally comes back as output (its echo or a redraw) within the link's usual round trip. When
    // nothing has come back after about twice that, an animated signal sits beside the cursor until output arrives.
    // ponytail: any output counts as the answer; a program that prints on its own can hide a lost key.
    private var sentAt: Date?
    private var usualEcho: TimeInterval = 0.15
    private lazy var waiting: UIImageView = {
        let v = UIImageView(image: UIImage(systemName: "wifi", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)))
        v.tintColor = UIColor(SidraColor.text)
        v.contentMode = .center
        v.isHidden = true
        v.isUserInteractionEnabled = false
        v.isAccessibilityElement = true
        v.accessibilityLabel = "Waiting for the host"
        v.addSymbolEffect(.variableColor.iterative.dimInactiveLayers)
        addSubview(v)
        return v
    }()

    private func awaitEcho() {
        guard sentAt == nil else { return }
        let sent = Date()
        sentAt = sent
        let wait = min(1.5, max(0.3, usualEcho * 2))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.sentAt == sent, let c = self.frame_?.cursor else { return }
            self.waiting.frame = CGRect(x: CGFloat(c.x + 1) * self.cellSize.width, y: CGFloat(c.y) * self.cellSize.height,
                                        width: 22, height: self.cellSize.height)
            self.waiting.isHidden = false
        }
    }

    private func echoArrived() {
        guard let sent = sentAt else { return }
        sentAt = nil
        usualEcho = usualEcho * 0.8 + min(Date().timeIntervalSince(sent), 3) * 0.2
        waiting.isHidden = true
    }
    private lazy var thumbnails = TerminalThumbnails(host: self)
    public var onFetchImage: ((String) async -> Data?)? { get { thumbnails.fetch } set { thumbnails.fetch = newValue } }
    public var onOpenImage: ((String, PlatformImage) -> Void)? { get { thumbnails.open } set { thumbnails.open = newValue } }

    /// A tap on a thumbnail is the thumbnail's, not a click for the program.
    public func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !thumbnails.owns(touch.view) && !(touch.view is UIButton)   // thumbnails and the Copy offer take their own taps
    }

    public func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
        let secondary = event.buttonMask.contains(.secondary)
        return g === rightClickRecognizer ? secondary : !secondary
    }
    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let dy = g.translation(in: self).y
        g.setTranslation(.zero, in: self)
        panResidual += dy
        let lines = Int(panResidual / cellSize.height)
        guard lines != 0 else { return }
        panResidual -= CGFloat(lines) * cellSize.height
        if engine.mouseTracking {
            // Wheel events go to the program (buttons 4/5, 64/65 in SGR) instead of scrolling history.
            let p = g.location(in: self)
            for _ in 0..<abs(lines) { _ = report(.press, lines > 0 ? .wheelUp : .wheelDown, at: p) }
            return
        }
        engine.scroll(by: -lines)
        if searching { refreshSearch() }
        setNeedsDisplay()
    }

    // MARK: Drawing

    public override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        if let f = engine.frame(force: frame_ == nil) { frame_ = f } else { frame_?.cursor = engine.cursor() }   // a cursor-only move
        guard let frame = frame_ else { return }
        thumbnails.update(rows: frame.rows, cell: cellSize)
        ctx.setFillColor(UIColor(rgb: frame.background).cgColor)
        ctx.fill(bounds)
        let defaultFg = UIColor(rgb: frame.foreground)
        let selectionBg = UIColor(hex: 0x2a3340)
        // Links draw bold and underlined so they read as tappable.
        let rotT = lostAt.map { Date().timeIntervalSince($0) + (UIAccessibility.isReduceMotionEnabled ? 3 : 0) }
        let rotK = rotT.map { min(1, $0 / 0.6) } ?? 0
        let rotFg = UIColor(SidraColor.muted).greyed(0.4), rotGold = UIColor(SidraColor.gold).greyed(0.2)
        let grid = frame.rows.map { row in row.cells.map { $0.skip ? Character(" ") : ($0.text.first ?? " ") } }
        if grid != linkGrid {
            linkGrid = grid
            linkCellsCache = TerminalLinks.spans(in: grid).reduce(into: Set<Int>()) { $0.formUnion($1.cells) }
        }
        let linkCells = linkCellsCache

        for (y, row) in frame.rows.enumerated() {
            let top = CGFloat(y) * cellSize.height
            var x = 0
            for cell in row.cells {
                defer { x += 1 }
                if cell.skip { continue }
                let w = cellSize.width * (cell.wide ? 2 : 1)
                let cellRect = CGRect(x: CGFloat(x) * cellSize.width, y: top, width: w, height: cellSize.height)
                var fg = cell.fg.map(UIColor.init(rgb:)) ?? defaultFg
                var bg = cell.bg.map(UIColor.init(rgb:))
                if cell.inverse { let t = fg; fg = bg ?? UIColor(rgb: frame.background); bg = t }
                if cell.selected { bg = selectionBg }
                if let bg {
                    ctx.setFillColor(bg.cgColor)
                    ctx.fill(cellRect)
                }
                let blank = cell.text.isEmpty || cell.text == " "
                var text = cell.text
                if let rotT {
                    if let block = Self.rot(x: x, y: y, t: rotT, k: rotK, blank: blank) {
                        text = String(block)
                        // ponytail: a few gold flecks in the densest patches, picked by a cheap per-cell hash.
                        fg = block == "█" && (x * 7 + y * 13) % 11 == 0 ? rotGold : rotFg
                    } else {
                        fg = fg.greyed(rotK * 0.85)
                    }
                }
                guard !text.isEmpty, text != " " else { continue }
                let link = linkCells.contains(y * 10_000 + x)
                let ctFont = (cell.bold || link ? boldFont : font) as CTFont
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: ctFont,
                    .foregroundColor: (cell.faint ? fg.withAlphaComponent(0.6) : fg).cgColor,
                ]
                if cell.italic { attrs[.obliqueness] = 0.2 }
                if cell.underline || link { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue; attrs[.underlineColor] = fg.cgColor }
                if cell.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: terminalTextPresentation(text), attributes: attrs))
                ctx.saveGState()
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                let ascent = font.ascender
                let baseline = top + (cellSize.height - font.lineHeight) / 2 + ascent
                ctx.textPosition = CGPoint(x: cellRect.minX, y: baseline)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
        }

        for m in searchMatches where m.y < frame.rows.count {
            let r = CGRect(x: CGFloat(m.x0) * cellSize.width, y: CGFloat(m.y) * cellSize.height,
                           width: CGFloat(m.x1 - m.x0 + 1) * cellSize.width, height: cellSize.height)
            ctx.setStrokeColor(UIColor(SidraColor.gold).cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(r.insetBy(dx: 0.75, dy: 0.75))
        }

        if lostAt == nil, let cur = frame.cursor, cur.visible, cur.y >= 0, cur.y < frame.rows.count {
            let r = CGRect(x: CGFloat(cur.x) * cellSize.width, y: CGFloat(cur.y) * cellSize.height,
                           width: cellSize.width, height: cellSize.height)
            let color = UIColor(hex: 0xd9dde3)
            ctx.setFillColor(color.cgColor)
            ctx.setStrokeColor(color.cgColor)
            switch (cur.style, isFirstResponder) {
            case (_, false):
                ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
            case (.bar, _):
                ctx.fill(CGRect(x: r.minX, y: r.minY, width: 2, height: r.height))
            case (.underline, _):
                ctx.fill(CGRect(x: r.minX, y: r.maxY - 2, width: r.width, height: 2))
            case (.hollow, _):
                ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
            case (.block, _):
                ctx.fill(r)
                if let cell = frame.rows[cur.y].cells[safe: cur.x], !cell.text.isEmpty {
                    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(rgb: frame.background).cgColor]
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: cell.text, attributes: attrs))
                    ctx.saveGState()
                    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                    ctx.textPosition = CGPoint(x: r.minX, y: r.minY + (cellSize.height - font.lineHeight) / 2 + font.ascender)
                    CTLineDraw(line, ctx)
                    ctx.restoreGState()
                }
            }
        }
    }

    // MARK: UIKeyInput

    public var hasText: Bool { true }
    public var keyboardType: UIKeyboardType = .asciiCapable
    public var autocorrectionType: UITextAutocorrectionType = .no
    public var autocapitalizationType: UITextAutocapitalizationType = .none
    public var smartQuotesType: UITextSmartQuotesType = .no
    public var smartDashesType: UITextSmartDashesType = .no
    public var smartInsertDeleteType: UITextSmartInsertDeleteType = .no

    public func insertText(_ text: String) {
        FloatingKeyboard.shared.externalInput()
        let mods = keyRow.consumeModifiers()
        if mods.ctrl, let c = text.first { send(.ctrl(c)); return }
        if mods.alt, let c = text.first { send(.alt(c)); return }
        if text == "\n" { send(.enter) } else if text == "\t" { send(.tab) } else { send(.text(text)) }
    }

    public func deleteBackward() { FloatingKeyboard.shared.externalInput(); send(.backspace) }

    /// CSI I / CSI O when the program asked for focus reports (mode 1004), once per change.
    private var reportedFocus: Bool?
    private var focusWatch = FocusModeWatch()
    private var sceneObservers: [NSObjectProtocol] = []
    /// Focused for the program: first responder in a scene that is in front.
    private var hasFocus: Bool { isFirstResponder && window?.windowScene?.activationState == .foregroundActive }
    private func reportFocus(_ focused: Bool) {
        guard focused != reportedFocus, !lost else { return }
        let bytes = engine.encodeFocus(focused)
        guard !bytes.isEmpty else { return }   // mode off: nothing heard, so nothing recorded
        reportedFocus = focused
        io.write(bytes)
    }

    public func send(_ key: TerminalKey) {
        withdrawSend()
        guard !lost else { return }
        let bytes = engine.encode(key)
        guard !bytes.isEmpty else { return }
        io.write(bytes)
        awaitEcho()
        engine.scrollToBottom()
    }

    public func pasteText(_ text: String) {
        withdrawSend()
        guard !lost else { return }
        let bytes = engine.encodePaste(text)
        guard !bytes.isEmpty else { return }
        io.write(bytes)
        awaitEcho()
        engine.scrollToBottom()
    }

    public func copySelection() {
        guard let text = engine.selectionText(), !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        FloatingKeyboard.shared.externalInput()
        withdrawSend()
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            let mods = key.modifierFlags
            // "Cmd acts as Ctrl" (UserDefaults sidra.cmdAsCtrl): Cmd-C/Cmd-Z/Cmd-D reach the PTY as
            // control bytes. Caps Lock as Esc is an iPadOS system setting (Settings → General →
            // Keyboard → Hardware Keyboard → Modifier Keys); apps cannot remap it.
            let cmdAsCtrl = UserDefaults.standard.bool(forKey: "sidra.cmdAsCtrl") && mods.contains(.command) && !mods.contains(.shift)
            let ctrl = mods.contains(.control) || cmdAsCtrl
            let alt = mods.contains(.alternate)
            if mods.contains(.command), !mods.contains(.control), !alt {
                // Cmd-C copies when there is a selection (otherwise it may act as Ctrl-C below),
                // Cmd-V pastes, Cmd-F opens the find bar.
                switch key.charactersIgnoringModifiers {
                case "c" where engine.hasSelection: copySelection(); handled = true; continue
                case "v": paste(nil); handled = true; continue
                case "f": onFind?(); handled = true; continue
                default: break
                }
            }
            switch key.keyCode {
            case .keyboardUpArrow: send(.up); handled = true
            case .keyboardDownArrow: send(.down); handled = true
            case .keyboardLeftArrow: send(.left); handled = true
            case .keyboardRightArrow: send(.right); handled = true
            case .keyboardEscape: send(.escape); handled = true
            case .keyboardHome: send(.home); handled = true
            case .keyboardEnd: send(.end); handled = true
            case .keyboardPageUp: send(.pageUp); handled = true
            case .keyboardPageDown: send(.pageDown); handled = true
            case .keyboardDeleteForward: send(.delete); handled = true
            case .keyboardReturnOrEnter where mods.contains(.shift), .keypadEnter where mods.contains(.shift): send(.shiftEnter); handled = true
            case .keyboardTab where mods.contains(.shift): send(.text("\u{1b}[Z")); handled = true
            case .keyboardF1, .keyboardF2, .keyboardF3, .keyboardF4, .keyboardF5, .keyboardF6,
                 .keyboardF7, .keyboardF8, .keyboardF9, .keyboardF10, .keyboardF11, .keyboardF12:
                send(.function(Int(key.keyCode.rawValue) - Int(UIKeyboardHIDUsage.keyboardF1.rawValue) + 1)); handled = true
            default:
                if ctrl, let c = key.charactersIgnoringModifiers.first, c.isLetter || "[]\\^_@ ".contains(c) {
                    send(.ctrl(c)); handled = true
                } else if alt, !mods.contains(.command), let c = key.charactersIgnoringModifiers.first {
                    send(.alt(c)); handled = true
                }
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
        // iPadOS repeats a held key only for text it inserts itself; keys sent from here (arrows, page,
        // forward delete) repeat by this timer: 0.4 s, then 30 a second, until the key is let go.
        if let p = presses.first(where: { Self.repeating.contains($0.key?.keyCode ?? .keyboardErrorUndefined) }), let k = p.key {
            repeatTimer?.invalidate()
            repeatCode = k.keyCode
            let key: TerminalKey
            switch k.keyCode {
            case .keyboardUpArrow: key = .up
            case .keyboardDownArrow: key = .down
            case .keyboardLeftArrow: key = .left
            case .keyboardRightArrow: key = .right
            case .keyboardPageUp: key = .pageUp
            case .keyboardPageDown: key = .pageDown
            default: key = .delete
            }
            repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
                        MainActor.assumeIsolated { self?.send(key) }
                    }
                }
            }
        }
    }

    private static let repeating: Set<UIKeyboardHIDUsage> = [.keyboardUpArrow, .keyboardDownArrow, .keyboardLeftArrow, .keyboardRightArrow,
                                                             .keyboardPageUp, .keyboardPageDown, .keyboardDeleteForward]
    private var repeatTimer: Timer?
    private var repeatCode: UIKeyboardHIDUsage?

    private func stopRepeat(_ presses: Set<UIPress>) {
        guard presses.contains(where: { $0.key?.keyCode == repeatCode }) else { return }
        repeatTimer?.invalidate(); repeatTimer = nil; repeatCode = nil
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopRepeat(presses); super.pressesEnded(presses, with: event)
    }

    public override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopRepeat(presses); super.pressesCancelled(presses, with: event)
    }

    /// The terminal that last had the keys: where the floating mic's words go.
    public private(set) static weak var lastFocused: GhosttyTerminalView?

    public override func becomeFirstResponder() -> Bool {
        if FloatingKeyboard.shared.enabled { inputAssistantItem.leadingBarButtonGroups = []; inputAssistantItem.trailingBarButtonGroups = [] }
        let r = super.becomeFirstResponder()
        if r { Self.lastFocused = self; FloatingKeyboard.shared.focus(self); reportFocus(window?.windowScene?.activationState == .foregroundActive) }
        setNeedsDisplay()
        return r
    }

    public override func resignFirstResponder() -> Bool {
        repeatTimer?.invalidate(); repeatTimer = nil; repeatCode = nil
        let r = super.resignFirstResponder()
        if r { FloatingKeyboard.shared.blur(self); reportFocus(false) }
        setNeedsDisplay()
        return r
    }

    // Edit menu: copy and paste through the standard responder actions.
    public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) { return engine.hasSelection }
        if action == #selector(paste(_:)) { return UIPasteboard.general.hasStrings || (UIPasteboard.general.hasImages && onPasteImage != nil) }
        return false
    }

    public override func copy(_ sender: Any?) { copySelection() }

    /// A pasted image goes to the remote machine as a file; its path is pasted, which agent CLIs attach.
    public var onPasteImage: ((Data) async -> String?)? { didSet { keyRow.pastesImages = onPasteImage != nil } }
    public var pasteLabel: String { get { keyRow.pasteLabel } set { keyRow.pasteLabel = newValue; FloatingKeyboard.shared.pasteLabelChanged(self) } }

    public override func paste(_ sender: Any?) {
        FloatingKeyboard.shared.externalInput()
        // Paste after a hold: the held text was only the way to the menu, so its highlight goes.
        if engine.hasSelection { engine.clearSelection(); setNeedsDisplay() }
        let board = UIPasteboard.general
        if board.hasStrings, let s = board.string { pasteText(s); return }
        guard let data = board.image?.pngData() else { return }
        pasteImage(data)
    }

    /// Uploads an image to the far side and pastes its path, which agent CLIs attach. A paste from the
    /// keyboard sends the path to the clipboard if focus moved on during the upload; `here` (the Send
    /// screenshot sheet, which picked this terminal) always pastes it here.
    public func pasteImage(_ data: Data, here: Bool = false) {
        guard let upload = onPasteImage else { return }
        Task { @MainActor [weak self] in
            guard let path = await upload(data) else { return }
            if let image = UIImage(data: data) { self?.thumbnails.remember(path, image) }
            if let self, here || self.isFirstResponder { self.pasteText(path) } else { UIPasteboard.general.string = path }
        }
    }
}

extension GhosttyTerminalView: FloatingKeyboardTarget {
    public func keyboardInsert(_ text: String, ctrl: Bool, alt: Bool) {
        if ctrl, let c = text.first { send(.ctrl(c)); return }
        if alt, let c = text.first { send(.alt(c)); return }
        if text == "\n" { send(.enter) } else if text == "\t" { send(.tab) } else { send(.text(text)) }
    }
    public func keyboardKey(_ key: SidraKeyRow.Key) { keyRow.onKey?(key, false, false) }
    public func keyboardBackspace() { send(.backspace) }
    public func keyboardPaste(_ text: String) { pasteText(text) }
    public var learnsCommands: Bool { true }
    public var keyboardPasteLabel: String { pasteLabel }
    public var cursorLineText: String? {
        guard let f = currentFrame(), let c = f.cursor, f.rows.indices.contains(c.y) else { return nil }
        return f.rows[c.y].cells.map(\.text).joined()
    }
}

extension UIColor {
    /// Toward a dim grey of the same lightness by `amount` (0…1).
    func greyed(_ amount: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        let l = (r * 0.3 + g * 0.59 + b * 0.11) * 0.62
        return UIColor(red: r + (l - r) * amount, green: g + (l - g) * amount, blue: b + (l - b) * amount, alpha: a)
    }

    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                  blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}

#endif

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}


/// Symbols such as ⏺ (Claude Code's bullet) are text by default, but the font cascade finds them
/// in Apple Color Emoji and draws a grey button that ignores the cell colour. Ask for the text form,
/// and swap ⏺ for ●, which the terminal font has, so it takes the cell's colour.
func terminalTextPresentation(_ text: String) -> String {
    let scalars = text.unicodeScalars
    guard scalars.count == 1, let s = scalars.first, s.value > 0x7F else { return text }
    if s.value == 0x23FA { return "\u{25CF}" }
    if s.properties.isEmoji && !s.properties.isEmojiPresentation { return text + "\u{FE0E}" }
    return text
}
