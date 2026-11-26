import Foundation
import Observation
import SidraSSH
import SidraDesign

/// The saved Substrate accounts and one store each. Today there is one account; the list keeps the door open.
@MainActor @Observable
final class SubstrateHub {
    static let shared = SubstrateHub()
    private let key = "sidra.substrate.connections"
    private(set) var connections: [SubstrateConnection] = []
    private var stores: [UUID: SubstrateStore] = [:]

    private init() {
        connections = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([SubstrateConnection].self, from: $0) } ?? []
        #if DEBUG
        // Simulator checks: -sidra.substrateBase URL with SIDRA_SUBSTRATE_TOKEN set signs in a fixed account
        // (id …5b5) against that server; without the token the account is there, signed out.
        if let base = UserDefaults.standard.string(forKey: "sidra.substrateBase"), !base.isEmpty {
            let id = UUID(uuidString: "00000000-0000-0000-0000-0000000005b5")!
            if !connections.contains(where: { $0.id == id }) { connections.append(SubstrateConnection(id: id, base: base, email: "waseem@example.com")); save() }
            if let t = ProcessInfo.processInfo.environment["SIDRA_SUBSTRATE_TOKEN"], !t.isEmpty { try? KeychainStore.set(t, for: "substrate.token.\(id.uuidString)") }
            else { KeychainStore.remove("substrate.token.\(id.uuidString)") }
        }
        #endif
        for c in connections where KeychainStore.string(for: c.tokenKey) != nil { store(c.id)?.start() }   // the waiting count runs from launch
    }

    func connection(_ id: UUID) -> SubstrateConnection? { connections.first { $0.id == id } }

    func store(_ id: UUID) -> SubstrateStore? {
        if let s = stores[id] { return s }
        guard let c = connection(id) else { return nil }
        let s = SubstrateStore(connection: c)
        stores[id] = s
        return s
    }

    /// A new account, signed out until its tab signs in.
    func add() -> SubstrateConnection {
        let c = SubstrateConnection()
        connections.append(c); save()
        return c
    }

    func update(_ c: SubstrateConnection) {
        guard let i = connections.firstIndex(where: { $0.id == c.id }) else { return }
        connections[i] = c; save()
    }

    /// Requests waiting for approval across signed-in accounts: the title bar pill.
    var waiting: Int { connections.compactMap { stores[$0.id]?.waiting }.reduce(0, +) }

    /// herdr pane ids whose agent has a request waiting: the small Substrate mark on a herdr space chip.
    var waitingPanes: Set<String> { connections.compactMap { stores[$0.id]?.waitingPanes }.reduce(into: Set()) { $0.formUnion($1) } }

    private func save() {
        if let d = try? JSONEncoder().encode(connections) { UserDefaults.standard.set(d, forKey: key) }
    }
}

/// One account: sign-in, the dashboard, sessions and machines, refetched on each `changed` from /live.
@MainActor @Observable
final class SubstrateStore {
    private(set) var connection: SubstrateConnection
    private(set) var signedIn: Bool
    var dashboard: Substrate.Dashboard?
    var sessions: Substrate.Sessions?
    var machines: [Substrate.Machine] = []
    var conversations: [String: Substrate.Conversation] = [:]
    var sessionDetails: [String: Substrate.Session] = [:]
    var error: String?
    var loading = false
    /// The request and session picked in the pane, kept across tab switches.
    var pickedMessage: String?
    /// The request whose "Edit before approving" editor is open (also opened by a notification's Edit).
    var editing: String?
    var pickedSession: String?
    var section: Section = .requests
    enum Section: String, CaseIterable {
        // Pulse and Agents: Theasa's screens, moved into Substrate (2026-11-26).
        case requests = "Requests", sessions = "Sessions", pulse = "Pulse", agents = "Agents", machines = "Machines"
        var icon: String {
            switch self { case .requests: "tray"; case .sessions: "link"; case .pulse: "waveform.path.ecg"; case .agents: "person.2"; case .machines: "desktopcomputer" }
        }
    }

    @ObservationIgnored private var liveTask: Task<Void, Never>?
    /// Requests already waiting at the last refresh; nil before the first, so launching does not notify the backlog.
    @ObservationIgnored private var seenWaiting: Set<String>?
    /// Substrate has this device's push token; until then each refresh tries again (a server without
    /// /devices yet, or no network at launch, left pushes off until the next launch).
    @ObservationIgnored private var deviceRegistered = false

