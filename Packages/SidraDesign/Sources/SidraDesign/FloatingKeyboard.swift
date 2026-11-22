#if os(iOS)   // touch keyboard UI: a Mac has a hardware keyboard
import UIKit
import Observation
import GameController

/// A view Sidra's floating keyboard can type into: the terminal and the code editor.
@MainActor public protocol FloatingKeyboardTarget: AnyObject {
    func keyboardInsert(_ text: String, ctrl: Bool, alt: Bool)
    /// esc, tab, arrows and paste, as the key row sends them.
    func keyboardKey(_ key: SidraKeyRow.Key)
    func keyboardBackspace()
    /// Dictated text, pasted as one piece (bracketed in a terminal, so a newline does not run it).
    func keyboardPaste(_ text: String)
    /// Terminals learn the commands typed into them; the editor does not.
    var learnsCommands: Bool { get }
    /// Text on the cursor's line, so a password prompt is never learned.
    var cursorLineText: String? { get }
    /// ⌘V or ^V, after the far side's OS.
    var keyboardPasteLabel: String { get }
    /// After dictation: offer one tap to send what was just pasted (a terminal shows a Send button at the cursor).
    func offerSend()
}

public extension FloatingKeyboardTarget {
    func offerSend() {}
}

/// Sidra's own floating keyboard: which view it types into, whether it shows, its modifiers, and the
/// commands it has learned. The panel itself is drawn by the app; terminal and editor report focus here
/// and give iOS an empty input view while it is on, so Apple's keyboard never appears.
@MainActor @Observable
public final class FloatingKeyboard {
    public static let shared = FloatingKeyboard()

