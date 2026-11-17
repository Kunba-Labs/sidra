import Foundation
import SwiftUI
import SidraDesign
import SidraSSH

// MARK: - API shapes (GitLab REST v4)

struct GitLabProject: Decodable, Identifiable, Sendable, Hashable {
    struct Namespace: Decodable, Sendable, Hashable { let id: Int; let kind: String; let full_path: String }
    let id: Int
    let name: String
    let path_with_namespace: String
    let web_url: String
    let avatar_url: String?
    let namespace: Namespace
    let last_activity_at: Date?

    /// The list groups projects by their top namespace (group or user).
    var group: String { String(path_with_namespace.split(separator: "/").first ?? Substring(path_with_namespace)) }
}

struct GitLabPipeline: Decodable, Identifiable, Sendable, Hashable {
    let id: Int
    let project_id: Int
    let ref: String
    let status: String
    let sha: String
    let web_url: String
    let created_at: Date
    let updated_at: Date

    var isActive: Bool { GitLabStatus.active.contains(status) }
    var shortSHA: String { String(sha.prefix(8)) }
}

struct GitLabJob: Decodable, Identifiable, Sendable, Hashable {
    let id: Int
    let name: String
    let stage: String
    let status: String
    let duration: Double?
    let failure_reason: String?
    let web_url: String
}

enum GitLabStatus {
    static let active: Set<String> = ["running", "pending", "created", "preparing", "waiting_for_resource", "scheduled"]
}

struct GitLabError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Client

struct GitLabClient: Sendable {
    let base: URL
    let token: String

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let frac = ISO8601DateFormatter(); frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = frac.date(from: s) ?? plain.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "not a date: \(s)"))
        }
        return d
    }()

    /// https://git.example.com (no /api/v4, no trailing slash), or nil. HTTPS only: every request carries the token.
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/api/v4") { s.removeLast(7) }
        guard let url = URL(string: s), url.host != nil, url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    func data(_ path: String, _ query: [String: String] = [:]) async throws -> Data {
        var c = URLComponents(url: base.appendingPathComponent("api/v4" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: c.url!, timeoutInterval: 20)
        req.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300: return data
        case 401: throw GitLabError(message: "GitLab refused the token (401). It needs the read_api scope and must not be expired.")
        case 403: throw GitLabError(message: "The token may not read this (403).")
        case 404: throw GitLabError(message: "GitLab has no \(path) (404).")
        default: throw GitLabError(message: "GitLab answered \(code).")
        }
    }

    func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        try Self.decoder.decode(T.self, from: try await data(path, query))
    }

    /// Every page of a list endpoint, 100 at a time, up to `maxPages`.
    func all<T: Decodable>(_ path: String, _ query: [String: String] = [:], maxPages: Int = 20) async throws -> [T] {
        var out: [T] = []
        for page in 1...maxPages {
            let batch: [T] = try await get(path, query.merging(["per_page": "100", "page": "\(page)"]) { $1 })
            out += batch
            if batch.count < 100 { break }
        }
        return out
    }
}

// MARK: - Job log

/// A GitLab job trace, split into its sections with the lines that look like errors marked.
/// Runners write `<time> <stream><O|E>[+] text`; `+` continues the previous line. Sections come
/// as `section_start:<unix>:<name>` / `section_end:<unix>:<name>` (ESC[0K after each).
struct JobLog: Sendable {
    struct Line: Sendable, Identifiable { let id: Int; let text: String; let isError: Bool }
    struct Section: Sendable, Identifiable {
        let id: Int
        let name: String        // "" for lines outside any section
        var title: String
        var lines: [Line] = []
        var started: Int?
        var ended: Int?
        var duration: Int? { started.flatMap { s in ended.map { $0 - s } } }
        var hasErrors: Bool { lines.contains(where: \.isError) }
    }
    var sections: [Section]
    var lineCount: Int { sections.reduce(0) { $0 + $1.lines.count } }

    /// The section to open: the last one with errors that is not the runner's cleanup.
    var failingSectionID: Int? {
        sections.last { $0.hasErrors && !$0.name.hasPrefix("cleanup") && !$0.name.isEmpty }?.id
            ?? sections.last { $0.hasErrors }?.id
    }

