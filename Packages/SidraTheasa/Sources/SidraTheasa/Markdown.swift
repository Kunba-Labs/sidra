import Foundation

/// Block-level Markdown for an agent's reply. Inline syntax (bold, code, links) is left to
/// `AttributedString(markdown:)`, which handles inline only.
// ponytail: no nested lists or HTML blocks; agent replies rarely use them. Add when a reply renders wrong.
public enum MDBlock: Equatable, Sendable {
    case heading(Int, String)
    case paragraph(String)
    case list(ordered: Bool, items: [String])
    case code(String)
    case quote(String)
    case table([[String]])
    case rule
}

public func markdownBlocks(_ text: String) -> [MDBlock] {
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var out: [MDBlock] = []
    var i = 0
    var para: [String] = []
    func flushPara() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] } }
    func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
    func listItem(_ s: String) -> (Bool, String)? {
        let t = trimmed(s)
        for p in ["- ", "* ", "+ "] where t.hasPrefix(p) { return (false, String(t.dropFirst(2))) }
        if let r = t.range(of: #"^\d+[.)] "#, options: .regularExpression) { return (true, String(t[r.upperBound...])) }
        return nil
    }
    while i < lines.count {
        let line = lines[i], t = trimmed(line)
        if t.hasPrefix("```") || t.hasPrefix("~~~") {
            flushPara()
            let fence = String(t.prefix(3))
            var body: [String] = []
            i += 1
            while i < lines.count, !trimmed(lines[i]).hasPrefix(fence) { body.append(lines[i]); i += 1 }
            out.append(.code(body.joined(separator: "\n")))
            i += 1
            continue
        }
        if t.isEmpty { flushPara(); i += 1; continue }
        if let r = t.range(of: #"^#{1,6} "#, options: .regularExpression) {
            flushPara()
            out.append(.heading(t[r].count - 1, String(t[r.upperBound...])))
            i += 1; continue
        }
        if t.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil { flushPara(); out.append(.rule); i += 1; continue }
        if t.hasPrefix(">") {
            flushPara()
            var q: [String] = []
            while i < lines.count, trimmed(lines[i]).hasPrefix(">") { q.append(trimmed(String(trimmed(lines[i]).dropFirst()))); i += 1 }
            out.append(.quote(q.joined(separator: "\n")))
            continue
        }
        if t.hasPrefix("|"), i + 1 < lines.count, trimmed(lines[i + 1]).range(of: #"^\|?[\s:|-]+\|?$"#, options: .regularExpression) != nil, trimmed(lines[i + 1]).contains("-") {
            flushPara()
            var rows: [[String]] = []
            func cells(_ s: String) -> [String] {
                var x = trimmed(s)
                if x.hasPrefix("|") { x.removeFirst() }
                if x.hasSuffix("|") { x.removeLast() }
                return x.components(separatedBy: "|").map(trimmed)
            }
            rows.append(cells(t))
            i += 2
            while i < lines.count, trimmed(lines[i]).hasPrefix("|") { rows.append(cells(lines[i])); i += 1 }
            out.append(.table(rows))
            continue
        }
        if let (ordered, first) = listItem(line) {
            flushPara()
            var items = [first]
            i += 1
            while i < lines.count {
                if let (_, next) = listItem(lines[i]) { items.append(next); i += 1 }
                else if !trimmed(lines[i]).isEmpty, lines[i].hasPrefix("  ") { items[items.count - 1] += " " + trimmed(lines[i]); i += 1 }
                else { break }
            }
            out.append(.list(ordered: ordered, items: items))
            continue
        }
        para.append(t)
        i += 1
    }
    flushPara()
    return out
}