    /// The setting. Off: Apple's keyboard and the key row, as before.
    public var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "sidra.floatingKeyboard")
            NotificationCenter.default.post(name: Self.changed, object: nil)   // views restore Apple's keyboard and the key row
            (target as? UIResponder)?.reloadInputViews()
        }
    }
    @ObservationIgnored public private(set) weak var target: (any FloatingKeyboardTarget)?
    public private(set) var focused = false
    public static let changed = Notification.Name("sidra.floatingKeyboardChanged")
    /// Collapsed by its own button; stays collapsed (across launches) until the keyboard button opens it.
    public var dismissed = UserDefaults.standard.bool(forKey: "sidra.floatingKeyboardCollapsed") {
        didSet { UserDefaults.standard.set(dismissed, forKey: "sidra.floatingKeyboardCollapsed") }
    }
    /// The window of the view it types into; each window draws the keyboard only for its own views.
    public private(set) var targetWindow: ObjectIdentifier?
    public private(set) var hardware = FloatingKeyboard.hardwareAttached
    /// -sidra.softKeyboard (Simulator, UI tests): the Mac's keyboard shows up as a hardware keyboard there.
    static var hardwareAttached: Bool { HardwareKeyboard.attached && !CommandLine.arguments.contains("-sidra.softKeyboard") }
    /// Where the keyboard sits, in window coordinates: terminals ignore touches there (and in the suggestions row above it).
    @ObservationIgnored public var coveredFrame: CGRect?
    public func covers(_ windowPoint: CGPoint) -> Bool {
        guard visible, let f = coveredFrame else { return false }
        return f.insetBy(dx: -20, dy: 0).union(CGRect(x: f.minX, y: f.minY - 56, width: f.width, height: 56)).contains(windowPoint)   // + the suggestions row and the corner mic
    }
    public var visible: Bool { enabled && focused && !dismissed && (!hardware || shownWithHardware) }
    /// The expand button can bring the keys up beside a hardware keyboard; reset when one comes or goes.
    public var shownWithHardware = false
    /// Collapsed or hidden for a hardware keyboard: the round mic and expand buttons stand in.
    public var showsBubbles: Bool { enabled && focused && !visible }
    public func expand() { dismissed = false; if hardware { shownWithHardware = true } }

    public var shift = false
    public var ctrl = false
    public var alt = false
    public private(set) var often: [(command: String, count: Int)] = []
    public var pasteLabel = "⌘V"

    /// What was typed since the last return; nil once it can't be followed (history, arrows, ctrl).
    private var line: String? = ""
    /// What was typed on these keys since the last return, tap, arrow or other input: the phone's keyboard
    /// shows it above the keys, which cover the terminal's own line (Waseem, 2026-11-22).
    public private(set) var typed = ""
    private var counts: [String: Int]

    private init() {
        // bool(forKey:) also reads a launch argument (`-sidra.floatingKeyboard NO`), which arrives as a string.
        enabled = UserDefaults.standard.object(forKey: "sidra.floatingKeyboard") == nil ? true : UserDefaults.standard.bool(forKey: "sidra.floatingKeyboard")
        // Stored before arguments were dropped: cut every entry to its stem, merge the counts, rewrite.
        let stored = UserDefaults.standard.dictionary(forKey: "sidra.learnedCommands") as? [String: Int] ?? [:]
        var stems: [String: Int] = [:]
        for (line, n) in stored { if let stem = Self.commandStem(line) { stems[stem, default: 0] += n } }
        counts = stems
        if stems != stored { UserDefaults.standard.set(stems, forKey: "sidra.learnedCommands") }
        refreshOften()
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { FloatingKeyboard.shared.hardware = FloatingKeyboard.hardwareAttached; FloatingKeyboard.shared.shownWithHardware = false }
            }
        }
    }

    // MARK: Focus

    /// A target whose paste label changed (remote OS detected) refreshes the key, if it is the one typed into.
    public func pasteLabelChanged(_ t: any FloatingKeyboardTarget) {
        if target === t { pasteLabel = t.keyboardPasteLabel }
    }

    public func focus(_ t: any FloatingKeyboardTarget) {
        if target !== t { line = ""; typed = ""; alternatives = []; lastSwiped = nil }
        target = t; focused = true; pasteLabel = t.keyboardPasteLabel
        targetWindow = ((t as? UIView)?.window).map(ObjectIdentifier.init)
    }

    public func blur(_ t: any FloatingKeyboardTarget) {
        guard target === t else { return }
        target = nil; focused = false; targetWindow = nil; alternatives = []; lastSwiped = nil
    }

    // MARK: Keys

    /// Next guesses after a swipe; shown where Often sits, cleared by any other key.
    public private(set) var alternatives: [String] = [] { didSet { if alternatives.isEmpty { undoingVoice = false } } }
    private var lastSwiped: String?
    /// The view that received the last swipe; a replacement only ever edits that view.
    private weak var swipeTarget: (any FloatingKeyboardTarget)?

    /// How often each word was swiped (a pick from the alternatives counts three): the decoder ranks
    /// these up. Only swiped words, never typed text, so nothing typed at a prompt is stored.
    // ponytail: unbounded until it matters; prune the singles when it passes a few thousand words
    public private(set) var swipeHistory: [String: Int] = UserDefaults.standard.dictionary(forKey: "sidra.swipeWords") as? [String: Int] ?? [:]
    private func remember(_ word: String, _ n: Int) {
        swipeHistory[word.lowercased(), default: 0] += n
        UserDefaults.standard.set(swipeHistory, forKey: "sidra.swipeWords")
    }

    /// A swiped word, best guess first: typed with a trailing space, the rest offered as alternatives.
    public func swipe(_ words: [String]) {
        guard var w = words.first else { return }
        remember(w, 1)
        if shift { w = w.prefix(1).uppercased() + w.dropFirst(); shift = false }
        insert(w + " ")
        lastSwiped = w + " "
        swipeTarget = target
        undoingVoice = false
        alternatives = Array(words.dropFirst().prefix(3))
    }

    /// A dictation the voice clean-up changed: the alternatives row offers what Whisper heard.
    public private(set) var undoingVoice = false
    public func offerOriginal(_ original: String, replacing pasted: String) {
        lastSwiped = pasted; swipeTarget = target; alternatives = [original]; undoingVoice = true
    }

    /// Swaps the last swiped word for one of its alternatives.
    public func replaceSwipe(with word: String) {
        guard let last = lastSwiped, let t = target, t === swipeTarget else { alternatives = []; lastSwiped = nil; undoingVoice = false; return }
        for _ in last { forward { target?.keyboardBackspace() }; if var l = line { if !l.isEmpty { l.removeLast() }; line = l }; if !typed.isEmpty { typed.removeLast() } }
        if undoingVoice {   // a dictation: put the original back as is, no swipe learning
            undoingVoice = false
            insert(word); lastSwiped = nil; alternatives = []
            return
        }
        remember(word, 3)
        let wrong = last.trimmingCharacters(in: .whitespaces).lowercased()
        if let n = swipeHistory[wrong] {
            swipeHistory[wrong] = n > 1 ? n - 1 : nil   // the guess that was wrong loses the point it got
        }
        UserDefaults.standard.set(swipeHistory, forKey: "sidra.swipeWords")
        insert(word + " ")
        lastSwiped = word + " "
        alternatives = []
    }

    /// True while this keyboard drives the target, so the target's own input hooks can tell its
    /// keys from a hardware keyboard, a paste or a tap that moved the cursor.
    private var forwarding = false
    private func forward(_ body: () -> Void) { forwarding = true; body(); forwarding = false }

    /// Hardware keys held down, by the on-screen key they match ("a", "return", "⇧"…): those keys light up.
    public private(set) var held: Set<String> = []

    /// The on-screen key a hardware key matches, if any.
    public static func keyID(_ key: UIKey) -> String? {
        switch key.keyCode {
        case .keyboardReturnOrEnter, .keypadEnter: "return"
        case .keyboardDeleteOrBackspace: "⌫"
        case .keyboardTab: "tab"
        case .keyboardEscape: "esc"
        case .keyboardSpacebar: " "
        case .keyboardLeftShift, .keyboardRightShift: "⇧"
        case .keyboardLeftControl, .keyboardRightControl: "ctrl"
        case .keyboardLeftAlt, .keyboardRightAlt: "alt"
        case .keyboardUpArrow: "↑"
        case .keyboardDownArrow: "↓"
        case .keyboardLeftArrow: "←"
        case .keyboardRightArrow: "→"
        default: key.charactersIgnoringModifiers.isEmpty ? nil : key.charactersIgnoringModifiers.lowercased()
        }
    }

    public func hardware(_ presses: Set<UIPress>, down: Bool) {
        guard visible else { if !held.isEmpty { held = [] }; return }
        for p in presses { if let k = p.key, let id = Self.keyID(k) { if down { held.insert(id) } else { held.remove(id) } } }
    }

    /// Called by targets on every input or cursor move. Anything not from this keyboard means the
    /// swiped word may no longer sit before the cursor: drop the alternatives and the line followed.
    public func externalInput() {
        guard !forwarding else { return }
        if !alternatives.isEmpty { alternatives = [] }
        lastSwiped = nil; line = nil; typed = ""
    }

    /// Text from a hardware keyboard (or iOS) into the target: the typed line follows it too.
    public func typedElsewhere(_ text: String) {
        guard !forwarding else { return }
        if !alternatives.isEmpty { alternatives = [] }
        lastSwiped = nil; line = nil
        if text == "\n" { typed = "" } else { typed += text }
    }

    public func backspacedElsewhere() {
        guard !forwarding else { return }
        if !alternatives.isEmpty { alternatives = [] }
        lastSwiped = nil; line = nil
        if !typed.isEmpty { typed.removeLast() }
    }

    /// A paste into the target (the paste key, ⌘V or the menu; an image as its uploaded path): the typed line shows it.
    public func pasted(_ text: String) {
        typed += text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    private func insert(_ text: String) {
        forward { target?.keyboardInsert(text, ctrl: false, alt: false) }
        line = line.map { $0 + text }
        typed += text
    }

    public func type(_ s: String) {
        alternatives = []; lastSwiped = nil
        var text = s
        if shift, s.count == 1 { text = Self.shifted[s] ?? s.uppercased() }
        let c = ctrl, a = alt
        shift = false; ctrl = false; alt = false
        forward { target?.keyboardInsert(text, ctrl: c, alt: a) }
        line = (c || a) ? nil : line.map { $0 + text }
        if c || a { typed = "" } else { typed += text }
    }

    public func backspace() {
        // Right after a swipe, backspace takes the whole swiped word and its space, as on Apple's keyboard (Waseem, 2026-11-22).
        let n = !undoingVoice && target === swipeTarget ? max(1, lastSwiped?.count ?? 1) : 1
        alternatives = []; lastSwiped = nil; undoingVoice = false
        for _ in 0..<n {
            forward { target?.keyboardBackspace() }
            if var l = line { if !l.isEmpty { l.removeLast() }; line = l }
            if !typed.isEmpty { typed.removeLast() }
        }
    }

    public func key(_ k: SidraKeyRow.Key) {
        alternatives = []; lastSwiped = nil
        forward { target?.keyboardKey(k) }
        line = nil   // the line can no longer be followed (history, completion, cursor moves)
        if k != .paste { typed = "" }   // a paste reports its text (pasted(_:))
    }

    public func enter() {
        alternatives = []; lastSwiped = nil
        learn()
        forward { target?.keyboardInsert("\n", ctrl: false, alt: false) }
        line = ""; typed = ""
    }

    /// Pastes into `expected` only if it still has focus; otherwise the text goes to the clipboard.
    @discardableResult
    public func paste(_ text: String, into expected: (any FloatingKeyboardTarget)?) -> Bool {
        guard let t = target, let expected, t === expected else { UIPasteboard.general.string = text; return false }
        forward { t.keyboardPaste(text) }
        line = nil; typed += text
        return true
    }

    /// Types a learned command without running it.
    public func insertCommand(_ cmd: String) {
        forward { target?.keyboardInsert(cmd, ctrl: false, alt: false) }
        line = line.map { $0 + cmd }
        typed += cmd
    }

    // MARK: Learning

    private func learn() {
        guard let t = target, t.learnsCommands, let typed = line?.trimmingCharacters(in: .whitespaces),
              let screen = t.cursorLineText, Self.atShellPrompt(screen, typed: typed), Self.learnable(typed, prompt: screen),
              let l = Self.commandStem(typed) else { return }
        counts[l, default: 0] += 1
        // ponytail: unbounded until it matters; prune the singles when the list passes a few thousand
        UserDefaults.standard.set(counts, forKey: "sidra.learnedCommands")
        refreshOften()
    }

    /// A command worth remembering: never at a password or passphrase prompt, and either a line with
    /// arguments or one short lowercase word (`herdr`, `htop`). Single odd tokens could be secrets.
    /// What is remembered of a command line: the program, plus a subcommand and value-less long flags
    /// for tools known to take subcommands. `cargo build --release` stays whole; `echo hunter` becomes
    /// `echo`, `git commit -m "…"` becomes `git commit`. Free arguments, where secrets live, are never stored.
    public static func commandStem(_ line: String) -> String? {
        let words = line.split(separator: " ")
        guard let tool = words.first, tool.range(of: #"^[a-z][a-z0-9._-]*$"#, options: .regularExpression) != nil else { return nil }
        var kept = [tool]
        guard subcommandTools.contains(String(tool)) else { return String(tool) }
        for word in words.dropFirst() {
            let sub = kept.count == 1 && word.range(of: #"^[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil
            let longFlag = kept.count > 1 && word.range(of: #"^--[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil
            guard sub || longFlag else { break }
            kept.append(word)
            if kept.count == 4 { break }
        }
        return kept.joined(separator: " ")
    }

    /// Tools whose second word is a fixed subcommand, not data.
    static let subcommandTools: Set<String> = ["git", "cargo", "rustup", "docker", "npm", "pnpm", "yarn", "bun", "go", "brew",
        "apt", "pip", "pip3", "herdr", "systemctl", "kubectl", "pl", "make", "idf.py", "espflash", "arduino-cli", "pio",
        "swift", "xcodebuild", "gh", "tmux", "uv", "poetry", "mix", "bundle", "rails"]

    /// Learning needs proof the line went to a shell: the text before it on screen must end in a shell
    /// prompt sign (`$`, `%`, `#`, `❯`, `➜`, `»`, `λ`; not `>`, which programs use for their own prompts),
    /// and what precedes the sign must look like a shell's: nothing, one word (`bash-5.2`), or a path or
    /// user@host (`~/sidra`, `dev@devbox:~`). "Enter API key$" or any wordy prompt never qualifies.
    public static func atShellPrompt(_ screenLine: String, typed: String) -> Bool {
        let trimmed = screenLine.trimmingCharacters(in: .whitespaces)
        guard let r = trimmed.range(of: typed, options: .backwards) else { return false }
        var before = trimmed[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
        guard let last = before.last, "$%#❯➜»λ".contains(last) else { return false }
        before.removeLast()
        let words = before.split(separator: " ")
        return words.count <= 1 || before.contains("@") || before.contains("/") || before.contains("~")
    }

    public static func learnable(_ line: String, prompt: String) -> Bool {
        let p = prompt.lowercased()
        // A shell prompt is required as well (atShellPrompt); these catch prompts that end in $ or >.
        if ["password", "passphrase", "passcode", " pin", "token", "secret", "otp"].contains(where: p.contains) { return false }
        guard line.count >= 2, line.count <= 200 else { return false }
        if sensitive(line) { return false }
        if line.contains(" ") { return true }
        return line.count <= 12 && line.allSatisfy { $0.isLowercase || $0 == "-" || $0 == "_" }
    }

    /// Lines that may carry a credential are never stored: secret-ish words, `export`/env assignments,
    /// user:pass@ URLs, `-p<password>` style flags, and long random-looking tokens.
    public static func sensitive(_ line: String) -> Bool {
        let l = line.lowercased()
        let words = ["pass", "secret", "token", "bearer", "authorization", "api_key", "apikey", "api-key", "private", "credential", "auth", "cookie", "session", "key="]
        if words.contains(where: l.contains) { return true }
        let patterns = [#"^\s*export\s"#, #"(^|\s)[A-Za-z_][A-Za-z0-9_]*=\S"#, #"://[^/\s:@]+:[^/\s@]+@"#, #"(^|\s)-p\S"#, #"[A-Za-z0-9+/_=-]{24,}"#]
        return patterns.contains { line.range(of: $0, options: .regularExpression) != nil }
    }

    private func refreshOften() {
        // Shown once typed twice; the three most used.
        often = counts.filter { $0.value >= 2 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(3).map { ($0.key, $0.value) }
    }

    public static let shifted: [String: String] = ["1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
                                            ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "-": "_", "=": "+", "`": "~", "\\": "|", "[": "{", "]": "}"]
}
#endif
