import XCTest
@testable import Sidra

/// Records what the assistant sends; the tests feed events to `Assistant.handle` themselves.
final class FakeLive: LiveLink, @unchecked Sendable {
    private(set) var sent: [[String: Any]] = []
    let events: AsyncStream<LiveEvent> = AsyncStream { _ in }
    func send(_ json: [String: Any]) { sent.append(json) }
    func close() {}
    var types: [String] { sent.compactMap { $0["type"] as? String } }
    /// The text of the last message item sent (a typed line or an event).
    var lastMessage: String? {
        sent.last { ($0["item"] as? [String: Any])?["type"] as? String == "message" }
            .flatMap { ($0["item"] as? [String: Any])?["content"] as? [[String: Any]] }?.first?["text"] as? String
    }
    var results: [String] { sent.compactMap { ($0["item"] as? [String: Any]).flatMap { $0["type"] as? String == "function_call_output" ? $0["output"] as? String : nil } } }
}

@MainActor
final class FakeHost: AssistantHost {
    var list = [AgentState(space: "plotter", pane: "p1", status: .working), AgentState(space: "pushleft", pane: "p2", status: .idle)]
    var made: [String] = [], prompts: [String] = [], shown: [String] = []
    var screen = "9 passed, 1 failed"
    func spaces() -> [SpaceRow] { list.map { SpaceRow(name: $0.space, status: $0.status.rawValue, agent: "claude") } }
    func agents() -> [AgentState] { list }
    func frontSpace() -> String? { "plotter" }
    func folder(forNew name: String) -> String { "~/Development/" + name }
    func switchSpace(_ name: String) async -> Bool { shown.append(name); return list.contains { $0.space == name } }
    func newProject(_ name: String) async -> Bool { made.append(name); return true }
    func prompt(space: String?, text: String) async -> Bool { prompts.append((space ?? "front") + ": " + text); return true }
    func read(space: String?) async -> String? { screen }
}

@MainActor
final class AssistantTests: XCTestCase {
    private func json(_ s: String) -> LiveEvent { LiveCodec.parse(Data(s.utf8)) }

    // MARK: Wire format (shapes copied from the real service, 2026-11-28)

