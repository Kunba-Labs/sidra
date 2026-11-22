#if os(iOS)   // touch keyboard: a Mac has a hardware keyboard
import SwiftUI
import SidraDesign

/// Sidra's floating keyboard (design/screens/07a-keyboard.png). Types into the focused terminal or editor
/// through `FloatingKeyboard`; drag the top bar to move it, the chevron hides it until the next tap.
/// Ported from sidra-full (2026-11-19) without its own Whisper voice path: the corner mic is the app's
/// dictation (VoiceInput, FloatingMic), and collapsed, FloatingMic shows the keyboard button.
struct FloatingKeyboardLayer: View {
    @State private var kb = FloatingKeyboard.shared
    /// This window. The keyboard is process-wide; each window draws it only for views it holds.
    @State private var uiWindow: UIWindow?
    private var mine: Bool { uiWindow != nil && kb.targetWindow == uiWindow.map(ObjectIdentifier.init) }
    @AppStorage("sidra.kbX") private var savedX = -1.0
    @AppStorage("sidra.kbY") private var savedY = -1.0
    @State private var drag: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let size = CGSize(width: min(640, geo.size.width - 24), height: 360)
            let origin = clamp(CGPoint(x: savedX < 0 ? geo.size.width - size.width - 24 : savedX,
                                       y: savedY < 0 ? geo.size.height - size.height - 20 : savedY), size, geo.size)
            ZStack(alignment: .topLeading) {
                if kb.visible, mine {
                    FloatingKeyboardPanel(kb: kb, grab: DragGesture(coordinateSpace: .global)
                        .onChanged { drag = $0.translation }
                        .onEnded { v in
                            let p = clamp(CGPoint(x: origin.x + v.translation.width, y: origin.y + v.translation.height), size, geo.size)
                            savedX = p.x; savedY = p.y; drag = .zero
                        }, window: uiWindow, compact: size.width < 520)
                    .frame(width: size.width)
                    .offset(x: origin.x + drag.width, y: origin.y + drag.height)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(.easeOut(duration: 0.18), value: kb.visible)
            .background { WindowReader { uiWindow = $0 }.allowsHitTesting(false) }
        }
    }

    private func clamp(_ p: CGPoint, _ s: CGSize, _ bounds: CGSize) -> CGPoint {
        // The corner mic sticks out 18 pt up and right: keep it on screen too.
        CGPoint(x: min(max(8, p.x), max(8, bounds.width - s.width - 8 - 18)), y: min(max(8 + 18, p.y), max(8 + 18, bounds.height - s.height - 8)))
    }
}

/// A light tap under the finger on each key press, like Apple's keyboard with Keyboard Feedback on. iPhone only: an iPad has no Taptic Engine.
@MainActor enum KeyHaptic {
    private static let generator = UIImpactFeedbackGenerator(style: .light)
    static func tap() { generator.impactOccurred(intensity: 0.6) }
}

struct KeyboardCap {
    enum Action { case text(String), key(SidraKeyRow.Key), backspace, enter, shift, ctrl, alt, hide, language, returnSlot }
    let label: String
    var alt: String? = nil
    var action: Action
    var width: CGFloat = 1
    var style: Style = .letter
    var repeats = false
    /// Letter keys take part in swipe typing and type on lift-off, so a tap never starts a swipe.
    var swipeLetter: Character? = nil
    enum Style { case letter, symbol, modifier, glyph, wide }
}

struct FloatingKeyboardPanel<G: Gesture>: View {
    typealias Cap = KeyboardCap
    let kb: FloatingKeyboard
    let grab: G
    /// For the corner mic: dictation shows its card in this window.
    let window: UIWindow?
    /// A narrow window: the mic shrinks to a round key above the letters and the symbol row scrolls,
    /// so every key keeps a usable size.
    var compact = false
    @State private var letters: [Character: CGRect] = [:]
    @State private var trail: [CGPoint] = []
    /// The swipe has left its first key: from then on only the key under the finger is marked.
    @State private var swipeLeft = false
    private func letter(at p: CGPoint) -> Character? { letters.first { $0.value.contains(p) }?.key }
    private var swipeOver: Character? { swipeLeft ? trail.last.flatMap(letter(at:)) : nil }

