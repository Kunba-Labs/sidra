import Foundation
import SidraDesign
#if os(iOS)
import UIKit
typealias ThumbHost = UIView
#else
import AppKit
typealias ThumbHost = NSView
#endif

/// Image paths printed in a terminal (Claude Code's `[image] /tmp/…/shot.png` lines), found on screen so
/// Sidra can show a thumbnail beside each one. Programs wrap long paths onto the next row, often under a
/// sidebar (herdr), so a path that runs to its row's end continues with the next row's first word at or
/// right of where it started.
public enum TerminalImagePaths {
    static let ext = #"\.(png|jpe?g|gif|webp|heic)$"#

    /// `lines` hold one Character per column. Returns the row each path starts on, and the path.
    public static func find(_ lines: [[Character]]) -> [(row: Int, path: String)] {
        var out: [(Int, String)] = []
        for (r, line) in lines.enumerated() {
            for (start, token) in tokens(line) where token.first == "/" || token.hasPrefix("~/") {
                var path = token, row = r
                // Wrapped: the token ends the row's text (a "(123KB)" size may follow) and the next row continues it.
                while path.range(of: ext, options: [.regularExpression, .caseInsensitive]) == nil, row + 1 < lines.count, row - r < 3,
                      endsRow(line: lines[row], token: row == r ? token : nil),
                      let next = tokens(lines[row + 1]).first(where: { $0.0 >= start - 2 }),
                      next.1.allSatisfy({ !$0.isWhitespace && $0 != "(" }) {
                    path += next.1; row += 1
                }
                if path.range(of: ext, options: [.regularExpression, .caseInsensitive]) != nil {
                    out.append((r, path))
                }
            }
        }
        return out
    }

    /// Words with their start column; `[image]/x.png` yields `/x.png` at its own column.
    static func tokens(_ line: [Character]) -> [(Int, String)] {
        var out: [(Int, String)] = [], cur = "", start = 0, inLink = false   // inLink: cur holds "://", tracked per append (no rescan)
        for (i, c) in line.enumerated() {
            // Brackets end a word, except inside a link ("…/Foo_(bar)").
            if c.isWhitespace || "│┃|'\"<>`".contains(c) || ("()".contains(c) && !inLink) {
                if !cur.isEmpty { out.append((start, cur)); cur = ""; inLink = false }
            } else {
                if cur.isEmpty { start = i }
                if c == "/" && cur.hasSuffix(":/") { inLink = true }
                cur.append(c)
            }
        }
        if !cur.isEmpty { out.append((start, cur)) }
        return out.map { s, t in
            if let slash = t.firstIndex(of: "/"), t.first != "/", t.first != "~", t[..<slash].hasSuffix("]") {
                return (s + t.distance(from: t.startIndex, to: slash), String(t[slash...]))
            }
            return (s, t)
        }
    }

