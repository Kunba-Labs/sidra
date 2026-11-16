import XCTest
import UIKit
import SidraSSH
@testable import Sidra

final class HerdrTests: XCTestCase {
    /// The shape `herdr api snapshot` prints (protocol 22), trimmed.
    static let snapshot = #"""
    {"id":"cli:api:snapshot","result":{"snapshot":{"version":"0.9.1","protocol":22,"focused_workspace_id":"w4D","focused_pane_id":"w4D:pQ","focused_tab_id":"w4D:t1",
     "workspaces":[{"workspace_id":"w3W","label":"📊 status","number":1,"agent_status":"unknown","tab_count":1,"pane_count":2,"focused":false,"active_tab_id":"w3W:t1"},
                   {"workspace_id":"w4D","label":"webapp","number":2,"agent_status":"blocked","tab_count":2,"pane_count":2,"focused":true,"active_tab_id":"w4D:t1"}],
     "agents":[{"agent":"claude","agent_status":"blocked","pane_id":"w4D:pQ","workspace_id":"w4D","tab_id":"w4D:t1","terminal_title_stripped":"Webapp","cwd":"/p"},
               {"agent":"claude","agent_status":"working","pane_id":"w4D:pZ","workspace_id":"w4D","tab_id":"w4D:tB","terminal_title_stripped":"Jobs","cwd":"/p"},
               {"agent":"newagent","agent_status":"sleeping","pane_id":"w4D:pX","workspace_id":"w4D","tab_id":"w4D:tB"}],
     "panes":[{"pane_id":"w3W:p1","workspace_id":"w3W","cwd":"/home/dev/tools"},{"pane_id":"w4D:pQ","workspace_id":"w4D","cwd":"/home/dev/webapp"}],
     "tabs":[],"layouts":[]}}}
    """#

    func testParsesASnapshot() throws {
        let s = try MuxSnapshot.parse(Data(Self.snapshot.utf8))
        XCTAssertEqual(s.workspaces.map(\.label), ["📊 status", "webapp"])
        XCTAssertEqual(s.focused_workspace_id, "w4D")
        XCTAssertEqual(s.folder(of: "w4D"), "/home/dev/webapp")
        XCTAssertEqual(s.agents(in: "w4D").count, 3)
        XCTAssertEqual(s.agents.last?.agent_status, .unknown, "a status from a newer herdr reads as unknown, not a parse failure")
        XCTAssertEqual(s.count(.blocked), 1)
        XCTAssertEqual(s.count(.working), 1)
    }

    func testServerNotRunningIsExplained() {
        let reply = #"{"id":"x","error":{"code":"server_not_running","message":"no herdr server is running"}}"#
        XCTAssertThrowsError(try MuxSnapshot.parse(Data(reply.utf8))) { e in
            XCTAssertEqual((e as? HerdrError)?.code, "server_not_running")
            XCTAssertTrue(describeError(e).contains("not running"))
        }
    }

    func testWorstStatusLeads() {
        XCTAssertEqual(MuxStatus.worst([.idle, .working, .done]), .working)
        XCTAssertEqual(MuxStatus.worst([.working, .blocked]), .blocked)
        XCTAssertEqual(MuxStatus.worst([]), .unknown)
    }

    func testSessionArgumentIsQuoted() {
        XCTAssertEqual(Herdr.sessionArg(nil), "")
        XCTAssertEqual(Herdr.sessionArg("default"), "")
        XCTAssertEqual(Herdr.sessionArg("it's"), #" --session 'it'\''s'"#)
        XCTAssertEqual(Herdr.attachCommand(session: "work"), "exec sh ~/.local/share/sidra/herdr-attach.sh 'work'")
        XCTAssertEqual(Herdr.attachCommand(session: "default"), "exec sh ~/.local/share/sidra/herdr-attach.sh")
        XCTAssertEqual(HerdrAdapter().splitPaneCommand(session: nil, pane: "p_1", down: true), "herdr pane split 'p_1' --direction down --focus")
        XCTAssertTrue(Herdr.attachScript.contains("HERDR_CONFIG_PATH"), "Sidra's client reads its own config copy")
        XCTAssertTrue(Herdr.installScript.hasSuffix("\nSIDRA_EOF\n"))
    }
}

