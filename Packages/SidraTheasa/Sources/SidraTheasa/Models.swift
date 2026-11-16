import Foundation

// Response shapes of the Theasa server (src/server.ts). Property names are the JSON keys as sent:
// a snake_case key strategy would also rewrite dictionary keys (file paths in `diffs`, tool names).
// Anything the server can leave out or send as null is optional.

public enum Verdict: String, Codable, Sendable { case clean, watch, broken }

public struct Health: Codable, Sendable {
    public let status: String
    public let version: String
    public let turns: Int
    public let queue: Int
    public let failed: Int
    public let db_bytes: Int
}

public struct Project: Codable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let key: String?
    public let name: String
    public let repo_name: String?
    public let root: String?
    public let remote: String?
    public let hidden: Bool?
    public let has_icon: Bool?
    public let icon_url: String?
    public let initial: String?
    public let icon_locked: Bool?
}

/// Row of GET /api/projects.
public struct ProjectRow: Codable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let hidden: Bool?
    public let icon_url: String?
    public let initial: String?
    public let last_at: String?
    public let turns: Int
    public let tokens: Int
    public let cost: Double?
    public let agent_ms: Int
    public let open_watch: Int
    public let machines: [String]
    public var project: Project {
        Project(id: id, key: nil, name: name, repo_name: nil, root: nil, remote: nil, hidden: hidden, has_icon: nil,
                icon_url: icon_url, initial: initial, icon_locked: nil)
    }
}

// MARK: Pulse

public struct Pulse: Codable, Sendable {
    public struct Totals: Codable, Sendable {
        public let turns: Int
        public let agent_ms: Int
        public let tokens: Int
        public let cache_share: Double
        public let cost: Double?
        public let priced: Int
        public let by_agent: [String: Int]
    }
    public struct Bar: Codable, Sendable { public let label: String; public let day: String?; public let claude: Int; public let codex: Int }
    public struct Day: Codable, Sendable { public let day: String; public let items: [Item] }
    public struct Item: Codable, Sendable {
        public let project: Project
        public let turns: Int
        public let agents: [String]
        public let last_at: String?
        public let health: Verdict?
        public let pending: Int
        public let bullets: [Bullet]
        public let decisions: Int
        public let watch: Int
        public let files: Int
    }
    public struct Bullet: Codable, Sendable { public let turn_id: Int; public let text: String; public let verdict: Verdict? }
    public struct Attention: Codable, Sendable, Identifiable {
        public let id: Int; public let text: String; public let impact: String
        public let created_at: String; public let turn_id: Int; public let project: Project?
    }
    public struct Decision: Codable, Sendable, Identifiable {
        public let id: Int; public let text: String; public let created_at: String; public let turn_id: Int; public let project: Project?
    }
    public struct Worker: Codable, Sendable {
        public let written: Int; public let tokens: Int; public let cost: Double?
        public let queued: Int; public let running: Int; public let failed: Int; public let median_delay_s: Int?
    }
    public struct Active: Codable, Sendable { public let agent: String; public let session_id: String; public let machine: String?; public let project: String? }

    public let totals: Totals
    public let bars: [Bar]
    public let days: [Day]
    public let attention: [Attention]
    public let open_watch: Int
    public let decisions: [Decision]
    public let decisions_count: Int
    public let worker: Worker
    public let active: [Active]
}

// MARK: Turns

public struct Tokens: Codable, Sendable, Hashable {
    public let input: Int; public let output: Int; public let cache_read: Int; public let cache_write: Int
    public var totalIn: Int { input + cache_read + cache_write }
}

public struct FileChange: Codable, Sendable, Hashable { public let path: String; public let add: Int; public let del: Int }

public struct Step: Codable, Sendable, Hashable { public let at: String; public let title: String; public let text: String; public let tone: String? }

public struct Note: Codable, Sendable, Hashable {
    public let kind: String   // decision | watch
    public let id: Int
    public let text: String
    public let impact: String?
    public let status: String?
}

public struct Turn: Codable, Sendable, Identifiable {
    public let id: Int
    public let agent: String
    public let session_id: String
    public let machine: String?
    public let cwd: String?
    public let branch: String?
    public let head: String?
    public let started_at: String
    public let ended_at: String?
    public let duration_ms: Int?
    public let tool_ms: Int?
    public let prompt: String
    public let model: String?
    public let tokens: Tokens
    public let model_calls: Int?
    public let cost: Double?
    public let tools: [String: Int]?
    public let files: [FileChange]?
    public let headline: String?
    public let summary: [String]?
    public let verdict: Verdict?
    public let steps: [Step]?
    public let summary_status: String?
    public let summary_error: String?
    public let decisions: Int?
    public let watch: Int?
    public let att_in: Int?
    public let att_out: Int?
    public let notes: [Note]?
    // Only on GET /api/turns/:id
    public let final_text: String?
    public let diffs: [String: String]?

    public var isPending: Bool { summary_status == "queued" || summary_status == "running" }
    public var isFailed: Bool { summary_status == "failed" }
    /// A card on the timeline: it has notes, files, attachments or broke.
    public var isHeavy: Bool {
        !isPending && !isFailed && headline != nil
            && (!(notes ?? []).isEmpty || !(files ?? []).isEmpty || (att_in ?? 0) > 0 || (att_out ?? 0) > 0 || verdict == .broken)
    }
    /// A one-line turn that may fold into "Show n more quiet turns".
    public var isQuiet: Bool { !isHeavy && !isPending && !isFailed && headline != nil }
}

