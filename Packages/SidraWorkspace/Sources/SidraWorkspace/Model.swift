import Foundation
import SwiftUI
import SidraDesign

/// What a pane shows. Data only; the app maps kinds to views.
public enum PaneKind: Codable, Hashable, Sendable {
    case terminal(TerminalTarget)
    /// herdr's own client on another machine, attached in a terminal.
    case herdr(target: TerminalTarget, session: String?)
    /// A Theasa server's dashboard (pulse, agents, projects, turns), by saved connection.
    case theasa(connection: UUID)
    /// HackerTab: Hacker News, comments first.
    case hackertab
    /// CI pipelines (GitLab or GitHub) of one saved connection, with each run's stages and failing log.
    /// Nil: the first connection (tabs saved before there could be several).
    case pipelines(connection: UUID?)
    /// Chess against Sidra's own engine.
    case chess
    /// Substrate (substrate.gliph.sh): testers' requests to approve, sessions and machines, by saved account.
    case substrate(connection: UUID)

    public var icon: ProcessIcon.Kind {
        switch self {
        case .terminal(let t): t.icon
        case .herdr: .herdr
        case .theasa: .theasa
        case .hackertab: .hackertab
        case .pipelines: .pipelines
        case .chess: .chess
        case .substrate: .substrate
        }
    }
}

/// Where a terminal runs. Only SSH hosts today; the VM and serial lines live in sidra-full.
public enum TerminalTarget: Codable, Hashable, Sendable {
    case ssh(hostID: UUID)

    public var icon: ProcessIcon.Kind { .ssh }
}

public struct Pane: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var kind: PaneKind
    public var title: String
    public var project: String?

    public init(id: UUID = UUID(), kind: PaneKind, title: String, project: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.project = project
    }
}

public enum SplitAxis: String, Codable, Hashable, Sendable {
    /// Children side by side.
    case horizontal
    /// Children stacked.
    case vertical
}

/// Binary split tree. Leaves are panes; splits carry a ratio for the first child.
public indirect enum PaneNode: Codable, Hashable, Sendable {
    case leaf(Pane)
    case split(id: UUID, axis: SplitAxis, ratio: Double, first: PaneNode, second: PaneNode)

    public var panes: [Pane] {
        switch self {
        case .leaf(let p): [p]
        case .split(_, _, _, let a, let b): a.panes + b.panes
        }
    }

    public func contains(_ paneID: UUID) -> Bool {
        panes.contains { $0.id == paneID }
    }

    public func pane(_ id: UUID) -> Pane? {
        panes.first { $0.id == id }
    }

    /// Replaces the leaf with `paneID` by `node`.
    public func replacingLeaf(_ paneID: UUID, with node: PaneNode) -> PaneNode {
        switch self {
        case .leaf(let p):
            return p.id == paneID ? node : self
        case .split(let id, let axis, let ratio, let a, let b):
            return .split(id: id, axis: axis, ratio: ratio,
                          first: a.replacingLeaf(paneID, with: node),
                          second: b.replacingLeaf(paneID, with: node))
        }
    }

    /// Removes the leaf; its sibling takes the parent's place. Returns nil when the tree empties.
    public func removingLeaf(_ paneID: UUID) -> PaneNode? {
        switch self {
        case .leaf(let p):
            return p.id == paneID ? nil : self
        case .split(let id, let axis, let ratio, let a, let b):
            if case .leaf(let p) = a, p.id == paneID { return b }
            if case .leaf(let p) = b, p.id == paneID { return a }
            let na = a.removingLeaf(paneID) ?? a
            let nb = b.removingLeaf(paneID) ?? b
            return .split(id: id, axis: axis, ratio: ratio, first: na, second: nb)
        }
    }

    public func updatingPane(_ pane: Pane) -> PaneNode {
        replacingLeaf(pane.id, with: .leaf(pane))
    }

    public func settingRatio(_ ratio: Double, forSplit splitID: UUID) -> PaneNode {
        switch self {
        case .leaf: return self
        case .split(let id, let axis, let r, let a, let b):
            let nr = id == splitID ? min(max(ratio, 0.15), 0.85) : r
            return .split(id: id, axis: axis, ratio: nr,
                          first: a.settingRatio(ratio, forSplit: splitID),
                          second: b.settingRatio(ratio, forSplit: splitID))
        }
    }

    /// Leaves in visual order: left to right, top to bottom.
    public var orderedPaneIDs: [UUID] { panes.map(\.id) }
}

public struct WorkspaceTab: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var subtitle: String?
    public var icon: ProcessIcon.Kind
    public var root: PaneNode?
    public var focusedPaneID: UUID?
    public var maximizedPaneID: UUID?

    public init(id: UUID = UUID(), title: String, subtitle: String? = nil, icon: ProcessIcon.Kind,
                root: PaneNode?, focusedPaneID: UUID? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.root = root
        self.focusedPaneID = focusedPaneID ?? root?.panes.first?.id
    }

    public var panes: [Pane] { root?.panes ?? [] }
    public var focusedPane: Pane? { focusedPaneID.flatMap { root?.pane($0) } }
}

public struct WorkspaceState: Codable, Sendable {
    public var tabs: [WorkspaceTab]
    public var activeTabID: UUID?
    public init(tabs: [WorkspaceTab] = [], activeTabID: UUID? = nil) {
        self.tabs = tabs
        self.activeTabID = activeTabID
    }
}
