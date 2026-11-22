#if DEBUG
import Foundation
#if os(iOS)
import UIKit
#endif
import SidraSSH
import SidraWorkspace
import SidraTerminal
import SidraTheasa

/// `-sidra.demo`: fake data for screenshots and the demo film (Debug builds). In the Simulator it reads
/// this checkout; a device demo build (tools/demo-ipad.sh) is always on and reads
/// the fixtures copied into its bundle.
/// A made-up machine "devbox" answers herdr's commands and opens canned terminal screens; Theasa
/// (https://theasa.demo) and GitLab (https://gitlab.demo) answer from JSON files in this repo.
/// Nothing here reaches a network or a real machine.
enum DemoMode {
    static let isOn = CommandLine.arguments.contains("-sidra.demo") || bundled != nil
    /// Only a device demo build carries the fixtures.
    private static let bundled = Bundle.main.url(forResource: "Demo", withExtension: nil)
    static let hostID = UUID(uuidString: "00000000-0000-0000-0000-0000000de300")!
    static let host = SSHHostProfile(id: hostID, alias: "devbox", host: "devbox.local", user: "dev", auth: .key, startupCommand: "", trustOnFirstUse: false)

    /// The bundle's copy of the fixtures on a device, else the repo from this file's path (the Simulator reads the Mac's files).
    static let repo = bundled
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Before any request: URLSession.shared and Theasa's session answer from the stub.
    static func registerProtocol() {
        guard isOn else { return }
        URLProtocol.registerClass(DemoURLProtocol.self)
        TheasaClient.extraProtocolClasses = [DemoURLProtocol.self]
        UserDefaults.standard.set("https://theasa.demo", forKey: "sidra.theasa")
        UserDefaults.standard.set("demo", forKey: "sidra.theasaToken")
        UserDefaults.standard.set(true, forKey: "sidra.theasaClosed")
        UserDefaults.standard.set("https://gitlab.demo", forKey: "pipelines.url")
        try? KeychainStore.set("demo", for: "pipelines.token")
    }

    /// The demo machine, and the tabs a fresh demo workspace opens with.
    @MainActor static func install(_ app: AppModel) {
        guard isOn else { return }
        if app.hosts.host(hostID) == nil { app.hosts.upsert(host) }
        // -sidra.demoScreenshot: the Send screenshot card opens on one of the site's screenshots (UI tests).
        #if os(iOS)
        if CommandLine.arguments.contains("-sidra.demoScreenshot"),
           let data = try? Data(contentsOf: repo.appendingPathComponent("docs/media/ipad-01-herdr.png")) {
            ScreenshotInbox.shared.pending = UIImage(data: data)
        }
        #endif
        guard app.workspace.tabs.isEmpty else { return }
        app.openTab(kind: .herdr(target: .ssh(hostID: hostID), session: nil))
        app.openTab(kind: .terminal(.ssh(hostID: hostID)))
        app.openTab(kind: .pipelines(connection: nil))
        app.openSingle(.chess)
        if let first = app.workspace.tabs.first { app.workspace.select(tab: first.id) }
    }

    // MARK: herdr on devbox

    /// Which space herdr has focused; the spaces bar switches it.
    nonisolated(unsafe) static var focused = "w1"

    static func run(_ command: String) -> CommandResult {
        func ok(_ s: String) -> CommandResult { CommandResult(stdout: Data(s.utf8), stderr: Data(), exitCode: 0) }
        if command.contains("command -v herdr") { return ok("herdr 0.9.1\n{\"sessions\":[{\"name\":\"default\",\"default\":true,\"running\":true}]}\n\nSNAP\n" + snapshot()) }
        if command.contains("api snapshot") { return ok(snapshot()) }
        if command.contains("workspace focus"), let id = ["w1", "w2", "w3", "w4"].first(where: { command.contains("'\($0)'") }) { focused = id }
        if command.contains("uname") { return ok("Linux\n") }
        // Sidra's project-logo finder: answer with the made-up project's icon.
        if command.contains("base64 <"), let name = ["webapp", "api", "mobile", "docs"].first(where: { command.contains("/home/dev/\($0)") }),
           let png = icon(name) { return ok(png.base64EncodedString()) }
        return ok("")
    }

