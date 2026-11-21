import XCTest
@testable import Sidra
import SidraWorkspace
import SidraSSH

final class SmokeTests: XCTestCase {
    /// Every kind on the new-tab sheet maps to its own pane icon, and the seven are the baseline's whole set.
    func testNewTabKindsCoverTheBaseline() {
        XCTAssertEqual(NewTabKind.allCases.map(\.rawValue), ["herdr", "ssh", "theasa", "pipelines", "substrate", "hackertab", "chess"])
        XCTAssertEqual(Set(NewTabKind.allCases.map(\.icon)).count, 7)
    }

    /// HackerTab and Chess open once; a second request selects the open tab.
    @MainActor func testSingleTabsOpenOnce() {
        let app = AppModel()
        app.workspace = WorkspaceStore(state: WorkspaceState(), storageURL: nil)
        app.openSingle(.chess)
        app.openSingle(.hackertab)
        app.openSingle(.chess)
        XCTAssertEqual(app.workspace.tabs.map(\.icon), [.chess, .hackertab])
        XCTAssertEqual(app.workspace.activeTab?.icon, .chess)
    }

    /// herdr runs on several machines at once, next to plain SSH tabs: each tab keeps its own host.
    @MainActor func testHerdrOnSeveralHostsNextToSSH() {
        let app = AppModel(hosts: HostStore(url: nil))
        app.workspace = WorkspaceStore(state: WorkspaceState(), storageURL: nil)
        let a = SSHHostProfile(alias: "devbox", host: "devbox.example", user: "dev")
        let b = SSHHostProfile(alias: "buildbox", host: "buildbox.example", user: "dev")
        app.hosts.upsert(a); app.hosts.upsert(b)

        app.openTab(kind: .herdr(target: .ssh(hostID: a.id), session: nil))
        app.openTab(kind: .herdr(target: .ssh(hostID: b.id), session: "ops"))
        app.openTab(kind: .terminal(.ssh(hostID: a.id)))

        let panes = app.workspace.tabs.flatMap(\.panes)
        XCTAssertEqual(panes.map(\.project), ["devbox", "buildbox, session ops", "dev@devbox.example"])
        XCTAssertEqual(panes.map(\.kind), [.herdr(target: .ssh(hostID: a.id), session: nil),
                                          .herdr(target: .ssh(hostID: b.id), session: "ops"),
                                          .terminal(.ssh(hostID: a.id))])
    }
}
