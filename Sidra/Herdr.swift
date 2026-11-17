import Foundation
import SwiftUI
import SidraDesign
import SidraWorkspace
import SidraSSH

/// A terminal multiplexer on another machine (herdr today; rex and others later). The pane runs the
/// multiplexer's own client for the terminal, with its own space list hidden; Sidra draws spaces and
/// agents natively from the snapshot and switches them through the multiplexer's CLI. Every command
/// runs in a shell on that machine, over a second SSH channel.
protocol MultiplexerAdapter: Sendable {
    var name: String { get }
    /// Typed into the pane's login shell; `exec` it, so a detach ends the pane, which then offers Reconnect.
    func attachCommand(session: String?) -> String
    /// Runs over the second channel before the client attaches (herdr writes its attach script); nil when none.
    func prepareCommand() -> String?
    func snapshotCommand(session: String?) -> String
    func parseSnapshot(_ data: Data) throws -> MuxSnapshot
    func focusSpaceCommand(session: String?, space: String) -> String
    func focusAgentCommand(session: String?, pane: String) -> String
    func focusTabCommand(session: String?, tab: String) -> String
    func newTabCommand(session: String?, space: String) -> String
    /// A new space (herdr workspace) named `label` working in `folder`. Prints JSON with `.result.root_pane.pane_id`.
    func newSpaceCommand(session: String?, label: String, folder: String) -> String
    /// Types `command` into `pane`'s shell and runs it.
    func runInPaneCommand(session: String?, pane: String, command: String) -> String
    /// Moves a pane into a new space of its own.
    func movePaneToNewSpaceCommand(session: String?, pane: String, label: String) -> String
    /// Moves a pane into `tab`, or into a new tab of `space` when `tab` is nil.
    func movePaneCommand(session: String?, pane: String, tab: String?, space: String) -> String
    /// Splits `pane` in two, the new half to its right or below it, and focuses the new half.
    func splitPaneCommand(session: String?, pane: String, down: Bool) -> String
    /// Moves a space to `index` in the multiplexer's own order; nil when it cannot.
    func moveSpaceCommand(session: String?, space: String, index: Int) -> String?
    /// Types `text` into each agent and submits it; prints "FAILED <pane>" for each one that refused.
    func promptAgentsCommand(session: String?, panes: [String], text: String) -> String
    /// Footer hints for the client's own keys.
    var keyHints: [(key: String, label: String)] { get }
}

extension PaneKind {
    /// The adapter, machine and session behind a multiplexer pane.
    var multiplexer: (adapter: any MultiplexerAdapter, target: TerminalTarget, session: String?)? {
        if case .herdr(let target, let session) = self { return (HerdrAdapter(), target, session) }
        return nil
    }
}

struct HerdrAdapter: MultiplexerAdapter {
    var name: String { "herdr" }

    func attachCommand(session: String?) -> String {
        "exec sh " + Herdr.scriptPath + (session.flatMap { $0.isEmpty || $0 == "default" ? nil : " " + Herdr.shellQuote($0) } ?? "")
    }
    func prepareCommand() -> String? { Herdr.installScript }


