import Foundation
import SidraSSH

/// Substrate (substrate.gliph.sh): testers chat with the developer's agents, the developer approves each
/// message, a relay on the Mac hands it to the herdr pane. Contract: ~/Development/substrate/docs/app-api.md
/// (2026-11-20). Every call but the two sign-in calls sends the bearer token; a 401 means sign in again.
enum Substrate {
    static let defaultBase = "https://substrate.gliph.sh/api/v1"

    struct Project: Codable, Hashable, Identifiable {
        let id: String
        let name: String
        var handle: String?
        var agent: String?
        var state: String?
        var icon_url: String?
    }

    struct Person: Codable, Hashable {
        var id: String?
        let name: String
        var avatar_url: String?
    }

    struct Message: Codable, Hashable, Identifiable {
        let id: String
        var conversation_id: String?
        var kind: String?
        let text: String
        let stage: String
        var deploy_stage: String?
        var deploy_allow: String?
        var risk: String?
        var client: String?
        var sender: Person?
        var project: Project?
        var created_at: Date?
        var updated_at: Date?
        var web_url: String?
        /// The exact text the agent gets; on waiting messages and in a conversation.
        var prompt: String?
        /// The request as agreed with the agent in review (`substrate propose`); approving sends this, never the original (2026-11-21).
        var proposal: Proposal?

        var held: Bool { !(risk ?? "").isEmpty }
    }

    struct Proposal: Codable, Hashable {
        var text: String
        var why: String?
    }

    struct Counts: Codable, Hashable {
        var waiting: Int?
        var active: Int?
        var agents: Int?
        var working: Int?
    }

    struct Dashboard: Codable {
        var counts: Counts
        var waiting: [Message]
        var active: [Message]
        var history: [Message]
        var new_session_url: String?
    }

    struct Event: Codable, Hashable {
        var seq: Int?
        var time: Date?
        var actor: String?
        var name: String?
        var kind: String?
        var text: String?
        var stage: String?
        var held: Bool?
        var avatar_url: String?
    }

    struct Conversation: Codable {
        let id: String
        var project: Project?
        var deploy_stage: String?
        var messages: [Message]
        var events: [Event]
    }

    struct Permissions: Codable, Hashable {
        var replies: Bool?
        var deploys: Bool?
        var files: Bool?
        var no_approval: Bool?
        var deploy_test: Bool?
        var deploy_production: Bool?
    }

    struct SessionCounts: Codable, Hashable {
        var messages: Int?
        var waiting: Int?
        var active: Int?
        var completed: Int?
        var deployed: Int?
    }

    struct HistoryItem: Codable, Hashable, Identifiable {
        let id: String
        var title: String?
        var project: Project?
        var deploy_stage: String?
        var events: [Event]?
    }

    struct Session: Codable, Hashable, Identifiable {
        let id: String
        let name: String
        var avatar_url: String?
        var projects: [Project]?
        var permissions: Permissions?
        var waiting: Int?
        var last_used_at: Date?
        var expires_at: Date?
        var active: Bool?
        var web_url: String?
        /// Only in GET /sessions/{id}.
        var counts: SessionCounts?
        var history: [HistoryItem]?
    }

    struct Sessions: Codable {
        var sessions: [Session]
        var new_session_url: String?
    }

    struct Agent: Codable, Hashable, Identifiable {
        let pane_id: String
        var workspace: String?
        var agent: String?
        var status: String?
        var title: String?
        /// The contract names it `project`; read as an object or as its id.
        var project: Project?
        var id: String { pane_id }