    static func snapshot() -> String {
        func space(_ id: String, _ label: String, _ n: Int, _ status: String, tabs: Int) -> String {
            #"{"workspace_id":"\#(id)","label":"\#(label)","number":\#(n),"agent_status":"\#(status)","tab_count":\#(tabs),"pane_count":\#(tabs),"focused":\#(id == focused),"active_tab_id":"\#(id):t1"}"#
        }
        func agent(_ name: String, _ status: String, _ ws: String, _ tab: String, _ title: String) -> String {
            #"{"agent":"\#(name)","agent_status":"\#(status)","pane_id":"\#(ws):p\#(tab)","workspace_id":"\#(ws)","tab_id":"\#(ws):t\#(tab)","terminal_title_stripped":"\#(title)","cwd":"/home/dev/\#(ws)"}"#
        }
        let spaces = [space("w1", "webapp", 1, "blocked", tabs: 2), space("w2", "api", 2, "working", tabs: 1),
                      space("w3", "mobile", 3, "working", tabs: 2), space("w4", "docs", 4, "done", tabs: 1)]
        let agents = [agent("claude", "blocked", "w1", "1", "Rate limit login"), agent("codex", "working", "w1", "2", "Fix flaky test"),
                      agent("claude", "working", "w2", "1", "Add /v2/orders"), agent("claude", "working", "w3", "1", "Dark mode"),
                      agent("codex", "idle", "w3", "2", "Release notes"), agent("claude", "done", "w4", "1", "API guide")]
        // A tab per agent, named for its task; t1 is the one up.
        let tabs = [("w1", 1, "Rate limit login", "blocked"), ("w1", 2, "Fix flaky test", "working"), ("w2", 1, "Add /v2/orders", "working"),
                    ("w3", 1, "Dark mode", "working"), ("w3", 2, "Release notes", "idle"), ("w4", 1, "API guide", "done")].map { ws, n, label, status in
            #"{"tab_id":"\#(ws):t\#(n)","workspace_id":"\#(ws)","label":"\#(label)","number":\#(n),"focused":\#(n == 1),"agent_status":"\#(status)"}"#
        }
        let panes = ["w1", "w2", "w3", "w4"].map { #"{"pane_id":"\#($0):p1","workspace_id":"\#($0)","cwd":"/home/dev/\#(["w1": "webapp", "w2": "api", "w3": "mobile", "w4": "docs"][$0]!)"}"# }
        return #"{"id":"cli:api:snapshot","result":{"snapshot":{"version":"0.9.1","protocol":22,"focused_workspace_id":"\#(focused)","focused_pane_id":"\#(focused):p1","focused_tab_id":"\#(focused):t1","workspaces":[\#(spaces.joined(separator: ","))],"agents":[\#(agents.joined(separator: ","))],"panes":[\#(panes.joined(separator: ","))],"tabs":[\#(tabs.joined(separator: ","))],"layouts":[]}}}"#
    }

    /// The made-up projects' icons, from tools/dev/demo-icons in this checkout.
    static func icon(_ name: String) -> Data? { try? Data(contentsOf: repo.appendingPathComponent("tools/dev/demo-icons/\(name).png")) }

    // MARK: Terminal screens

    static func session(herdr: Bool) -> DemoSession { DemoSession(screen: herdr ? agentScreen : shellScreen) }

    private static let esc = "\u{1b}["
    private static func c(_ code: String, _ s: String) -> String { "\(esc)\(code)m\(s)\(esc)0m" }

    static let agentScreen: String = {
        let dim = "2", bold = "1", orange = "38;5;209", green = "38;5;114", red = "38;5;203", blue = "38;5;111"
        return [
            c(dim, "~/webapp") + "  " + c(blue, "main"),
            "",
            c(bold, "> ") + "Add rate limiting to the login endpoint. 5 tries a minute per IP.",
            "",
            c(orange, "● ") + "I'll add a limiter in front of " + c(bold, "POST /login") + " and test it.",
            "",
            c(orange, "● ") + c(bold, "Read") + c(dim, "(src/auth/login.ts)"),
            c(dim, "  ⎿  Read 84 lines"),
            c(orange, "● ") + c(bold, "Update") + c(dim, "(src/auth/login.ts)"),
            c(dim, "  ⎿  Updated src/auth/login.ts with 9 additions"),
            c(dim, "     12  ") + "import { Router } from \"express\";",
            c(green, "     13 +import { limit } from \"./limit\";"),
            c(dim, "     14  "),
            c(red, "     15 -router.post(\"/login\", login);"),
            c(green, "     15 +router.post(\"/login\", limit(5), login);"),
            "",
            c(orange, "● ") + c(bold, "Bash") + c(dim, "(npm test -- auth)"),
            c(dim, "  ⎿  ") + c(green, "PASS") + " test/auth/login.test.ts (14 tests)",
            c(orange, "● ") + c(bold, "Read") + c(dim, "(login.png)"),
            c(dim, "  ⎿  ") + "/home/dev/webapp/login.png",
            "",
            "",
            "",
            "╭────────────────────────────────────────────╮",
            "│ " + c(bold, "Run database migration?") + "                    │",
            "│                                            │",
            "│  npx prisma migrate dev                    │",
            "│                                            │",
            "│ " + c(blue, "❯ 1. Yes") + "                                   │",
            "│   2. Yes, don't ask again for prisma       │",
            "│   3. No, tell Claude what to do instead    │",
            "╰────────────────────────────────────────────╯",
        ].joined(separator: "\r\n")
    }()

    static let shellScreen: String = {
        let green = "32", blue = "34", yellow = "33", dim = "2"
        let prompt = c(green, "dev@devbox") + ":" + c(blue, "~/webapp") + "$ "
        return [
            prompt + "git log --oneline -5",
            c(yellow, "a41c2e9") + " Rate limit the login endpoint",
            c(yellow, "9be0f13") + " Orders API: cursor pagination",
            c(yellow, "1d7aa02") + " Dark mode for settings",
            c(yellow, "77c3b18") + " Fix flaky checkout test",
            c(yellow, "e02d5c4") + " Release 2.4.0",
            prompt + "docker compose ps",
            "NAME      STATUS       PORTS",
            "web-1     " + c(green, "Up 3 hours") + "   3000/tcp",
            "db-1      " + c(green, "Up 3 hours") + "   5432/tcp",
            "redis-1   " + c(green, "Up 3 hours") + "   6379/tcp",
            prompt + "uptime",
            c(dim, " 09:41  up 12 days,  load: 0.42 0.37 0.31"),
            prompt,
        ].joined(separator: "\r\n")
    }()
}

/// A terminal session that prints one screen and then echoes what is typed.
final class DemoSession: PaneSession, @unchecked Sendable {
    let output: AsyncStream<Data>
    let exit: AsyncStream<Int?>
    var endReason: String? { nil }
    private let out: AsyncStream<Data>.Continuation

