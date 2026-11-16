import SwiftUI

@MainActor @Observable final class AppModel {
    static let kept = AppModel()

    // Index
    var feed: Feed = .top
    var query = ""
    var stories: [Story] = []
    var loadingFeed = false
    var feedError: String?
    private var ids: [Int] = []
    private var loaded = 0
    private var loadingMore = false

    // Layout and keyboard
    enum Pane { case three, noIndex, discussion, article }
    var pane: Pane = .three              // iPad landscape
    var right: Route = .discussion       // iPad portrait: which of the two shares the right pane
    var showIndex = true                 // iPad portrait
    var typing = false                   // a text field has the focus: plain-letter commands are off
    var keyed = false                    // the keyboard moved the cursor, so the current comment is marked

    // Open story
    var selected: Story?
    var comments: [Comment] = []
    var threadLoading = false
    var threadError: String?
    var collapsed: Set<Int> = []
    var cursor: Int?        // id of the comment at the top of the discussion
    var baseline: Int?      // highest comment id seen on the previous visit; newer ones are "new"
    var focus: Int?         // id of the comment whose subthread is in focus
    var find = ""
    var finding = false
    let summary = Summarizer()
    private var index: [Int: Int] = [:]
    private(set) var roots: [Int] = []
    private var loadTask: Task<Void, Never>?

    // Kept between launches.
    // ponytail: UserDefaults, and `read` grows without limit. Move to a file with pruning if it gets large.
    var read: Set<Int> = AppModel.load("read") ?? [] { didSet { AppModel.save(read, "read") } }
    var seen: [Int: Int] = AppModel.load("seen") ?? [:] { didSet { AppModel.save(seen, "seen") } }
    var saved: [Story] = AppModel.load("saved") ?? [] { didSet { AppModel.save(saved, "saved") } }