    func testParsesAFunctionCallFromItsDoneItem() {
        let e = json(#"{"type":"response.event","delegation_id":"d","event":{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","id":"fc_1","call_id":"call_9","name":"new_project","arguments":"{\"name\":\"plotter\",\"confirmed\":true}","status":"completed"}}}"#)
        guard case .call(let c) = e else { return XCTFail("not a call: \(e)") }
        XCTAssertEqual(c.id, "call_9"); XCTAssertEqual(c.name, "new_project")
        XCTAssertEqual(c.string("name"), "plotter"); XCTAssertTrue(c.confirmed)
    }

    func testAReasoningItemIsNotACall() {
        if case .call = json(#"{"type":"response.event","event":{"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_1"}}}"#) { XCTFail("a reasoning item read as a call") }
    }

    func testParsesTextAudioTranscriptsAndErrors() {
        if case .text(let t) = json(#"{"type":"response.event","event":{"type":"response.output_text.done","text":"The plotter space is open."}}"#) { XCTAssertEqual(t, "The plotter space is open.") } else { XCTFail() }
        if case .audio(let d) = json(#"{"type":"session.output_audio.delta","delta":"AAECAw=="}"#) { XCTAssertEqual(d.count, 4) } else { XCTFail() }
        if case .heard(let h) = json(#"{"type":"session.input_transcript.delta","delta":" numbers","start_ms":0,"end_ms":200}"#) { XCTAssertEqual(h, " numbers") } else { XCTFail() }
        if case .error(let m) = json(#"{"type":"error","error":{"code":"missing_required_parameter","message":"Missing required parameter: 'session.delegation.type'."}}"#) { XCTAssertTrue(m.contains("delegation.type")) } else { XCTFail() }
        if case .closed(let r) = json(#"{"type":"session.closed","reason":"expired"}"#) { XCTAssertEqual(r, "expired") } else { XCTFail() }
        if case .other = json("not json") {} else { XCTFail("bad input must not crash or match") }
    }

    func testStartAndModeSwitchNameTheDelegationType() throws {
        let start = try XCTUnwrap((LiveCodec.start(.plan)["session"] as? [String: Any])?["delegation"] as? [String: Any])
        XCTAssertEqual(start["type"] as? String, "responses")
        let r = try XCTUnwrap(start["responses"] as? [String: Any])
        XCTAssertEqual((r["tools"] as? [[String: Any]])?.count, AssistantTools.all.count)
        XCTAssertTrue((r["instructions"] as? String ?? "").contains("Mode: PLAN"))
        // The service rejects an update without the type ("Missing required parameter: 'session.delegation.type'").
        let update = try XCTUnwrap((LiveCodec.update(.code)["session"] as? [String: Any])?["delegation"] as? [String: Any])
        XCTAssertEqual(update["type"] as? String, "responses")
        XCTAssertTrue(((update["responses"] as? [String: Any])?["instructions"] as? String ?? "").contains("Mode: CODE"))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(LiveCodec.start(.code)), "the tools must be plain JSON")
    }

    // MARK: Logic

    func testAgentChanges() {
        let old: [String: MuxStatus] = ["a": .working, "b": .idle, "c": .working, "d": .done]
        let (ended, blocked) = Assistant.changes(from: old, to: [
            AgentState(space: "one", pane: "a", status: .done), AgentState(space: "two", pane: "b", status: .blocked),
            AgentState(space: "three", pane: "c", status: .working), AgentState(space: "four", pane: "d", status: .idle),
            AgentState(space: "new", pane: "e", status: .blocked)])
        XCTAssertEqual(ended.map(\.space), ["one"], "only a turn that was working ends")
        XCTAssertEqual(blocked.map(\.space), ["two"], "an agent first seen blocked is history, not news")
    }

    func testSpokenNamesFindSpaces() {
        let labels = ["🚀 pushleft", "plotter", "inbox2"]
        XCTAssertEqual(HerdrHost.match("push left", in: labels), "🚀 pushleft")
        XCTAssertEqual(HerdrHost.match("Plotter.", in: labels), "plotter")
        XCTAssertEqual(HerdrHost.match("the inbox2 space", in: labels), "inbox2")
        XCTAssertNil(HerdrHost.match("sidra", in: labels))
        XCTAssertNil(HerdrHost.match("  ", in: labels))
    }

    func testProjectNamesAreSafeForAShell() {
        XCTAssertEqual(Assistant.projectName("My Plotter!"), "my-plotter")
        XCTAssertEqual(Assistant.projectName("a; rm -rf ~"), "a-rm-rf")
        XCTAssertEqual(Assistant.projectName("$(x)"), "x")
        XCTAssertEqual(Assistant.tail(String(repeating: "x", count: 5000)).count, 4000)
    }

    // MARK: A session, end to end against the fakes

    private func session(_ mode: AssistantMode = .plan) async -> (Assistant, FakeLive, FakeHost) {
        let a = Assistant(), live = FakeLive(), host = FakeHost()
        a.voiceOn = false   // no microphone in the tests
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: "sidra.assistant.voice") }
        a.start(mode, host: host, link: live)
        await a.handle(.started)
        return (a, live, host)
    }

    func testStartOpensTheSessionAndAsksTheFirstQuestion() async {
        let (a, live, _) = await session()
        XCTAssertEqual(a.phase, .ready)
        XCTAssertEqual(live.types.prefix(3), ["session.start", "response.item.create", "response.create"])
        XCTAssertTrue(live.lastMessage?.hasPrefix("Event: the session started in plan mode") == true)
        a.stop()
    }

    func testANewProjectWaitsForTheUsersYes() async {
        let (a, live, host) = await session()
        await a.handle(.call(ToolCall(id: "c1", name: "new_project", args: ["name": "My Plotter"])))
        XCTAssertEqual(a.card, .newProject(name: "my-plotter", folder: "~/Development/my-plotter", agent: CodingAgent.startOnNewSpace ?? "none"))
        XCTAssertTrue(host.made.isEmpty, "nothing is made before the user confirms")
        await a.handle(.responseDone)
        XCTAssertEqual(live.types.last, "response.create", "the results go back, then one resume")

        a.send("Yes, create it.")
        await a.handle(.call(ToolCall(id: "c2", name: "new_project", args: ["name": "My Plotter", "confirmed": true])))
        XCTAssertEqual(host.made, ["my-plotter"])
        XCTAssertNil(a.card)
        XCTAssertEqual(live.results.last, "Made my-plotter and switched to it.")
        await a.handle(.responseDone)
        await a.handle(.text("The project is made."))
        XCTAssertEqual(a.said, "The project is made.")
        XCTAssertFalse(a.thinking)
        XCTAssertEqual(a.thread.last?.body, .assistant("The project is made."))
        a.stop()
    }

    func testAPromptAndASkillWaitToo() async {
        let (a, live, host) = await session()
        await a.handle(.call(ToolCall(id: "c1", name: "prompt_agent", args: ["text": "Fix the empty-line test."])))
        XCTAssertEqual(a.card, .prompt(space: "plotter", text: "Fix the empty-line test."))
        XCTAssertTrue(host.prompts.isEmpty)
        await a.handle(.call(ToolCall(id: "c2", name: "prompt_agent", args: ["text": "Fix the empty-line test.", "confirmed": true])))
        XCTAssertEqual(host.prompts, ["plotter: Fix the empty-line test."])
        await a.handle(.call(ToolCall(id: "c3", name: "run_skill", args: ["skill": "code-audit", "brief": "the serial code", "confirmed": true])))
        XCTAssertEqual(host.prompts.last, "plotter: /code-audit the serial code")
        XCTAssertEqual(live.results.count, 3)
        a.stop()
    }

    func testCodeModeReportsATurnThatEnded() async {
        let (a, live, host) = await session(.code)
        host.list[0].status = .done
        await a.checkAgents()
        XCTAssertTrue(live.lastMessage?.hasPrefix("Event: the agent in space plotter ended a turn.") == true)
        XCTAssertTrue(live.lastMessage?.contains("9 passed, 1 failed") == true, "the backend gets the terminal text to summarise")
        await a.handle(.call(ToolCall(id: "c1", name: "turn_update", args: ["space": "plotter", "summary": "Wrote the parser. One test fails.", "verdict": "watch", "did_you_know": "No test covers long lines."])))
        XCTAssertEqual(a.card, .turn(space: "plotter", summary: "Wrote the parser. One test fails.", verdict: "watch", didYouKnow: "No test covers long lines."))
        a.stop()
    }

    func testPlanModeStaysQuietAboutTurnsButReportsASkillAndAQuestion() async {
        let (a, live, host) = await session(.plan)
        let before = live.sent.count
        host.list[0].status = .done
        await a.checkAgents()
        XCTAssertEqual(live.sent.count, before, "an ordinary turn is not news in plan mode")

        host.list[0].status = .working
        await a.checkAgents()
        await a.handle(.call(ToolCall(id: "c1", name: "run_skill", args: ["skill": "product-planner", "brief": "a serial plotter", "confirmed": true])))
        host.list[0].status = .done
        await a.checkAgents()
        XCTAssertTrue(live.lastMessage?.hasPrefix("Event: the skill product-planner finished in space plotter.") == true)

        host.list[1].status = .blocked
        await a.checkAgents()
        XCTAssertTrue(live.lastMessage?.hasPrefix("Event: the agent in space pushleft waits with a question.") == true)
        a.stop()
    }

    func testSpeechBecomesOneThreadItemBeforeTheAnswer() async {
        let (a, _, _) = await session()
        await a.handle(.heard("numbers first,")); await a.handle(.heard(" the labels can wait"))
        XCTAssertEqual(a.heard, "numbers first, the labels can wait")
        await a.handle(.text("Version 1 plots numbers."))
        XCTAssertEqual(a.thread.map(\.body), [.user("numbers first, the labels can wait"), .assistant("Version 1 plots numbers.")])
        XCTAssertEqual(a.heard, "")
        a.stop()
    }

    func testModeSwitchKeepsTheSession() async {
        let (a, live, _) = await session()
        a.setMode(.code)
        XCTAssertEqual(a.mode, .code)
        XCTAssertTrue(live.types.contains("session.update"))
        XCTAssertFalse(live.types.dropFirst().contains("session.start"), "no second session")
        a.stop()
    }

    func testNoKeyAndALostConnectionSayWhatToDo() async {
        let (a, _, _) = await session()
        await a.handle(.closed("connection_lost"))
        XCTAssertEqual(a.phase, .failed("The connection was lost. Start the session again."))
        XCTAssertEqual(Assistant.closeText("expired"), "The session reached its time limit. Start it again.")
    }

    // MARK: Live (needs TEST_RUNNER_OPENAI_API_KEY; costs a few cents)

    func testTheRealServiceAnswersAndCallsATool() async throws {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty else { throw XCTSkip("no OPENAI_API_KEY") }
        let live = LiveSocket(key: key)
        live.send(LiveCodec.start(.code))
        var started = false, called: String?, text: String?
        let deadline = Date().addingTimeInterval(40)
        for await event in live.events {
            switch event {
            case .started:
                started = true
                live.send(LiveCodec.update(.code))   // a mode switch must not be refused
                LiveCodec.message("Which spaces are open?").forEach(live.send)
            case .call(let c):
                called = c.name
                live.send(LiveCodec.result(c.id, "plotter: claude working; pushleft: claude blocked"))
            case .responseDone where called != nil && text == nil:
                live.send(LiveCodec.resume)
            case .text(let t): text = t
            case .error(let m): XCTFail("the service refused something: \(m)")
            case .closed(let r): XCTFail("closed early: \(r)")
            default: break
            }
            if text != nil || Date() > deadline { break }
        }
        live.close()
        XCTAssertTrue(started)
        XCTAssertEqual(called, "list_spaces")
        XCTAssertNotNil(text, "the backend answered after the tool result")
    }
    /// The whole loop with the real models and a fake machine: the first question, a confirm card, then the action.
    func testARealSessionMakesAProjectOnlyAfterYes() async throws {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty else { throw XCTSkip("no OPENAI_API_KEY") }
        let a = Assistant(), host = FakeHost()
        a.voiceOn = false
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: "sidra.assistant.voice") }
        a.start(.plan, host: host, link: LiveSocket(key: key))
        func wait(_ what: String, _ done: () -> Bool) async throws {
            for _ in 0..<300 where !done() { try await Task.sleep(for: .milliseconds(200)) }
            XCTAssertTrue(done(), "timed out waiting for " + what + "; phase \(a.phase), thread \(a.thread.map(\.body))")
        }
        try await wait("the first question") { a.thread.contains { if case .assistant = $0.body { true } else { false } } }
        a.send("Start a new project called plotter.")
        try await wait("the confirm card") { if case .newProject = a.card { true } else { false } }
        XCTAssertTrue(host.made.isEmpty, "nothing is made before yes")
        try await wait("the answer after the card") { !a.thinking }
        a.send("Yes, create it.")
        try await wait("the project") { !host.made.isEmpty }
        XCTAssertEqual(host.made, ["plotter"])
        try await wait("the last answer") { !a.thinking }
        // STE-80: the lines are short.
        for case .assistant(let t) in a.thread.map(\.body) { XCTAssertLessThan(t.split(separator: " ").count, 45, "too long for a spoken line: " + t) }
        a.stop()
    }
}