    init(screen: String) {
        (output, out) = AsyncStream.makeStream()
        (exit, _) = AsyncStream.makeStream()
        out.yield(Data(("\u{1b}[2J\u{1b}[H" + screen).utf8))
    }

    func write(_ data: Data) { out.yield(data.map { $0 == 13 ? Data("\r\n".utf8) : Data([$0]) }.reduce(Data(), +)) }
    func resize(cols: Int, rows: Int) {}
    func close() { out.finish() }
}

/// Answers https://theasa.demo from the Theasa fixtures and https://gitlab.demo from canned GitLab JSON.
final class DemoURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { ["theasa.demo", "gitlab.demo"].contains(request.url?.host ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let (status, type, body) = url.host == "theasa.demo" ? Self.theasa(url.path) : Self.gitlab(url.path)
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if url.path == "/api/events" { client?.urlProtocol(self, didLoad: Data("data: hello\n\n".utf8)); return }   // one event, then open and quiet
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func fixture(_ name: String) -> Data {
        (try? Data(contentsOf: DemoMode.repo.appendingPathComponent("Packages/SidraTheasa/Tests/SidraTheasaTests/Fixtures/\(name).json"))) ?? Data("{}".utf8)
    }

    static func theasa(_ path: String) -> (Int, String, Data) {
        let json = "application/json"
        switch path {
        case "/health": return (200, json, fixture("health"))
        case "/api/events": return (200, "text/event-stream", Data())
        case "/api/pulse": return (200, json, fixture("pulse"))
        case "/api/agents": return (200, json, fixture("agents"))
        case "/api/projects": return (200, json, fixture("projects"))
        case "/api/search": return (200, json, fixture("search"))
        default:
            if path.hasPrefix("/api/projects/"), !path.hasSuffix("/icon") { return (200, json, fixture("project")) }
            if path.hasPrefix("/api/turns/") { return (200, json, fixture("turn-diff")) }
            return (404, json, Data("{}".utf8))
        }
    }

    // MARK: GitLab

    private static let projects: [(id: Int, name: String, group: String)] = [(11, "webapp", "acme"), (12, "api", "acme"), (13, "mobile", "acme"), (14, "docs", "acme")]
    private static let pipelines: [(id: Int, project: Int, ref: String, status: String, minutesAgo: Int)] = [
        (9104, 11, "main", "running", 1), (9103, 12, "feature/orders-v2", "failed", 6), (9102, 13, "main", "success", 14),
        (9101, 14, "main", "success", 38), (9100, 11, "rate-limit-login", "success", 52), (9099, 12, "main", "success", 75),
    ]

    private static func iso(_ minutesAgo: Int) -> String { ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double(-minutesAgo * 60))) }