    /// Swipe typing: the trail follows the finger; on lift a long enough path becomes a word.
    private var swipeHooks: SwipeHooks {
        SwipeHooks(moved: { p in
            trail.append(p)
            if !swipeLeft, let s = trail.first, letter(at: p) != letter(at: s) { swipeLeft = true }
        }, ended: {
            defer { trail = []; swipeLeft = false }
            let width = letters.values.first?.width ?? 40
            var length: CGFloat = 0
            for i in trail.indices.dropFirst() { length += SwipeTyping.dist(trail[i - 1], trail[i]) }
            guard length > width * 0.9 else { return false }   // a tap, not a swipe
            let words = SwipeTyping.decode(trail, keys: letters.mapValues { CGPoint(x: $0.midX, y: $0.midY) }, keyWidth: width, used: kb.swipeHistory, after: Self.previousWord(kb.typed))
            guard !words.isEmpty else { return false }   // nothing fits: the touch types its starting letter instead
            kb.swipe(words)
            return true
        })
    }

    /// The last whole word before the cursor, for the next-word odds; nil at the start of a line or mid-word.
    static func previousWord(_ typed: String) -> String? {
        guard typed.last?.isWhitespace == true else { return nil }
        return WordModel.sentences(typed).last?.last
    }

    @ViewBuilder private var strip: some View {
        if !kb.often.isEmpty { oftenRow }
    }

