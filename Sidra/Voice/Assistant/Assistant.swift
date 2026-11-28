import Foundation
import Observation
import AVFoundation
import SidraSSH
import SidraWorkspace

struct AgentState: Equatable, Sendable { var space: String; var pane: String; var status: MuxStatus }

/// What the assistant can do on the machine. `HerdrHost` does it through herdr; the tests use a fake.
@MainActor
protocol AssistantHost: AnyObject {
    func spaces() -> [SpaceRow]
    func agents() -> [AgentState]
    func frontSpace() -> String?
    func folder(forNew name: String) -> String
    func switchSpace(_ name: String) async -> Bool
    func newProject(_ name: String) async -> Bool
    /// nil space: the one in front. False when no agent took the text.
    func prompt(space: String?, text: String) async -> Bool
    func read(space: String?) async -> String?
}

@MainActor @Observable
final class Assistant {
    static let shared = Assistant()

    enum Phase: Equatable { case off, connecting, ready, failed(String) }

    private(set) var phase: Phase = .off
    private(set) var mode: AssistantMode = .plan
    private(set) var thread: [ThreadItem] = []
    /// The line over the blob: what Sidra said last.
    private(set) var said = ""
    /// Under the blob: what it hears now.
    private(set) var heard = ""
    private(set) var plan: [PlanLine] = []
    /// The card under the blob; nil shows the big blob alone.
    private(set) var card: AssistantCard?
    /// The backend works on an answer.
    private(set) var thinking = false
    /// Loudness 0…1 of the voice or the microphone.
    private(set) var level = 0.0
    private(set) var holding = false
    private(set) var seconds = 0
    /// The screen is up; false with a live session shows the floating blob.
    var open = false
    var showThread = false
    /// Speak and listen. Off: the same session by text and cards only.
    var voiceOn: Bool = UserDefaults.standard.object(forKey: "sidra.assistant.voice") as? Bool ?? true {
        didSet { UserDefaults.standard.set(voiceOn, forKey: "sidra.assistant.voice"); if !voiceOn { audio.stop() } else if phase == .ready { startAudio() } }
    }

    var active: Bool { phase == .ready || phase == .connecting }

    private var link: (any LiveLink)?
    private var host: (any AssistantHost)?
    private let audio = AssistantAudio()
    private var pump: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var saidBuffer = ""
    private var answeredByBackend = false
    /// Calls of the response in flight; their results go back together, then one resume.
    private var pendingCalls = 0
    /// Skills started through run_skill, by pane: their end is reported in plan mode too.
    private var skills: [String: String] = [:]
    private var lastStatus: [String: MuxStatus] = [:]

    // MARK: Key

    static let keychainKey = "openai-api-key"
    static var apiKey: String? {
        if let k = KeychainStore.string(for: keychainKey), !k.isEmpty { return k }
        #if DEBUG
        return ProcessInfo.processInfo.environment["OPENAI_API_KEY"]   // simulator runs
        #else
        return nil
        #endif
    }

    // MARK: Session

