import XCTest
@testable import SidraTheasa

/// Fixtures are trimmed responses from the live server (2026-11-14). agents.json adds two
/// synthetic agents (an `ask` and a `screen`) in the documented shape: none was blocked then.
final class TheasaDecodeTests: XCTestCase {
    func fixture<T: Decodable>(_ name: String, _ type: T.Type) throws -> T {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    func testAskPreviewsAndExtras() throws {
        let r = try fixture("agents-extras", AgentsResponse.self)
        let a = try XCTUnwrap(r.agents.first)
        XCTAssertEqual(a.ask?[0].options[0].preview?.contains("\n"), true, "previews keep their line breaks")
        XCTAssertNil(a.ask?[0].options[1].preview)
        let x = try XCTUnwrap(a.ask_extras)
        XCTAssertEqual(x.context?.hasPrefix("Two designs"), true)
        XCTAssertEqual(x.attachments.filter(\.isImage).count, 2)
        XCTAssertEqual(x.attachments.first?.basename, "login-a.png")
        XCTAssertEqual(x.attachments.first { $0.kind == "artifact" }?.artifactLink?.host, "claude.ai")
        XCTAssertNil(x.attachments.first { $0.kind == "sent" && $0.src == nil }?.artifactLink)
        // A question without extras still decodes (the live server sends {attachments: []} or nothing).
        XCTAssertNil(try fixture("agents", AgentsResponse.self).agents.first?.ask_extras)
    }

    func testHealth() throws {
        let h = try fixture("health", Health.self)
        XCTAssertEqual(h.status, "ok")
        XCTAssertGreaterThan(h.turns, 0)
    }

    func testPulse() throws {
        let p = try fixture("pulse", Pulse.self)
        XCTAssertGreaterThan(p.totals.turns, 0)
        XCTAssertEqual(p.bars.count, 7)
        XCTAssertFalse(p.days.isEmpty)
        XCTAssertFalse(p.days[0].items[0].bullets.isEmpty)
        XCTAssertNotNil(p.attention.first?.project)
        XCTAssertNotNil(p.worker.median_delay_s)
    }

    func testProjects() throws {
        let rows = try fixture("projects", [ProjectRow].self)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertFalse(rows[0].machines.isEmpty)
    }

    func testProjectDetail() throws {
        let d = try fixture("project", ProjectDetail.self)
        XCTAssertEqual(d.project.name, "theasa")
        XCTAssertFalse(d.turns.isEmpty)
        XCTAssertNotNil(d.turns[0].notes)
        XCTAssertFalse(d.decisions.isEmpty)
        XCTAssertFalse(d.watch.isEmpty)
        XCTAssertFalse(d.sessions.isEmpty)
    }

    func testTurnWithDiffs() throws {
        let d = try fixture("turn-diff", TurnDetail.self)
        XCTAssertFalse(d.turn.diffs?.isEmpty ?? true)
        XCTAssertNotNil(d.turn.final_text)
        XCTAssertTrue(d.resume.contains("--resume"))
        XCTAssertFalse(d.turn.steps?.isEmpty ?? true)
    }

    func testTurnWithAttachments() throws {
        let d = try fixture("turn-attachments", TurnDetail.self)
        XCTAssertEqual(d.attachments.filter { $0.dir == "in" }.first?.src, "/api/attachments/2332")
        XCTAssertEqual(d.attachments.filter { $0.kind == "sent" }.count, 3)
    }

    func testSearch() throws {
        let hits = try fixture("search", [SearchHit].self)
        XCTAssertTrue(hits[0].snippet.contains("[["))
        XCTAssertTrue(snippetRuns(hits[0].snippet).contains { $0.1 && $0.0 == "sidra" })
    }

    func testAgents() throws {
        let r = try fixture("agents", AgentsResponse.self)
        XCTAssertTrue(r.available)
        let ask = try XCTUnwrap(r.agents.first { $0.ask != nil })
        XCTAssertEqual(ask.ask?[1].multiSelect, true)
        let screen = try XCTUnwrap(r.agents.first { $0.screen != nil })
        XCTAssertEqual(screen.screen?.options[0].keys, ["1"])
        XCTAssertEqual(AgentLogic.waiting(r.agents).first?.status, "blocked")
    }
}

final class TheasaLogicTests: XCTestCase {
    let qs = [LiveAgent.Question(question: "Which database?", header: "DB", multiSelect: false, options: []),
              LiveAgent.Question(question: "Which targets?", header: nil, multiSelect: true, options: []),
              LiveAgent.Question(question: "Anything else?", header: nil, multiSelect: false, options: [])]

    func testAnswerText() {
        let picks = [0: ["SQLite"], 1: ["iPad", "Mac"]], own = [2: "no"]
        XCTAssertEqual(AgentLogic.missing(qs, picks: picks, own: own), [])
        XCTAssertEqual(AgentLogic.answerText(qs, picks: picks, own: own),
                       "Answers to your questions:\n- Which database? SQLite\n- Which targets? iPad, Mac\n- Anything else? no")
    }

    func testOwnAnswerReplacesPicks() {
        let text = AgentLogic.answerText(qs, picks: [0: ["SQLite"], 1: ["Mac"]], own: [0: "  DuckDB ", 2: "later"])
        XCTAssertEqual(text, "Answers to your questions:\n- Which database? DuckDB\n- Which targets? Mac\n- Anything else? later")
    }

    func testUnansweredQuestionsBlockTheSend() {
        XCTAssertEqual(AgentLogic.missing(qs, picks: [0: ["SQLite"], 1: []], own: [2: "   "]), [1, 2])
        XCTAssertEqual(AgentLogic.missingMessage([1, 2], of: 3), "Answer questions 2, 3 first.")
        XCTAssertEqual(AgentLogic.missingMessage([1], of: 3), "Answer question 2 first.")
        XCTAssertEqual(AgentLogic.missingMessage([0], of: 1), "Pick an option or type an answer first.")
    }

