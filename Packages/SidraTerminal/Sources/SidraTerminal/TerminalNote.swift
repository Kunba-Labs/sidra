import Foundation

/// A choice row a TUI draws as "1: Learn more   2: Knew this already   0: Dismiss": Claude Code's "You should know"
/// notes (Heads up), and its session rating. Sidra shows it as a card with real buttons (Waseem, 2026-11-28: the
/// digits were hard to hit on a phone). A button types its digit, as the keyboard would; nothing else changes.
public struct TerminalNote: Equatable, Sendable {
    public struct Choice: Equatable, Sendable { public let key: String; public let label: String }
    /// "Heads up", "You should know", or nil for another row (the rating).
    public let tag: String?
    /// The note's text above the choices, wrapped lines joined.
    public let text: String
    public let choices: [Choice]

    /// The lowest choice row on screen that has a "0: Dismiss", searched in the last 24 rows only (the note sits
    /// above the prompt; older output in the scrollback must not raise a card).
    public static func find(in rows: [String]) -> TerminalNote? {
        let start = max(0, rows.count - 24)
        guard let at = rows.indices.reversed().first(where: { $0 >= start && choices(rows[$0]) != nil }), let picks = choices(rows[at]) else { return nil }
        // The text: lines above the choices, up to a rule, two blank lines, or 14 lines.
        var lines: [String] = [], blanks = 0
        for i in stride(from: at - 1, through: max(0, at - 14), by: -1) {
            let l = rows[i].trimmingCharacters(in: .whitespaces)
            // A rule, or Claude Code's own transcript marks, end the note.
            if ["─", "━", "╭", "╰", "⏺", "❯", "⎿"].contains(where: { l.hasPrefix($0) }) { break }
            if l.isEmpty { blanks += 1; if blanks == 2, !lines.isEmpty { break }; continue }
            blanks = 0
            lines.insert(l, at: 0)
            if l.hasPrefix("Heads up") || l.hasPrefix("You should know") { break }   // its first line
        }
        var text = lines.joined(separator: " ")
        var tag: String?
        for t in ["Heads up", "You should know"] {
            if text.hasPrefix(t), let r = text.range(of: t + " · ") ?? text.range(of: t + " ") {
                tag = t; text = String(text[r.upperBound...]); break
            }
        }
        return TerminalNote(tag: tag, text: text.trimmingCharacters(in: .whitespaces), choices: picks)
    }

    /// "1: Learn more   2: Knew this already   0: Dismiss" → three choices; nil unless it has 0: Dismiss and two or more.
    static func choices(_ row: String) -> [Choice]? {
        let parts = row.trimmingCharacters(in: .whitespaces).components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var out: [Choice] = []
        for p in parts {
            guard p.count > 3, let d = p.first, d.isNumber, p.dropFirst().hasPrefix(": ") else { return nil }
            out.append(Choice(key: String(d), label: String(p.dropFirst(3))))
        }
        guard out.count >= 2, out.contains(where: { $0.key == "0" && $0.label == "Dismiss" }) else { return nil }
        return out
    }
}