    func start(_ mode: AssistantMode, host: any AssistantHost, link: (any LiveLink)? = nil) {
        guard !active else { open = true; return }
        guard let link = link ?? Self.apiKey.map({ LiveSocket(key: $0) }) else {
            phase = .failed("Add your OpenAI key in Settings › Voice."); open = true; return
        }
        self.mode = mode; self.host = host; self.link = link
        thread = []; plan = []; card = nil; said = ""; heard = ""; seconds = 0; skills = [:]
        lastStatus = Dictionary(host.agents().map { ($0.pane, $0.status) }, uniquingKeysWith: { a, _ in a })
        phase = .connecting; open = true
        link.send(LiveCodec.start(mode))
        pump = Task { [weak self] in
            for await event in link.events { await self?.handle(event) }
        }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.checkAgents()
            }
        }
    }

    func stop() {
        pump?.cancel(); watcher?.cancel()
        link?.close(); link = nil
        audio.stop()
        phase = .off; open = false; thinking = false; holding = false; level = 0
    }

    func setMode(_ m: AssistantMode) {
        guard m != mode else { return }
        mode = m; card = nil
        link?.send(LiveCodec.update(m))
        event("the user switched to \(m.rawValue) mode. Say so in one sentence and go on.")
    }

    // MARK: Input

    /// Typed text, a tapped option, or a tapped button: all reach the backend as the user's words.
    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, phase == .ready else { return }
        thread.append(ThreadItem(body: .user(t)))
        thinking = true; answeredByBackend = false
        LiveCodec.message(t).forEach { link?.send($0) }
    }

    /// Something Sidra saw: an agent ended a turn, an agent waits, the user switched mode.
    func event(_ text: String) {
        guard phase == .ready else { return }
        thinking = true; answeredByBackend = false
        LiveCodec.message("Event: " + text, role: "developer").forEach { link?.send($0) }
    }

    /// Hold to talk: frames leave the device only while the mic is held.
    func hold(_ down: Bool) {
        guard phase == .ready, voiceOn, holding != down else { return }
        holding = down
        if down { flushSaid(); heard = "" }
        audio.listen(down)
        // The service ends a turn on silence, and a released mic sends none: send it half a second.
        if !down { link?.send(LiveCodec.audio(Data(count: Int(LiveCodec.rate)))) }
    }

    func dismissCard() { card = nil }

    func pick(_ row: SpaceRow) {
        Task { if await host?.switchSpace(row.name) == true { card = nil; said = "Now showing \(row.name)." } }
    }

    // MARK: Events from the service

    func handle(_ event: LiveEvent) async {
        switch event {
        case .started:
            phase = .ready
            if voiceOn { startAudio() }
            self.event(mode == .plan ? "the session started in plan mode. Ask what the user wants to build, in one sentence."
                                     : "the session started in code mode. Say in one sentence that you report each agent turn.")
        case .audio(let pcm):
            if voiceOn, !holding { audio.play(pcm) }
        case .heard(let delta):
            heard += delta
        case .said(let delta):
            saidBuffer += delta
            if !answeredByBackend { said = saidBuffer.trimmingCharacters(in: .whitespaces) }
        case .text(let text):
            flushHeard()
            answeredByBackend = true; saidBuffer = ""
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { said = t; thread.append(ThreadItem(body: .assistant(t))) }
            thinking = false
        case .call(let call):
            flushHeard()
            pendingCalls += 1
            link?.send(LiveCodec.result(call.id, await run(call)))
        case .responseDone:
            // A response that ended in calls waits for their results: one resume after the last. Events come
            // one at a time, so every result is sent by now.
            if pendingCalls > 0 { pendingCalls = 0; link?.send(LiveCodec.resume) } else { thinking = false }
        case .usage(let s):
            seconds = s
        case .closed(let reason):
            audio.stop()
            phase = reason == "close_requested" ? .off : .failed(Self.closeText(reason))
            thinking = false
        case .error(let message):
            thinking = false
            thread.append(ThreadItem(body: .assistant("The voice service reported: " + message)))
        case .other:
            break
        }
    }

    static func closeText(_ reason: String) -> String {
        switch reason {
        case "expired": "The session reached its time limit. Start it again."
        case "connection_lost", "remote_hangup": "The connection was lost. Start the session again."
        case "content": "The voice service ended the session."
        default: reason
        }
    }

    /// The user's speech is one thread item, placed before the answer to it.
    private func flushHeard() {
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        if !h.isEmpty { thread.append(ThreadItem(body: .user(h))); thinking = true; answeredByBackend = false }
        heard = ""
    }

    /// The voice answered small talk itself, without the backend: keep what it said.
    private func flushSaid() {
        let s = saidBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty, !answeredByBackend { thread.append(ThreadItem(body: .assistant(s))) }
        saidBuffer = ""
    }

    private func startAudio() {
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                voiceOn = false
                thread.append(ThreadItem(body: .assistant("Sidra may not use the microphone. Turn it on in Settings, or type.")))
                return
            }
            let link = link
            audio.onChunk = { link?.send(LiveCodec.audio($0)) }
            audio.onLevel = { [weak self] l in self?.level = l }
            do { try audio.start() } catch { voiceOn = false; thread.append(ThreadItem(body: .assistant("Could not start the microphone: \(error.localizedDescription)"))) }
        }
    }

    // MARK: Tools

    private func show(_ c: AssistantCard) { card = c; thread.append(ThreadItem(body: .card(c))) }

    /// Runs one call and returns what the backend reads as its result.
    func run(_ call: ToolCall) async -> String {
        guard let host else { return "No machine is connected." }
        switch call.name {
        case "show_choice":
            let options = call.dicts("options").compactMap { o in (o["title"] as? String).map { ChoiceOption(title: $0, detail: o["detail"] as? String) } }
            guard !options.isEmpty else { return "No options given." }
            show(.choice(question: call.string("question") ?? "", options: options, recommended: call.args["recommended"] as? Int))
            return "Shown. The user answers in the next turn."
        case "update_plan":
            plan = call.dicts("lines").compactMap { l in
                guard let label = l["label"] as? String, let text = l["text"] as? String else { return nil }
                return PlanLine(label: label, text: text)
            }
            return "Saved \(plan.count) lines."
        case "show_rivals":
            let rivals = call.dicts("rivals").compactMap { r in (r["name"] as? String).map { Rival(name: $0, finding: r["finding"] as? String ?? "") } }
            show(.rivals(source: call.string("source") ?? "Product planner", rivals: rivals, gap: call.string("gap")))
            return "Shown."
        case "show_findings":
            let findings = call.dicts("findings").compactMap { f in
                (f["title"] as? String).map { Finding(severity: f["severity"] as? String ?? "medium", title: $0, detail: f["detail"] as? String, file: f["file"] as? String) }
            }
            show(.findings(source: call.string("source") ?? "Code audit", findings: findings))
            return "Shown. The user says per finding: fix first or park."
        case "settle_plan":
            show(.settled(title: call.string("title") ?? "Plan", features: call.strings("features"), later: call.strings("later"), fixFirst: call.strings("fix_first")))
            return "Shown."
        case "list_spaces":
            let rows = host.spaces()
            guard !rows.isEmpty else { return "No herdr tab is open in Sidra, so no spaces are known." }
            show(.spaces(rows))
            return rows.map { "\($0.name): \($0.agent ?? "no agent") \($0.status)" }.joined(separator: "; ")
        case "switch_space":
            let name = call.string("name") ?? ""
            if await host.switchSpace(name) { card = nil; return "Now showing \(name)." }
            return "No space matches \(name). Spaces: " + host.spaces().map(\.name).joined(separator: ", ")
        case "new_project":
            guard let name = call.string("name").map(Self.projectName), !name.isEmpty else { return "A project needs a name." }
            guard call.confirmed else {
                show(.newProject(name: name, folder: host.folder(forNew: name), agent: CodingAgent.startOnNewSpace ?? "none"))
                return "Card shown. Ask the user to confirm, then call again with confirmed true."
            }
            card = nil
            return await host.newProject(name) ? "Made \(name) and switched to it." : "herdr could not make the project."
        case "prompt_agent":
            guard let text = call.string("text") else { return "No text to send." }
            let space = call.string("space") ?? host.frontSpace()
            guard call.confirmed else {
                show(.prompt(space: space ?? "the space in front", text: text))
                return "Card shown. Ask the user to confirm, then call again with confirmed true."
            }
            card = nil
            return await host.prompt(space: space, text: text) ? "Sent." : "No agent in that space took the text."
        case "run_skill":
            guard let skill = call.string("skill") else { return "Name a skill." }
            let brief = call.string("brief") ?? ""
            let text = "/" + skill + (brief.isEmpty ? "" : " " + brief)
            let space = host.frontSpace()
            guard call.confirmed else {
                show(.prompt(space: space ?? "the space in front", text: text))
                return "Card shown. Ask the user to confirm, then call again with confirmed true."
            }
            card = nil
            guard await host.prompt(space: space, text: text) else { return "No agent in the space in front took the skill." }
            if let pane = host.agents().first(where: { $0.space == space })?.pane { skills[pane] = skill }
            return "Started. Its result arrives as an event. Go on with the session."
        case "read_agent":
            return Self.tail(await host.read(space: call.string("space")) ?? "") .nonEmpty ?? "Nothing to read."
        case "show_agent_question":
            show(.question(space: call.string("space") ?? "", question: call.string("question") ?? "", options: call.strings("options")))
            return "Shown. When the user answers, call prompt_agent with the answer and confirmed true."
        case "turn_update":
            show(.turn(space: call.string("space") ?? "", summary: call.string("summary") ?? "", verdict: call.string("verdict") ?? "clean", didYouKnow: call.string("did_you_know")))
            return "Shown."
        default:
            return "Unknown tool \(call.name)."
        }
    }

    /// A folder and space name: lower case, dashes, nothing a shell reads.
    nonisolated static func projectName(_ raw: String) -> String {
        let s = raw.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(s).split(separator: "-").joined(separator: "-")
    }

    /// The end of a terminal read: enough for one turn, small enough for the backend.
    nonisolated static func tail(_ text: String, limit: Int = 4000) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= limit ? t : String(t.suffix(limit))
    }

    // MARK: Agents

    /// What changed between two looks at the agents: turns that ended and agents that started to wait.
    nonisolated static func changes(from old: [String: MuxStatus], to new: [AgentState]) -> (ended: [AgentState], blocked: [AgentState]) {
        var ended: [AgentState] = [], blocked: [AgentState] = []
        for a in new {
            guard let before = old[a.pane], before != a.status else { continue }
            if a.status == .blocked { blocked.append(a) }
            else if before == .working, a.status == .done || a.status == .idle { ended.append(a) }
        }
        return (ended, blocked)
    }

    func checkAgents() async {
        guard phase == .ready, let host else { return }
        let now = host.agents()
        let (ended, blocked) = Self.changes(from: lastStatus, to: now)
        lastStatus = Dictionary(now.map { ($0.pane, $0.status) }, uniquingKeysWith: { a, _ in a })
        for a in blocked {
            let screen = Self.tail(await host.read(space: a.space) ?? "", limit: 2500)
            event("the agent in space \(a.space) waits with a question. Its terminal shows:\n\(screen)")
        }
        for a in ended {
            let skill = skills.removeValue(forKey: a.pane)
            guard mode == .code || skill != nil else { continue }   // plan mode stays quiet about ordinary turns
            let screen = Self.tail(await host.read(space: a.space) ?? "")
            event((skill.map { "the skill \($0) finished in space \(a.space)." } ?? "the agent in space \(a.space) ended a turn.") + " Its terminal shows:\n\(screen)")
        }
    }

    // MARK: Demo

    /// The design's screens without a network, for the simulator: -sidra.assistantDemo <plan|code|thread>.
    func demo(_ which: String) {
        phase = .ready; open = true; seconds = 74
        plan = [PlanLine(label: "Goal", text: "A serial plotter for iPad."), PlanLine(label: "User", text: "People who flash boards without a Mac."),
                PlanLine(label: "Market", text: "No rival reads USB on iPad.")]
        let choice = AssistantCard.choice(question: "What does version 1 plot?", options: [
            ChoiceOption(title: "Numbers on one line", detail: "Reads what Serial.println sends. Smallest build."),
            ChoiceOption(title: "Named values", detail: "Reads temp:21.4 pairs. One line per name."),
            ChoiceOption(title: "Binary frames", detail: "Needs a format editor. Largest build.")], recommended: 1)
        let turn = AssistantCard.turn(space: "plotter", summary: "Wrote the serial line parser. 9 tests pass. One test for empty lines fails.", verdict: "watch",
                                      didYouKnow: "The parser drops a line longer than 256 bytes. No test covers that.")
        thread = [ThreadItem(body: .user("A serial plotter for iPad. Numbers first, the labels can wait.")),
                  ThreadItem(body: .assistant("Version 1 plots numbers on one line.")), ThreadItem(body: .card(choice)),
                  ThreadItem(body: .user("The first one.")), ThreadItem(body: .card(turn))]
        switch which {
        case "code": mode = .code; said = "Turn 4 ended. One test fails."; card = turn
        case "thread": mode = .plan; said = "What does version 1 plot?"; showThread = true
        case "talk": mode = .plan; said = "What does version 1 plot?"; heard = "numbers first, the labels can wait"; level = 0.6
        default: mode = .plan; said = "What does version 1 plot?"; card = choice
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - herdr

/// The assistant's hands: the first herdr tab of the window in front.
@MainActor
final class HerdrHost: AssistantHost {
    private let app: AppModel
    init(app: AppModel) { self.app = app }

    private var located: (tab: UUID, monitor: MuxMonitor)? {
        for tab in app.workspace.tabs {
            for pane in tab.panes { if let m = MuxMonitors.shared.monitor(for: pane, app: app) { return (tab.id, m) } }
        }
        return nil
    }
    private var monitor: MuxMonitor? { located?.monitor }

    func spaces() -> [SpaceRow] {
        guard let s = monitor?.snapshot else { return [] }
        return s.workspaces.sorted { $0.number < $1.number }.map { ws in
            SpaceRow(name: ws.label, status: ws.agent_status.rawValue, agent: s.agents(in: ws.id).first?.agent)
        }
    }

    func agents() -> [AgentState] {
        guard let s = monitor?.snapshot else { return [] }
        let names = Dictionary(s.workspaces.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
        return s.agents.map { AgentState(space: names[$0.workspace_id] ?? $0.workspace_id, pane: $0.pane_id, status: $0.agent_status) }
    }

    func frontSpace() -> String? {
        guard let s = monitor?.snapshot else { return nil }
        return s.workspaces.first { $0.id == s.focused_workspace_id }?.label
    }

    func folder(forNew name: String) -> String { (monitor?.projectRoot ?? "~") + "/" + name }

    /// A spoken name is loose: "push left" finds "🚀 pushleft".
    nonisolated static func match(_ spoken: String, in labels: [String]) -> String? {
        func key(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }
        let want = key(spoken)
        guard !want.isEmpty else { return nil }
        return labels.first { key($0) == want } ?? labels.first { key($0).contains(want) } ?? labels.first { !key($0).isEmpty && want.contains(key($0)) }
    }

    private func workspace(_ name: String?) -> MuxSnapshot.Workspace? {
        guard let s = monitor?.snapshot else { return nil }
        guard let name else { return s.workspaces.first { $0.id == s.focused_workspace_id } }
        return Self.match(name, in: s.workspaces.map(\.label)).flatMap { label in s.workspaces.first { $0.label == label } }
    }

    func switchSpace(_ name: String) async -> Bool {
        guard let l = located, let ws = workspace(name) else { return false }
        await l.monitor.focus(app, ws)
        app.workspace.select(tab: l.tab)
        return true
    }

    func newProject(_ name: String) async -> Bool {
        guard let m = monitor else { return false }
        if m.projectRoots.isEmpty { await m.findProjectRoots(app) }
        return await m.newSpace(app, label: name, folder: folder(forNew: name))
    }

    private func pane(_ space: String?) -> String? {
        guard let s = monitor?.snapshot, let ws = workspace(space) else { return nil }
        return s.agents(in: ws.id).first?.pane_id
    }

    func prompt(space: String?, text: String) async -> Bool {
        guard let m = monitor, let pane = pane(space) else { return false }
        return await m.broadcast(app, text, to: [pane])?.isEmpty == true
    }

    func read(space: String?) async -> String? {
        guard let m = monitor, let pane = pane(space) else { return nil }
        let cmd = "herdr" + Herdr.sessionArg(m.session) + " agent read " + Herdr.shellQuote(pane) + " --lines 80 --format text"
        return (try? await app.herdrRun(m.target, cmd))?.stdoutText
    }
}