    func testToggle() {
        XCTAssertEqual(AgentLogic.toggle(["a"], "b", multi: false), ["b"])
        XCTAssertEqual(AgentLogic.toggle(["a"], "a", multi: false), [])
        XCTAssertEqual(AgentLogic.toggle(["a"], "b", multi: true), ["a", "b"])
        XCTAssertEqual(AgentLogic.toggle(["a", "b"], "a", multi: true), ["b"])
    }

    func testPromptRequest() throws {
        let c = TheasaClient(base: URL(string: "http://127.0.0.1:4747/")!, token: " secret\n")
        let r = try c.request(TheasaClient.promptPath(pane: "w4D:pQ"), post: ["text": "hi"])
        XCTAssertEqual(r.url?.absoluteString, "http://127.0.0.1:4747/api/agents/w4D%3ApQ/prompt")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(r.httpBody)) as? [String: String]
        XCTAssertEqual(body, ["text": "hi"])
        let k = try c.request(TheasaClient.keysPath(pane: "w4D:pQ"), post: ["keys": ["up", "enter"]])
        XCTAssertEqual(k.url?.path(percentEncoded: true), "/api/agents/w4D%3ApQ/keys")
        XCTAssertThrowsError(try TheasaClient(base: c.base, token: nil).request("/api/watch/1/done", post: [:])) {
            XCTAssertEqual($0 as? TheasaError, .noToken)
        }
        XCTAssertEqual(try c.request("/api/agents").value(forHTTPHeaderField: "Authorization"), "Bearer secret", "reads send the token when there is one")
        XCTAssertNil(try TheasaClient(base: c.base, token: nil).request("/api/pulse").value(forHTTPHeaderField: "Authorization"))
    }

    func testIconUploadRequest() throws {
        let c = TheasaClient(base: URL(string: "http://127.0.0.1:4747")!, token: "secret")
        let r = try c.iconRequest(project: 48, image: Data([0x89, 0x50]), mime: "image/png")
        XCTAssertEqual(r.url?.absoluteString, "http://127.0.0.1:4747/api/projects/48/icon")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let type = try XCTUnwrap(r.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary="))
        let body = String(decoding: try XCTUnwrap(r.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"icon\""))
        XCTAssertTrue(body.contains("Content-Type: image/png"))
        XCTAssertTrue(body.hasSuffix("--\r\n"))
        XCTAssertThrowsError(try TheasaClient(base: c.base, token: nil).iconRequest(project: 1, image: Data(), mime: "image/png"))
    }

    func testNormalize() {
        XCTAssertEqual(TheasaClient.normalize("127.0.0.1:4747/")?.absoluteString, "http://127.0.0.1:4747")
        XCTAssertEqual(TheasaClient.normalize("https://devbox.example.ts.net:4747")?.absoluteString, "https://devbox.example.ts.net:4747")
        XCTAssertNil(TheasaClient.normalize("ftp://x"))
    }

    func testFormat() {
        XCTAssertEqual(TFormat.tok(6_371_414_255), "6.4B")
        XCTAssertEqual(TFormat.tok(80_701_218), "80.7M")
        XCTAssertEqual(TFormat.tok(57_149), "57k")
        XCTAssertEqual(TFormat.dur(732_525), "12m 13s")
        XCTAssertEqual(TFormat.dur(615_623_364), "171h 00m")
        XCTAssertEqual(TFormat.money(nil), "n/a")
        XCTAssertEqual(TFormat.money(0.004), "<$0.01")
        XCTAssertEqual(TFormat.money(2282.04), "$2282")
        XCTAssertEqual(TFormat.money(4.4996), "$4.50")
        let now = TFormat.date("2026-11-14T08:20:00.000Z")!
        XCTAssertEqual(TFormat.ago("2026-11-14T08:16:48.669Z", now: now), "3 min ago")
        XCTAssertEqual(TFormat.ago("2026-11-13T08:00:00.000Z", now: now), "yesterday")
    }

    func testFileKinds() {
        XCTAssertEqual(FileKind.of("/r/src/a.ts", root: "/r"), .code)
        XCTAssertEqual(FileKind.of("/r/README.md", root: "/r"), .docs)
        XCTAssertEqual(FileKind.of("/r/x.png", root: "/r"), .media)
        XCTAssertEqual(FileKind.of("/home/dev/.claude/settings.json", root: "/r"), .outside)
        XCTAssertEqual(diffLineKind("@@ -1 +1 @@"), .hunk)
        XCTAssertEqual(diffLineKind("+x"), .add)
        XCTAssertEqual(diffLineKind("-x"), .del)
    }

    func testTimelineFolds() throws {
        let d = try TheasaDecodeTests().fixture("project", ProjectDetail.self)
        let quiet = d.turns.filter(\.isQuiet)
        let days = timeline(d.turns, open: [])
        XCTAssertEqual(days.reduce(0) { $0 + $1.count }, d.turns.count)
        XCTAssertLessThanOrEqual(days.flatMap(\.rows).filter { if case .turn(let t) = $0 { t.isQuiet } else { false } }.count, max(quiet.count, 0))
    }

    func testMarkdown() {
        let b = markdownBlocks("# Title\n\nSome **bold**\ntext.\n\n- one\n- two\n\n```\ncode\n```\n> quote\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n---")
        XCTAssertEqual(b, [.heading(1, "Title"), .paragraph("Some **bold**\ntext."), .list(ordered: false, items: ["one", "two"]),
                           .code("code"), .quote("quote"), .table([["a", "b"], ["1", "2"]]), .rule])
    }
}