    static let stamp = try! NSRegularExpression(pattern: #"^\d{4}-\d\d-\d\dT[0-9:.]+Z [0-9a-f]{2}[OE](\+?) ?"#)
    static let ansi = try! NSRegularExpression(pattern: "\u{1b}\\[[0-9;?]*[A-Za-z]|\u{1b}\\][^\u{07}]*\u{07}")
    static let marker = try! NSRegularExpression(pattern: #"section_(start|end):(\d+):([A-Za-z0-9_.\-]+)(\[[^\]]*\])?"#)

    static func parse(_ raw: String) -> JobLog {
        // 1. Physical lines, timestamps off, continuations joined.
        var logical: [String] = []
        for line in raw.components(separatedBy: "\n") {
            let ns = line as NSString
            if let m = stamp.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let rest = ns.substring(from: m.range.location + m.range.length)
                if m.range(at: 1).length > 0, !logical.isEmpty { logical[logical.count - 1] += rest } else { logical.append(rest) }
            } else {
                logical.append(line)
            }
        }
        while logical.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { logical.removeLast() }
        // 2. Sections and lines.
        var sections = [Section(id: 0, name: "", title: "")]
        var stack: [Int] = []   // open section indexes
        var n = 0
        func add(_ text: String) {
            let clean = ansi.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
                .replacingOccurrences(of: "\r", with: "")
            if clean.trimmingCharacters(in: .whitespaces).isEmpty && sections[stack.last ?? 0].lines.isEmpty { return }
            n += 1
            let target = stack.last ?? appendLoose()
            sections[target].lines.append(Line(id: n, text: clean, isError: isError(clean)))
        }
        func appendLoose() -> Int {
            // Text outside sections after one closed goes into a fresh unnamed block, so order holds.
            if sections.last?.name == "" { return sections.count - 1 }
            sections.append(Section(id: sections.count, name: "", title: ""))
            return sections.count - 1
        }
        for line in logical {
            var rest = line as NSString
            while let m = marker.firstMatch(in: rest as String, range: NSRange(location: 0, length: rest.length)) {
                let before = rest.substring(to: m.range.location)
                if !ansi.stringByReplacingMatches(in: before, range: NSRange(location: 0, length: (before as NSString).length), withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\r"))).isEmpty { add(before) }
                let kind = rest.substring(with: m.range(at: 1)), time = Int(rest.substring(with: m.range(at: 2))), name = rest.substring(with: m.range(at: 3))
                rest = rest.substring(from: m.range.location + m.range.length) as NSString
                if kind == "start" {
                    // The header text follows on the same line after ESC[0K.
                    let header = ansi.stringByReplacingMatches(in: rest as String, range: NSRange(location: 0, length: rest.length), withTemplate: "")
                        .replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespaces)
                    sections.append(Section(id: sections.count, name: name, title: header.isEmpty ? Self.title(name) : header, started: time))
                    stack.append(sections.count - 1)
                    rest = ""
                } else if let i = stack.lastIndex(where: { sections[$0].name == name }) {
                    sections[stack[i]].ended = time
                    stack.removeSubrange(i...)
                }
            }
            let tail = rest as String
            // What a marker leaves behind (\r ESC[0K) is no line; a plain empty line is.
            let visible = ansi.stringByReplacingMatches(in: tail, range: NSRange(location: 0, length: (tail as NSString).length), withTemplate: "").replacingOccurrences(of: "\r", with: "")
            if !visible.isEmpty || !line.contains("section_") { add(tail) }
        }
        return JobLog(sections: sections.filter { !$0.lines.isEmpty || !$0.name.isEmpty })
    }

    static func title(_ name: String) -> String {
        switch name {
        case "prepare_executor": "Prepare executor"
        case "prepare_script": "Prepare environment"
        case "get_sources": "Get sources"
        case "step_script": "Script"
        case "after_script": "After script"
        case "upload_artifacts_on_failure", "upload_artifacts_on_success": "Upload artifacts"
        default: name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static let errorWords = try! NSRegularExpression(pattern: #"(?i)(^|[^a-z])(error|fatal|panic(ked)?|exception|traceback|segmentation fault)([^a-z]|$)|exit (code|status) [1-9]|(^|[^0-9 ] ?)\bfailed\b|^FAIL\b|_failed\b"#)
    static let noError = try! NSRegularExpression(pattern: #"(?i)\b0 (failed|errors?)\b|\berrors?: 0\b|no errors"#)

    static func isError(_ s: String) -> Bool {
        let r = NSRange(location: 0, length: (s as NSString).length)
        return errorWords.firstMatch(in: s, range: r) != nil && noError.firstMatch(in: s, range: r) == nil
    }
}

// MARK: - Store

/// One connection's recent pipelines, projects and avatars. Polls while the app runs, faster while a
/// tab of this connection is on screen (the title bar's working pill counts running pipelines).
@MainActor @Observable
final class PipelinesStore {
    let connection: PipelineConnection
    private(set) var projects: [Int: GitLabProject] = [:]
    private(set) var pipelines: [GitLabPipeline] = []
    private(set) var error: String?
    private(set) var loading = false
    private var refreshing = false
    private var round = 0
    private(set) var lastRefresh: Date?
    private(set) var avatars: [String: PlatformImage] = [:]   // "p<id>" or "g<id>"
    private var groupIDs: [String: Int] = [:]           // full_path → id, for groups with an avatar
    private var avatarTried: Set<String> = []
    private var jobsCache: [Int: [GitLabJob]] = [:]
    /// A pipeline the working dropdown asked to show.
    var reveal: Int?
    /// What the tab shows, kept here so a tab switch comes back to the same run and log.
    var selected: Int? { didSet { if let selected { markSeen(selected) } } }
    var expanded: Set<String> = []
    var selectedJob: [Int: Int] = [:]          // pipeline → job
    private var logCache: [Int: JobLog] = [:]  // job → parsed log, the last few
    private var logOrder: [Int] = []
    var visiblePanes = 0
    private var poller: Task<Void, Never>?

    init(connection: PipelineConnection) {
        self.connection = connection
        seenFailed = Set(UserDefaults.standard.array(forKey: "sidra.pipelines.seenFailed.\(connection.id.uuidString)") as? [Int] ?? [])
    }

    var host: String { connection.host }
    /// Set when the connection's URL or token changes or it is removed: this store makes no more clients,
    /// so a pane still holding it never sends the new token to the old server.
    private(set) var retired = false
    func retire() { retired = true; stop() }
    var client: (any CIClient)? {
        guard !retired, let token = KeychainStore.string(for: connection.tokenKey), !token.isEmpty else { return nil }
        return connection.client(token: token)
    }
    var connected: Bool { client != nil }
    var running: [GitLabPipeline] { pipelines.filter(\.isActive) }
    /// Projects whose newest pipeline failed in the last 7 days; an old failure nobody touched is no news.
    var failedCount: Int {
        let since = Date().addingTimeInterval(-7 * 86400)
        return latestPerProject.filter { $0.status == "failed" && $0.updated_at > since }.count
    }
    /// Failed pipelines you opened: the title bar's red dot leaves them out until a new one fails (2026-11-14).
    private var seenKey: String { "sidra.pipelines.seenFailed.\(connection.id.uuidString)" }
    private(set) var seenFailed: Set<Int>
    var unseenFailedCount: Int {
        let since = Date().addingTimeInterval(-7 * 86400)
        return latestPerProject.filter { $0.status == "failed" && $0.updated_at > since && !seenFailed.contains($0.id) }.count
    }
    func markSeen(_ id: Int) {
        guard pipelines.contains(where: { $0.id == id && $0.status == "failed" }), seenFailed.insert(id).inserted else { return }
        let listed = Set(pipelines.map(\.id))
        seenFailed = seenFailed.filter(listed.contains)   // forget pipelines that left the list
        UserDefaults.standard.set(Array(seenFailed), forKey: seenKey)
    }
    /// The newest pipeline of each project.
    var latestPerProject: [GitLabPipeline] {
        var seen = Set<Int>()
        return pipelines.filter { seen.insert($0.project_id).inserted }
    }

    func start() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.connected { await self.refresh() }
                let p = self.client?.pollSeconds ?? (visible: 15, hidden: 60)
                try? await Task.sleep(for: .seconds(self.visiblePanes > 0 ? p.visible : p.hidden))
            }
        }
    }

    func stop() { poller?.cancel(); poller = nil }

    // ponytail: GitLab reads every member project (eight at a time), GitHub the 30 most recently pushed repositories; an events feed if this grows
    func refresh() async {
        guard let client, !refreshing else { return }
        refreshing = true; loading = true
        defer { refreshing = false; loading = false; lastRefresh = Date() }
        do {
            if projects.isEmpty || lastRefresh.map({ Date().timeIntervalSince($0) > 300 }) ?? true {
                let list = try await client.projects()
                projects = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                groupIDs = await client.groupsWithAvatar()
            }
            // Every project: a project's activity date says nothing about its CI, so a running pipeline
            // in a quiet project still shows. A project whose request fails keeps its last pipelines.
            let active = client.pollSet(Array(projects.values), round: round)
            round += 1
            let results = await withTaskGroup(of: (Int, [GitLabPipeline]?, String?).self) { group in
                var started = 0
                var all: [(Int, [GitLabPipeline]?, String?)] = []
                for p in active {
                    if started >= 8, let r = await group.next() { all.append(r) }
                    started += 1
                    group.addTask {
                        do { return (p.id, try await client.pipelines(of: p), nil) }
                        catch { return (p.id, nil, describeError(error)) }
                    }
                }
                for await r in group { all.append(r) }
                return all
            }
            let previous = Dictionary(grouping: pipelines, by: \.project_id)
            let polled = Set(active.map(\.id))
            // Projects not asked this round keep their last pipelines.
            let kept = previous.filter { !polled.contains($0.key) && projects[$0.key] != nil }.flatMap(\.value)
            let fetched = kept + results.flatMap { pid, list, _ in list ?? previous[pid] ?? [] }
            pipelines = fetched.sorted { $0.updated_at > $1.updated_at }
            for id in Set(pipelines.filter(\.isActive).map(\.id)) { jobsCache[id] = nil }   // running jobs change
            let failures = results.compactMap { pid, _, e in e.map { (pid, $0) } }
            error = failures.isEmpty ? nil
                : "\(failures.count) of \(results.count) projects did not answer; their last pipelines stay. \(failures[0].1)"
            Task { await loadAvatars() }
        } catch {
            self.error = describeError(error)
        }
    }

    func jobs(_ p: GitLabPipeline) async throws -> [GitLabJob] {
        if let j = jobsCache[p.id], !p.isActive { return j }
        guard let client else { throw GitLabError(message: "Not connected") }
        let j = try await client.jobs(of: p, in: projects[p.project_id]).sorted { $0.id < $1.id }
        jobsCache[p.id] = j
        return j
    }

    func log(_ job: GitLabJob, project: Int) async throws -> JobLog {
        if let l = logCache[job.id], !GitLabStatus.active.contains(job.status) { return l }
        guard let client else { throw GitLabError(message: "Not connected") }
        let parsed = try await client.log(of: job, in: projects[project])
        logCache[job.id] = parsed
        logOrder.removeAll { $0 == job.id }; logOrder.append(job.id)
        if logOrder.count > 8 { logCache[logOrder.removeFirst()] = nil }   // ponytail: the last 8 logs; a big log is a few MB of lines
        return parsed
    }

    // MARK: Avatars

    /// A project's avatar, else its closest group's that has one.
    func avatar(project id: Int) -> PlatformImage? {
        if let a = avatars["p\(id)"] { return a }
        guard let p = projects[id] else { return nil }
        return groupKey(for: p.namespace.full_path).flatMap { avatars[$0] }
    }
    /// A group's avatar; on GitHub the owner's, which is the repositories' avatar.
    func avatar(group name: String) -> PlatformImage? {
        if let id = groupIDs[name] { return avatars["g\(id)"] }
        // GitHub: the owner's avatar is every one of its repositories' avatar. GitLab: a group without one has none.
        guard connection.provider == .github else { return nil }
        return projects.values.first { $0.group == name }.flatMap { avatars["p\($0.id)"] }
    }

    private func groupKey(for path: String) -> String? {
        var parts = path.split(separator: "/").map(String.init)
        while !parts.isEmpty {
            if let id = groupIDs[parts.joined(separator: "/")] { return "g\(id)" }
            parts.removeLast()
        }
        return nil
    }

    private func loadAvatars() async {
        guard let client else { return }
        for pid in Set(pipelines.map(\.project_id)) {
            guard let p = projects[pid] else { continue }
            if !avatarTried.contains("p\(pid)") {
                avatarTried.insert("p\(pid)")
                if let d = await client.projectAvatar(p), let img = PlatformImage(data: d) { avatars["p\(pid)"] = img }
            }
            for g in [groupKey(for: p.namespace.full_path), groupIDs[p.group].map { "g\($0)" }].compactMap({ $0 }) where !avatarTried.contains(g) {
                avatarTried.insert(g)
                if let id = Int(g.dropFirst()), let d = await client.groupAvatar(id: id), let img = PlatformImage(data: d) { avatars[g] = img }
            }
        }
    }
}

/// Every Pipelines connection: the saved list, one store each, and the sums the title bar shows.
@MainActor @Observable
final class PipelinesHub {
    static let shared = PipelinesHub()
    private let key = "sidra.pipelines.connections"
    private(set) var connections: [PipelineConnection] = []
    private var stores: [UUID: PipelinesStore] = [:]

    private init() {
        connections = (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([PipelineConnection].self, from: $0) } ?? []
        migrateSingleGitLab()
    }

    /// The one GitLab connection of earlier builds (pipelines.url, token under pipelines.token) becomes
    /// the first entry of the list.
    private func migrateSingleGitLab() {
        #if DEBUG
        // -sidra.gitlab URL with SIDRA_GITLAB_TOKEN in the environment (Simulator checks): saves that connection.
        if let u = UserDefaults.standard.string(forKey: "sidra.gitlab"), let t = ProcessInfo.processInfo.environment["SIDRA_GITLAB_TOKEN"], !t.isEmpty {
            try? KeychainStore.set(t, for: "pipelines.token")
            UserDefaults.standard.set(u, forKey: "pipelines.url")
        }
        #endif
        guard let url = UserDefaults.standard.string(forKey: "pipelines.url"), !url.isEmpty,
              let token = KeychainStore.string(for: "pipelines.token"), !token.isEmpty else { return }
        let c = PipelineConnection(provider: .gitlab, url: PipelineConnection.normalize(url)?.absoluteString ?? url)
        guard (try? KeychainStore.set(token, for: c.tokenKey)) != nil else { return }
        if let seen = UserDefaults.standard.array(forKey: "sidra.pipelines.seenFailed") {
            UserDefaults.standard.set(seen, forKey: "sidra.pipelines.seenFailed.\(c.id.uuidString)")
        }
        connections.append(c); save()
        KeychainStore.remove("pipelines.token")
        UserDefaults.standard.removeObject(forKey: "pipelines.url")
        UserDefaults.standard.removeObject(forKey: "sidra.pipelines.seenFailed")
    }

    private func save() {
        if let d = try? JSONEncoder().encode(connections) { UserDefaults.standard.set(d, forKey: key) }
    }

    /// The connection with `id`; nil asks for the first (tabs saved before there were several). A removed
    /// connection is gone: its tabs show none rather than another account's pipelines.
    func connection(_ id: UUID?) -> PipelineConnection? {
        guard let id else { return connections.first }
        return connections.first { $0.id == id }
    }

    /// The store of a connection (the first one for a tab saved before there were several).
    func store(_ id: UUID?) -> PipelinesStore? {
        guard let c = connection(id) else { return nil }
        if let s = stores[c.id] { return s }
        let s = PipelinesStore(connection: c)
        stores[c.id] = s
        s.start()
        if c.account == nil { Task { await fillAccount(c.id) } }   // saved before accounts were kept
        return s
    }
    var all: [PipelinesStore] { connections.compactMap { store($0.id) } }

    /// The connection's current label, from the hub's list: a store's copy predates an account read later.
    func label(for c: PipelineConnection) -> String { (connections.first { $0.id == c.id } ?? c).label }

    var connected: Bool { all.contains(where: \.connected) }
    var runningCount: Int { all.reduce(0) { $0 + $1.running.count } }
    var unseenFailedCount: Int { all.reduce(0) { $0 + $1.unseenFailedCount } }
    var loading: Bool { all.contains(where: \.loading) }

    func start() { _ = all }

    /// Checks the token against the service, then keeps the connection (a new one, or `id` replaced).
    @discardableResult
    func save(id: UUID?, provider: PipelineConnection.Provider, url raw: String, token: String) async throws -> PipelineConnection {
        guard let base = PipelineConnection.normalize(raw) else {
            throw GitLabError(message: raw.lowercased().hasPrefix("http://") ? "Use https://: the token would travel unencrypted." : "That is not a URL.")
        }
        var c = PipelineConnection(provider: provider, url: base.absoluteString, tokenID: UUID())
        if let id { c.id = id }
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client = c.client(token: t) else { throw GitLabError(message: "That is not a URL.") }
        c.account = try await client.verify()
        // The new token goes to its own entry first; the old store keeps reading the old entry, so it never
        // sees the new token, and a failed write leaves the connection as it was.
        try KeychainStore.set(t, for: c.tokenKey)
        let old = connections.first { $0.id == c.id }
        stores[c.id]?.retire(); stores[c.id] = nil
        if let i = connections.firstIndex(where: { $0.id == c.id }) { connections[i] = c } else { connections.append(c) }
        save()
        if let old, old.tokenKey != c.tokenKey { KeychainStore.remove(old.tokenKey) }
        _ = store(c.id)
        return c
    }

    /// Reads the token's username once for a connection saved without one, for its label.
    private func fillAccount(_ id: UUID) async {
        guard let s = stores[id], let client = s.client, let name = try? await client.verify(),
              let i = connections.firstIndex(where: { $0.id == id }), connections[i].account == nil else { return }
        connections[i].account = name
        save()
    }

    func remove(_ id: UUID) {
        guard let c = connections.first(where: { $0.id == id }) else { return }
        KeychainStore.remove(c.tokenKey)
        UserDefaults.standard.removeObject(forKey: "sidra.pipelines.seenFailed.\(id.uuidString)")
        stores[id]?.retire(); stores[id] = nil
        connections.removeAll { $0.id == id }
        save()
    }
}
