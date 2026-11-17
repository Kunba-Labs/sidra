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

/// The GitLab connection (URL in defaults, token in the Keychain), recent pipelines of the user's
/// projects, and avatars. Polls every 15 s while a Pipelines pane is on screen, every 60 s otherwise
/// (the title bar's working pill counts running pipelines).
@MainActor @Observable
final class PipelinesStore {
    static let shared = PipelinesStore()
    private let urlKey = "pipelines.url", tokenKey = "pipelines.token"

    private(set) var url: String = UserDefaults.standard.string(forKey: "pipelines.url") ?? ""
    private(set) var projects: [Int: GitLabProject] = [:]
    private(set) var pipelines: [GitLabPipeline] = []
    private(set) var error: String?
    private(set) var loading = false
    private var loadingGeneration: Int?
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

    var host: String? { client.flatMap { $0.base.host } }
    var client: GitLabClient? {
        guard let base = GitLabClient.normalize(url), let token = KeychainStore.string(for: tokenKey), !token.isEmpty else { return nil }
        return GitLabClient(base: base, token: token)
    }
    var connected: Bool { client != nil }
    var running: [GitLabPipeline] { pipelines.filter(\.isActive) }
    /// Projects whose newest pipeline failed in the last 7 days; an old failure nobody touched is no news.
    var failedCount: Int {
        let since = Date().addingTimeInterval(-7 * 86400)
        return latestPerProject.filter { $0.status == "failed" && $0.updated_at > since }.count
    }
    /// Failed pipelines you opened: the title bar's red dot leaves them out until a new one fails (2026-11-14).
    private(set) var seenFailed = Set(UserDefaults.standard.array(forKey: "sidra.pipelines.seenFailed") as? [Int] ?? [])
    var unseenFailedCount: Int {
        let since = Date().addingTimeInterval(-7 * 86400)
        return latestPerProject.filter { $0.status == "failed" && $0.updated_at > since && !seenFailed.contains($0.id) }.count
    }
    func markSeen(_ id: Int) {
        guard pipelines.contains(where: { $0.id == id && $0.status == "failed" }), seenFailed.insert(id).inserted else { return }
        let listed = Set(pipelines.map(\.id))
        seenFailed = seenFailed.filter(listed.contains)   // forget pipelines that left the list
        UserDefaults.standard.set(Array(seenFailed), forKey: "sidra.pipelines.seenFailed")
    }
    /// The newest pipeline of each project.
    var latestPerProject: [GitLabPipeline] {
        var seen = Set<Int>()
        return pipelines.filter { seen.insert($0.project_id).inserted }
    }

    func save(url raw: String, token: String) async throws {
        guard let base = GitLabClient.normalize(raw) else {
            throw GitLabError(message: raw.lowercased().hasPrefix("http://") ? "Use https://: the token would travel unencrypted." : "That is not a URL.")
        }
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = GitLabClient(base: base, token: t)
        // /version answers without a token; /user needs a valid one.
        struct User: Decodable { let username: String }
        _ = try await probe.get("/user") as User
        try KeychainStore.set(t, for: tokenKey)
        url = base.absoluteString
        UserDefaults.standard.set(url, forKey: urlKey)
        reset()
        await refresh()
    }

    func disconnect() {
        KeychainStore.remove(tokenKey)
        url = ""
        UserDefaults.standard.removeObject(forKey: urlKey)
        reset()
    }

    /// Bumped whenever the connection changes; a refresh that started under an older one drops its results.
    private var generation = 0

    private func reset() {
        generation += 1
        projects = [:]; pipelines = []; avatars = [:]; avatarTried = []; groupIDs = [:]; jobsCache = [:]; error = nil
        logCache = [:]; logOrder = []; selectedJob = [:]; selected = nil; expanded = []
    }

