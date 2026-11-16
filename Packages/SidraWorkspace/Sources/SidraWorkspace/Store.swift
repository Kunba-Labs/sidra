import SwiftUI
import Foundation
import Observation
import SidraDesign

/// Tabs, pane tree, focus and persistence. One per window scene.
@MainActor
@Observable
public final class WorkspaceStore {
    public private(set) var state: WorkspaceState
    /// True when a saved workspace was found, even one with every tab closed.
    public let restored: Bool
    public var hostName: String = "Sidra"
    public var hostDetail: String = ""

    private let storageURL: URL?
    private var saveTask: Task<Void, Never>?

    public init(state: WorkspaceState = WorkspaceState(), storageURL: URL? = WorkspaceStore.defaultStorageURL) {
        self.storageURL = storageURL
        if let storageURL, let data = try? Data(contentsOf: storageURL),
           let saved = try? JSONDecoder().decode(WorkspaceState.self, from: data) {
            self.state = saved
            self.restored = true
            // Chess panes used to carry "against the engine"; it is always the engine (2026-11-15).
            for i in self.state.tabs.indices where self.state.tabs[i].icon == .chess {
                self.state.tabs[i].subtitle = nil
                for p in self.state.tabs[i].panes where p.project != nil { var q = p; q.project = nil; self.state.tabs[i].root = self.state.tabs[i].root?.updatingPane(q) }
            }
        } else {
            self.state = state
            self.restored = false
        }
    }

