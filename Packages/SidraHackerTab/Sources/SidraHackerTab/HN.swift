import Foundation
import SwiftUI

enum Feed: String, CaseIterable, Identifiable {
    case top, new, best, ask, show, jobs, saved, search
    var id: String { rawValue }
    static let remote: [Feed] = [.top, .new, .best, .ask, .show, .jobs]
    var endpoint: String { self == .jobs ? "jobstories" : rawValue + "stories" }
}

struct Story: Identifiable, Codable, Hashable {
    let id: Int
    var title: String
    var url: URL?
    var text: String?
    var by: String
    var score: Int
    var time: Int
    var descendants: Int
    var kids: [Int]

    var host: String? {
        guard let h = url?.host() else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
    var age: String { HN.age(time) }
    var hnURL: URL { URL(string: "https://news.ycombinator.com/item?id=\(id)")! }

    enum CodingKeys: String, CodingKey { case id, title, url, text, by, score, time, descendants, kids }
    init(id: Int, title: String, url: URL?, text: String?, by: String, score: Int, time: Int, descendants: Int, kids: [Int] = []) {
        self.id = id; self.title = title; self.url = url; self.text = text; self.by = by
        self.score = score; self.time = time; self.descendants = descendants; self.kids = kids
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        url = (try? c.decodeIfPresent(String.self, forKey: .url)).flatMap { $0 }.flatMap(URL.init(string:))
        text = try c.decodeIfPresent(String.self, forKey: .text)
        by = try c.decodeIfPresent(String.self, forKey: .by) ?? ""
        score = try c.decodeIfPresent(Int.self, forKey: .score) ?? 0
        time = try c.decodeIfPresent(Int.self, forKey: .time) ?? 0
        descendants = try c.decodeIfPresent(Int.self, forKey: .descendants) ?? 0
        kids = try c.decodeIfPresent([Int].self, forKey: .kids) ?? []
    }
}

/// One comment in a thread, stored flat in display (pre-)order.
struct Comment: Identifiable {
    let id: Int
    let author: String
    let time: Int
    let depth: Int
    let parent: Int?      // index of the parent in the flat array
    let root: Int         // number of the top-level thread, from 0
    var subtree: Int      // number of descendants
    let text: AttributedString
    let plain: String
}

enum HN {
    static let fb = "https://hacker-news.firebaseio.com/v0/"
    static let algolia = "https://hn.algolia.com/api/v1/"

    static func get<V: Decodable>(_ url: String, as: V.Type = V.self) async throws -> V {
        let (data, _) = try await URLSession.shared.data(from: URL(string: url)!)
        return try JSONDecoder().decode(V.self, from: data)
    }

    static func ids(_ feed: Feed) async throws -> [Int] { try await get(fb + feed.endpoint + ".json") }

    /// Fetches items at the same time and keeps the order of `ids`. Items that fail to load are dropped.
    static func stories(_ ids: [Int]) async -> [Story] {
        await withTaskGroup(of: (Int, Story?).self) { group in
            for (i, id) in ids.enumerated() {
                group.addTask { (i, try? await get(fb + "item/\(id).json", as: Story.self)) }
            }
            var out = [Story?](repeating: nil, count: ids.count)
            for await (i, s) in group { out[i] = s }
            return out.compactMap { $0 }.filter { !$0.title.isEmpty }
        }
    }

    static func search(_ query: String) async throws -> [Story] {
        struct Hits: Decodable { let hits: [Hit] }
        struct Hit: Decodable {
            let objectID: String; let title: String?; let url: String?; let author: String?
            let points: Int?; let created_at_i: Int?; let num_comments: Int?; let story_text: String?
        }
        var c = URLComponents(string: algolia + "search")!
        c.queryItems = [.init(name: "query", value: query), .init(name: "tags", value: "story"), .init(name: "hitsPerPage", value: "40")]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        return try JSONDecoder().decode(Hits.self, from: data).hits.compactMap { h in
            guard let id = Int(h.objectID), let title = h.title else { return nil }
            return Story(id: id, title: title, url: h.url.flatMap(URL.init(string:)), text: h.story_text, by: h.author ?? "",
                         score: h.points ?? 0, time: h.created_at_i ?? 0, descendants: h.num_comments ?? 0)
        }
    }

    // MARK: Threads

