import Foundation
import SidraSSH

// MARK: - Connections

/// One CI service Sidra reads: GitLab or GitHub, hosted or self-hosted. Its token is in the Keychain
/// under `tokenKey`; the list itself in UserDefaults. A Pipelines tab shows one connection.
struct PipelineConnection: Codable, Identifiable, Hashable, Sendable {
    enum Provider: String, Codable, CaseIterable, Sendable {
        case gitlab, github
        var name: String { self == .gitlab ? "GitLab" : "GitHub" }
        /// The public service; anything else is self-hosted.
        var hostedURL: String { self == .gitlab ? "https://gitlab.com" : "https://github.com" }
    }
    var id = UUID()
    var provider: Provider
    /// The web address: https://gitlab.com, https://github.com, or a self-hosted server.
    var url: String
    /// Which Keychain entry holds the token: a new token gets a new entry, so the old one stays intact
    /// until the new one is saved. Nil: the entry named after `id`.
    var tokenID: UUID?

    var tokenKey: String { "pipelines.token.\((tokenID ?? id).uuidString)" }
    var host: String { URL(string: url)?.host ?? url }
    var isHosted: Bool { URL(string: url)?.host == URL(string: provider.hostedURL)?.host }
    /// "GitHub", "GitLab", or the self-hosted server's host.
    var title: String { isHosted ? provider.name : host }

    /// https://host[/path] with no trailing slash, https only (every request carries the token); nil if not a URL.
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        for suffix in ["/api/v4", "/api/v3"] where s.hasSuffix(suffix) { s.removeLast(suffix.count) }
        guard let url = URL(string: s), url.host != nil, url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    /// The API client for this connection with `token`.
    func client(token: String) -> (any CIClient)? {
        guard let base = Self.normalize(url) else { return nil }
        switch provider {
        case .gitlab: return GitLabClient(base: base, token: token)
        case .github: return GitHubClient(web: base, token: token)
        }
    }
}

/// What a Pipelines tab needs from a CI service, in GitLab's shapes (the pane was built on them):
/// projects, their recent pipelines, a pipeline's jobs, a job's log, avatars.
protocol CIClient: Sendable {
    var token: String { get }
    var provider: PipelineConnection.Provider { get }
    /// Throws when the token is not accepted.
    func verify() async throws
    func projects() async throws -> [GitLabProject]
    /// full_path → id of groups that have an avatar (GitLab); empty elsewhere.
    func groupsWithAvatar() async -> [String: Int]
    func pipelines(of project: GitLabProject) async throws -> [GitLabPipeline]
    func jobs(of pipeline: GitLabPipeline, in project: GitLabProject?) async throws -> [GitLabJob]
    func log(of job: GitLabJob, in project: GitLabProject?) async throws -> JobLog
    func projectAvatar(_ project: GitLabProject) async -> Data?
    func groupAvatar(id: Int) async -> Data?
    /// Seconds between refreshes while a tab is on screen, and while none is.
    var pollSeconds: (visible: Double, hidden: Double) { get }
    /// The projects to ask for pipelines this refresh (`round` counts refreshes); the rest keep their last.
    func pollSet(_ projects: [GitLabProject], round: Int) -> [GitLabProject]
}

extension CIClient {
    func pollSet(_ projects: [GitLabProject], round: Int) -> [GitLabProject] { projects }
}

// MARK: - GitLab

extension GitLabClient: CIClient {
    var provider: PipelineConnection.Provider { .gitlab }
    var pollSeconds: (visible: Double, hidden: Double) { (15, 60) }

    func verify() async throws {
        struct User: Decodable { let username: String }
        _ = try await get("/user") as User
    }
    func projects() async throws -> [GitLabProject] {
        try await all("/projects", ["membership": "true", "simple": "true", "order_by": "last_activity_at"])
    }
    func groupsWithAvatar() async -> [String: Int] {
        struct Group: Decodable { let id: Int; let full_path: String; let avatar_url: String? }
        guard let groups: [Group] = try? await all("/groups") else { return [:] }
        return Dictionary(groups.filter { $0.avatar_url != nil }.map { ($0.full_path, $0.id) }, uniquingKeysWith: { a, _ in a })
    }
    func pipelines(of project: GitLabProject) async throws -> [GitLabPipeline] {
        try await get("/projects/\(project.id)/pipelines", ["per_page": "3", "order_by": "updated_at", "sort": "desc"])
    }
    func jobs(of pipeline: GitLabPipeline, in project: GitLabProject?) async throws -> [GitLabJob] {
        try await get("/projects/\(pipeline.project_id)/pipelines/\(pipeline.id)/jobs", ["per_page": "100", "include_retried": "false"])
    }
    func log(of job: GitLabJob, in project: GitLabProject?) async throws -> JobLog {
        guard let pid = project?.id else { throw GitLabError(message: "The project of this job is not known.") }
        let raw = String(decoding: try await data("/projects/\(pid)/jobs/\(job.id)/trace"), as: UTF8.self)
        return await Task.detached { JobLog.parse(raw) }.value
    }
    func projectAvatar(_ project: GitLabProject) async -> Data? {
        project.avatar_url == nil ? nil : try? await data("/projects/\(project.id)/avatar")
    }
    func groupAvatar(id: Int) async -> Data? { try? await data("/groups/\(id)/avatar") }
}

