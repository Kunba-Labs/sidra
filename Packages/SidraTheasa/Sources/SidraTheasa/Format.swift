import Foundation

/// Formatting shared by the Theasa screens: tokens, durations, money, dates.
public enum TFormat {
    public static func tok(_ n: Int?) -> String {
        let n = Double(n ?? 0)
        if n >= 1e9 { return String(format: "%.1fB", n / 1e9) }
        if n >= 1e6 { return String(format: "%.1fM", n / 1e6) }
        if n >= 1e3 { return "\(Int((n / 1e3).rounded()))k" }
        return String(Int(n))
    }

    public static func dur(_ ms: Int?) -> String {
        let s = Int((Double(ms ?? 0) / 1000).rounded())
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m " + String(format: "%02d", s % 60) + "s" }
        return "\(m / 60)h " + String(format: "%02d", m % 60) + "m"
    }

    public static func money(_ c: Double?) -> String {
        guard let c else { return "n/a" }
        if c > 0 && c < 0.01 { return "<$0.01" }
        return c >= 100 ? "$\(Int(c.rounded()))" : String(format: "$%.2f", c)
    }

    public static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n) " + (n == 1 ? one : many ?? one + "s")
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()

    public static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    public static func ago(_ s: String?, now: Date = Date()) -> String {
        guard let d = date(s) else { return "" }
        let sec = now.timeIntervalSince(d)
        if sec < 60 { return "just now" }
        if sec < 3600 { return "\(Int((sec / 60).rounded())) min ago" }
        if sec < 86400 { return "\(Int((sec / 3600).rounded())) h ago" }
        let days = Int((sec / 86400).rounded())
        return days == 1 ? "yesterday" : "\(days) days ago"
    }

    private static func fmt(_ f: String) -> DateFormatter {
        let d = DateFormatter(); d.locale = Locale(identifier: "en_GB"); d.dateFormat = f; return d
    }
    private static let hm = fmt("HH:mm")
    private static let dayKeyF = fmt("yyyy-MM-dd")
    private static let shortDay = fmt("EEE d MMM")
    private static let longDayF = fmt("d MMMM")
    private static let stamp = fmt("EEE d MMM, HH:mm")
    private static let stampShort = fmt("d MMM, HH:mm")
    private static let todayF = fmt("EEEE d MMMM")

    public static func clock(_ s: String?) -> String { date(s).map(hm.string) ?? "" }
    public static func dayKey(_ s: String?) -> String { date(s).map(dayKeyF.string) ?? "" }
    public static func longDate(_ s: String?) -> String { date(s).map(longDayF.string) ?? "" }
    public static func stamp(_ s: String?) -> String { date(s).map(stamp.string) ?? "" }
    public static func stampShort(_ s: String?) -> String { date(s).map(stampShort.string) ?? "" }
    public static func today(_ d: Date = Date()) -> String { todayF.string(from: d) }

    /// "Today", "Yesterday" or "Sat 8 Nov" for a `yyyy-MM-dd` key.
    public static func dayLabel(_ key: String, now: Date = Date()) -> String {
        guard let d = dayKeyF.date(from: key) else { return key }
        let cal = Calendar.current
        let diff = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day ?? 99
        return diff == 0 ? "Today" : diff == 1 ? "Yesterday" : shortDay.string(from: d)
    }

    public static func turnMeta(_ t: Turn) -> String {
        [dur(t.duration_ms), tok(t.tokens.totalIn) + " in / " + tok(t.tokens.output) + " out", money(t.cost),
         (t.model ?? "").replacingOccurrences(of: "^claude-", with: "", options: .regularExpression)]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }

    public static func shortPath(_ p: String) -> String {
        p.replacingOccurrences(of: "^/Users/[^/]+", with: "~", options: .regularExpression)
    }

    public static func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
}

// MARK: Files changed

public enum FileKind: String, CaseIterable, Sendable {
    case code, docs, media, outside
    public var label: String {
        switch self {
        case .code: "Code"
        case .docs: "Documents and text"
        case .media: "Images and media"
        case .outside: "Outside this repo"
        }
    }

