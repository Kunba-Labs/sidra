import SwiftUI
import Observation
import SidraDesign
import SidraWorkspace
import SidraTerminal
import SidraSSH

/// App-wide state: the workspace stores, sheet routing, SSH hosts and connections, toasts.
@MainActor
@Observable
final class AppModel {
    enum Sheet: Identifiable {
        case settings, shortcuts, herdr, theasa, pipelines, newTab
        var id: Self { self }
    }

    /// The key window's workspace: menu commands, openTab and splits target it. Each scene owns a
    /// store (see SceneRoot); the first scene takes this initial one, which holds workspace.json.
    var workspace: WorkspaceStore
    private var primaryWorkspaceClaimed = false
    private var sceneWorkspaces: [String: WorkspaceStore] = [:]
    let hosts: HostStore
    var sheet: Sheet?
    /// Failure of a pane action; RootView presents it. Sheets keep their own, one sheet cannot cover another.
    var alert: SidraAlert?
    var terminalEngine: TerminalEngineKind = .ghostty
    /// Set by a sheet that wants something done after it has gone.
    var afterSheetDismiss: (() -> Void)?
    var toastMessage: String?

    private var connections: [UUID: SSHConnection] = [:]
    private var toastTask: Task<Void, Never>?

    init() {
        if CommandLine.arguments.contains("-sidra.resetWorkspace") {   // UI tests that need a saved workspace in a known state
            if let url = WorkspaceStore.defaultStorageURL { try? FileManager.default.removeItem(at: url) }
        }
        let fresh = CommandLine.arguments.contains("-sidra.freshWorkspace")
        workspace = WorkspaceStore(storageURL: fresh ? nil : WorkspaceStore.defaultStorageURL)
        hosts = HostStore(url: fresh ? nil : HostStore.defaultURL)
        SSHConnection.setKeyUseConfirmation { host in await KeyUsePrompter.shared.ask(host) }
    }

    /// The store for a UI scene. The first scene gets the primary store (workspace.json); further
    /// windows get their own file and start empty (the New tab menu seeds them).
    /// One store per window, including the front one before its scene has registered.
    var allWorkspaces: [WorkspaceStore] {
        let stores = Array(sceneWorkspaces.values)
        return stores.contains { $0 === workspace } ? stores : stores + [workspace]
    }

    func workspace(forScene id: String) -> WorkspaceStore {
        if let s = sceneWorkspaces[id] { return s }
        let store: WorkspaceStore
        if !primaryWorkspaceClaimed {
            primaryWorkspaceClaimed = true
            store = workspace
        } else {
            let fresh = CommandLine.arguments.contains("-sidra.freshWorkspace")
            store = WorkspaceStore(storageURL: fresh ? nil : WorkspaceStore.storageURL(forScene: id))
            store.hostDetail = workspace.hostDetail
        }
        sceneWorkspaces[id] = store
        return store
    }

    /// A tapped notification: selects the tab holding the pane, in whichever window has it.
    func open(_ route: Notifier.Route) {
        switch route {
        case .pane(let id):
            for store in [workspace] + sceneWorkspaces.values {
                guard let tab = store.tabs.first(where: { $0.panes.contains { $0.id == id } }) else { continue }
                store.select(tab: tab.id)
                store.focus(pane: id)
                if store !== workspace { activateWindow(of: store) }
                return
            }
        }
    }

    private func activateWindow(of store: WorkspaceStore) {
        guard let id = sceneWorkspaces.first(where: { $0.value === store })?.key,
              let session = UIApplication.shared.openSessions.first(where: { $0.persistentIdentifier == id }) else { return }
        UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: session))
    }

    func connection(for profile: SSHHostProfile) -> SSHConnection {
        if let c = connections[profile.id], c.profile == profile { return c }
        connections[profile.id].map { old in Task { await old.disconnect() } }
        let c = SSHConnection(profile: profile, jump: profile.jumpHostID.flatMap { hosts.host($0) })
        connections[profile.id] = c
        return c
    }

    func toast(_ message: String) {
        toastMessage = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { toastMessage = nil }
        }
    }

    // MARK: Pane factory

    func newPane(kind: PaneKind) -> Pane {
        switch kind {
        case .terminal(.ssh(let id)): return Pane(kind: kind, title: hosts.host(id)?.alias ?? "ssh", project: hosts.host(id).map { "\($0.user)@\($0.host)" })
        case .herdr(let target, let session): return Pane(kind: kind, title: "herdr", project: herdrMachineName(target) + (session.map { ", session \($0)" } ?? ""))
        case .theasa(let id):
            // The machine, not the connection's name (usually "Theasa" again): box.tailnet.ts.net shows as box.
            let c = TheasaStore.shared.connection(id)
            let host = c.flatMap { URL(string: $0.url)?.host }.map { $0.first?.isLetter == true ? String($0.prefix { $0 != "." }) : $0 }
            return Pane(kind: kind, title: "Theasa", project: host ?? c?.name)
        case .hackertab: return Pane(kind: kind, title: "HackerTab", project: nil)
        case .chess: return Pane(kind: kind, title: "Chess", project: nil)
        case .pipelines: return Pane(kind: kind, title: "Pipelines", project: PipelinesStore.shared.host)
        }
    }

    func openLink(_ url: URL) { UIApplication.shared.open(url) }

    func openTab(kind: PaneKind) {
        let pane = newPane(kind: kind)
        workspace.addTab(WorkspaceTab(title: pane.title, subtitle: pane.project, icon: kind.icon, root: .leaf(pane)))
    }
}
