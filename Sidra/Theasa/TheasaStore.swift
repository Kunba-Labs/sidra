import SwiftUI
import Observation
import SidraSSH
import SidraTheasa
import SidraWorkspace

/// The work log and live agents (Theasa's screens, in the Substrate tab since 2026-11-26), read from Substrate's
/// app API with the signed-in account. The live model runs app-wide: the Substrate pill shows its counts.
@MainActor @Observable
final class TheasaStore {
    static let shared = TheasaStore()
    private var navs: [UUID: TheasaNav] = [:]
    /// What the screens read: Substrate's work log and live agents. Nil while signed out of Substrate.
    var activeLive: TheasaLive? {
        #if DEBUG
        if DemoMode.isOn { return demoLive }
        #endif
        return substrateLive
    }
    #if DEBUG
    /// Demo mode: a Substrate-shaped stub (DemoURLProtocol) answers from the work-log fixtures.
    @ObservationIgnored private lazy var demoLive = TheasaLive(client: TheasaClient(base: URL(string: "https://substrate.demo/api/v1")!, token: "demo", substrate: true))
    #endif

    /// Substrate's app API with the signed-in account's token (2026-11-26): the same screens, the paths mapped by TheasaClient.
    @ObservationIgnored private var substrateCache: TheasaLive?
    var substrateLive: TheasaLive? {
        let hub = SubstrateHub.shared
        guard let c = hub.connections.first(where: { hub.store($0.id)?.signedIn == true }), let base = URL(string: c.base),
              let token = KeychainStore.string(for: c.tokenKey) else { return nil }
        if let l = substrateCache, l.client.base == base, l.client.token == token { return l }
        let l = TheasaLive(client: TheasaClient(base: base, token: token, substrate: true))
        substrateCache = l
        return l
    }
    /// Theasa's screen stack and keyboard state; one per app, shared by the Theasa tab in every window.
    static let popoverPane = UUID(uuidString: "7EA5A000-0000-0000-0000-000000000001")!
    var popoverNav: TheasaNav { nav(in: app) }
    /// Each window's Theasa pane keeps its own screens and keyboard state; no Theasa pane yet: the shared fallback.
    func nav(in app: AppModel?) -> TheasaNav {
        let pane = app?.workspace.tabs.first(where: Self.isTheasaTab)?.panes.first { if case .substrate = $0.kind { true } else { false } }
        return nav(pane?.id ?? Self.popoverPane)
    }

    /// Theasa is a tab whose only handle is the title-bar pill (2026-11-14: "the pill is a tab,
    /// so clicking on it opens the same tab as before but theasa pill acts as its tab"). The tab strip,
    /// dock and orb hide it through `WorkspaceStore.isHiddenTab`.
    /// Since 2026-11-26 that is the Substrate tab: Theasa's screens are its Pulse and Agents sections, and the
    /// Substrate pill is its handle.
    static func isTheasaTab(_ t: WorkspaceTab) -> Bool { t.panes.contains { if case .substrate = $0.kind { true } else { false } } }

    /// The app, for the tab and the connections sheet (set at launch).
    @ObservationIgnored weak var app: AppModel?

    /// The Theasa tab is the active tab of the key window.
    /// The Substrate tab is in front on Pulse or Agents (⌘F, ⌘. and ⌘↩ go to Theasa's screens then).
    var presented: Bool {
        guard let t = app?.workspace.activeTab, Self.isTheasaTab(t) else { return false }
        return t.panes.contains { if case .substrate(let id) = $0.kind, let s = SubstrateHub.shared.store(id) { [.pulse, .agents].contains(s.section) } else { false } }
    }

    /// Esc and ⌘.: a typing field gives the keyboard up, else one screen back.
    func escape() { popoverNav.escape() }

    /// Selects the Theasa tab (made on first use), on a root screen if given; without a connection, the connect sheet.
    func open(_ app: AppModel, root: TheasaNav.Root? = nil) {
        self.app = app
        guard activeLive != nil else { app.startTab(.substrate); return }   // signed out of Substrate: its sign-in
        // The Substrate tab on its Pulse or Agents section (2026-11-26).
        let hub = SubstrateHub.shared
        let c = hub.connections.first ?? hub.add()
        if let s = hub.store(c.id) {
            if let root { s.section = root == .agents ? .agents : .pulse }
            else if ![.pulse, .agents].contains(s.section) { s.section = .pulse }
        }
        app.startTab(.substrate)
        if let root { popoverNav.show(root) }
        if let a = pendingAgent { pendingAgent = nil; popoverNav.show(.agents); popoverNav.highlightAgent = a }
    }

