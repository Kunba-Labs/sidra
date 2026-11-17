import XCTest
@testable import SidraWorkspace

final class PaneTreeTests: XCTestCase {
    @MainActor func makeStore() -> WorkspaceStore {
        let a = Pane(kind: .chess, title: "a")
        let tab = WorkspaceTab(title: "t", icon: .code, root: .leaf(a))
        return WorkspaceStore(state: WorkspaceState(tabs: [tab], activeTabID: tab.id), storageURL: nil)
    }

    @MainActor func testSplitRightThenDownThenCloseRestoresSibling() {
        let store = makeStore()
        let a = store.activeTab!.panes[0]
        let b = Pane(kind: .terminal(.ssh(hostID: UUID())), title: "b")
        store.split(a.id, axis: .horizontal, newPane: b)
        XCTAssertEqual(store.activeTab?.panes.map(\.title), ["a", "b"])
        XCTAssertEqual(store.focusedPane?.id, b.id)

        let c = Pane(kind: .terminal(.ssh(hostID: UUID())), title: "c")
        store.split(b.id, axis: .vertical, newPane: c)
        XCTAssertEqual(store.activeTab?.panes.map(\.title), ["a", "b", "c"])

        store.close(pane: b.id)
        XCTAssertEqual(store.activeTab?.panes.map(\.title), ["a", "c"])
        guard case .split(_, let axis, _, .leaf(let l), .leaf(let r)) = store.activeTab!.root! else {
            return XCTFail("expected a two-leaf split")
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual([l.title, r.title], ["a", "c"])
    }

    @MainActor func testClosingLastPaneClosesTab() {
        let store = makeStore()
        store.close(pane: store.activeTab!.panes[0].id)
        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertNil(store.activeTab)
    }

    @MainActor func testRatioIsClamped() {
        let store = makeStore()
        let a = store.activeTab!.panes[0]
        store.split(a.id, axis: .horizontal, newPane: Pane(kind: .hackertab, title: "p"))
        guard case .split(let id, _, _, _, _) = store.activeTab!.root! else { return XCTFail() }
        store.setRatio(0.01, forSplit: id)
        guard case .split(_, _, let r, _, _) = store.activeTab!.root! else { return XCTFail() }
        XCTAssertEqual(r, 0.15, accuracy: 0.0001)
    }

    @MainActor func testMaximizeTogglesAndFocuses() {
        let store = makeStore()
        let a = store.activeTab!.panes[0]
        let b = Pane(kind: .hackertab, title: "b")
        store.split(a.id, axis: .horizontal, newPane: b)
        store.toggleMaximize(pane: a.id)
        XCTAssertEqual(store.activeTab?.maximizedPaneID, a.id)
        XCTAssertEqual(store.focusedPane?.id, a.id)
        store.toggleMaximize(pane: a.id)
        XCTAssertNil(store.activeTab?.maximizedPaneID)
    }

    func testStateRoundTripsThroughJSON() throws {
        let a = Pane(kind: .pipelines(connection: nil), title: "x")
        let b = Pane(kind: .terminal(.ssh(hostID: UUID())), title: "y")
        let root = PaneNode.split(id: UUID(), axis: .vertical, ratio: 0.3, first: .leaf(a), second: .leaf(b))
        let tab = WorkspaceTab(title: "t", subtitle: "s", icon: .agent, root: root)
        let state = WorkspaceState(tabs: [tab], activeTabID: tab.id)
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(WorkspaceState.self, from: data)
        XCTAssertEqual(back.tabs, state.tabs)
        XCTAssertEqual(back.activeTabID, tab.id)
    }
}

extension PaneTreeTests {
    @MainActor func testCrossTabPaneUpdateAndClose() {
        let store = WorkspaceStore(storageURL: nil)
        let a = Pane(kind: .herdr(target: .ssh(hostID: UUID()), session: nil), title: "herdr", project: "a")
        let b = Pane(kind: .chess, title: "Chess", project: "b")
        let t1 = store.addTab(WorkspaceTab(title: "one", icon: .code, root: .leaf(a)))
        let t2 = store.addTab(WorkspaceTab(title: "two", icon: .code, root: .split(id: UUID(), axis: .horizontal, ratio: 0.5, first: .leaf(b), second: .leaf(Pane(kind: .hackertab, title: "P", project: nil)))))
        store.select(tab: t2.id)
        var moved = a; moved.kind = .herdr(target: .ssh(hostID: UUID()), session: "b")
        store.update(pane: moved, inTab: t1.id)   // inactive tab
        if case .herdr(_, let session)? = store.tabs.first { $0.id == t1.id }?.panes.first?.kind { XCTAssertEqual(session, "b") } else { XCTFail("herdr pane not updated") }
        store.select(tab: t1.id)
        store.close(pane: b.id, inTab: t2.id)     // inactive tab, pane in a split
        XCTAssertEqual(store.tabs.first { $0.id == t2.id }?.panes.map(\.title), ["P"])
    }
}

final class PipelinesKindCodingTests: XCTestCase {
    /// A Pipelines tab saved before connections ({"pipelines":{}}) still opens, on the first connection.
    func testOldPipelinesKindDecodes() throws {
        let old = Data(#"{"pipelines":{}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PaneKind.self, from: old), .pipelines(connection: nil))
        let id = UUID()
        let round = try JSONDecoder().decode(PaneKind.self, from: JSONEncoder().encode(PaneKind.pipelines(connection: id)))
        XCTAssertEqual(round, .pipelines(connection: id))
    }
}