    public nonisolated static var defaultStorageURL: URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("workspace.json")
    }

    /// Storage for an additional window scene, keyed by the scene session's persistent identifier.
    public nonisolated static func storageURL(forScene id: String) -> URL? {
        let safe = id.replacingOccurrences(of: "/", with: "_")
        return defaultStorageURL?.deletingLastPathComponent().appendingPathComponent("workspace-\(safe).json")
    }

    // MARK: Tabs

    public var tabs: [WorkspaceTab] { state.tabs }
    public var activeTab: WorkspaceTab? {
        state.tabs.first { $0.id == state.activeTabID } ?? state.tabs.first
    }
    public var activeTabID: UUID? { activeTab?.id }

    public func select(tab id: UUID) {
        guard state.tabs.contains(where: { $0.id == id }) else { return }
        state.activeTabID = id
        persist()
    }

    /// Set by the app: a tab with its own handle elsewhere (Theasa's title-bar pill). It never shows in
    /// the tab strip, the iPhone dock or the orb, and tab cycling skips it.
    public var isHiddenTab: ((WorkspaceTab) -> Bool)?
    public var visibleTabs: [WorkspaceTab] { state.tabs.filter { isHiddenTab?($0) != true } }

    public func selectTab(offset: Int) {
        let tabs = visibleTabs
        guard !tabs.isEmpty else { return }
        let n = tabs.count
        guard let current = activeTabID, let i = tabs.firstIndex(where: { $0.id == current }) else { select(tab: tabs[offset > 0 ? 0 : n - 1].id); return }
        select(tab: tabs[((i + offset) % n + n) % n].id)
    }

    /// Puts tab `id` where `target` is (drag to reorder).
    public func moveTab(_ id: UUID, to target: UUID) {
        guard id != target, let from = state.tabs.firstIndex(where: { $0.id == id }),
              let to = state.tabs.firstIndex(where: { $0.id == target }) else { return }
        state.tabs.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
        persist()
    }

    public func selectTab(index: Int) {
        let tabs = visibleTabs
        guard tabs.indices.contains(index) else { return }
        select(tab: tabs[index].id)
    }

    @discardableResult
    public func addTab(_ tab: WorkspaceTab, activate: Bool = true) -> WorkspaceTab {
        state.tabs.append(tab)
        if activate || state.activeTabID == nil { state.activeTabID = tab.id }
        persist()
        return tab
    }

    /// Every close path (pane button, tab close, keyboard) goes through here. `isBusy` is set by the
    /// app; a busy pane or tab is parked in `pendingClose` until the user confirms.
    public enum PendingClose: Identifiable, Equatable { case pane(UUID, String), tab(UUID, String)
        public var id: String { switch self { case .pane(let u, _): "p\(u)"; case .tab(let u, _): "t\(u)" } }
        public var title: String { switch self { case .pane(_, let t), .tab(_, let t): t } }
    }
    public var isBusy: ((UUID) -> Bool)?
    /// Set by the app: whether a tab shows the blue "something new" dot.
    public var tabDot: ((WorkspaceTab) -> Bool)?
    /// A tab's activity for its long-press details on iPhone (what runs, agents, pipelines); set by the app.
    public var tabDetail: ((WorkspaceTab) -> AnyView)?
    /// How many things need the user (agents asking), for the floating orb's badge; set by the app.
    public var attention: (() -> Int)?
    public var pendingClose: PendingClose?

    public func requestClose(pane id: UUID) {
        guard let tab = state.tabs.first(where: { $0.panes.contains { $0.id == id } }), let p = tab.panes.first(where: { $0.id == id }) else { return }
        if isBusy?(id) == true { pendingClose = .pane(id, p.title) } else { close(pane: id, inTab: tab.id) }
    }

    public func requestCloseTab(_ id: UUID) {
        guard let tab = state.tabs.first(where: { $0.id == id }) else { return }
        if tab.panes.contains(where: { isBusy?($0.id) == true }) { pendingClose = .tab(id, tab.title) } else { closeTab(id) }
    }

    public func confirmPendingClose() {
        switch pendingClose {
        case .pane(let id, _)?: if let tab = state.tabs.first(where: { $0.panes.contains { $0.id == id } }) { close(pane: id, inTab: tab.id) }
        case .tab(let id, _)?: closeTab(id)
        case nil: break
        }
        pendingClose = nil
    }

    public func closeTab(_ id: UUID) {
        guard let i = state.tabs.firstIndex(where: { $0.id == id }) else { return }
        state.tabs.remove(at: i)
        if state.activeTabID == id {
            state.activeTabID = state.tabs.indices.contains(i) ? state.tabs[i].id : state.tabs.last?.id
        }
        persist()
    }

    public func renameTab(_ id: UUID, title: String, subtitle: String? = nil) {
        update(tab: id) { $0.title = title; $0.subtitle = subtitle }
    }

    private func update(tab id: UUID, _ change: (inout WorkspaceTab) -> Void) {
        guard let i = state.tabs.firstIndex(where: { $0.id == id }) else { return }
        change(&state.tabs[i])
        persist()
    }

    // MARK: Panes

    public var focusedPane: Pane? { activeTab?.focusedPane }

    public func focus(pane id: UUID) {
        guard let tab = activeTab, tab.root?.contains(id) == true else { return }
        update(tab: tab.id) { $0.focusedPaneID = id }
    }

    /// Moves focus to the next or previous pane in visual order.
    public func focusPane(offset: Int) {
        guard let tab = activeTab, let root = tab.root else { return }
        let ids = root.orderedPaneIDs
        guard !ids.isEmpty else { return }
        let i = tab.focusedPaneID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let n = ids.count
        focus(pane: ids[((i + offset) % n + n) % n])
    }

    public func focusPane(index: Int) {
        guard let ids = activeTab?.root?.orderedPaneIDs, ids.indices.contains(index) else { return }
        focus(pane: ids[index])
    }

    /// Splits `paneID` along `axis`; the new pane goes second (right or below) and takes focus.
    public func split(_ paneID: UUID, axis: SplitAxis, newPane: Pane, ratio: Double = 0.5) {
        guard let tab = activeTab, let root = tab.root, let existing = root.pane(paneID) else { return }
        let node = PaneNode.split(id: UUID(), axis: axis, ratio: ratio, first: .leaf(existing), second: .leaf(newPane))
        update(tab: tab.id) {
            $0.root = root.replacingLeaf(paneID, with: node)
            $0.focusedPaneID = newPane.id
            $0.maximizedPaneID = nil
        }
    }

    public func close(pane id: UUID) {
        guard let tab = activeTab else { return }
        close(pane: id, inTab: tab.id)
    }

    /// Closes a pane in any tab; closing the last pane closes the tab.
    public func close(pane id: UUID, inTab tabID: UUID) {
        guard let tab = state.tabs.first(where: { $0.id == tabID }), let root = tab.root else { return }
        let newRoot = root.removingLeaf(id)
        if newRoot == nil {
            closeTab(tab.id)
            return
        }
        update(tab: tab.id) {
            $0.root = newRoot
            if $0.focusedPaneID == id { $0.focusedPaneID = newRoot?.panes.first?.id }
            if $0.maximizedPaneID == id { $0.maximizedPaneID = nil }
        }
    }

    public func toggleMaximize(pane id: UUID) {
        guard let tab = activeTab else { return }
        update(tab: tab.id) {
            $0.maximizedPaneID = $0.maximizedPaneID == id ? nil : id
            $0.focusedPaneID = id
        }
    }

    public func setRatio(_ ratio: Double, forSplit splitID: UUID) {
        guard let tab = activeTab, let root = tab.root else { return }
        update(tab: tab.id) { $0.root = root.settingRatio(ratio, forSplit: splitID) }
    }

    public func update(pane: Pane) {
        guard let tab = activeTab else { return }
        update(pane: pane, inTab: tab.id)
    }

    /// Replaces a pane (matched by id) in any tab.
    public func update(pane: Pane, inTab tabID: UUID) {
        guard let tab = state.tabs.first(where: { $0.id == tabID }), let root = tab.root else { return }
        update(tab: tab.id) { $0.root = root.updatingPane(pane) }
    }

    /// Adds a pane to the active tab: splits the focused pane right, or becomes the root.
    public func open(_ pane: Pane, axis: SplitAxis = .horizontal) {
        guard let tab = activeTab else {
            addTab(WorkspaceTab(title: pane.title, icon: pane.kind.icon, root: .leaf(pane)))
            return
        }
        if let focused = tab.focusedPaneID, tab.root != nil {
            split(focused, axis: axis, newPane: pane)
        } else {
            update(tab: tab.id) { $0.root = .leaf(pane); $0.focusedPaneID = pane.id }
        }
    }

    // MARK: Persistence

    private func persist() {
        guard let storageURL else { return }
        let snapshot = state
        saveTask?.cancel()
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: storageURL, options: .atomic)
            }
        }
    }

    public func saveNow() {
        guard let storageURL, let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