    func snapshotCommand(session: String?) -> String { "herdr" + Herdr.sessionArg(session) + " api snapshot" }
    func parseSnapshot(_ data: Data) throws -> MuxSnapshot { try MuxSnapshot.parse(data) }
    func focusSpaceCommand(session: String?, space: String) -> String { "herdr" + Herdr.sessionArg(session) + " workspace focus " + Herdr.shellQuote(space) }
    func focusAgentCommand(session: String?, pane: String) -> String { "herdr" + Herdr.sessionArg(session) + " agent focus " + Herdr.shellQuote(pane) }
    func focusTabCommand(session: String?, tab: String) -> String { "herdr" + Herdr.sessionArg(session) + " tab focus " + Herdr.shellQuote(tab) }
    func newTabCommand(session: String?, space: String) -> String { "herdr" + Herdr.sessionArg(session) + " tab create --focus --workspace " + Herdr.shellQuote(space) }
    func newSpaceCommand(session: String?, label: String, folder: String) -> String {
        // The folder may start with ~, which only the shell expands; quote the rest.
        let dir = folder.hasPrefix("~/") ? "\"$HOME\"/" + Herdr.shellQuote(String(folder.dropFirst(2))) : Herdr.shellQuote(folder)
        return "mkdir -p " + dir + " && herdr" + Herdr.sessionArg(session) + " workspace create --focus --label " + Herdr.shellQuote(label) + " --cwd " + dir
    }
    func runInPaneCommand(session: String?, pane: String, command: String) -> String {
        "herdr" + Herdr.sessionArg(session) + " pane run " + Herdr.shellQuote(pane) + " " + Herdr.shellQuote(command)
    }
    func movePaneToNewSpaceCommand(session: String?, pane: String, label: String) -> String {
        "herdr" + Herdr.sessionArg(session) + " pane move " + Herdr.shellQuote(pane) + " --new-workspace --focus --label " + Herdr.shellQuote(label)
    }
    func splitPaneCommand(session: String?, pane: String, down: Bool) -> String {
        "herdr" + Herdr.sessionArg(session) + " pane split " + Herdr.shellQuote(pane) + " --direction " + (down ? "down" : "right") + " --focus"
    }
    func movePaneCommand(session: String?, pane: String, tab: String?, space: String) -> String {
        "herdr" + Herdr.sessionArg(session) + " pane move " + Herdr.shellQuote(pane) + " --focus "
            + (tab.map { "--tab " + Herdr.shellQuote($0) + " --split right" } ?? "--new-tab --workspace " + Herdr.shellQuote(space))
    }
    var keyHints: [(key: String, label: String)] { [("^b", "prefix"), ("^b w", "spaces"), ("^b q", "detach")] }

    func promptAgentsCommand(session: String?, panes: [String], text: String) -> String {
        let t = Herdr.shellQuote(text)
        return panes.map { p in
            "herdr" + Herdr.sessionArg(session) + " agent prompt " + Herdr.shellQuote(p) + " " + t + " >/dev/null 2>&1 || echo FAILED " + Herdr.shellQuote(p)
        }.joined(separator: "; ")
    }

    /// herdr's CLI has no move (0.9.5), so this sends `workspace.move` to its socket with whatever the
    /// machine has: nc, python3 or socat. Prints herdr's JSON reply.
    func moveSpaceCommand(session: String?, space: String, index: Int) -> String? {
        guard !space.isEmpty, space.allSatisfy({ $0.isLetter || $0.isNumber || ":_-".contains($0) }) else { return nil }
        let dir = session.map { $0.isEmpty || $0 == "default" ? "" : "/sessions/" + $0 } ?? ""
        let msg = #"{"id":"sidra-move","method":"workspace.move","params":{"workspace_id":"\#(space)","insert_index":\#(max(0, index))}}"#
        return "s=" + Herdr.shellQuote("/.config/herdr" + dir + "/herdr.sock") + "; s=\"$HOME$s\"; m=" + Herdr.shellQuote(msg) + "; "
            + #"if command -v nc >/dev/null; then printf '%s\n' "$m" | nc -U -w 3 "$s"; "#
            + #"elif command -v python3 >/dev/null; then python3 -c 'import socket,sys; c=socket.socket(socket.AF_UNIX); c.connect(sys.argv[1]); c.sendall(sys.argv[2].encode()+b"\n"); print(c.recv(65536).decode())' "$s" "$m"; "#
            + #"elif command -v socat >/dev/null; then printf '%s\n' "$m" | socat -t 3 - UNIX-CONNECT:"$s"; "#
            + #"else echo 'moving a space needs nc, python3 or socat on this machine' >&2; exit 3; fi"#
    }
}

