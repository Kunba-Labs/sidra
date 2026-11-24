#if os(visionOS)
import SwiftUI
import SidraDesign
import SidraWorkspace

/// Apple Vision Pro (Waseem, 2026-11-24): the first window lists the herdr spaces running on every
/// machine Sidra knows. A space opens in a window of its own, so several sit side by side in the room.
/// Each window runs its own herdr client: herdr lets every client show a different space, and a window
/// moves its client there with herdr's own goto keys (a `workspace focus` command would move every client).
/// The full Sidra workspace (tabs, settings, connect a machine) stays one window away.
struct VisionScenes: Scene {
    let app: AppModel

    var body: some Scene {
        WindowGroup(id: "main") {
            VisionSessions().environment(app)
        }
        .defaultSize(width: 560, height: 720)

        WindowGroup(id: "space", for: VisionSpace.self) { $space in
            if let space { VisionSpaceWindow(space: space).environment(app) }
        }
        .defaultSize(width: 1100, height: 720)

        WindowGroup(id: "workspace") {
            SceneRoot().environment(app)
        }
        .defaultSize(width: 1376, height: 1032)
        .commands { WorkspaceCommands(app: app) }
    }
}

/// One herdr space on one machine: what a space window shows.
struct VisionSpace: Codable, Hashable {
    var host: UUID
    var session: String?
    var space: String
    var label: String
    var target: TerminalTarget { .ssh(hostID: host) }
}

// MARK: - The list

/// Every herdr space Sidra can reach, by machine, with its agents' state. Machines come from the herdr
/// tabs in the saved workspace; connecting one adds such a tab.
struct VisionSessions: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var connecting = false

    /// One herdr pane per machine and session, from the saved workspace.
    private var machines: [Pane] {
        var seen = Set<PaneKind>()
        return app.primaryWorkspace.tabs.flatMap(\.panes).filter {
            if case .herdr = $0.kind { return seen.insert($0.kind).inserted }
            return false
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if machines.isEmpty {
                    ContentUnavailableView {
                        Label("No herdr machines", systemImage: "rectangle.stack")
                    } description: {
                        Text("Connect a machine that runs herdr. Its spaces show here, and each one opens in a window of its own.")
                    } actions: {
                        Button("Connect a machine") { connect() }
                    }
                }
                ForEach(machines) { pane in
                    if let mux = pane.kind.multiplexer { VisionMachineSection(pane: pane, target: mux.target, session: mux.session) }
                }
            }
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Connect a machine", systemImage: "plus") { connect() }
                    Button("Open workspace", systemImage: "rectangle.split.3x1") { openWindow(id: "workspace") }
                }
            }
        }
        .sheet(isPresented: $connecting) { HerdrConnectSheet().environment(app) }
        #if DEBUG
        .task {
            DemoMode.install(app)
            // -sidra.visionOpen w1,w2 (screenshots): opens those demo spaces' windows.
            for id in (UserDefaults.standard.string(forKey: "sidra.visionOpen") ?? "").split(separator: ",") {
                openWindow(id: "space", value: VisionSpace(host: DemoMode.hostID, session: nil, space: String(id), label: String(id)))
            }
        }
        #endif
    }

    /// The connect sheet adds its herdr tab to `app.workspace`: point that at the saved workspace first.
    private func connect() {
        app.workspace = app.primaryWorkspace
        connecting = true
    }
}

private struct VisionMachineSection: View {
    let pane: Pane
    let target: TerminalTarget
    let session: String?
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let m = MuxMonitors.shared.monitor(for: pane, app: app)
        Section {
            if let s = m?.snapshot {
                ForEach(s.workspaces) { ws in row(ws, s, m!) }
            } else if let e = m?.error {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            Text(app.herdrMachineName(target) + (session.map { " · " + $0 } ?? ""))
        }
    }