    static let docExts: Set<String> = ["md", "mdx", "txt", "rst", "adoc", "pdf", "doc", "docx", "rtf", "odt", "pptx", "ppt", "key", "xlsx", "xls", "numbers", "pages"]
    static let mediaExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "heic", "avif", "bmp", "tiff", "mp4", "mov", "webm", "mp3", "wav", "m4a", "ogg", "woff", "woff2", "ttf", "otf", "glb", "gltf", "psd", "fig"]

    public static func of(_ path: String, root: String?) -> FileKind {
        if path.hasPrefix("/"), let root, !root.isEmpty, !path.hasPrefix(root + "/") { return .outside }
        let ext = (path as NSString).pathExtension.lowercased()
        return mediaExts.contains(ext) ? .media : docExts.contains(ext) ? .docs : .code
    }

    public static func group(_ files: [FileChange], root: String?) -> [(FileKind, [FileChange])] {
        let g = Dictionary(grouping: files) { of($0.path, root: root) }
        return allCases.compactMap { k in g[k].map { (k, $0) } }
    }

    public static func filesLine(_ files: [FileChange]) -> String {
        guard !files.isEmpty else { return "" }
        return "+\(files.reduce(0) { $0 + $1.add }) -\(files.reduce(0) { $0 + $1.del }) in " + TFormat.plural(files.count, "file")
    }

    /// The timeline card's change line: "Code +3 -1 in 2 files", "1 document", …
    public static func changeBits(_ t: Turn, root: String?) -> [String] {
        let g = Dictionary(uniqueKeysWithValues: group(t.files ?? [], root: root))
        var bits: [String] = []
        if let c = g[.code] { bits.append("Code " + filesLine(c)) }
        if let c = g[.docs] { bits.append(TFormat.plural(c.count, "document")) }
        if let c = g[.media] { bits.append(TFormat.plural(c.count, "image or media file", "images or media files")) }
        if let c = g[.outside] { bits.append(TFormat.plural(c.count, "file") + " outside the repo") }
        if let n = t.att_in, n > 0 { bits.append(TFormat.plural(n, "attachment") + " from you") }
        if let n = t.att_out, n > 0 { bits.append(TFormat.plural(n, "item") + " shared with you") }
        return bits
    }
}

public enum DiffLineKind: Sendable { case hunk, add, del, context }

public func diffLineKind(_ l: String) -> DiffLineKind {
    if l.hasPrefix("@@") || l.hasPrefix("…") { return .hunk }
    if l.hasPrefix("+") { return .add }
    if l.hasPrefix("-") { return .del }
    return .context
}

// MARK: Search snippet

/// FTS snippets mark hits with `[[` and `]]`. Returns runs of (text, isHit).
public func snippetRuns(_ s: String) -> [(String, Bool)] {
    var out: [(String, Bool)] = []
    var rest = Substring(s)
    while let open = rest.range(of: "[[") {
        if open.lowerBound > rest.startIndex { out.append((String(rest[..<open.lowerBound]), false)) }
        let after = rest[open.upperBound...]
        if let close = after.range(of: "]]") {
            out.append((String(after[..<close.lowerBound]), true))
            rest = after[close.upperBound...]
        } else { out.append((String(after), true)); rest = "" }
    }
    if !rest.isEmpty { out.append((String(rest), false)) }
    return out
}

// MARK: Agents

public enum AgentLogic {
    /// Sort order: Needs you, Your turn, Ready, Working, Unknown.
    public static let order = ["blocked": 0, "done": 1, "idle": 2, "working": 3, "unknown": 4]

    public static func label(_ status: String) -> String {
        ["blocked": "Needs you", "done": "Your turn", "idle": "Ready", "working": "Working"][status] ?? "Unknown"
    }

    /// Pulse's "Waiting for you": blocked agents, then done/idle ones whose last reply asks something.
    public static func waiting(_ agents: [LiveAgent]) -> [LiveAgent] {
        agents.filter { $0.status == "blocked" || (($0.status == "done" || $0.status == "idle") && $0.last?.question != nil) }
            .enumerated().sorted { (order[$0.element.status] ?? 4, $0.offset) < (order[$1.element.status] ?? 4, $1.offset) }.map(\.element)
    }

