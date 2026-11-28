import Foundation

/// The voice assistant (design/html/14-voice-modes.html): you talk to a blob, and a card comes up only when
/// words are not enough. Plan mode settles a plan with you; code mode tells you what each agent turn did.
/// This file is the part with no UI and no network: the cards, the tools the model may call, and the wire
/// format of OpenAI's Live API (checked against the real endpoint on 2026-11-28).
enum AssistantMode: String, CaseIterable, Sendable { case plan, code }

struct ChoiceOption: Equatable, Sendable { var title: String; var detail: String? }
struct Rival: Equatable, Sendable { var name: String; var finding: String }
struct Finding: Equatable, Sendable { var severity: String; var title: String; var detail: String?; var file: String? }
struct SpaceRow: Equatable, Sendable, Identifiable { var name: String; var status: String; var agent: String?; var id: String { name } }
struct PlanLine: Equatable, Sendable { var label: String; var text: String }

/// What a tool shows. One at a time sits under the blob; all of them stay in the thread.
enum AssistantCard: Equatable, Sendable {
    case choice(question: String, options: [ChoiceOption], recommended: Int?)
    case rivals(source: String, rivals: [Rival], gap: String?)
    case findings(source: String, findings: [Finding])
    case settled(title: String, features: [String], later: [String], fixFirst: [String])
    case newProject(name: String, folder: String, agent: String)
    case spaces([SpaceRow])
    case question(space: String, question: String, options: [String])
    case prompt(space: String, text: String)
    case turn(space: String, summary: String, verdict: String, didYouKnow: String?)
}

struct ThreadItem: Identifiable, Equatable {
    enum Body: Equatable { case user(String), assistant(String), card(AssistantCard) }
    let id = UUID()
    var body: Body
}

/// A function call from the backend model.
struct ToolCall: @unchecked Sendable {   // args is JSON: strings, numbers, arrays and dictionaries only
    let id: String
    let name: String
    let args: [String: Any]