    /// The token is the row's last word, apart from a trailing "(size)".
    private static func endsRow(line: [Character], token: String?) -> Bool {
        guard let token else { return true }
        let words = tokens(line).map(\.1).filter { $0.range(of: #"^\d+(\.\d+)?[KMG]?B$"#, options: .regularExpression) == nil }
        return words.last == token
    }
}

/// Web links on screen: a tap on one opens it in Safari. A URL wrapped onto the next row (the row is
/// full, or ends at a pane border) continues with that row's word at or right of where it started.
public enum TerminalLinks {
    public static func url(atRow row: Int, col: Int, in lines: [[Character]]) -> URL? {
        spans(in: lines).first { $0.cells.contains(row * 10_000 + col) }?.url
    }

    /// Every link on screen with the cells it covers (row * 10_000 + col), wrapped links joined.
    public static func spans(in lines: [[Character]]) -> [(url: URL, cells: Set<Int>)] {
        var out: [(URL, Set<Int>)] = []
        for r in lines.indices {
            for (start, token) in TerminalImagePaths.tokens(lines[r]) {
                guard let lo = token.range(of: "https://") ?? token.range(of: "http://") else { continue }
                let begin = start + token.distance(from: token.startIndex, to: lo.lowerBound)
                var text = String(token[lo.lowerBound...]), end = start + token.count - 1, rr = r
                var cells = Set((begin...end).map { r * 10_000 + $0 })
                while rr + 1 < lines.count, rr - r < 3, full(lines[rr], after: end),
                      let next = TerminalImagePaths.tokens(lines[rr + 1]).first(where: { $0.0 >= begin - 2 }),
                      next.0 <= begin + 4 {
                    rr += 1; text += next.1; end = next.0 + next.1.count - 1
                    cells.formUnion((next.0...end).map { rr * 10_000 + $0 })
                }
                // Trailing punctuation is not part of the link; a ")" only when it has no "(" to close.
                while let last = text.last, ".,;:!?]>'\")".contains(last),
                      last != ")" || text.filter({ $0 == ")" }).count > text.filter({ $0 == "(" }).count { text.removeLast() }
                if let url = URL(string: text) { out.append((url, cells)) }
            }
        }
        return out
    }

    /// Nothing but blanks or a box border after `col`: the text ran into the edge.
    private static func full(_ line: [Character], after col: Int) -> Bool {
        let rest = line.dropFirst(col + 1)
        if rest.isEmpty { return true }
        guard let firstMark = rest.firstIndex(where: { !$0.isWhitespace }) else { return false }
        return "│┃|".contains(line[firstMark]) && firstMark - col <= 2
    }
}

/// Thumbnails at the terminal's right edge, one per image path on screen; a tap opens the image.
@MainActor final class TerminalThumbnails {
    private weak var host: ThumbHost?
    private var views: [String: ThumbHost] = [:]
    private var images: [String: PlatformImage] = [:]
    private var pending: Set<String> = []
    /// Paths that could not be read, and when; tried again after 15 s (the file may not exist yet).
    private var failed: [String: Date] = [:]
    private var lastLayout: [String] = []
    /// Images pasted from this device, by their path on the far side: shown without reading them back,
    /// since a read shares the shell's SSH connection and typing waited behind it (Waseem, 2026-11-19).
    private var local: [String: PlatformImage] = [:]
    var fetch: ((String) async -> Data?)?
    var open: ((String, PlatformImage) -> Void)?

    init(host: ThumbHost) { self.host = host }

    func remember(_ path: String, _ image: PlatformImage) {
        if local.count >= 4 { local.removeAll() }   // ponytail: only the last few pastes; older ones are read back like any image
        local[path] = image
    }

    func owns(_ view: ThumbHost?) -> Bool { view.map { v in views.values.contains { $0 === v } } ?? false }

    func update(rows: [TerminalRow], cell: CGSize) {
        guard let host, fetch != nil else { return }
        let lines = rows.map { row in row.cells.map { $0.skip ? Character(" ") : ($0.text.first ?? " ") } }
        // One thumbnail per image: a path printed twice (the command and its output) shows at its last row.
        var found = TerminalImagePaths.find(lines)
        found = found.enumerated().filter { i, hit in !found[(i + 1)...].contains { $0.path == hit.path } }.map(\.element)
        let signature = found.map { "\($0.row):\($0.path)" } + ["\(host.bounds.width)"]
        guard signature != lastLayout else { return }
        lastLayout = signature
        // Only images whose path is on screen stay in memory; scrolling back fetches them again.
        let onScreen = Set(found.map(\.path))
        images = images.filter { onScreen.contains($0.key) }
        failed = failed.filter { onScreen.contains($0.key) }
        var seen = Set<String>()
        for (i, hit) in found.enumerated() {
            let key = "\(hit.row):\(hit.path)"
            seen.insert(key)
            guard let image = images[hit.path] ?? local[hit.path] else { load(hit.path); continue }
            let y = CGFloat(hit.row) * cell.height
            let nextY = i + 1 < found.count ? CGFloat(found[i + 1].row) * cell.height : y + 60
            let h = max(18, min(54, nextY - y - 4))
            let w = min(96, h * max(0.6, min(2, image.size.width / max(1, image.size.height))))
            // Only on blank cells, as far right as fits: a thumbnail never hides output or catches its taps.
            let cols = Int(((w + SidraSpace.gap) / cell.width).rounded(.up))
            let covered = (hit.row...(hit.row + Int(((h + 2) / cell.height).rounded(.up)) - 1)).filter { $0 < lines.count }
            let width = lines[hit.row].count
            guard let c = stride(from: width - cols, through: 0, by: -1).first(where: { c in
                covered.allSatisfy { r in lines[r].indices.contains(c + cols - 1) && lines[r][c..<(c + cols)].allSatisfy(\.isWhitespace) }
            }) else { seen.remove(key); continue }
            let v = views[key] ?? makeView(image, path: hit.path, key: key)
            v.frame = CGRect(x: CGFloat(c) * cell.width + SidraSpace.gap / 2, y: y + 2, width: w, height: h)
        }
        for (key, v) in views where !seen.contains(key) { v.removeFromSuperview(); views[key] = nil }
    }

    #if os(iOS)
    private func makeView(_ image: UIImage, path: String, key: String) -> ThumbHost {
        let v = UIImageView(image: image.preparingThumbnail(of: CGSize(width: 192, height: 120)) ?? image)
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.layer.cornerRadius = SidraRadius.icon
        v.layer.borderWidth = 1
        v.layer.borderColor = UIColor(white: 1, alpha: 0.14).cgColor
        v.isUserInteractionEnabled = true
        v.isAccessibilityElement = true
        v.accessibilityLabel = "Image " + (path as NSString).lastPathComponent
        v.accessibilityTraits = .button
        v.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        host?.addSubview(v)
        views[key] = v
        return v
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) { opened(g.view) }
    private func redraw() { host?.setNeedsDisplay() }
    #else
    private func makeView(_ image: NSImage, path: String, key: String) -> ThumbHost {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.contents = image
        v.layer?.contentsGravity = .resizeAspectFill
        v.layer?.masksToBounds = true
        v.layer?.cornerRadius = SidraRadius.icon
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        v.setAccessibilityElement(true)
        v.setAccessibilityRole(.button)
        v.setAccessibilityLabel("Image " + (path as NSString).lastPathComponent)
        v.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(tapped(_:))))
        host?.addSubview(v)
        views[key] = v
        return v
    }

    @objc private func tapped(_ g: NSClickGestureRecognizer) { opened(g.view) }
    private func redraw() { host?.needsDisplay = true }
    #endif

    /// The tapped thumbnail's image, full size.
    private func opened(_ view: ThumbHost?) {
        guard let key = views.first(where: { $0.value === view })?.key,
              let path = key.split(separator: ":", maxSplits: 1).last.map(String.init),
              let image = images[path] ?? local[path] else { return }
        open?(path, image)
    }

    private func load(_ path: String) {
        guard let fetch, !pending.contains(path), failed[path].map({ Date().timeIntervalSince($0) > 15 }) ?? true else { return }
        pending.insert(path)
        Task { @MainActor [weak self] in
            let data = await fetch(path)
            guard let self else { return }
            self.pending.remove(path)
            if let data, let image = PlatformImage(data: data), self.lastLayout.contains(where: { $0.hasSuffix(":" + path) }) {
                self.images[path] = image
                self.lastLayout = []   // lay out again with the new image
                self.redraw()
            } else {
                self.failed[path] = Date()
                // Try again in 15 s even if nothing else redraws the terminal.
                try? await Task.sleep(for: .seconds(15.5))
                self.lastLayout = []
                self.redraw()
            }
        }
    }
}