    private struct Node: Decodable {
        let id: Int; let author: String?; let text: String?; let created_at_i: Int?; let children: [Node]
    }

    /// The whole comment tree in HN's ranked order.
    /// Algolia gives the tree in one request but in time order; Firebase gives the rank of each
    /// comment's replies. So: one Algolia request, then one small Firebase request for each
    /// comment that has two or more replies.
    static func thread(_ storyID: Int) async throws -> [Comment] {
        let tree: Node = try await get(algolia + "items/\(storyID)")
        var parents: [Int] = []
        func collect(_ n: Node) { if n.children.count > 1 { parents.append(n.id) }; n.children.forEach(collect) }
        collect(tree)
        let rank = await withTaskGroup(of: (Int, [Int]?).self) { group in
            for id in parents { group.addTask { (id, try? await get(fb + "item/\(id)/kids.json", as: [Int].self)) } }
            var out: [Int: [Int: Int]] = [:]
            for await (id, kids) in group {
                if let kids { out[id] = Dictionary(kids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a }) }
            }
            return out
        }
        var flat: [Comment] = []
        func walk(_ n: Node, depth: Int, parent: Int?, root: Int) {
            // A deleted comment has no text. Keep it only when it has replies to hang on.
            guard n.text != nil || !n.children.isEmpty else { return }
            let i = flat.count
            let text = attributed(n.text ?? "[deleted]")
            flat.append(Comment(id: n.id, author: n.author ?? "[deleted]", time: n.created_at_i ?? 0, depth: depth,
                                parent: parent, root: root, subtree: 0, text: text, plain: String(text.characters)))
            for c in ordered(n) { walk(c, depth: depth + 1, parent: i, root: root) }
            flat[i].subtree = flat.count - i - 1
        }
        func ordered(_ n: Node) -> [Node] {
            guard let r = rank[n.id] else { return n.children }
            return n.children.sorted { (r[$0.id] ?? .max) < (r[$1.id] ?? .max) }
        }
        var root = 0
        for c in ordered(tree) {
            let before = flat.count
            walk(c, depth: 0, parent: nil, root: root)
            if flat.count > before { root += 1 }
        }
        return flat
    }

    // MARK: Text

    static func age(_ time: Int) -> String {
        let s = max(0, Int(Date().timeIntervalSince1970) - time)
        if s < 3600 { return "\(max(1, s / 60))m" }
        if s < 86400 { return "\(s / 3600)h" }
        if s < 86400 * 365 { return "\(s / 86400)d" }
        return "\(s / (86400 * 365))y"
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in ["&quot;": "\"", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&apos;": "'"] { out = out.replacingOccurrences(of: k, with: v) }
        out = out.replacing(/&#(x?)([0-9a-fA-F]+);/) { m in
            UInt32(m.2, radix: m.1.isEmpty ? 10 : 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// HN comment HTML (p, i, a, pre, code and entities) as an attributed string.
    /// ponytail: a small scanner, not an HTML parser. HN only emits these tags.
    static func attributed(_ html: String, size: CGFloat = 15) -> AttributedString {
        var out = AttributedString()
        var italic = false, code = false
        var link: URL?
        var buf = ""
        func flush() {
            guard !buf.isEmpty else { return }
            var run = AttributedString(decodeEntities(buf))
            if code { run.font = T.mono(size - 2) } else if italic { run.font = .custom("IBMPlexSans-Italic", size: size) }
            if let link { run.link = link; run.foregroundColor = T.accent }
            out.append(run)
            buf = ""
        }
        var i = html.startIndex
        while i < html.endIndex {
            if html[i] == "<", let close = html[i...].firstIndex(of: ">") {
                flush()
                let tag = html[html.index(after: i)..<close]
                switch tag.split(separator: " ").first?.lowercased() ?? "" {
                case "p": if !out.characters.isEmpty { out.append(AttributedString("\n\n")) }
                case "i": italic = true
                case "/i": italic = false
                case "pre": code = true
                case "/pre": code = false
                case "a":
                    if let m = tag.firstMatch(of: /href="([^"]*)"/) { link = URL(string: decodeEntities(String(m.1))) }
                case "/a": link = nil
                default: break
                }
                i = html.index(after: close)
            } else {
                buf.append(html[i])
                i = html.index(after: i)
            }
        }
        flush()
        return out
    }
}