        enum CodingKeys: String, CodingKey { case pane_id, workspace, agent, status, title, project }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            pane_id = try c.decode(String.self, forKey: .pane_id)
            workspace = try c.decodeIfPresent(String.self, forKey: .workspace)
            agent = try c.decodeIfPresent(String.self, forKey: .agent)
            status = try c.decodeIfPresent(String.self, forKey: .status)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            if let p = try? c.decodeIfPresent(Project.self, forKey: .project) { project = p }
            else if let id = try? c.decodeIfPresent(String.self, forKey: .project) { project = Project(id: id, name: id) }
        }
    }

    struct Machine: Codable, Hashable, Identifiable {
        let id: String
        let name: String
        var platform: String?
        var relay_version: String?
        var online: Bool?
        var last_seen: Date?
        var agents: [Agent]
    }

    struct Machines: Codable { var machines: [Machine] }

    struct Account: Codable, Hashable {
        var id: String?
        var email: String?
        var name: String?
        var avatar_url: String?
    }

    struct Verified: Codable {
        let token: String
        var expires_in: Int?
        var account: Account?
    }

    struct Failure: LocalizedError {
        let status: Int
        let text: String
        var errorDescription: String? { text }
        var signedOut: Bool { status == 401 }
    }

    /// Deploy track (Commit, Checks, Push, CI, Deploy, Live) for a message's `deploy_stage`.
    enum StepState { case waiting, running, done, failed }
    static let steps = ["Commit", "Checks", "Push", "CI", "Deploy", "Live"]

    static func track(_ stage: String?) -> [StepState]? {
        guard let stage, !["not_deploying", "unknown"].contains(stage) else { return nil }
        let (at, state): (Int, StepState) = switch stage {
        case "committing": (0, .running)
        case "running_checks": (1, .running)
        case "pushing": (2, .running)
        case "fix_committed", "ci_running": (3, .running)
        case "ci_passed": (3, .done)
        case "ci_failed": (3, .failed)
        case "deploying": (4, .running)
        case "deployed": (4, .done)
        case "deploy_failed": (4, .failed)
        case "verified", "ready_to_retest": (5, .done)
        default: (0, .waiting)
        }
        return steps.indices.map { $0 < at ? .done : $0 == at ? state : .waiting }
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "not an ISO 8601 date: \(s)"))
        }
        return d
    }()
}

/// One Substrate account: its base URL and email are saved in UserDefaults, its token in the Keychain.
struct SubstrateConnection: Codable, Hashable, Identifiable {
    var id = UUID()
    var base = SubstrateConnection.newBase
    var email = ""
    var name: String?
    var tokenKey: String { "substrate.token.\(id.uuidString)" }
    /// -sidra.substrateBase URL (Debug builds, Simulator checks against a stub) for accounts added after launch.
    static var newBase: String {
        #if DEBUG
        if let b = UserDefaults.standard.string(forKey: "sidra.substrateBase"), !b.isEmpty { return b }
        #endif
        return Substrate.defaultBase
    }
    var host: String { URL(string: base)?.host ?? base }
}

private struct ErrorBody: Decodable { let error: String }

struct SubstrateClient: Sendable {
    let base: String
    let token: String?

    func get<T: Decodable>(_ path: String) async throws -> T { try await call("GET", path, nil) }

    func post<T: Decodable>(_ path: String, _ body: [String: String]? = nil) async throws -> T { try await call("POST", path, body) }

    func delete<T: Decodable>(_ path: String) async throws -> T { try await call("DELETE", path, nil) }

    private func call<T: Decodable>(_ method: String, _ path: String, _ body: [String: String]?) async throws -> T {
        guard let url = URL(string: base + path) else { throw Substrate.Failure(status: 0, text: "Bad address: \(base + path)") }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let text = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
                ?? (status == 429 ? "Too many tries. Wait a minute and try again." : "Substrate answered \(status).")
            throw Substrate.Failure(status: status, text: text)
        }
        return try Substrate.decoder.decode(T.self, from: data)
    }

    /// GET /live: one call per `data: changed` line until the stream ends or fails.
    func live(_ changed: @escaping @Sendable () async -> Void) async throws {
        guard let url = URL(string: base + "/live") else { return }
        var req = URLRequest(url: url, timeoutInterval: 60 * 60)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Substrate.Failure(status: status, text: "Substrate's live updates answered \(status).") }
        for try await line in bytes.lines where line.hasPrefix("data:") {
            if line.dropFirst(5).trimmingCharacters(in: .whitespaces) == "changed" { await changed() }
        }
    }
}