    func start() {
        guard poller == nil else { return }
        #if DEBUG
        // -sidra.gitlab URL with SIDRA_GITLAB_TOKEN in the environment (Simulator checks): saves that connection.
        if let u = UserDefaults.standard.string(forKey: "sidra.gitlab"), let t = ProcessInfo.processInfo.environment["SIDRA_GITLAB_TOKEN"], !t.isEmpty {
            try? KeychainStore.set(t, for: tokenKey)
            url = GitLabClient.normalize(u)?.absoluteString ?? u
            UserDefaults.standard.set(url, forKey: urlKey)
        }
        #endif
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.connected { await self.refresh() }
                try? await Task.sleep(for: .seconds(self.visiblePanes > 0 ? 15 : 60))
            }
        }
    }

    // ponytail: projects active in the last 30 days, at most 40, three pipelines each (the TUI's shape); a GitLab events feed if this grows
    func refresh() async {
        // One refresh per connection: one still running for an old connection does not block the new one.
        guard let client, loadingGeneration != generation else { return }
        let gen = generation
        loadingGeneration = gen
        loading = true
        defer { if loadingGeneration == gen { loadingGeneration = nil; loading = false }; if gen == generation { lastRefresh = Date() } }
        do {
            if projects.isEmpty || lastRefresh.map({ Date().timeIntervalSince($0) > 300 }) ?? true {
                let list: [GitLabProject] = try await client.all("/projects", ["membership": "true", "simple": "true", "order_by": "last_activity_at"])
                guard gen == generation else { return }
                projects = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                struct Group: Decodable { let id: Int; let full_path: String; let avatar_url: String? }
                if let groups: [Group] = try? await client.all("/groups"), gen == generation {
                    groupIDs = Dictionary(groups.filter { $0.avatar_url != nil }.map { ($0.full_path, $0.id) }, uniquingKeysWith: { a, _ in a })
                }
            }
            // Every project, eight requests at a time: a project's activity date says nothing about its CI,
            // so a running pipeline in a quiet project still shows.
            // ponytail: one request per project per refresh; GitLab's events or a per-group pipelines API if accounts grow past a few hundred projects
            let active = Array(projects.values)
            // A project whose request fails keeps its last pipelines; the failures are reported, not hidden.
            let results = await withTaskGroup(of: (Int, [GitLabPipeline]?, String?).self) { group in
                var started = 0
                var all: [(Int, [GitLabPipeline]?, String?)] = []
                for p in active {
                    if started >= 8, let r = await group.next() { all.append(r) }
                    started += 1
                    group.addTask {
                        do { return (p.id, try await client.get("/projects/\(p.id)/pipelines", ["per_page": "3", "order_by": "updated_at", "sort": "desc"]), nil) }
                        catch { return (p.id, nil, describeError(error)) }
                    }
                }
                for await r in group { all.append(r) }
                return all
            }
            guard gen == generation else { return }   // disconnected or reconnected meanwhile
            let previous = Dictionary(grouping: pipelines, by: \.project_id)
            let fetched = results.flatMap { pid, list, _ in list ?? previous[pid] ?? [] }
            pipelines = fetched.sorted { $0.updated_at > $1.updated_at }
            for id in Set(pipelines.filter(\.isActive).map(\.id)) { jobsCache[id] = nil }   // running jobs change
            let failures = results.compactMap { pid, _, e in e.map { (pid, $0) } }
            error = failures.isEmpty ? nil
                : "\(failures.count) of \(results.count) projects did not answer; their last pipelines stay. \(failures[0].1)"
            Task { await loadAvatars() }
        } catch {
            if gen == generation { self.error = describeError(error) }
        }
    }

    func jobs(_ p: GitLabPipeline) async throws -> [GitLabJob] {
        if let j = jobsCache[p.id], !p.isActive { return j }
        guard let client else { throw GitLabError(message: "Not connected") }
        let gen = generation
        let j: [GitLabJob] = try await client.get("/projects/\(p.project_id)/pipelines/\(p.id)/jobs", ["per_page": "100", "include_retried": "false"])
        let sorted = j.sorted { $0.id < $1.id }
        guard gen == generation else { throw GitLabError(message: "The GitLab connection changed.") }
        jobsCache[p.id] = sorted
        return sorted
    }

    func log(_ job: GitLabJob, project: Int) async throws -> JobLog {
        if let l = logCache[job.id], !GitLabStatus.active.contains(job.status) { return l }
        guard let client else { throw GitLabError(message: "Not connected") }
        let gen = generation
        let raw = String(decoding: try await client.data("/projects/\(project)/jobs/\(job.id)/trace"), as: UTF8.self)
        let parsed = await Task.detached { JobLog.parse(raw) }.value
        guard gen == generation else { throw GitLabError(message: "The GitLab connection changed.") }
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
    func avatar(group name: String) -> PlatformImage? { groupIDs[name].flatMap { avatars["g\($0)"] } }

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
        let gen = generation
        var wanted: [(String, String)] = []   // key, API path
        for pid in Set(pipelines.map(\.project_id)) {
            guard let p = projects[pid] else { continue }
            if p.avatar_url != nil { wanted.append(("p\(pid)", "/projects/\(pid)/avatar")) }
            if let g = groupKey(for: p.namespace.full_path) { wanted.append((g, "/groups/\(g.dropFirst())/avatar")) }
            if let id = groupIDs[p.group] { wanted.append(("g\(id)", "/groups/\(id)/avatar")) }
        }
        for (key, path) in wanted where !avatarTried.contains(key) {
            avatarTried.insert(key)
            if let d = try? await client.data(path), let img = PlatformImage(data: d), gen == generation { avatars[key] = img }
        }
    }
}