    init(connection: SubstrateConnection) {
        self.connection = connection
        signedIn = KeychainStore.string(for: connection.tokenKey) != nil
    }

    private var client: SubstrateClient { SubstrateClient(base: connection.base, token: KeychainStore.string(for: connection.tokenKey)) }

    var waiting: Int { signedIn ? dashboard?.counts.waiting ?? dashboard?.waiting.count ?? 0 : 0 }

    var waitingPanes: Set<String> {
        let projects = Set((dashboard?.waiting ?? []).compactMap { $0.project?.id })
        return Set(machines.flatMap(\.agents).filter { a in a.project.map { projects.contains($0.id) } ?? false }.map(\.pane_id))
    }

    /// The machine agent (herdr pane) a project runs in, for "Open in herdr".
    func agent(for project: Substrate.Project?) -> Substrate.Agent? {
        guard let project else { return nil }
        return machines.flatMap(\.agents).first { $0.project?.id == project.id || ($0.project?.handle != nil && $0.project?.handle == project.handle) }
    }

    // MARK: Sign in

    func requestCode(email: String) async throws {
        struct OK: Decodable { var ok: Bool? }
        let _: OK = try await SubstrateClient(base: connection.base, token: nil).post("/auth/code", ["email": email])
        connection.email = email
        SubstrateHub.shared.update(connection)
    }

    func verify(code: String) async throws {
        let device = "Sidra on \(Platform.deviceName)"
        let v: Substrate.Verified = try await SubstrateClient(base: connection.base, token: nil)
            .post("/auth/verify", ["email": connection.email, "code": code, "device": device])
        try KeychainStore.set(v.token, for: connection.tokenKey)
        connection.name = v.account?.name ?? v.account?.email
        SubstrateHub.shared.update(connection)
        signedIn = true
        start()
    }

    func signOut() async {
        struct OK: Decodable { var ok: Bool? }
        #if os(iOS) || os(visionOS)
        if let t = SubstratePush.token { let _: OK? = try? await client.delete("/devices/\(t)") }   // before the token stops working
        #endif
        let _: OK? = try? await client.post("/auth/logout")
        forget()
    }

    private func forget() {
        KeychainStore.remove(connection.tokenKey)
        signedIn = false
        liveTask?.cancel(); liveTask = nil
        dashboard = nil; sessions = nil; machines = []; conversations = [:]; sessionDetails = [:]
    }

    // MARK: Reading

    /// Fetches everything and keeps /live open; reconnects after a drop, waiting longer each time (at most a minute).
    func start() {
        guard signedIn, liveTask == nil else { return }
        #if os(iOS) || os(visionOS)
        SubstratePush.enable()
        if let t = SubstratePush.token { Task { await registerDevice(t) } }
        #endif
        Task { await refresh() }
        liveTask = Task { [weak self] in
            var wait = 2.0
            while !Task.isCancelled {
                guard let self, self.signedIn else { return }
                do {
                    try await self.client.live { [weak self] in await self?.refresh() }
                    wait = 2
                } catch let f as Substrate.Failure where f.signedOut {
                    self.forget(); return
                } catch {
                    wait = min(60, wait * 2)
                }
                try? await Task.sleep(for: .seconds(wait))
                await self.refresh()   // whatever changed while the stream was down
            }
        }
    }