    func string(_ k: String) -> String? { (args[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    func strings(_ k: String) -> [String] { args[k] as? [String] ?? [] }
    func dicts(_ k: String) -> [[String: Any]] { args[k] as? [[String: Any]] ?? [] }
    var confirmed: Bool { args["confirmed"] as? Bool ?? false }
}

enum AssistantTools {
    private static func tool(_ name: String, _ description: String, _ props: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        ["type": "function", "name": name, "description": description,
         "parameters": ["type": "object", "properties": props, "required": required]]
    }
    private static let str: [String: Any] = ["type": "string"]
    private static let strs: [String: Any] = ["type": "array", "items": ["type": "string"]]
    private static func objs(_ props: [String: Any], _ required: [String]) -> [String: Any] {
        ["type": "array", "items": ["type": "object", "properties": props, "required": required]]
    }
    private static let confirmed: [String: Any] = ["type": "boolean", "description": "false shows the card and waits; true only after the user said yes"]

    static let all: [[String: Any]] = [
        tool("show_choice", "Show two to four options when the answer has options. The user answers by voice or tap in the next turn.",
             ["question": str, "options": objs(["title": str, "detail": str], ["title"]), "recommended": ["type": "integer", "description": "1-based, omit if none"]],
             required: ["question", "options"]),
        tool("update_plan", "Record what is settled. Send the whole plan each time, one line per label (Goal, User, Market, Scope…).",
             ["lines": objs(["label": str, "text": str], ["label", "text"])], required: ["lines"]),
        tool("show_rivals", "Show the rivals a market check found, one line each, and the gap.",
             ["source": str, "rivals": objs(["name": str, "finding": str], ["name", "finding"]), "gap": str], required: ["rivals"]),
        tool("show_findings", "Show audit or security findings, one line each with its file.",
             ["source": ["type": "string", "description": "Code audit or Security review"],
              "findings": objs(["severity": ["type": "string", "enum": ["high", "medium", "low"]], "title": str, "detail": str, "file": str], ["severity", "title"])],
             required: ["source", "findings"]),
        tool("settle_plan", "Show the settled plan. Call it only when the user says the plan is settled.",
             ["title": str, "features": strs, "later": strs, "fix_first": strs], required: ["title", "features"]),
        tool("list_spaces", "List the herdr spaces on the machine and what each agent does now. Shows them as a card."),
        tool("switch_space", "Show another herdr space by name.", ["name": str], required: ["name"]),
        tool("new_project", "Make a new project: a folder, a herdr space and a coding agent in it, then switch there.",
             ["name": ["type": "string", "description": "short, lower case, no spaces"], "confirmed": confirmed], required: ["name"]),
        tool("prompt_agent", "Send an instruction or a slash command to the coding agent of a space. Write the instruction as a clear prompt, not the user's raw words.",
             ["space": ["type": "string", "description": "omit for the space in front"], "text": str, "confirmed": confirmed], required: ["text"]),
        tool("run_skill", "Run one of the user's skills in the coding agent of the space in front. Its result arrives later as an event.",
             ["skill": ["type": "string", "enum": ["product-planner", "app-icon-lab", "code-audit", "security-review"]], "brief": str, "confirmed": confirmed],
             required: ["skill", "brief"]),
        tool("read_agent", "Read what the coding agent of a space printed last: its answer, or the question it waits on.",
             ["space": ["type": "string", "description": "omit for the space in front"]]),
        tool("show_agent_question", "Show the question a blocked agent asks, in one line, with its options.",
             ["space": str, "question": str, "options": strs], required: ["space", "question"]),
        tool("turn_update", "Code mode: show what an agent turn did. Two sentences at most. did_you_know is one thing the user may have missed (an untested path, a spec line not built, a risk), or omit it.",
             ["space": str, "summary": str, "verdict": ["type": "string", "enum": ["clean", "watch", "broken"]], "did_you_know": str],
             required: ["space", "summary", "verdict"]),
    ]

    /// STE-80, the register of Waseem's voice-dna skill: every line the user hears or reads follows it.
    static let register = """
    How you write and speak, always:
    - One idea per sentence. Twenty words at most. Short, common words.
    - Active voice, present tense. Say what happened, then stop.
    - No filler, no praise, no "great question", no "let me", no summary of what you just said.
    - Numbers as digits. Name files and commands exactly.
    - Never read terminal output aloud. Say what it means.
    """

    static let voice = """
    You are the voice of Sidra, a developer's assistant on a phone or a headset. A backend agent thinks and uses tools; you speak its results.
    \(register)
    - Speak one or two sentences. A card on screen carries lists, options and files: do not read a card aloud, say only what it is for.
    - When the backend shows options, say "Say one, two or three" or similar. Do not list them.
    """

    static func backend(_ mode: AssistantMode) -> String {
        let common = """
        You are Sidra's assistant for a developer who works by voice on a phone. Your text is spoken and shown, so keep it short.
        \(register)
        Tools show cards. Use a card when the user must see something: options, rivals, findings, a plan, spaces. After a card, write one sentence that says what it is for.
        new_project, prompt_agent and run_skill change things: call them with confirmed false first, then with confirmed true after the user says yes.
        Messages that start with "Event:" come from Sidra, not from the user. Act on them; do not answer them as speech from the user.
        If an event says an agent waits with a question, call read_agent if you need the text, then show_agent_question.
        """
        switch mode {
        case .plan:
            return common + """

            Mode: PLAN. Hold a planning session until the user says the plan is settled.
            - Ask one question at a time. Use show_choice when the answer has options, and mark the option you would pick.
            - After each answer call update_plan with every settled line.
            - For a market check call run_skill product-planner; for an app icon, app-icon-lab; before the build, code-audit and security-review. Do not wait for them: go on with the next question. Their results arrive as events; then call show_rivals or show_findings.
            - When the user settles the plan, call settle_plan and offer code mode.
            """
        case .code:
            return common + """

            Mode: CODE. Coding agents work in herdr spaces. You report, you do not narrate.
            - When an event says an agent turn ended, call turn_update: what it did in two sentences at most, a verdict, and did_you_know if there is one real thing the user may have missed. No did_you_know is better than a weak one.
            - When the user gives an instruction for the agent, call prompt_agent with a clear prompt.
            """
        }
    }
}

// MARK: - Live API wire format

enum LiveEvent: @unchecked Sendable {
    case started
    case audio(Data)            // 24 kHz mono 16-bit PCM
    case heard(String)          // the user's speech, as it is transcribed
    case said(String)           // the voice's speech, as it is transcribed
    case text(String)           // the backend's whole answer
    case call(ToolCall)
    case responseDone
    case usage(seconds: Int)
    case closed(String)
    case error(String)
    case other
}

enum LiveCodec {
    static let url = URL(string: "wss://api.openai.com/v1/live/sessions")!
    static let voiceModel = "gpt-live-1.1", backendModel = "gpt-6-luna"
    static let rate = 24_000.0

    static func delegation(_ mode: AssistantMode) -> [String: Any] {
        ["type": "responses", "responses": ["model": backendModel, "instructions": AssistantTools.backend(mode), "tools": AssistantTools.all]]
    }

    static func start(_ mode: AssistantMode) -> [String: Any] {
        ["type": "session.start", "session": [
            "model": voiceModel, "instructions": AssistantTools.voice,
            "audio": ["format": ["type": "audio/pcm", "rate": Int(rate)], "output": ["voice": "marin"]],
            "delegation": delegation(mode)]]
    }

    /// A mode switch keeps the session: only the backend's instructions change. The type must be named again.
    static func update(_ mode: AssistantMode) -> [String: Any] {
        ["type": "session.update", "session": ["delegation": delegation(mode)]]
    }

    static func audio(_ pcm: Data) -> [String: Any] { ["type": "session.input_audio.append", "audio": pcm.base64EncodedString()] }

    /// A typed message (role user) or something Sidra saw (role developer, text starts with "Event:"). Two frames:
    /// the item, then the request to answer it.
    static func message(_ text: String, role: String = "user") -> [[String: Any]] {
        [["type": "response.item.create", "item": ["type": "message", "role": role, "content": [["type": "input_text", "text": text]]]],
         ["type": "response.create"]]
    }

    static func result(_ id: String, _ output: String) -> [String: Any] {
        ["type": "response.item.create", "item": ["type": "function_call_output", "call_id": id, "output": output]]
    }
    static let resume: [String: Any] = ["type": "response.create"]
    static let close: [String: Any] = ["type": "session.close"]

    static func parse(_ data: Data) -> LiveEvent {
        guard let e = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = e["type"] as? String else { return .other }
        switch type {
        case "session.started": return .started
        case "session.output_audio.delta": return (e["delta"] as? String).flatMap { Data(base64Encoded: $0) }.map(LiveEvent.audio) ?? .other
        case "session.input_transcript.delta": return .heard(e["delta"] as? String ?? "")
        case "session.output_transcript.delta": return .said(e["delta"] as? String ?? "")
        case "session.usage.updated": return .usage(seconds: (e["usage"] as? [String: Any])?["seconds"] as? Int ?? 0)
        case "session.closed": return .closed(e["reason"] as? String ?? "closed")
        case "error": return .error((e["error"] as? [String: Any])?["message"] as? String ?? "The voice service reported an error")
        case "response.event":
            guard let inner = e["event"] as? [String: Any], let t = inner["type"] as? String else { return .other }
            switch t {
            case "response.output_text.done": return .text(inner["text"] as? String ?? "")
            case "response.completed": return .responseDone
            case "response.output_item.done":
                // The call is read here: an arguments event alone does not name it.
                guard let item = inner["item"] as? [String: Any], item["type"] as? String == "function_call",
                      let id = item["call_id"] as? String, let name = item["name"] as? String else { return .other }
                let args = (item["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                return .call(ToolCall(id: id, name: name, args: args))
            default: return .other
            }
        default: return .other
        }
    }
}

/// The connection to the Live API. `FakeLive` in the tests stands in for it.
protocol LiveLink: AnyObject, Sendable {
    func send(_ json: [String: Any])
    var events: AsyncStream<LiveEvent> { get }
    func close()
}