    private var alternativesRow: some View {
        HStack(spacing: 6) {
            Text(kb.undoingVoice ? "HEARD" : "OR").font(SidraFont.ui(10.5, weight: .semibold)).tracking(0.8).foregroundStyle(SidraColor.dim)
            ForEach(kb.alternatives, id: \.self) { w in
                Button { kb.replaceSwipe(with: w) } label: {
                    Text(w).font(SidraFont.ui(13.5)).foregroundStyle(SidraColor.text).lineLimit(1).truncationMode(.middle).frame(maxWidth: 420)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Color(hex: 0x20252d), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SidraColor.hairline))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(SidraColor.popup, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(SidraColor.hairline2))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Capsule().fill(Color(hex: 0x3a414c)).frame(width: 44, height: 5)
                HStack {
                    // Left: the mic sits on the right corner.
                    Button { kb.dismissed = true } label: {
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(SidraColor.muted)
                            .frame(width: 34, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Hide keyboard")
                    Spacer()
                }
            }
            .frame(height: 22).contentShape(Rectangle()).gesture(grab)
            if compact { typedRow(kb.typed) }   // always there, so the keys never jump
            strip.padding(.bottom, 8).padding(.trailing, 30)   // clear of the corner mic
            HStack(alignment: .top, spacing: 6) {
                    VStack(spacing: 5) { ForEach(Array((compact ? compactRows : rows).enumerated()), id: \.offset) { i, row in if compact && i == 0 { scrollingRow(row) } else { keyRow(row) } } }
                        .coordinateSpace(name: "keys")
                        .onPreferenceChange(LetterFrames.self) { letters = $0 }
                        .overlayPreferenceValue(ReturnFrames.self) { rects in ReturnKey(rects: rects) { kb.enter() } }
                        .overlay { SwipeTrail(points: trail).allowsHitTesting(false) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 10)
        // The background takes any touch the keys miss (the edge, the padding): none reaches the terminal underneath
        // as a click, which moved Claude Code's cursor under herdr (Waseem, 2026-11-22).
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(SidraColor.popup).gesture(DragGesture(minimumDistance: 0)))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { kb.coveredFrame = $0 }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(SidraColor.hairline2))
        // The mic: a round key on the top-right corner, mostly outside the keyboard, so it takes no row or
        // column of its own (Waseem, 2026-11-14). It used to be a full-height tile beside the keys.
        .overlay(alignment: .topTrailing) { MicKey(voice: VoiceInput.shared, window: window).offset(x: 18, y: -18) }
        // Swipe alternatives float above the keyboard, so the keys never move (Waseem, 2026-11-15).
        .overlay(alignment: .topLeading) {
            // Floating above the keyboard (the row is 40 pt tall), so the keys and the typed line never move.
            if !kb.alternatives.isEmpty {
                alternativesRow.padding(.leading, 10).offset(y: -48)
            }
        }
        .shadow(color: .black.opacity(0.55), radius: 30, y: 16)
    }

    /// Phone: the keys cover the terminal's input line, so what you type shows here until return.
    private func typedRow(_ text: String) -> some View {
        HStack(spacing: 0) {
            Text(text).font(SidraFont.mono(14)).foregroundStyle(SidraColor.terminalText).lineLimit(1).truncationMode(.head)
            Rectangle().fill(SidraColor.jade).frame(width: 2, height: 17).padding(.leading, 1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).frame(height: 34)
        .background(SidraColor.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SidraColor.hairline))
        .padding(.trailing, 30).padding(.bottom, 8)   // clear of the corner mic
        .accessibilityElement().accessibilityLabel(text.isEmpty ? "Nothing typed" : "Typed: \(text)")
    }

    private var oftenRow: some View {
        HStack(spacing: 6) {
            Text("OFTEN").font(SidraFont.ui(10.5, weight: .semibold)).tracking(0.8).foregroundStyle(SidraColor.dim)
            ForEach(Array(kb.often.enumerated()), id: \.element.command) { i, item in
                Button { kb.insertCommand(item.command) } label: {
                    HStack(spacing: 7) {
                        Text(item.command).font(SidraFont.mono(12.5)).foregroundStyle(SidraColor.text).lineLimit(1)
                        Text("\(item.count)×").font(SidraFont.ui(10.5, weight: .semibold)).foregroundStyle(i == 0 ? SidraColor.jade : SidraColor.dim)
                    }
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(Color(hex: 0x20252d), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(i == 0 ? SidraColor.jade.opacity(0.35) : SidraColor.hairline))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Keys

    /// A narrow window: at most ten-and-a-half key widths per row, so letters stay about 26 pt wide.
    /// Tab, paste and the punctuation join the scrolling symbol row; return is a plain key.
    private var compactRows: [[Cap]] {
        let sym = ["tab", kb.pasteLabel, ".", ",", ";", "'", "|", "~", "`", "\\", "/", "-", "_", "=", "{", "}", "[", "]", "<", ">"]
        let letter: (String) -> Cap = { c in Cap(label: kb.shift ? c.uppercased() : c, action: .text(c), swipeLetter: c.first) }
        return [
            [Cap(label: "esc", action: .key(.esc), style: .modifier)] + sym.map { s in
                s == "tab" ? Cap(label: "tab", action: .key(.tab), style: .modifier)
                : s == kb.pasteLabel ? Cap(label: s, action: .key(.paste), style: .modifier)
                : Cap(label: s, alt: FloatingKeyboard.shifted[s], action: .text(s), style: .symbol) },
            Array("1234567890").map { Cap(label: String($0), alt: FloatingKeyboard.shifted[String($0)], action: .text(String($0))) },
            "qwertyuiop".map { letter(String($0)) },
            // Backspace above return, as on Apple's keyboard (Waseem, 2026-11-22).
            "asdfghjkl".map { letter(String($0)) } + [Cap(label: "⌫", action: .backspace, width: 1.5, style: .glyph, repeats: true)],
            [Cap(label: "⇧", action: .shift, width: 1.5, style: .glyph)] + "zxcvbnm".map { letter(String($0)) }
                + [Cap(label: "return", action: .enter, width: 1.5, style: .wide)],
            [Cap(label: "ctrl", action: .ctrl, style: .modifier), Cap(label: "alt", action: .alt, style: .modifier), Cap(label: "⌄", action: .hide, style: .glyph),
             Cap(label: "", action: .text(" "), width: 3, repeats: true),
             Cap(label: "←", action: .key(.left), style: .glyph, repeats: true), Cap(label: "↑", action: .key(.up), style: .glyph, repeats: true),
             Cap(label: "↓", action: .key(.down), style: .glyph, repeats: true), Cap(label: "→", action: .key(.right), style: .glyph, repeats: true)],
        ]
    }

    private var rows: [[Cap]] {
        let sym = ["|", "~", "`", "\\", "/", "-", "_", "=", "{", "}", "[", "]", "<", ">"]
        let nums = Array("1234567890").map(String.init)
        let letter: (String) -> Cap = { c in Cap(label: kb.shift ? c.uppercased() : c, action: .text(c), swipeLetter: c.first) }
        return [
            [Cap(label: "esc", action: .key(.esc), style: .modifier)] + sym.map { Cap(label: $0, action: .text($0), style: .symbol) },
            nums.map { Cap(label: $0, alt: FloatingKeyboard.shifted[$0], action: .text($0)) }
                + [Cap(label: "⌫", action: .backspace, width: 1.5, style: .glyph, repeats: true)],
            // Tab where a US keyboard has it: left of Q.
            [Cap(label: "tab", action: .key(.tab), width: 1.5, style: .modifier)] + "qwertyuiop".map { letter(String($0)) }
                + [Cap(label: ";", alt: ":", action: .text(";"), style: .symbol), Cap(label: "", action: .returnSlot, width: 1.5)],
            [Cap(label: "ctrl", action: .ctrl, width: 1.5, style: .modifier)] + "asdfghjkl".map { letter(String($0)) }
                + [Cap(label: "", action: .returnSlot, width: 2)],
            [Cap(label: "⇧", action: .shift, width: 1.5, style: .glyph)] + "zxcvbnm".map { letter(String($0)) }
                + [Cap(label: "'", alt: "\"", action: .text("'"), style: .symbol), Cap(label: "↑", action: .key(.up), style: .glyph, repeats: true),
                   Cap(label: kb.pasteLabel, action: .key(.paste), style: .modifier)],
            [Cap(label: "EN", action: .language, style: .modifier), Cap(label: "alt", action: .alt, width: 1.25, style: .modifier), Cap(label: "⌄", action: .hide, style: .glyph),
             Cap(label: "", action: .text(" "), width: 5, repeats: true), Cap(label: ",", alt: "<", action: .text(","), style: .symbol),
             Cap(label: ".", alt: ">", action: .text("."), style: .symbol),
             Cap(label: "←", action: .key(.left), style: .glyph, repeats: true), Cap(label: "↓", action: .key(.down), style: .glyph, repeats: true),
             Cap(label: "→", action: .key(.right), style: .glyph, repeats: true)],
        ]
    }

    private func isOn(_ c: Cap) -> Bool {
        switch c.action { case .shift: kb.shift; case .ctrl: kb.ctrl; case .alt: kb.alt; default: false }
    }

    private func fire(_ c: Cap) {
        switch c.action {
        case .text(let s): kb.type(s)
        case .key(let k): kb.key(k)
        case .backspace: kb.backspace()
        case .enter: kb.enter()
        case .shift: kb.shift.toggle()
        case .ctrl: kb.ctrl.toggle()
        case .alt: kb.alt.toggle()
        case .hide: kb.dismissed = true
        case .language, .returnSlot: break   // a menu (LanguageKey) and the two halves of the L-shaped return
        }
    }

    /// One row, each key as wide as its weight; rows with fewer keys get wider keys, like a real keyboard.
    /// The symbol row in a narrow window: fixed-size keys that scroll sideways.
    private func scrollingRow(_ row: [Cap]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(row.indices, id: \.self) { i in KeyCap(cap: row[i], on: false, action: { fire(row[i]) }).frame(width: row[i].style == .modifier ? 52 : 38) }
            }
        }
        .frame(height: 42)
    }

    private func keyRow(_ row: [Cap]) -> some View {
        GeometryReader { geo in
            let unit = (geo.size.width - 5 * CGFloat(row.count - 1)) / row.reduce(0) { $0 + $1.width }
            HStack(spacing: 5) {
                // By position: Caps are rebuilt every render, and a fresh identity would drop a held key's gesture.
                ForEach(row.indices, id: \.self) { i in
                    let c = row[i]
                    Group {
                        if case .language = c.action { LanguageKey() }
                        else if case .returnSlot = c.action {
                            Color.clear.frame(height: 42)
                                .background { GeometryReader { g in Color.clear.preference(key: ReturnFrames.self, value: [g.frame(in: .named("keys"))]) } }
                        } else { KeyCap(cap: c, on: isOn(c), action: { fire(c) }, swipe: c.swipeLetter == nil ? nil : swipeHooks,
                                         swiping: swipeLeft, swipeOver: c.swipeLetter != nil && c.swipeLetter == swipeOver) }
                    }
                    .frame(width: unit * c.width)
                    .background { if let ch = c.swipeLetter { GeometryReader { g in Color.clear.preference(key: LetterFrames.self, value: [ch: g.frame(in: .named("keys"))]) } } }
                }
            }
        }
        .frame(height: 42)
    }
}

/// One key. Fires on touch-down like a hardware key; repeating keys keep firing while held.
struct SwipeHooks {
    let moved: (CGPoint) -> Void
    /// True when the touch was a swipe (handled); false means it was a tap.
    let ended: () -> Bool
}

private struct ReturnFrames: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

/// Return as one L-shaped key over two rows (like ISO Enter): the slot at the end of the Q row joined
/// to the wider slot at the end of the A row, so it is hard to miss.
private struct ReturnKey: View {
    let rects: [CGRect]
    let action: () -> Void
    @State private var pressed = false

    var body: some View {
        if rects.count == 2 {
            let top = rects.min { $0.minY < $1.minY }!, bottom = rects.max { $0.minY < $1.minY }!
            let shape = LShape(top: top, bottom: bottom)
            ZStack(alignment: .topLeading) {
                let down = pressed || FloatingKeyboard.shared.held.contains("return")
                shape.fill(down ? Color(hex: 0x56606f) : Color(hex: 0x2f3640)).shadow(color: Color(hex: 0x0a0c10), radius: 0, y: down ? 0 : 1.5)
                Text("return").font(SidraFont.ui(13)).foregroundStyle(Color(hex: 0xe6e9ee))
                    .frame(width: bottom.width, height: bottom.height).offset(x: bottom.minX, y: bottom.minY)
            }
            .contentShape(shape)
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in if !pressed { pressed = true; KeyHaptic.tap(); action() } }.onEnded { _ in pressed = false })
            .accessibilityElement().accessibilityLabel("return").accessibilityAddTraits(.isButton).accessibilityAction { action() }
        }
    }
}

private struct LShape: Shape {
    let top: CGRect, bottom: CGRect
    func path(in _: CGRect) -> Path {
        var p = Path()
        p.addRoundedRect(in: top, cornerSize: CGSize(width: 8, height: 8), style: .continuous)
        p.addRoundedRect(in: bottom, cornerSize: CGSize(width: 8, height: 8), style: .continuous)
        // The bridge across the row gap, as wide as the narrower half, so the two read as one key.
        let w = min(top.width, bottom.width)
        p.addRect(CGRect(x: top.maxX - w, y: top.midY, width: w, height: bottom.midY - top.midY))
        return p
    }
}

private struct LetterFrames: PreferenceKey {
    static let defaultValue: [Character: CGRect] = [:]
    static func reduce(value: inout [Character: CGRect], nextValue: () -> [Character: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// The swipe trail: a smoothed curve that thins and fades towards its tail, strongest at the fingertip.
private struct SwipeTrail: View {
    let points: [CGPoint]
    var body: some View {
        Canvas { ctx, _ in
            let pts = Self.smooth(Array(points.suffix(90)))
            guard pts.count > 2 else { return }
            for i in 1..<pts.count {
                let t = Double(i) / Double(pts.count - 1)          // 0 at the tail, 1 at the finger
                var seg = Path()
                seg.move(to: pts[i - 1]); seg.addLine(to: pts[i])
                ctx.stroke(seg, with: .color(SidraColor.jade.opacity(0.42 * t * t)),
                           style: StrokeStyle(lineWidth: 2 + 5 * t, lineCap: .round, lineJoin: .round))
            }
        }
    }

    /// Chaikin corner cutting, twice: turns the jagged touch samples into a soft curve.
    static func smooth(_ p: [CGPoint]) -> [CGPoint] {
        var pts = p
        for _ in 0..<2 where pts.count > 2 {
            var out = [pts[0]]
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                out.append(CGPoint(x: 0.75 * a.x + 0.25 * b.x, y: 0.75 * a.y + 0.25 * b.y))
                out.append(CGPoint(x: 0.25 * a.x + 0.75 * b.x, y: 0.25 * a.y + 0.75 * b.y))
            }
            out.append(pts[pts.count - 1])
            pts = out
        }
        return pts
    }
}

/// Bottom-left: the swipe and suggestion language. English only for now.
private struct LanguageKey: View {
    var body: some View {
        Menu {
            Button { } label: { Label("English (US)", systemImage: "checkmark") }
            Section("Later") {
                Text("Nederlands")
                Text("Deutsch")
                Text("Français")
            }
        } label: {
            Text("EN").font(SidraFont.mono(12.5)).foregroundStyle(SidraColor.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(hex: 0x1f242c), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: Color(hex: 0x0a0c10), radius: 0, y: 1.5)
        }
        .frame(height: 42)
        .accessibilityLabel("Keyboard language, English")
    }
}

private struct KeyCap: View {
    let cap: KeyboardCap
    let on: Bool
    let action: () -> Void
    var swipe: SwipeHooks? = nil
    /// A swipe is under way past its first key: the first key drops its pressed look.
    var swiping = false
    /// The swipe's finger is over this key: a darker fill shows where the finger is.
    var swipeOver = false
    @State private var pressed = false
    /// A quick tap ends before its press is drawn: the pressed look stays at least this long, as on Apple's keyboard.
    @State private var lingering = false
    /// The matching hardware key is down: the key lights (no letter bubble).
    private var hardwareDown: Bool {
        let id: String? = switch cap.action {
        case .text(let s): s
        case .key(let k): ["esc": "esc", "tab": "tab", "↑": "↑", "↓": "↓", "←": "←", "→": "→"][k.rawValue]
        case .backspace: "⌫"
        case .enter: "return"
        case .shift: "⇧"
        case .ctrl: "ctrl"
        case .alt: "alt"
        default: nil
        }
        return id.map(FloatingKeyboard.shared.held.contains) ?? false
    }
    private var touched: Bool { (pressed || lingering) && !swiping }
    private var lit: Bool { touched || hardwareDown }
    @State private var repeater: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Pressed: clearly lighter, sunk (no edge shadow) and a touch smaller.
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? SidraColor.jade : swipeOver ? Color(hex: 0x15191f) : (lit ? Color(hex: 0x56606f) : base))
                .shadow(color: Color(hex: 0x0a0c10), radius: 0, y: lit || swipeOver ? 0 : 1.5)
            if let a = cap.alt { Text(a).font(SidraFont.mono(9.5)).foregroundStyle(SidraColor.muted).padding(.leading, 6).padding(.top, 3) }
            Text(cap.label).font(font).foregroundStyle(on ? Color(hex: 0x06140e) : fg)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 42)
        .scaleEffect(lit ? 0.94 : 1)
        .animation(.easeOut(duration: 0.06), value: lit)
        // Letters and symbols pop up above the finger, which hides the key itself.
        .overlay(alignment: .top) {
            if touched, cap.style == .letter || cap.style == .symbol, !cap.label.isEmpty {
                Text(cap.label).font(cap.style == .letter ? SidraFont.ui(24, weight: .semibold) : SidraFont.mono(20))
                    .foregroundStyle(Color(hex: 0xf2f4f7))
                    .frame(minWidth: 44).frame(height: 50)
                    .background(Color(hex: 0x56606f), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
                    .offset(y: -56)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(lit ? 1 : 0)
        .contentShape(Rectangle().inset(by: -2.5))   // half the 5 pt gap each side: a tap between keys types the nearest one
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("keys"))
            .onChanged { v in
                if let swipe {
                    // Letters: follow the finger for a swipe; the letter itself types on lift-off.
                    if !pressed { pressed = true; KeyHaptic.tap(); swipe.moved(v.startLocation) }
                    swipe.moved(v.location)
                    return
                }
                guard !pressed else { return }
                pressed = true
                KeyHaptic.tap()
                action()
                if cap.repeats {
                    repeater = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        while !Task.isCancelled { action(); try? await Task.sleep(for: .milliseconds(55)) }
                    }
                }
            }
            .onEnded { _ in
                pressed = false; repeater?.cancel(); repeater = nil
                let tapped = swipe.map { !$0.ended() } ?? true   // false: a swipe typed a word
                if swipe != nil, tapped { action() }
                if tapped {
                    lingering = true
                    Task { @MainActor in try? await Task.sleep(for: .milliseconds(110)); lingering = false }
                }
            })
        .onDisappear { repeater?.cancel(); repeater = nil }
        .accessibilityLabel(cap.label.isEmpty ? "space" : cap.label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }

    private var base: Color {
        switch cap.style { case .letter: Color(hex: 0x262c35); case .wide: Color(hex: 0x2f3640); default: Color(hex: 0x1f242c) }
    }
    private var fg: Color {
        switch cap.style { case .modifier: SidraColor.muted; case .symbol: SidraColor.terminalText; default: Color(hex: 0xe6e9ee) }
    }
    private var font: Font {
        switch cap.style {
        case .letter: SidraFont.ui(16)
        case .glyph: .system(size: 18)
        case .symbol: SidraFont.mono(14)
        case .modifier: SidraFont.mono(12.5)
        case .wide: SidraFont.ui(13)
        }
    }
}

/// Reports the UIWindow this view lives in.
private struct WindowReader: UIViewRepresentable {
    let found: (UIWindow?) -> Void
    func makeUIView(context: Context) -> Probe { Probe(found: found) }
    func updateUIView(_ uiView: Probe, context: Context) {}
    final class Probe: UIView {
        let found: (UIWindow?) -> Void
        init(found: @escaping (UIWindow?) -> Void) { self.found = found; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func didMoveToWindow() { super.didMoveToWindow(); let w = window; DispatchQueue.main.async { self.found(w) } }
    }
}
#endif