// MARK: - GitHub

/// GitHub Actions through the REST API, on github.com or GitHub Enterprise Server (`<host>/api/v3`).
/// A repository is a project, a workflow run a pipeline, its jobs the jobs (one stage per workflow).
struct GitHubClient: CIClient {
    let web: URL
    let token: String
    var provider: PipelineConnection.Provider { .github }
    /// 50 repositories a refresh, every 2 minutes (5 with no tab on screen): under GitHub's 5,000 an hour.
    var pollSeconds: (visible: Double, hidden: Double) { (120, 300) }
    static let repoLimit = 300
    static let recent = 30, rotating = 20

    /// The 30 most recently pushed every time, and 20 of the others in turn: a scheduled workflow in a
    /// repository nobody pushes to still shows, within a few rounds.
    func pollSet(_ projects: [GitLabProject], round: Int) -> [GitLabProject] {
        let sorted = projects.sorted { ($0.last_activity_at ?? .distantPast) > ($1.last_activity_at ?? .distantPast) }
        let head = Array(sorted.prefix(Self.recent)), rest = Array(sorted.dropFirst(Self.recent))
        guard !rest.isEmpty else { return head }
        let start = (round * Self.rotating) % rest.count
        return head + (0..<min(Self.rotating, rest.count)).map { rest[(start + $0) % rest.count] }
    }

    var api: URL {
        web.host == "github.com" ? URL(string: "https://api.github.com")! : web.appendingPathComponent("api/v3")
    }