/// herdr on another machine: Sidra runs herdr's own client in a terminal pane and reads its
/// socket API over a second SSH channel for the spaces bar, status counts and project logos.
enum Herdr {
    /// Non-interactive SSH commands skip the login profile, so add herdr's usual install paths.
    static let path = #"export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.nix-profile/bin:$PATH"; "#

    static func sessionArg(_ session: String?) -> String {
        guard let s = session, !s.isEmpty, s != "default" else { return "" }
        return " --session " + shellQuote(s)
    }

    /// Typed into the pane's login shell. `exec` makes a detach end the pane, which then offers Reconnect.
    static func attachCommand(session: String?) -> String { HerdrAdapter().attachCommand(session: session) }

    /// Where the attach script lives on the machine; `~` so any login shell (sh, zsh, fish) expands it.
    static let scriptPath = "~/.local/share/sidra/herdr-attach.sh"

    /// The pane's startup script (Resources/Scripts/herdr-attach.sh): checks herdr is there, points
    /// Sidra's client at its own config copy, then execs herdr.
    static let attachScript: String = {
        guard let url = Bundle.main.url(forResource: "herdr-attach", withExtension: "sh"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { fatalError("herdr-attach.sh is missing from the app bundle") }
        return s
    }()

    /// Writes the attach script before every attach (temp file, then rename), so the machine always runs
    /// this build's version. A quoted heredoc keeps the script byte for byte.
    static var installScript: String {
        #"f="$HOME/.local/share/sidra/herdr-attach.sh"; mkdir -p "${f%/*}" && cat > "$f.$$" <<'SIDRA_EOF' && mv -f "$f.$$" "$f""#
            + "\n" + attachScript + (attachScript.hasSuffix("\n") ? "" : "\n") + "SIDRA_EOF\n"
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
}

// MARK: - Socket API shapes (`herdr api snapshot`, protocol 22)

enum MuxStatus: String, Decodable, Sendable {
    case idle, working, blocked, done, unknown
    init(from decoder: Decoder) throws { self = MuxStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }

    /// The status a space shows: the most urgent of its agents.
    static func worst(_ all: [MuxStatus]) -> MuxStatus {
        for s in [MuxStatus.blocked, .working, .done, .idle] where all.contains(s) { return s }
        return .unknown
    }
}

struct MuxSnapshot: Decodable, Sendable {
    struct Workspace: Decodable, Sendable, Identifiable {
        let workspace_id: String
        let label: String
        let number: Int
        let agent_status: MuxStatus
        let tab_count: Int
        let focused: Bool
        var id: String { workspace_id }
    }
    struct Agent: Decodable, Sendable, Identifiable {
        let agent: String
        let agent_status: MuxStatus
        let pane_id: String
        let workspace_id: String
        let terminal_title_stripped: String?
        var id: String { pane_id }
    }
    struct PaneInfo: Decodable, Sendable {
        let pane_id: String
        let workspace_id: String
        let cwd: String?
    }
    struct Tab: Decodable, Sendable, Identifiable {
        let tab_id: String
        let workspace_id: String
        let label: String?
        let number: Int
        let focused: Bool
        let agent_status: MuxStatus
        var id: String { tab_id }
    }
    let workspaces: [Workspace]
    let agents: [Agent]
    /// Optional so a multiplexer without tabs (or an older herdr) still parses.
    let tabs: [Tab]?
    let focused_pane_id: String?
    let panes: [PaneInfo]
    let focused_workspace_id: String?
    let version: String?

    static func parse(_ data: Data) throws -> MuxSnapshot {
        struct Envelope: Decodable {
            struct R: Decodable { let snapshot: MuxSnapshot }
            struct E: Decodable { let code: String; let message: String }
            let result: R?
            let error: E?
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        if let e = env.error { throw HerdrError(code: e.code, message: e.message) }
        guard let s = env.result?.snapshot else { throw HerdrError(code: "bad_reply", message: "herdr sent no snapshot") }
        return s
    }

    func agents(in ws: String) -> [Agent] { agents.filter { $0.workspace_id == ws } }
    func tabs(in ws: String) -> [Tab] { (tabs ?? []).filter { $0.workspace_id == ws }.sorted { $0.number < $1.number } }
    /// The folder a space works in: its first pane's directory.
    func folder(of ws: String) -> String? { panes.first { $0.workspace_id == ws }?.cwd }
    func count(_ status: MuxStatus) -> Int { agents.filter { $0.agent_status == status }.count }
}

struct HerdrError: Error, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? {
        switch code {
        case "server_not_running": "herdr is installed but not running. Opening the pane starts it."
        case "not_installed": "herdr is not installed on this machine."
        default: message
        }
    }
}

// MARK: - Talking to the machine

extension AppModel {
    /// Runs a command on the machine a herdr pane points at.
    func herdrRun(_ target: TerminalTarget, _ command: String) async throws -> CommandResult {
        let full = Herdr.path + command
        #if DEBUG
        if DemoMode.isOn, target == .ssh(hostID: DemoMode.hostID) { return DemoMode.run(command) }
        #endif
        switch target {
        case .ssh(let id):
            guard let profile = hosts.host(id) else { throw AppError.message("No host profile") }
            return try await connection(for: profile).run(full, timeout: .seconds(20))
        }
    }

    /// Runs an adapter's prepare command; a failure says what the machine answered.
    func herdrPrepare(_ target: TerminalTarget, _ command: String) async throws {
        let r = try await herdrRun(target, command)
        guard r.exitCode == 0 else {
            throw AppError.message("Could not write herdr's attach script: " + String(decoding: r.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func herdrMachineName(_ target: TerminalTarget) -> String {
        switch target {
        case .ssh(let id): hosts.host(id)?.alias ?? "host"
        }
    }
}

/// What the connect sheet finds on a machine.
struct HerdrProbe: Sendable {
    var version: String?
    var running = false
    var sessions: [String] = []
    var snapshot: MuxSnapshot?

    static func run(_ app: AppModel, _ target: TerminalTarget) async throws -> HerdrProbe {
        let r = try await app.herdrRun(target, "command -v herdr >/dev/null || { echo NOHERDR; exit 0; }; herdr --version; herdr session list --json 2>/dev/null; echo; echo SNAP; herdr api snapshot 2>/dev/null")
        let out = r.stdoutText
        if out.contains("NOHERDR") { return HerdrProbe() }
        var p = HerdrProbe()
        let lines = out.components(separatedBy: "\n")
        p.version = lines.first { $0.hasPrefix("herdr ") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        // Any line that is a JSON object with a sessions list, whatever its key order.
        if let list = lines.lazy.compactMap({ (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] })
            .compactMap({ $0["sessions"] as? [[String: Any]] }).first {
            p.sessions = list.compactMap { $0["name"] as? String }
            p.running = list.contains { ($0["default"] as? Bool) == true && ($0["running"] as? Bool) == true }
        }
        if let range = out.range(of: "SNAP\n") {
            p.snapshot = try? MuxSnapshot.parse(Data(out[range.upperBound...].utf8))
            if p.snapshot != nil { p.running = true }
        }
        return p
    }
}

// MARK: - Live state for one herdr pane

/// One monitor per herdr pane; the title bar adds up their counts.
@MainActor
@Observable
final class MuxMonitors {
    static let shared = MuxMonitors()
    private(set) var byPane: [UUID: MuxMonitor] = [:]

    private var watchers: [UUID: Task<Void, Never>] = [:]

    /// The pane's monitor, polling from first sight until the pane closes, so a hidden tab's counts stay current.
    func monitor(for pane: Pane, app: AppModel) -> MuxMonitor? {
        guard let mux = pane.kind.multiplexer else { return nil }
        if let m = byPane[pane.id] { return m }
        let m = MuxMonitor(adapter: mux.adapter, target: mux.target, session: mux.session)
        byPane[pane.id] = m
        watchers[pane.id] = Task { await m.watch(app) }
        return m
    }

    func remove(_ id: UUID) { byPane[id] = nil; watchers.removeValue(forKey: id)?.cancel() }

    /// Drops monitors of panes closed anywhere, including in tabs that were not on screen.
    func prune(live: Set<UUID>) { for id in byPane.keys where !live.contains(id) { remove(id) } }

    /// `live` is every pane still open in any window; a closed pane's monitor no longer counts.
    // ponytail: called from a view body, so it skips stale monitors instead of mutating; they are tiny and stop polling with their view
    func count(_ status: MuxStatus, live: Set<UUID>) -> Int {
        // Two panes on the same machine and session see the same agents; count each once.
        var seen = Set<String>()
        var n = 0
        for (id, m) in byPane where live.contains(id) {
            guard let s = m.snapshot else { continue }
            for a in s.agents where a.agent_status == status && seen.insert("\(m.key)|\(a.pane_id)").inserted { n += 1 }
        }
        return n
    }
}

@MainActor
@Observable
final class MuxMonitor {
    let adapter: any MultiplexerAdapter
    let target: TerminalTarget
    let session: String?
    private(set) var snapshot: MuxSnapshot?
    private(set) var error: String?
    private(set) var logos: [String: PlatformImage] = [:]   // by folder
    private var logoTried: Set<String> = []
    private var loadingLogos = false

    var key: String { "\(target)|\(session ?? "default")" }

    init(adapter: any MultiplexerAdapter = HerdrAdapter(), target: TerminalTarget, session: String?) {
        self.adapter = adapter
        self.target = target
        self.session = session
    }

    /// Polls the snapshot from first sight until the pane closes.
    // ponytail: polls every 2 s (a space switched inside herdr shows in the bar that late); stream `herdr api events.subscribe` if it lags
    func watch(_ app: AppModel) async {
        while !Task.isCancelled {
            await refresh(app)
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func refresh(_ app: AppModel) async {
        do {
            let r = try await app.herdrRun(target, adapter.snapshotCommand(session: session))
            let s = try adapter.parseSnapshot(r.stdout)
            snapshot = s
            error = nil
            if !loadingLogos { Task { await loadLogos(app) } }
        } catch {
            // Stale counts from a machine we can no longer reach would mislead the title bar.
            snapshot = nil
            self.error = describeError(error)
        }
    }

    func focus(_ app: AppModel, _ ws: MuxSnapshot.Workspace) async {
        _ = try? await app.herdrRun(target, adapter.focusSpaceCommand(session: session, space: ws.id))
        await refresh(app)
    }

    /// Moves a space in the multiplexer's order; false when it refused or cannot.
    @discardableResult
    func moveSpace(_ app: AppModel, _ id: String, to index: Int) async -> Bool {
        guard let cmd = adapter.moveSpaceCommand(session: session, space: id, index: index),
              let r = try? await app.herdrRun(target, cmd) else { return false }
        await refresh(app)
        return r.exitCode == 0 && r.stdoutText.contains("\"result\"")
    }

    func focusTab(_ app: AppModel, _ tab: String) async {
        _ = try? await app.herdrRun(target, adapter.focusTabCommand(session: session, tab: tab))
        await refresh(app)
    }

    func newTab(_ app: AppModel, in space: String) async {
        _ = try? await app.herdrRun(target, adapter.newTabCommand(session: session, space: space))
        await refresh(app)
    }

    /// Broadcast: one command to many agents in one round trip. Returns the panes that did not take it
    /// (nil when the machine could not be reached).
    func broadcast(_ app: AppModel, _ text: String, to panes: [String]) async -> [String]? {
        guard !panes.isEmpty, let r = try? await app.herdrRun(target, adapter.promptAgentsCommand(session: session, panes: panes, text: text)) else { return nil }
        await refresh(app)
        let failed = r.stdoutText.split(separator: "\n").compactMap { $0.hasPrefix("FAILED ") ? String($0.dropFirst(7)) : nil }
        // The shell itself failed (no herdr, a syntax error): no pane can be counted as sent.
        return failed.isEmpty && r.exitCode != 0 ? panes : failed
    }

    @discardableResult
    func newSpace(_ app: AppModel, label: String, folder: String, agent: String? = CodingAgent.startOnNewSpace) async -> Bool {
        guard let r = try? await app.herdrRun(target, adapter.newSpaceCommand(session: session, label: label, folder: folder)), r.exitCode == 0 else {
            await refresh(app); return false
        }
        // The space is made; a failed agent start is its own message, so nobody retries into a second space.
        if let agent {
            struct Reply: Decodable { struct R: Decodable { struct P: Decodable { let pane_id: String }; let root_pane: P }; let result: R }
            var ran: CommandResult?
            if let pane = try? JSONDecoder().decode(Reply.self, from: r.stdout).result.root_pane.pane_id {
                ran = try? await app.herdrRun(target, adapter.runInPaneCommand(session: session, pane: pane, command: agent))
            }
            if ran?.exitCode != 0 { app.toast("The space is made, but herdr did not start \(agent)") }
        }
        await refresh(app)
        return true
    }

    /// The folders directly under `root` on that machine (`~/Development` by default), sorted, hidden ones left out.
    func folders(_ app: AppModel, under root: String = "~/Development") async -> [String] {
        let dir = root.hasPrefix("~/") ? "\"$HOME\"/" + Herdr.shellQuote(String(root.dropFirst(2))) : Herdr.shellQuote(root)
        guard let r = try? await app.herdrRun(target, "for d in " + dir + "/*/; do [ -d \"$d\" ] && basename \"$d\"; done") else { return [] }
        return r.stdoutText.split(separator: "\n").map(String.init).filter { !$0.isEmpty && $0 != "*" }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    @discardableResult
    func moveFocusedPaneToNewSpace(_ app: AppModel, label: String) async -> Bool {
        guard let pane = snapshot?.focused_pane_id,
              let r = try? await app.herdrRun(target, adapter.movePaneToNewSpaceCommand(session: session, pane: pane, label: label)) else { return false }
        await refresh(app)
        return r.exitCode == 0
    }

    /// Splits the pane herdr has focused.
    @discardableResult
    func splitFocusedPane(_ app: AppModel, down: Bool) async -> Bool {
        guard let pane = snapshot?.focused_pane_id,
              let r = try? await app.herdrRun(target, adapter.splitPaneCommand(session: session, pane: pane, down: down)) else { return false }
        await refresh(app)
        return r.exitCode == 0
    }

    /// Moves the pane herdr has focused into `tab`, or into a new tab of its space.
    @discardableResult
    func moveFocusedPane(_ app: AppModel, to tab: String?) async -> Bool {
        guard let s = snapshot, let pane = s.focused_pane_id, let space = s.focused_workspace_id,
              let r = try? await app.herdrRun(target, adapter.movePaneCommand(session: session, pane: pane, tab: tab, space: space)) else { return false }
        await refresh(app)
        return r.exitCode == 0
    }

    /// Shows the agent's pane in the multiplexer (its space and tab).
    func focusAgent(_ app: AppModel, pane: String) async {
        _ = try? await app.herdrRun(target, adapter.focusAgentCommand(session: session, pane: pane))
        await refresh(app)
    }

    func logo(for ws: MuxSnapshot.Workspace) -> PlatformImage? {
        snapshot?.folder(of: ws.id).flatMap { logos[$0] }
    }

    /// One folder at a time: sshd allows 10 sessions per connection (MaxSessions), so ten spaces
    /// fetched at once beside the snapshot poll lost the last one's logo. A fetch the connection
    /// refused is tried again on the next poll; a folder without a logo is not.
    private func loadLogos(_ app: AppModel) async {
        loadingLogos = true
        defer { loadingLogos = false }
        let folders = snapshot?.workspaces.compactMap { snapshot?.folder(of: $0.id) } ?? []
        for folder in folders where !logoTried.contains(folder) {
            guard let r = try? await app.herdrRun(target, HerdrLogo.script(folder: folder)) else { continue }
            logoTried.insert(folder)
            if r.exitCode == 0, let data = Data(base64Encoded: r.stdoutText.filter { !$0.isWhitespace }), let image = HerdrLogo.image(data) {
                logos[folder] = image
            }
        }
    }
}

/// Finds a project's own logo in its folder: app icon, touch icon, a desktop app icon, then a favicon.
enum HerdrLogo {
    static let candidates = [
        "design/icon/icon-1024.png", "design/icon/icon-512.png", "design/icon/icon.png", "*/Assets.xcassets/AppIcon.appiconset/*1024*.png", "*/*/Assets.xcassets/AppIcon.appiconset/*1024*.png",
        "apple-touch-icon.png", "public/apple-touch-icon.png", "*/public/apple-touch-icon.png", "*/*/public/apple-touch-icon.png",
        "public/icon-512.png", "*/public/icon-512.png",
        "src-tauri/icons/icon.png", "*/src-tauri/icons/icon.png", "*/*/src-tauri/icons/icon.png",
        // mobile and game app icons (Flutter, Expo, Godot)
        "assets/brand/app_icon.png", "*/*/assets/brand/app_icon.png", "assets/icon/app_icon.png", "*/*/assets/icon/app_icon.png",
        "assets/icon.png", "*/assets/icon.png", "*/*/assets/icon.png",
        "public/favicon.png", "*/public/favicon.png", "public/icon.png", "*/public/icon.png",
        "public/favicon.ico", "*/public/favicon.ico",
        "public/favicon.svg", "*/public/favicon.svg", "*/*/public/favicon.svg",
    ]

    /// Prints the first good logo as base64 PNG, or exits 1. Shrinks it to 128 px where the machine
    /// can (sips on a Mac) and rasterises an SVG with rsvg-convert or Quick Look; a machine with neither
    /// skips SVGs. Stays under 512 KB. Skips the Rails starter icon (a red circle, recognisable by the
    /// tiny icon.svg next to it). Runs under sh: zsh, the macOS login shell, aborts on a glob that matches nothing.
    static func script(folder: String) -> String {
        let inner = #"cd "$1" 2>/dev/null || exit 1; cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; t=$(mktemp -d); trap 'rm -rf "$t"' EXIT; "#
            + "for f in \(candidates.joined(separator: " ")); do "
            + #"[ -s "$f" ] || continue; "#
            + #"v="${f%.png}.svg"; [ -f "$v" ] && [ "$(wc -c < "$v")" -lt 200 ] && grep -q 'fill="red"' "$v" && continue; "#
            + #"rm -f "$t"/*; case "$f" in "#
            + #"*.svg) if command -v rsvg-convert >/dev/null; then rsvg-convert -w 128 -h 128 "$f" > "$t/l.png" 2>/dev/null; "#
            + #"elif command -v qlmanage >/dev/null; then qlmanage -t -s 128 -o "$t" "$f" >/dev/null 2>&1 && mv "$t"/*.png "$t/l.png" 2>/dev/null; fi;; "#
            + #"*) if command -v sips >/dev/null; then sips -Z 128 -s format png "$f" --out "$t/l.png" >/dev/null 2>&1; fi; [ -s "$t/l.png" ] || cp "$f" "$t/l.png";; esac; "#
            + #"[ -s "$t/l.png" ] && [ "$(wc -c < "$t/l.png")" -lt 524288 ] || continue; "#
            + #"base64 < "$t/l.png" | tr -d '\n'; exit 0; done; exit 1"#
        return "sh -c " + Herdr.shellQuote(inner) + " sh " + Herdr.shellQuote(folder)
    }

    /// PNG, JPEG and ICO decode with PlatformImage; SVGs arrive rasterised by the script.
    static func image(_ data: Data) -> PlatformImage? { PlatformImage(data: data) }
}