    static func load<V: Decodable>(_ key: String) -> V? {
        UserDefaults.standard.data(forKey: "hackertab." + key).flatMap { try? JSONDecoder().decode(V.self, from: $0) }
    }
    static func save<V: Encodable>(_ value: V, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: "hackertab." + key)
    }

    // MARK: Index

    func show(_ f: Feed) {
        guard f != feed else { return }
        feed = f
        stories = []
        Task { await loadFeed() }
    }

    func loadFeed() async {
        let f = feed, q = query
        loadingFeed = true
        feedError = nil
        defer { if f == feed { loadingFeed = false } }
        do {
            let result: [Story]
            switch f {
            case .saved: result = saved
            case .search: result = q.isEmpty ? [] : try await HN.search(q)
            default:
                let all = try await HN.ids(f)
                result = await HN.stories(Array(all.prefix(30)))
                if f == feed { ids = all; loaded = min(30, all.count) }
            }
            if f == feed && q == query { stories = result }
        } catch {
            if f == feed { feedError = "could not load · pull to retry" }
        }
    }

    func loadMore() async {
        guard Feed.remote.contains(feed), !loadingMore, !loadingFeed, loaded < ids.count else { return }
        let f = feed
        loadingMore = true
        defer { loadingMore = false }
        let next = Array(ids[loaded..<min(loaded + 30, ids.count)])
        let more = await HN.stories(next)
        guard f == feed else { return }
        loaded += next.count
        stories += more.filter { s in !stories.contains { $0.id == s.id } }
    }

    func isSaved(_ s: Story) -> Bool { saved.contains { $0.id == s.id } }
    func toggleSaved(_ s: Story) {
        if isSaved(s) { saved.removeAll { $0.id == s.id } } else { saved.insert(s, at: 0) }
        if feed == .saved { stories = saved }
    }

    // MARK: Thread

    /// Opens a story. The thread loads now, and the summary starts as soon as it has loaded,
    /// so that it is ready when the reader reaches the discussion.
    func open(_ s: Story) {
        guard selected?.id != s.id else { return }
        selected = s
        read.insert(s.id)
        baseline = seen[s.id]
        reloadThread()
    }

    func reloadThread() {
        guard let s = selected else { return }
        comments = []; index = [:]; roots = []
        collapsed = []; cursor = nil; focus = nil; find = ""; finding = false
        threadError = nil
        threadLoading = true
        loadTask?.cancel()
        summary.cancel()
        loadTask = Task {
            do {
                let c = try await HN.thread(s.id)
                guard !Task.isCancelled, selected?.id == s.id else { return }
                comments = c
                index = Dictionary(uniqueKeysWithValues: c.enumerated().map { ($1.id, $0) })
                roots = c.indices.filter { c[$0].depth == 0 }
                threadLoading = false
                summary.start(story: s, comments: c)
            } catch {
                guard !Task.isCancelled, selected?.id == s.id else { return }
                threadLoading = false
                threadError = "could not load the discussion"
            }
        }
    }

    /// Call when the discussion is on screen: what is there now counts as seen next time.
    func markSeen() {
        guard let s = selected, let top = comments.map(\.id).max() else { return }
        seen[s.id] = top
    }

    func isNew(_ c: Comment) -> Bool { baseline.map { c.id > $0 } ?? false }
    var newCount: Int { baseline.map { b in comments.reduce(0) { $0 + ($1.id > b ? 1 : 0) } } ?? 0 }

    /// The comments to draw: the focused subthread or all, minus collapsed replies, or the find matches.
    var rows: [Comment] {
        var range = 0..<comments.count
        if let f = focus, let i = index[f] { range = i..<(i + comments[i].subtree + 1) }
        if finding && !find.isEmpty {
            return comments[range].filter { $0.plain.localizedCaseInsensitiveContains(find) || $0.author.localizedCaseInsensitiveContains(find) }
        }
        var out: [Comment] = []
        var i = range.lowerBound
        while i < range.upperBound {
            let c = comments[i]
            out.append(c)
            i += collapsed.contains(c.id) ? c.subtree + 1 : 1
        }
        return out
    }

    func comment(_ id: Int?) -> Comment? { id.flatMap { index[$0] }.map { comments[$0] } }
    var current: Comment? { comment(cursor) ?? rows.first }

    /// The ancestors of a comment, outermost first.
    func ancestors(of c: Comment) -> [Comment] {
        var out: [Comment] = []
        var p = c.parent
        // Guarded: a view can still ask about a comment of the thread that was just replaced.
        while let i = p, comments.indices.contains(i) { out.insert(comments[i], at: 0); p = comments[i].parent }
        return out
    }

    func toggle(_ id: Int) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    func jump(to id: Int) {
        guard let c = comment(id) else { return }
        for a in ancestors(of: c) { collapsed.remove(a.id) }
        if let f = focus, let fi = index[f], let ci = index[id], !(fi...(fi + comments[fi].subtree)).contains(ci) { focus = nil }
        finding = false
        cursor = id
    }

    func step(_ d: Int) {
        keyed = true
        let r = rows
        guard !r.isEmpty else { return }
        let i = r.firstIndex { $0.id == cursor } ?? (d > 0 ? -1 : 0)
        cursor = r[min(max(i + d, 0), r.count - 1)].id
    }

    func stepThread(_ d: Int) {
        guard let c = current, !roots.isEmpty else { return }
        // "Previous" from inside a thread goes to the top of that thread first.
        let target = d < 0 && c.depth > 0 ? c.root : c.root + d
        focus = nil
        keyed = true
        jump(to: comments[roots[min(max(target, 0), roots.count - 1)]].id)
    }

    /// Opens the next or previous story in the list.
    func stepStory(_ d: Int) {
        guard !stories.isEmpty else { return }
        let i = stories.firstIndex { $0.id == selected?.id } ?? (d > 0 ? -1 : 0)
        open(stories[min(max(i + d, 0), stories.count - 1)])
    }

    /// Focus on the thread under the cursor, or leave focus.
    func toggleFocus() {
        if focus != nil { focus = nil; return }
        guard var c = current else { return }
        if c.subtree == 0, let p = c.parent { c = comments[p] }
        if c.subtree > 0 { collapsed.remove(c.id); focus = c.id; cursor = c.id; keyed = true }
    }

    func escape() {
        if finding { finding = false } else if focus != nil { focus = nil } else { keyed = false }
    }

    func setPane(_ p: Pane) {
        pane = pane == p ? .three : p
        if p == .article { right = .article }
        if p == .discussion { right = .discussion }
    }

    func toParent() {
        keyed = true
        if let p = current?.parent { jump(to: comments[p].id) }
    }

    func toggleCurrent() {
        if let c = current { cursor = c.id; keyed = true; toggle(c.id) }
    }
}
