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
    var pickedSession: String?
    var section: Section = .requests
    enum Section: String, CaseIterable { case requests = "Requests", sessions = "Sessions", machines = "Machines" }

    @ObservationIgnored private var liveTask: Task<Void, Never>?
    /// Requests already waiting at the last refresh; nil before the first, so launching does not notify the backlog.
    @ObservationIgnored private var seenWaiting: Set<String>?

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
    private func notifyNewApprovals() {
        let waiting = (dashboard?.waiting ?? []).filter { $0.stage == "pending_approval" || $0.stage == "held" }
        defer { seenWaiting = Set(waiting.map(\.id)) }
        guard let seen = seenWaiting else { return }
        for m in waiting where !seen.contains(m.id) {
            let who = m.sender?.name ?? "Someone"
            Notifier.notify(m.held ? "Held: \(m.project?.name ?? "a project")" : "\(who) asks \(m.project?.name ?? "an agent")",
                            m.held ? "\(who): \(m.text)" : m.text,
                            route: .substrate(connection.id, m.id), category: Notifier.approvalCategory, id: "substrate.\(m.id)")
        }
    }

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

    func approve(_ id: String) async throws { try await act(id, "approve") }
    func reject(_ id: String) async throws { try await act(id, "reject") }

    private func act(_ id: String, _ verb: String) async throws {
        struct R: Decodable { var id: String?; var stage: String? }
        let _: R = try await client.post("/messages/\(id)/\(verb)")
        await refresh()
    }
}