    /// An agent herdr's list asked to open while signed out: shown once Agents opens.
    private var pendingAgent: String?

    /// herdr's agent list: Agents opens on that agent's card.
    func openAgent(_ agentPane: String, app: AppModel) {
        pendingAgent = agentPane
        open(app, root: .agents)
    }

    /// Saved workspaces: Theasa tabs close, their screens live in the Substrate tab now (2026-11-26).
    func mergeTheasaTabs(_ app: AppModel) {
        for ws in app.allWorkspaces {
            for tab in ws.tabs {
                for p in tab.panes {
                    guard case .theasa = p.kind else { continue }
                    ws.close(pane: p.id, inTab: tab.id)
                }
            }
        }
    }

    /// Per pane: the screen stack and keyboard state the menu commands act on.
    func nav(_ pane: UUID) -> TheasaNav {
        if let n = navs[pane] { return n }
        let n = TheasaNav(pane: pane)
        if let r = Self.launchRoute { n.path = [r] }
        navs[pane] = n
        return n
    }

    private init() { Self.forgetTheasaServers() }

    /// The saved Theasa servers of older versions: their tokens leave the Keychain, the list leaves UserDefaults (2026-11-26).
    private static func forgetTheasaServers() {
        struct Old: Decodable { let id: UUID }
        guard let d = UserDefaults.standard.data(forKey: "sidra.theasaConnections") else { return }
        for c in (try? JSONDecoder().decode([Old].self, from: d)) ?? [] { KeychainStore.remove("theasa.token.\(c.id.uuidString)") }
        UserDefaults.standard.removeObject(forKey: "sidra.theasaConnections")
        UserDefaults.standard.removeObject(forKey: "sidra.theasaActive")
    }

    /// At launch: closes Theasa tabs of saved workspaces. `-sidra.theasaRoute agents|project:48|turn:9557|search:word`
    /// (UI tests, screenshots) opens the Substrate tab on that screen.
    func openFromLaunchArguments(_ app: AppModel) {
        self.app = app
        mergeTheasaTabs(app)
        if Self.launchRoute != nil { open(app); _ = popoverNav }
    }

    static var launchRoute: TheasaRoute? {
        guard let r = UserDefaults.standard.string(forKey: "sidra.theasaRoute") else { return nil }
        let parts = r.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "agents": return .agents
        case "project": return parts.count > 1 ? Int(parts[1]).map(TheasaRoute.project) : nil
        case "turn": return parts.count > 1 ? Int(parts[1]).map(TheasaRoute.turn) : nil
        case "search": return parts.count > 1 ? .search(parts[1]) : nil
        default: return nil
        }
    }
}

/// Live state for one server: the event stream, the agents list (the header counts and Pulse's
/// Waiting for you), and what the user has typed or picked that a refetch must not wipe.
@MainActor @Observable
final class TheasaLive {
    private(set) var client: TheasaClient
    /// Bumped on every `data: change`; screens refetch on it.
    private(set) var tick = 0
    private(set) var connected = false
    var agents: AgentsResponse?
    var drafts: [String: String] = [:]
    var picks: [String: [String]] = [:]
    var openFiles: Set<String> = []
    var openFolds: Set<String> = []
    var toast: String?
    /// Reads remembered per connection: range on Pulse and Project, agent filter, only-notes.
    var range = "week"
    var projectRange = "today"
    var agentFilter = "all"
    var onlyNotes = false

    private var stream: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    init(client: TheasaClient) {
        self.client = client
        start()
    }

    /// Bumped on reconnect: an agents request to the old server that lands late is dropped.
    private var generation = 0

    func reconnect(client: TheasaClient) {
        generation += 1
        self.client = client
        stop(); start()
    }

    func stop() { stream?.cancel(); stream = nil; poll?.cancel(); poll = nil; connected = false }

    /// The title bar's waiting count loads in the background: once at start, then every 5 s, so it is
    /// right without opening Theasa and without waiting for the event stream (2026-11-14).
    private var poll: Task<Void, Never>?