    private func row(_ ws: MuxSnapshot.Workspace, _ s: MuxSnapshot, _ m: MuxMonitor) -> some View {
        let folder = s.folder(of: ws.id)
        let agents = s.agents(in: ws.id)
        return Button {
            guard case .ssh(let host) = target else { return }
            openWindow(id: "space", value: VisionSpace(host: host, session: session, space: ws.id, label: ws.label))
        } label: {
            HStack(spacing: 14) {
                HerdrLogoView(name: ws.label, image: folder.flatMap { m.logos[$0] }, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ws.label).font(.headline)
                    if agents.isEmpty {
                        Text(folder.map(Self.short) ?? "No agents").font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 10) {
                            ForEach(agents) { a in
                                HStack(spacing: 5) {
                                    HerdrStatusIcon(status: a.agent_status, size: 9)
                                    Text(a.agent).font(.caption)
                                }
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if ws.agent_status != .unknown {
                    Text(HerdrStatusIcon.label(ws.agent_status)).font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "macwindow.badge.plus").foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    static func short(_ path: String) -> String {
        path.replacingOccurrences(of: #"^/(Users|home)/[^/]+"#, with: "~", options: .regularExpression)
    }
}

// MARK: - One space

/// A window holding one herdr client, moved to its space once attached. Its pane lives in a store of
/// its own that is never saved: closing the window ends the client, the space keeps running.
struct VisionSpaceWindow: View {
    let space: VisionSpace
    @Environment(AppModel.self) private var app
    @State private var store: WorkspaceStore
    private let pane: Pane

    init(space: VisionSpace) {
        self.space = space
        let pane = Pane(kind: .herdr(target: space.target, session: space.session), title: space.label)
        self.pane = pane
        _store = State(initialValue: WorkspaceStore(
            state: WorkspaceState(tabs: [WorkspaceTab(title: space.label, icon: .herdr, root: .leaf(pane))]), storageURL: nil))
    }

    private var link: TerminalLink { TerminalLink.of(pane.id) }

    var body: some View {
        let adapter = HerdrAdapter()
        TerminalPane(pane: pane, target: space.target, command: adapter.attachCommand(session: space.session),
                     prepare: adapter.prepareCommand().map { cmd in { [app, target = space.target] in try await app.herdrPrepare(target, cmd) } })
            .environment(store)
            .background(Color(red: 0x12 / 255, green: 0x15 / 255, blue: 0x1a / 255))
            // The keys go to the window last looked at and tapped.
            .simultaneousGesture(TapGesture().onEnded { app.workspace = store })
            .ornament(attachmentAnchor: .scene(.top), contentAlignment: .bottom) { header.padding(.bottom, 8) }
            .onAppear {
                app.setStore(store, scene: "vision-space-\(pane.id)")
                app.workspace = store
            }
            .onDisappear {
                TerminalLink.close(pane.id)
                MuxMonitors.shared.remove(pane.id)
                app.setStore(nil, scene: "vision-space-\(pane.id)")
            }
            // Every (re)connect starts a fresh client on herdr's shared focus: move it to this space again.
            .task(id: link.attempt) { await goToSpace() }
    }

    private var header: some View {
        let s = MuxMonitors.shared.monitor(for: pane, app: app)?.snapshot
        let agents = s?.agents(in: space.space) ?? []
        return HStack(spacing: 12) {
            HerdrStatusIcon(status: MuxStatus.worst(agents.map(\.agent_status)), size: 10)
            Text(s?.workspaces.first { $0.id == space.space }?.label ?? space.label).font(.headline)
            ForEach(agents) { a in
                HStack(spacing: 5) {
                    HerdrStatusIcon(status: a.agent_status, size: 8)
                    Text(a.agent).font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            Button("Show this space again", systemImage: "scope") { Task { await sendGoto() } }
                .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .glassBackgroundEffect()
    }

    private func goToSpace() async {
        for _ in 0..<150 where link.session == nil { try? await Task.sleep(for: .milliseconds(200)) }
        // ponytail: a fixed wait for herdr's client to draw its first frame; watch its output instead if keys arrive too early
        try? await Task.sleep(for: .seconds(1.5))
        await sendGoto()
    }

    /// herdr's goto picker (prefix g), filtered by the space's name, opens it in this client only.
    private func sendGoto() async {
        guard let io = link.session else { return }
        let label = MuxMonitors.shared.byPane[pane.id]?.snapshot?.workspaces.first { $0.id == space.space }?.label ?? space.label
        for step in ["\u{02}", "g", "/", label, "\r"] {
            io.write(Data(step.utf8))
            try? await Task.sleep(for: .milliseconds(300))
        }
    }
}
#endif