    static func gitlab(_ path: String) -> (Int, String, Data) {
        let json = "application/json"
        let parts = path.replacingOccurrences(of: "/api/v4", with: "").split(separator: "/").map(String.init)
        func data(_ s: String) -> (Int, String, Data) { (200, json, Data(s.utf8)) }
        switch parts.first {
        case "user": return data(#"{"username":"dev"}"#)
        case "groups": return data("[]")
        case "projects" where parts.count == 1:
            return data("[" + projects.map { #"{"id":\#($0.id),"name":"\#($0.name)","path_with_namespace":"\#($0.group)/\#($0.name)","web_url":"https://gitlab.demo/\#($0.group)/\#($0.name)","avatar_url":"https://gitlab.demo/a/\#($0.name).png","namespace":{"id":1,"kind":"group","full_path":"\#($0.group)"},"last_activity_at":"\#(iso(5))"}"# }.joined(separator: ",") + "]")
        case "projects" where parts.count == 3 && parts[2] == "pipelines":
            let pid = Int(parts[1]) ?? 0
            return data("[" + pipelines.filter { $0.project == pid }.map { p in
                #"{"id":\#(p.id),"project_id":\#(p.project),"ref":"\#(p.ref)","status":"\#(p.status)","sha":"\#(String(format: "%08x", p.id * 7919))c0ffee","web_url":"https://gitlab.demo/p/\#(p.id)","created_at":"\#(iso(p.minutesAgo + 4))","updated_at":"\#(iso(p.minutesAgo))"}"#
            }.joined(separator: ",") + "]")
        case "projects" where parts.count == 5 && parts[4] == "jobs":
            let pl = pipelines.first { "\($0.id)" == parts[3] }
            let failed = pl?.status == "failed", running = pl?.status == "running"
            let jobs: [(String, String, String)] = [("lint", "test", "success"), ("unit", "test", failed ? "failed" : "success"),
                                                    ("e2e", "test", running ? "running" : "success"), ("build", "build", running || failed ? "created" : "success"),
                                                    ("deploy", "deploy", running || failed ? "created" : "success")]
            return data("[" + jobs.enumerated().map { i, j in
                #"{"id":\#((Int(parts[3]) ?? 0) * 10 + i),"name":"\#(j.0)","stage":"\#(j.1)","status":"\#(j.2)","duration":\#(40 + i * 23),"failure_reason":\#(j.2 == "failed" ? "\"script_failure\"" : "null"),"web_url":"https://gitlab.demo/j"}"#
            }.joined(separator: ",") + "]")
        case "projects" where parts.count == 3 && parts[2] == "avatar":
            let name = projects.first { "\($0.id)" == parts[1] }?.name ?? ""
            return DemoMode.icon(name).map { (200, "image/png", $0) } ?? (404, json, Data())
        case "projects" where parts.last == "trace":
            return (200, "text/plain", Data(trace.utf8))
        default: return (404, json, Data("{}".utf8))
        }
    }

    private static let trace = """
    \u{1b}[0Ksection_start:1731790000:step_script\r\u{1b}[0K\u{1b}[0K\u{1b}[36;1mExecuting "step_script" stage of the job script\u{1b}[0;m
    $ npm ci
    added 812 packages in 21s
    $ npm test -- orders
    PASS test/orders/list.test.ts
    FAIL test/orders/cursor.test.ts
      ● cursor pagination › returns the next page after the last id

        expect(received).toEqual(expected)

        Expected: "ord_1043"
        Received: undefined

          41 |     const page = await list({ after: "ord_1042", limit: 1 });
        > 42 |     expect(page.items[0]?.id).toEqual("ord_1043");
             |                               ^

    Tests:       1 failed, 37 passed, 38 total
    \u{1b}[0Ksection_end:1731790031:step_script\r\u{1b}[0K
    \u{1b}[31;1mERROR: Job failed: exit code 1\u{1b}[0;m
    """
}
#endif