    func refresh() async {
        guard signedIn else { return }
        loading = true
        defer { loading = false }
        do {
            async let d: Substrate.Dashboard = client.get("/dashboard")
            async let s: Substrate.Sessions = client.get("/sessions")
            async let m: Substrate.Machines = client.get("/machines")
            dashboard = try await d
            notifyNewApprovals()
            #if os(iOS) || os(visionOS)
            if !deviceRegistered, let t = SubstratePush.token { await registerDevice(t) }
            #endif
            sessions = try await s
            machines = try await m.machines
            error = nil
            if let id = pickedMessage, let cid = message(id)?.conversation_id { await loadConversation(cid) }
            if let id = pickedSession { await loadSession(id) }
        } catch let f as Substrate.Failure where f.signedOut {
            forget()
            error = "Your Substrate sign-in ended. Sign in again."
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// A local notification per request that started waiting since the last refresh, with Approve and Reject
    /// (2026-11-20). Only while Sidra runs: Notifier skips it when Sidra is in front, where the pill shows it.
    /// On the Mac, Sidra's own desktop cards by default (SubstrateDesktop).
    private func notifyNewApprovals() {
        let waiting = (dashboard?.waiting ?? []).filter { $0.stage == "pending_approval" || $0.stage == "held" }
        defer { seenWaiting = Set(waiting.map(\.id)) }
        #if os(macOS)
        SubstrateDesktop.shared.prune(connection.id, keep: Set(waiting.map(\.id)))
        #endif
        guard let seen = seenWaiting else { return }
        for m in waiting where !seen.contains(m.id) {
            #if os(macOS)
            // The Mac's own cards (default) show whether Sidra is in front or not; System keeps the banner below.
            switch SubstrateDesktop.mode {
            case .cards: SubstrateDesktop.shared.show(m, connection: connection.id); continue
            case .off: continue
            case .system: break
            }
            #endif
            let who = m.sender?.name ?? "Someone"
            Notifier.notify(m.riskRules != nil ? "Held: \(m.project?.name ?? "a project")" : m.newWork ? "New work: \(m.project?.name ?? "a project")" : "\(who) asks \(m.project?.name ?? "an agent")",
                            m.held ? "\(who): \(m.text)" : m.proposal.map { "Adjusted in review: \($0.text)" } ?? m.text,
                            route: .substrate(connection.id, m.id), category: Notifier.approvalCategory, id: "substrate.\(m.id)")
        }
    }

    #if os(iOS) || os(visionOS)
    /// Tells Substrate where to push this account's approvals; `client_ref` (this account's id here) comes back in each push.
    func registerDevice(_ token: String) async {
        struct OK: Decodable { var ok: Bool? }
        let ok: OK? = try? await client.post("/devices", ["token": token, "bundle": Bundle.main.bundleIdentifier ?? "nl.sadiq.sidra",
                                                          "sandbox": SubstratePush.sandbox ? "true" : "false", "client_ref": connection.id.uuidString])
        deviceRegistered = ok != nil
    }
    #endif

    func message(_ id: String) -> Substrate.Message? {
        guard let d = dashboard else { return nil }
        return (d.waiting + d.active + d.history).first { $0.id == id }
    }

    func loadConversation(_ id: String) async {
        if let c: Substrate.Conversation = try? await client.get("/conversations/\(id)") { conversations[id] = c }
    }

    func loadSession(_ id: String) async {
        if let s: Substrate.Session = try? await client.get("/sessions/\(id)") { sessionDetails[id] = s }
    }

    // MARK: Acting

    /// PATCH /sessions/{id}: `permissions` holds only what the developer changed (each is set in every project of the
    /// session); `projects`, when given, is the full list the session should reach. Throws the server's error text.
    func editSession(_ id: String, permissions: [String: Bool], projects: [String]?) async throws {
        var body: [String: Any] = [:]
        if !permissions.isEmpty { body["permissions"] = permissions }
        if let projects { body["projects"] = projects }
        guard !body.isEmpty else { return }
        let s: Substrate.Session = try await client.patch("/sessions/\(id)", body)
        sessionDetails[id] = s
        await refresh()
    }

    /// `text`: the developer's edit of the tester's message; the agent gets it in place of the original (2026-11-20).
    /// No text approves the proposal when there is one. `why` reaches the tester with an edit (2026-11-21).
    func approve(_ id: String, text: String? = nil, why: String? = nil) async throws {
        var body = text.map { ["text": $0] }
        if let why, !why.isEmpty { body?["why"] = why }
        try await act(id, "approve", body)
    }
    func reject(_ id: String) async throws { try await act(id, "reject") }
    /// "Review with agent": the request goes to the project's agent, review-only; it comes back with a proposal (2026-11-21).
    func review(_ id: String) async throws { try await act(id, "review") }

    private func act(_ id: String, _ verb: String, _ body: [String: String]? = nil) async throws {
        struct R: Decodable { var id: String?; var stage: String? }
        do {
            let _: R = try await client.post("/messages/\(id)/\(verb)", body)
        } catch let f as Substrate.Failure where f.status == 409 {
            await refresh()
            // Review's 409 says why (agent offline, relay too old); show it as is.
            throw verb == "review" ? f : Substrate.Failure(status: 409, text: "Someone else decided this request first.")
        }
        if editing == id { editing = nil }
        await refresh()
    }
}