public struct Decision: Codable, Sendable, Identifiable {
    public let id: Int
    public let turn_id: Int
    public let text: String
    public let why: String?
    public let alternative: String?
    public let status: String   // active | dismissed | superseded
    public let superseded_by: Int?
    public let created_at: String
    public let agent: String?
}

public struct WatchItem: Codable, Sendable, Identifiable {
    public let id: Int
    public let turn_id: Int
    public let text: String
    public let impact: String   // high | medium | low
    public let status: String   // open | done
    public let done_at: String?
    public let created_at: String
    public let agent: String?
}

public struct ProjectDetail: Codable, Sendable {
    public struct Machine: Codable, Sendable { public let machine: String?; public let n: Int }
    public struct Totals: Codable, Sendable { public let turns: Int; public let agent_ms: Int; public let tokens: Int; public let cost: Double? }
    public struct Session: Codable, Sendable { public let agent: String; public let session_id: String; public let machine: String?; public let last_at: String?; public let active: Bool }
    public let project: Project
    public let first_at: String?
    public let last_at: String?
    public let total_turns: Int
    public let machines: [Machine]
    public let totals: Totals
    public let hist: [Int]
    public let turns: [Turn]
    public let decisions: [Decision]
    public let watch: [WatchItem]
    public let sessions: [Session]
}

public struct Attachment: Codable, Sendable, Identifiable {
    public let id: Int
    public let dir: String    // in | out
    public let kind: String   // image | file | document | artifact | sent
    public let name: String
    public let url: String?
    public let media_type: String?
    public let count: Int?
    public let src: String?
    /// Artifacts only ever live on claude.ai; anything else is shown as text, never a link.
    public var artifactLink: URL? {
        guard let url, url.hasPrefix("https://claude.ai/") else { return nil }
        return URL(string: url)
    }
}

public struct TurnDetail: Codable, Sendable {
    public struct Job: Codable, Sendable { public let model: String?; public let status: String?; public let finished_at: String? }
    public struct Session: Codable, Sendable { public let index: Int; public let count: Int; public let first_at: String? }
    public let turn: Turn
    public let attachments: [Attachment]
    public let project: Project
    public let decisions: [Decision]
    public let watch: [WatchItem]
    public let job: Job?
    public let job_count: Int
    public let session: Session
    public let prev: Int?
    public let next: Int?
    public let resume: String
}

public struct SearchHit: Codable, Sendable, Identifiable {
    public let id: Int
    public let project_id: Int?
    public let agent: String
    public let started_at: String
    public let headline: String?
    public let prompt: String
    public let verdict: Verdict?
    public let snippet: String
    public let project: Project
}

// MARK: Live agents (herdr on the Theasa machine)

public struct AgentsResponse: Codable, Sendable {
    public let available: Bool
    public let error: String?
    public let agents: [LiveAgent]
    public init(available: Bool, error: String?, agents: [LiveAgent]) { self.available = available; self.error = error; self.agents = agents }
}

public struct LiveAgent: Codable, Sendable, Identifiable {
    public struct ProjectRef: Codable, Sendable { public let id: Int?; public let name: String?; public let icon_url: String?; public let initial: String? }
    public struct Question: Codable, Sendable, Hashable {
        public struct Option: Codable, Sendable, Hashable {
            public let label: String
            public let description: String?
            /// Claude's option preview: an ASCII mockup, code or markdown, up to 8000 characters.
            public let preview: String?
        }
        public let question: String
        public let header: String?
        public let multiSelect: Bool?
        public let options: [Option]
    }
    public struct Screen: Codable, Sendable {
        public struct Option: Codable, Sendable, Hashable { public let label: String; public let keys: [String]; public let selected: Bool? }
        public let text: String
        public let options: [Option]
    }
    public struct Last: Codable, Sendable { public let turn_id: Int; public let headline: String?; public let text: String?; public let question: String?; public let ended_at: String? }

    public let pane_id: String
    public let agent: String
    public let status: String   // blocked | done | idle | working | unknown
    public let title: String?
    public let cwd: String?
    public let session_id: String?
    public let since: String?
    public let project: ProjectRef?
    public let ask: [Question]?
    /// What the agent showed with its question: its text just before, files it sent, artifacts.
    public let ask_extras: AskExtras?
    public let screen: Screen?
    public let last: Last?
    public var id: String { pane_id }

    public struct AskExtras: Codable, Sendable {
        public let context: String?
        public let attachments: [AskAttachment]
    }
    public struct AskAttachment: Codable, Sendable, Identifiable, Hashable {
        public let id: Int
        public let kind: String   // sent | artifact
        public let name: String   // a full path for sent files, a title for artifacts
        public let url: String?
        public let media_type: String?
        public let src: String?   // a raster image to GET (with the token)
        public var basename: String { (name as NSString).lastPathComponent }
        public var isImage: Bool { kind == "sent" && src != nil }
        /// Artifacts link out only to claude.ai.
        public var artifactLink: URL? { guard kind == "artifact", let url, url.hasPrefix("https://claude.ai/") else { return nil }; return URL(string: url) }
    }

    /// Drafts and picks are keyed per pane and session, so a new session in the pane starts clean.
    public func draftKey(_ k: String) -> String { "\(pane_id)|\(session_id ?? "")|\(k)" }
}