    /// Done or idle agents not in `waiting` (the "n more ready" count).
    public static func moreReady(_ agents: [LiveAgent]) -> Int {
        agents.filter { ($0.status == "done" || $0.status == "idle") && $0.last?.question == nil }.count
    }

    /// The Agents screen: Needs you, Your turn (questions first), Working.
    public static func groups(_ agents: [LiveAgent]) -> (needs: [LiveAgent], yourTurn: [LiveAgent], working: [LiveAgent]) {
        let turn = agents.filter { $0.status == "done" || $0.status == "idle" }
        return (agents.filter { $0.status == "blocked" },
                turn.filter { $0.last?.question != nil } + turn.filter { $0.last?.question == nil },
                agents.filter { $0.status == "working" || $0.status == "unknown" })
    }

    /// The message an `ask` answer sends: one line per question. A typed own
    /// answer replaces the picked options (theasa 96338dd). Send it only when `missing` is empty (theasa e4e3a29).
    public static func answerText(_ questions: [LiveAgent.Question], picks: [Int: [String]], own: [Int: String]) -> String {
        let lines = questions.enumerated().map { i, q in
            let typed = (own[i] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return "- \(q.question) \(!typed.isEmpty ? typed : (picks[i] ?? []).joined(separator: ", "))"
        }
        return "Answers to your questions:\n" + lines.joined(separator: "\n")
    }

    /// Questions with neither a pick nor typed text: nothing is sent while any is left.
    public static func missing(_ questions: [LiveAgent.Question], picks: [Int: [String]], own: [Int: String]) -> [Int] {
        questions.indices.filter { (picks[$0] ?? []).isEmpty && (own[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The toast for unanswered questions.
    public static func missingMessage(_ missing: [Int], of count: Int) -> String {
        if missing.count == 1 { return count > 1 ? "Answer question \(missing[0] + 1) first." : "Pick an option or type an answer first." }
        return "Answer questions \(missing.map { String($0 + 1) }.joined(separator: ", ")) first."
    }

    /// Next picks for question `q` after tapping `label`: multi-select toggles, single-select replaces or clears.
    public static func toggle(_ cur: [String], _ label: String, multi: Bool) -> [String] {
        if multi { return cur.contains(label) ? cur.filter { $0 != label } : cur + [label] }
        return cur.first == label ? [] : [label]
    }
}

// MARK: Timeline

public enum TimelineRow: Identifiable, Sendable {
    case turn(Turn)
    case fold(key: String, hidden: Int)
    public var id: String {
        switch self { case .turn(let t): "t\(t.id)"; case .fold(let k, _): "f" + k }
    }
}

public struct TimelineDay: Identifiable, Sendable {
    public let day: String
    public let count: Int
    public let rows: [TimelineRow]
    public var id: String { day }
}

/// Groups turns by local day; a run of more than three quiet turns shows three and a fold
/// ("Show n more quiet turns") unless its key is in `open`.
public func timeline(_ turns: [Turn], open: Set<String>) -> [TimelineDay] {
    var days: [(String, [Turn])] = []
    for t in turns {
        let k = TFormat.dayKey(t.started_at)
        if days.last?.0 == k { days[days.count - 1].1.append(t) } else { days.append((k, [t])) }
    }
    return days.map { k, ts in
        var rows: [TimelineRow] = [], run: [Turn] = []
        func flush() {
            if run.count > 3, !open.contains(k + "\(run[0].id)") {
                rows += run.prefix(3).map(TimelineRow.turn)
                rows.append(.fold(key: k + "\(run[0].id)", hidden: run.count - 3))
            } else { rows += run.map(TimelineRow.turn) }
            run = []
        }
        for t in ts { if t.isQuiet { run.append(t) } else { flush(); rows.append(.turn(t)) } }
        flush()
        return TimelineDay(day: k, count: ts.count, rows: rows)
    }
}