    private func start() {
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.loadAgents()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        stream = Task { [weak self] in
            while !Task.isCancelled {
                guard let c = self?.client else { return }
                do {
                    for try await data in c.events() {
                        guard let self else { return }
                        // "hello" on (re)connect: refetch too, changes may have been missed while away
                        if !self.connected || data == "change" { self.connected = true; self.changed() }
                    }
                } catch {}
                self?.connected = false
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Debounced: a burst of changes is one refetch.
    private var pending: Task<Void, Never>?
    func changed() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.tick += 1
            await self.loadAgents()
        }
    }

    /// Live agents and what they sent need the token (theasa 68f3cfb): without it, or on a 401, Agents
    /// and the pill say so instead of showing an empty list.
    private(set) var needsToken = false

    func loadAgents() async {
        var a: AgentsResponse
        let gen = generation
        if client.token == nil { needsToken = true; agents = nil; return }
        do { a = try await client.get("/api/agents", as: AgentsResponse.self) }
        catch TheasaError.unauthorized { if gen == generation { needsToken = true; agents = nil }; return }
        catch { return }
        guard gen == generation else { return }
        needsToken = false
        #if DEBUG
        // -sidra.theasaDemoAgents: adds an ask card and a screen card with pane ids herdr never has, so the
        // answer path can be driven end to end (the server answers 404 "that agent is gone", nothing is typed).
        if UserDefaults.standard.bool(forKey: "sidra.theasaDemoAgents") { a = AgentsResponse(available: true, error: a.error, agents: Self.demoAgents + a.agents) }
        #endif
        agents = a
    }

    #if DEBUG
    static let demoAgents: [LiveAgent] = {
        let json = #"""
        [{"pane_id":"demo:ask","agent":"claude","status":"blocked","title":"demo","cwd":"/tmp/demo","session_id":"demo-ask","since":null,"project":{"id":null,"name":"demo ask","icon_url":null,"initial":"D"},
          "ask":[{"question":"Which database should the cache use?","header":"Database","multiSelect":false,"options":[{"label":"SQLite","description":"One file next to the app"},{"label":"Postgres","description":"The shared server"}]},
                 {"question":"Which targets need it?","header":"Targets","multiSelect":true,"options":[{"label":"iPad"},{"label":"Mac"},{"label":"Linux VM"}]}]},
         {"pane_id":"demo:screen","agent":"codex","status":"blocked","title":"demo","cwd":"/tmp/demo","session_id":"demo-screen","since":null,"project":{"id":null,"name":"demo dialog","icon_url":null,"initial":"D"},
          "screen":{"text":"Allow Codex to run this command?\n\n  git push origin HEAD:main\n\n> 1. Yes\n  2. Yes, and don't ask again\n  3. No, tell Codex what to do","options":[{"label":"Yes","keys":["1"],"selected":true},{"label":"Yes, and don't ask again","keys":["2"],"selected":false},{"label":"No, tell Codex what to do","keys":["3"],"selected":false}]}},
         {"pane_id":"demo:reply","agent":"claude","status":"done","title":"demo reply","cwd":"/tmp/demo","session_id":"demo-reply","since":null,"project":{"id":null,"name":"demo reply","icon_url":null,"initial":"D"},
          "last":{"turn_id":9557,"headline":"Demo: a finished turn that asks something.","text":"Ship it now?","question":"Should I **ship it** now, or wait for the review?","ended_at":null}},
         {"pane_id":"demo:design","agent":"claude","status":"blocked","title":"demo","cwd":"/tmp/demo","session_id":"demo-design","since":null,"project":{"id":null,"name":"demo designs","icon_url":null,"initial":"D"},
          "ask":[{"question":"Which login screen should we build?","header":"Login","multiSelect":false,"options":[
            {"label":"Card","description":"A centred card","preview":"+------------------------------+\n|          Sign in             |\n|  [ email                  ]  |\n|  [ password               ]  |\n|  [        Continue        ]  |\n|  Forgot your password?       |\n+------------------------------+"},
            {"label":"Split","description":"Image left, form right","preview":"+--------------+---------------+\n|              |   Sign in     |\n|    image     |  [ email   ]  |\n|              |  [ Continue ]|\n+--------------+---------------+"}]}],
          "ask_extras":{"context":"Two login designs are ready. **Card** keeps the form centred on a plain background. **Split** puts the brand image on the left and the form on the right, which needs a wider screen.\n\n- Both use the same fields.\n- Both keep the password reset link.\n- Split hides the image under 700 pt.\n- Card works on the phone as is.\n- I can build either today.\n- The screenshots are below.",
            "attachments":[{"id":2332,"kind":"sent","name":"/tmp/demo/design/login-card.png","media_type":"image/jpeg","src":"/api/attachments/2332"},
                           {"id":2333,"kind":"sent","name":"/tmp/demo/design/login-split.png","media_type":"image/png","src":"/api/attachments/2333"},
                           {"id":9001,"kind":"sent","name":"/tmp/demo/design/notes.md","media_type":"text/markdown"},
                           {"id":9002,"kind":"artifact","name":"Login options","url":"https://claude.ai/artifact/demo"}]}}]
        """#
        let all = (try? JSONDecoder().decode([LiveAgent].self, from: Data(json.utf8))) ?? []
        return all.filter { $0.pane_id == "demo:design" } + all.filter { $0.pane_id != "demo:design" }   // the design question first
    }()
    #endif

    func say(_ msg: String) {
        toast = msg
        toastTask?.cancel()
        toastTask = Task { try? await Task.sleep(for: .seconds(3.5)); if !Task.isCancelled { toast = nil } }
    }

    /// A POST from a button. Errors become a toast; success triggers a refetch. Returns the reply or nil.
    @discardableResult
    func act(_ path: String, _ body: [String: Any] = [:], done: String? = nil) async -> [String: Any]? {
        do {
            let r = try await client.post(path, body)
            if let done { say(done) }
            changed()
            return r
        } catch {
            say((error as? LocalizedError)?.errorDescription ?? "That didn't work.")
            return nil
        }
    }
}

/// One Theasa pane's navigation and keyboard state. Lives outside the views so the Theasa menu
/// commands (Commands.swift) can drive the focused pane.
@MainActor @Observable
final class TheasaNav {
    let pane: UUID
    /// The workspace pane showing these screens now (the Theasa tab's pane); `pane` is only this state's key.
    var hostPane: UUID?
    var focusTarget: UUID { hostPane ?? pane }
    enum Root { case pulse, agents }
    /// The tab's root screen: Pulse or Agents, switched by the pills, never pushed.
    var root: Root = .pulse
    var path: [TheasaRoute] = [] {
        // Agents is a root: a caller that pushes it (herdr's "open in Theasa", a launch route) switches root.
        didSet { if path.first == .agents { root = .agents; path = Array(path.drop { $0 == .agents }) } }
    }
    /// Bumped by ⌘F: the nav row's search field takes focus.
    var focusSearch = 0
    /// Bumped when the pane loses focus or hides: every Theasa field gives the keyboard up.
    var resign = 0
    /// A Theasa text field in this pane has the keyboard. Esc then leaves the field, not the screen.
    var typing = false
    /// The focused message field's send action, for ⌘↩.
    var submit: (() -> Void)?
    /// Set by the key host: gives up first responder so a SwiftUI field can take the keyboard.
    @ObservationIgnored var releaseKeys: (() -> Void)?
    /// The agent card "Next agent that needs you" picked.
    var highlightAgent: String?
    /// A view id inside the Agents screen to scroll to (an unanswered question).
    var scrollTo: String?
    init(pane: UUID) { self.pane = pane }

    func back() { if !path.isEmpty { path.removeLast() } }
    func show(_ r: Root) { root = r; path = [] }
    /// Esc and ⌘.: a typing field gives the keyboard up; otherwise one screen back.
    func escape() { if typing { resign += 1; typing = false } else { back() } }

    /// Next blocked agent (or one whose last reply asks), cycling; opens Agents.
    func nextAgent(_ live: TheasaLive) -> Bool {
        let list = AgentLogic.waiting(live.agents?.available == true ? live.agents!.agents : [])
        guard !list.isEmpty else { return false }
        let i = list.firstIndex { $0.pane_id == highlightAgent }.map { ($0 + 1) % list.count } ?? 0
        highlightAgent = list[i].pane_id
        show(.agents)
        return true
    }
}