    func request(_ path: String, _ query: [String: String] = [:], absolute: URL? = nil) async throws -> Data {
        var c = URLComponents(url: absolute ?? api.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: c.url!, timeoutInterval: 20)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300: return data
        case 401: throw GitLabError(message: "GitHub refused the token (401). It must not be expired.")
        case 403, 429: throw GitLabError(message: "GitHub said no (\(code)): the token may lack Actions read access, or the hourly request limit is used up.")
        case 404: throw GitLabError(message: "GitHub has no \(path) for this token (404).")
        default: throw GitLabError(message: "GitHub answered \(code).")
        }
    }

    func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        try GitLabClient.decoder.decode(T.self, from: try await request(path, query))
    }

    func verify() async throws {
        struct User: Decodable { let login: String }
        _ = try await get("/user") as User
    }

    private struct Repo: Decodable {
        struct Owner: Decodable { let id: Int; let login: String; let type: String; let avatar_url: String? }
        let id: Int; let name: String; let full_name: String; let html_url: String
        let owner: Owner; let pushed_at: Date?; let archived: Bool?
    }

    /// Every repository the token can see (all pages), archived ones skipped, most recently pushed
    /// first, at most 300.
    func projects() async throws -> [GitLabProject] {
        var repos: [Repo] = []
        for page in 1...20 {
            let batch: [Repo] = try await get("/user/repos", ["sort": "pushed", "per_page": "100", "page": "\(page)",
                                                              "affiliation": "owner,collaborator,organization_member"])
            repos += batch
            if batch.count < 100 { break }
        }
        return repos.filter { $0.archived != true }.prefix(Self.repoLimit).map { r in
            GitLabProject(id: r.id, name: r.name, path_with_namespace: r.full_name, web_url: r.html_url,
                          avatar_url: r.owner.avatar_url,
                          namespace: .init(id: r.owner.id, kind: r.owner.type.lowercased(), full_path: r.owner.login),
                          last_activity_at: r.pushed_at)
        }
    }

    func groupsWithAvatar() async -> [String: Int] { [:] }   // an owner's avatar is the repository's

    private struct Runs: Decodable { let workflow_runs: [Run] }
    private struct Run: Decodable {
        let id: Int; let name: String?; let head_branch: String?; let head_sha: String
        let status: String?; let conclusion: String?; let html_url: String
        let created_at: Date; let updated_at: Date
    }

    func pipelines(of project: GitLabProject) async throws -> [GitLabPipeline] {
        let runs: Runs = try await get("/repos/\(project.path_with_namespace)/actions/runs", ["per_page": "3"])
        return runs.workflow_runs.map { r in
            GitLabPipeline(id: r.id, project_id: project.id, ref: r.head_branch ?? "", status: Self.status(r.status, r.conclusion),
                           sha: r.head_sha, web_url: r.html_url, created_at: r.created_at, updated_at: r.updated_at)
        }
    }

    private struct Jobs: Decodable { let jobs: [Job] }
    private struct Job: Decodable {
        let id: Int; let name: String; let status: String?; let conclusion: String?
        let started_at: Date?; let completed_at: Date?; let html_url: String?; let workflow_name: String?
    }

    func jobs(of pipeline: GitLabPipeline, in project: GitLabProject?) async throws -> [GitLabJob] {
        guard let repo = project?.path_with_namespace else { throw GitLabError(message: "The repository of this run is not known.") }
        let j: Jobs = try await get("/repos/\(repo)/actions/runs/\(pipeline.id)/jobs", ["per_page": "100", "filter": "latest"])
        return j.jobs.map { job in
            let duration = job.started_at.flatMap { s in (job.completed_at ?? Date()).timeIntervalSince(s) }
            return GitLabJob(id: job.id, name: job.name, stage: job.workflow_name ?? "jobs", status: Self.status(job.status, job.conclusion),
                             duration: duration, failure_reason: nil, web_url: job.html_url ?? pipeline.web_url)
        }
    }

    /// GitHub answers with a redirect to the plain-text log; URLSession follows it and drops the token
    /// for the other host, which the signed link does not need.
    func log(of job: GitLabJob, in project: GitLabProject?) async throws -> JobLog {
        guard let repo = project?.path_with_namespace else { throw GitLabError(message: "The repository of this job is not known.") }
        let raw = String(decoding: try await request("/repos/\(repo)/actions/jobs/\(job.id)/logs"), as: UTF8.self)
        return await Task.detached { JobLog.parseGitHub(raw) }.value
    }

    func projectAvatar(_ project: GitLabProject) async -> Data? {
        guard let s = project.avatar_url, let u = URL(string: s), u.scheme == "https" else { return nil }
        // The token goes only to the configured server (Enterprise avatars sit behind it); elsewhere, no credentials.
        if u.host == web.host { return try? await request("", absolute: u) }
        return try? await URLSession.shared.data(from: u).0
    }
    func groupAvatar(id: Int) async -> Data? { nil }

    /// GitHub's status and conclusion as the GitLab status words the pane draws.
    static func status(_ status: String?, _ conclusion: String?) -> String {
        switch status {
        case "in_progress": return "running"
        case "queued", "waiting", "requested", "pending": return "pending"
        default: break
        }
        switch conclusion {
        case "success": return "success"
        case "failure", "timed_out", "startup_failure": return "failed"
        case "cancelled": return "canceled"
        case "skipped", "neutral", "stale": return "skipped"
        case "action_required": return "manual"
        default: return status ?? "created"
        }
    }
}

extension JobLog {
    /// A GitHub Actions log: `<ISO time> text` lines, `##[group]Title` … `##[endgroup]` sections,
    /// `##[error]` lines marked as errors.
    static func parseGitHub(_ raw: String) -> JobLog {
        let stamp = try! NSRegularExpression(pattern: #"^\d{4}-\d\d-\d\dT[0-9:.]+Z ?"#)
        var sections = [Section(id: 0, name: "", title: "")]
        var current = 0, n = 0
        var open: [Int] = []   // nested ##[group]s; closing one resumes its parent
        for var line in raw.components(separatedBy: "\n") {
            line = line.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\u{FEFF}", with: "")
            let ns = line as NSString
            if let m = stamp.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) { line = ns.substring(from: m.range.length) }
            line = ansi.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "")
            if line.hasPrefix("##[group]") {
                if current != 0 || !open.isEmpty { open.append(current) }
                sections.append(Section(id: sections.count, name: "group\(sections.count)", title: String(line.dropFirst(9))))
                current = sections.count - 1
                continue
            }
            if line.hasPrefix("##[endgroup]") {
                if let parent = open.popLast(), !sections[parent].name.isEmpty {
                    current = parent   // back into the enclosing group
                } else {
                    sections.append(Section(id: sections.count, name: "", title: ""))
                    current = sections.count - 1
                }
                continue
            }
            var error = false
            if line.hasPrefix("##[error]") { line = String(line.dropFirst(9)); error = true }
            else if line.hasPrefix("##[") { line = String(line.drop { $0 != "]" }.dropFirst()) }   // warning, notice, debug
            n += 1
            sections[current].lines.append(Line(id: n, text: line, isError: error || isError(line)))
        }
        return JobLog(sections: sections.filter { !$0.lines.isEmpty || !$0.name.isEmpty })
    }
}
