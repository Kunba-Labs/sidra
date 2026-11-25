#if os(visionOS)
import SwiftUI
import SidraDesign
import SidraWorkspace
import SidraTerminal
import SidraSSH

/// Apple Vision Pro (Waseem, 2026-11-24): the first window lists the herdr panes running on every machine
/// Sidra knows, by space. A pane opens in a window of its own, so several sit side by side in the room.
/// Each window streams that one pane over its own SSH channel with `herdr terminal session control`
/// (2026-11-25): no herdr client and no shared focus, so windows never move each other.
/// The full Sidra workspace (tabs, settings, connect a machine) stays one window away.
struct VisionScenes: Scene {
    let app: AppModel

    var body: some Scene {
        // Single windows (2026-11-26): every pane and workspace window has a Sessions button, and opening
        // a single window brings back the one that was closed instead of stacking a second.
        Window("Sessions", id: "main") {
            VisionSessions().environment(app)
        }
        .defaultSize(width: 560, height: 720)

        WindowGroup(id: "pane", for: VisionPane.self) { $pane in
            if let pane { VisionPaneWindow(pane: pane).environment(app) }
        }
        .defaultSize(width: 1000, height: 680)

        Window("Sidra", id: "workspace") {
            SceneRoot().environment(app)
                .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) { SessionsButton().padding(.top, 8) }
        }
        .defaultSize(width: 1376, height: 1032)
        .commands { WorkspaceCommands(app: app) }
    }
}

/// One herdr pane on one machine: what a pane window streams.
struct VisionPane: Codable, Hashable {
    var host: UUID
    var session: String?
    var pane: String
    var terminal: String
    var space: String
    var label: String
    var target: TerminalTarget { .ssh(hostID: host) }
}

// MARK: - The list

/// Every herdr pane Sidra can reach, by machine and space, with its agent's state. Machines come from
/// the herdr tabs in the saved workspace; connecting one adds such a tab.
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
                        Text("Connect a machine that runs herdr. Its panes show here, and each one opens in a window of its own.")
                    } actions: {
                        Button("Connect a machine") { connect() }
                    }
                }
                ForEach(machines) { pane in
                    if let mux = pane.kind.multiplexer { VisionMachineSection(pane: pane, target: mux.target, session: mux.session) }
                }
                // The workspace's other tabs (2026-11-26): each opens, or comes to the front, in the workspace window.
                Section("Apps") {
                    ForEach(NewTabKind.allCases.filter { $0 != .herdr && $0 != .ssh }) { kind in
                        Button { openApp(kind) } label: {
                            HStack(spacing: 12) {
                                ProcessIcon(kind.icon, size: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kind.title)
                                    Text(kind.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
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
            if CommandLine.arguments.contains("-sidra.visionConnect") { connect() }   // screenshots of the connect sheet
            // -sidra.visionStream <host>,<user>,<session>,<terminal_id>[;<terminal_id>…]: a real machine, trusted on first use, and one
            // pane window streaming that terminal (simulator checks against a scratch herdr session).
            if let a = UserDefaults.standard.string(forKey: "sidra.visionStream")?.split(separator: ",").map(String.init), a.count == 4 {
                let id = UUID(uuidString: "00000000-0000-0000-0000-00000000c0de")!
                app.hosts.upsert(SSHHostProfile(id: id, alias: "check", host: a[0], user: a[1], auth: .key, startupCommand: "", trustOnFirstUse: true))
                for t in a[3].split(separator: ";").map(String.init) {   // several terminal IDs: several windows
                    openWindow(id: "pane", value: VisionPane(host: id, session: a[2], pane: "", terminal: t, space: "", label: "check, " + t))
                }
            }
            // -sidra.visionOpen w1,w2 (screenshots): opens those demo spaces' first panes.
            for id in (UserDefaults.standard.string(forKey: "sidra.visionOpen") ?? "").split(separator: ",").map(String.init) {
                openWindow(id: "pane", value: VisionPane(host: DemoMode.hostID, session: nil, pane: id + ":p1", terminal: "term_" + id, space: id, label: id))
            }
        }
        #endif
    }

    private func openApp(_ kind: NewTabKind) {
        app.workspace = app.primaryWorkspace
        app.startTab(kind)
        openWindow(id: "workspace")
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
            if let m, let s = m.snapshot {
                ForEach(s.workspaces) { ws in space(ws, s, m) }
            } else if let e = m?.error {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            Text(app.herdrMachineName(target) + (session.map { ", " + $0 } ?? ""))
        }
    }

    /// A space's name, then one row per pane in it.
    @ViewBuilder private func space(_ ws: MuxSnapshot.Workspace, _ s: MuxSnapshot, _ m: MuxMonitor) -> some View {
        let folder = s.folder(of: ws.id)
        HStack(spacing: 12) {
            HerdrLogoView(name: ws.label, image: folder.flatMap { m.logos[$0] }, size: 30)
            Text(ws.label).font(.headline)
            Spacer()
            if ws.agent_status != .unknown { Text(HerdrStatusIcon.label(ws.agent_status)).font(.caption).foregroundStyle(.secondary) }
        }
        ForEach(s.panes.filter { $0.workspace_id == ws.id }) { p in paneRow(p, ws, s) }
    }

    private func paneRow(_ p: MuxSnapshot.PaneInfo, _ ws: MuxSnapshot.Workspace, _ s: MuxSnapshot) -> some View {
        let agent = s.agents.first { $0.pane_id == p.pane_id }
        let tab = s.tabs(in: ws.id).first { $0.tab_id == p.tab_id }
        let title = agent?.agent ?? (p.terminal_title_stripped.flatMap { $0.isEmpty ? nil : $0 } ?? "Shell")
        let detail = [tab.map { "tab " + $0.name(in: ws.label) }, agent?.terminal_title_stripped].compactMap { $0 }.joined(separator: ", ")
        return Button {
            guard case .ssh(let host) = target, let term = p.terminal_id else { return }
            openWindow(id: "pane", value: VisionPane(host: host, session: session, pane: p.pane_id, terminal: term, space: ws.id, label: "\(ws.label), \(title)"))
        } label: {
            HStack(spacing: 12) {
                if let a = agent { HerdrStatusIcon(status: a.agent_status, size: 10).frame(width: 30) } else { Image(systemName: "terminal").frame(width: 30) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    // A greyed row said nothing (2026-11-26): name the reason.
                    if p.terminal_id == nil { Text("herdr \(s.version ?? "on this machine") sends no terminal ID, so this pane cannot open. Update herdr there.").font(.caption).foregroundStyle(.orange) }
                }
                Spacer()
                Image(systemName: "macwindow.badge.plus").foregroundStyle(.secondary)
            }
        }
        .disabled(p.terminal_id == nil)   // herdr before terminal IDs: nothing to stream
    }
}

/// Brings back the Sessions window, or to the front when it is open.
private struct SessionsButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Sessions", systemImage: "list.bullet") { openWindow(id: "main") }
            .padding(6)
            .glassBackgroundEffect()
    }
}

// MARK: - One pane

/// A window streaming one herdr pane. It holds the pane with `--takeover` (herdr allows one writer per pane)
/// and gives it this window's size; closing the window releases it, and the pane keeps running.
struct VisionPaneWindow: View {
    let pane: VisionPane
    @Environment(AppModel.self) private var app
    @State private var stream: (any TerminalIO)?
    @State private var ended: String?
    @State private var attempt = 0
    @State private var focus = 0
    @State private var prompter = HostKeyPrompter.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    /// Only a window that is connecting asks to trust a host key, so open windows do not all show the same prompt.
    @State private var connecting = false

    /// This window's own SSH connection. OpenSSH serves 10 channels per connection (MaxSessions), and Sidra
    /// shares one per machine, so the 11th pane window on a shared one was refused (found 2026-11-25).
    @State private var connection: SSHConnection?
    @State private var windowOpen = false
    private var monitor: MuxMonitor { VisionMonitors.shared.monitor(pane) }

    var body: some View {
        ZStack {
            Color(red: 0x12 / 255, green: 0x15 / 255, blue: 0x1a / 255)
            if let stream {
                TerminalPaneView(io: stream, engine: app.terminalEngine, focusToken: focus, onOpenLink: { app.openLink($0) })
                    .id("\(attempt)-\(app.terminalEngine.rawValue)")   // a new surface when the engine setting changes
                    .padding(10)
                    .simultaneousGesture(TapGesture().onEnded { focus += 1 })
            } else if let ended {
                VStack(spacing: 14) {
                    Text(ended).font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted).multilineTextAlignment(.center)
                    Button("Reconnect") { attempt += 1 }.buttonStyle(.sidraPrimary)
                }
                .padding(30)
            } else {
                ProgressView()
            }
        }
        .ornament(attachmentAnchor: .scene(.top), contentAlignment: .bottom) { header.padding(.bottom, 8) }
        // The project's logo on the window's corner, standing off the glass, so a glance across the room says which app it is.
        .ornament(attachmentAnchor: .scene(.topLeading), contentAlignment: .center) { badge }
        .keyUseConfirmation()   // a key marked confirm-on-use asks here, or a reconnect would wait unseen
        // A first or changed host key asks here too, as the connect sheet does.
        .sheet(item: Binding(get: { connecting ? prompter.pending.map { HostKeyBox(prompt: $0) } : nil }, set: { _ in })) { box in
            HostKeySheet(prompt: box.prompt) { prompter.decide($0) }
        }
        .onAppear { prompter.install() }
        .task(id: attempt) { await connect() }
        // Back from the background (headset off, app left): the SSH stream may have died without a word,
        // leaving a frozen screen that takes no input. Take the pane again.
        .onChange(of: scenePhase) { old, new in if old == .background, new == .active { attempt += 1 } }
        .task { await VisionMonitors.shared.watch(pane, app) }   // the header's agent state, one poll per machine
        .onAppear { windowOpen = true }
        .onDisappear {
            windowOpen = false
            drop()
            let c = connection; connection = nil
            Task { try? await Task.sleep(for: .milliseconds(600)); await c?.disconnect() }   // after the release went out
        }
    }

    private var badge: some View {
        let s = monitor.snapshot
        let ws = s?.workspaces.first { $0.id == pane.space }
        let name = ws?.label ?? pane.label.components(separatedBy: ", ").first ?? pane.label
        let image = ws.flatMap { monitor.logo(for: $0) }
        return HerdrLogoView(name: name, image: image, size: 76)
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
            .offset(z: 24)
            .accessibilityLabel(name)
    }

    private var header: some View {
        let agent = monitor.snapshot?.agents.first { $0.pane_id == pane.pane }
        return HStack(spacing: 10) {
            if let agent { HerdrStatusIcon(status: agent.agent_status, size: 10) }
            Text(pane.label).font(.headline)
            if let t = agent?.terminal_title_stripped, !t.isEmpty { Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Button("Sessions", systemImage: "list.bullet") { openWindow(id: "main") }.labelStyle(.iconOnly)
        }
        .fixedSize()   // the ornament proposes little width: keep the title whole
        .padding(.horizontal, 18).padding(.vertical, 10)
        .glassBackgroundEffect()
    }

    /// Releases the pane and lets go of the terminal surface built for this stream (TerminalPaneView keeps one per IO).
    private func drop() {
        if let s = stream { TerminalPaneView.forget(s); s.close() }
        stream = nil
    }

    private func connect() async {
        drop(); ended = nil
        #if DEBUG
        if DemoMode.isOn, pane.host == DemoMode.hostID { stream = DemoMode.session(herdr: false); return }
        #endif
        guard let profile = app.hosts.host(pane.host) else { ended = "This machine is no longer in Sidra."; return }
        connecting = true
        defer { connecting = false }
        do {
            // --takeover: a window reopened after a dropped network would otherwise find its own old stream still holding the pane.
            let cmd = Herdr.path + "herdr" + Herdr.sessionArg(pane.session) + " terminal session control " + Herdr.shellQuote(pane.terminal) + " --takeover --cols 100 --rows 32"
            // A profile edited since (user, port, key, jump host) needs a new connection; the old one keeps its own copy.
            if let c = connection, c.profile != profile { let old = c; connection = nil; Task { await old.disconnect() } }
            let conn = connection ?? SSHConnection(profile: profile, jump: profile.jumpHostID.flatMap { app.hosts.host($0) })
            connection = conn
            let channel: PTYSession
            do { channel = try await conn.openShell(cols: 0, rows: 0, command: cmd, exec: true) } catch {
                if Task.isCancelled { await conn.disconnect() }   // closed mid-handshake: nothing else would end it
                throw error
            }
            // The window closed (or reconnected) while the channel opened: hand the pane straight back, and if the
            // window is gone, its connection too (onDisappear may have run before the connection existed).
            guard !Task.isCancelled else {
                HerdrPaneStream(channel).close()
                if connection !== conn || !windowOpen { Task { try? await Task.sleep(for: .milliseconds(600)); await conn.disconnect() } }
                return
            }
            let s = HerdrPaneStream(channel)
            stream = s
            s.onEnd { [weak s] reason in Task { @MainActor in
                guard let s, let current = stream as? HerdrPaneStream, current === s else { return }
                drop()
                ended = reason
            } }
            focus += 1
        } catch {
            ended = describeError(error)
        }
    }
}

/// One snapshot poll per machine for every open pane window's header, running while any window needs it.
@MainActor final class VisionMonitors {
    static let shared = VisionMonitors()
    private var monitors: [String: MuxMonitor] = [:]
    private var users: [String: Int] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    private func key(_ p: VisionPane) -> String { "\(p.host)|\(p.session ?? "default")" }

    func monitor(_ p: VisionPane) -> MuxMonitor {
        if let m = monitors[key(p)] { return m }
        let m = MuxMonitor(target: p.target, session: p.session)
        monitors[key(p)] = m
        return m
    }

    /// Polls while the calling view's task lives; the last window to go stops it.
    func watch(_ p: VisionPane, _ app: AppModel) async {
        let k = key(p), m = monitor(p)
        users[k, default: 0] += 1
        if tasks[k] == nil { tasks[k] = Task { await m.watch(app) } }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }   // sleep wakes when the view's task is cancelled
        users[k, default: 1] -= 1
        if users[k] == 0 { tasks.removeValue(forKey: k)?.cancel(); monitors[k] = nil; users[k] = nil }
    }
}

private struct HostKeyBox: Identifiable { let prompt: HostKeyPrompt; var id: String { "\(prompt.host):\(prompt.port)" } }

/// One herdr pane as a terminal: `terminal session control` on a plain SSH channel. Its stdout is
/// newline-delimited JSON (`terminal.frame` with base64 ANSI that herdr redraws from its own screen,
/// `terminal.closed` with a reason); stdin takes `terminal.input`, `terminal.resize` and `terminal.release`.
final class HerdrPaneStream: TerminalIO, @unchecked Sendable {
    let output: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let channel: PTYSession
    private let lock = NSLock()
    private var size: (Int, Int)?
    private var reason: String?
    /// The last line that was not herdr's JSON: the remote shell's own error ("herdr: command not found").
    private var diagnostic: String?
    private var endHandler: ((String) -> Void)?
    private var finalReason: String?

    /// Called once with why the stream ended (herdr's reason, or what the channel said); right away when it
    /// already has, so a channel that fails before the window registers still shows its error and Reconnect.
    func onEnd(_ handler: @escaping (String) -> Void) {
        let done: String? = lock.withLock {
            if let r = finalReason { return r }
            endHandler = handler; return nil
        }
        if let done { handler(done) }
    }

    init(_ channel: PTYSession) {
        self.channel = channel
        var c: AsyncStream<Data>.Continuation!
        output = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
        Task { [weak self] in
            var buffer = Data()
            for await chunk in channel.output {
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 10) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    self?.handle(line)
                }
            }
            guard let self else { return }
            self.continuation.finish()
            let text = String(decoding: buffer, as: UTF8.self).replacingOccurrences(of: #"\x{1b}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let (said, diag) = self.lock.withLock { (self.reason, self.diagnostic) }
            let message = Self.describe(said) ?? (!text.isEmpty ? text : diag ?? channel.endReason ?? "The pane's stream ended.")
            let end = self.lock.withLock { () -> ((String) -> Void)? in
                self.finalReason = message
                let cb = self.endHandler; self.endHandler = nil; return cb
            }
            end?(message)
        }
    }

    private func handle(_ line: Data) {
        guard let rec = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = rec["type"] as? String else {
            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let plain = text.replacingOccurrences(of: #"\x{1b}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
            if !plain.isEmpty { lock.withLock { diagnostic = plain } }
            return
        }
        switch type {
        case "terminal.frame":
            if let b = rec["bytes"] as? String, let d = Data(base64Encoded: b) { continuation.yield(d) }
        case "terminal.closed":
            lock.withLock { reason = rec["reason"] as? String ?? "closed" }
        default: break
        }
    }

    /// herdr's close reasons in words.
    static func describe(_ reason: String?) -> String? {
        guard let reason else { return nil }
        if reason == "terminal attach taken over" { return "Another window or client took this pane." }
        if reason == "detached" { return "Disconnected from the pane. It is still running." }
        if reason.contains("unknown") || reason.contains("not found") { return "The pane is gone. It was closed on the machine." }
        return reason
    }

    func write(_ data: Data) { send(["type": "terminal.input", "bytes": data.base64EncodedString()]) }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        let changed: Bool = lock.withLock {
            if let s = size, s == (cols, rows) { return false }
            size = (cols, rows); return true
        }
        if changed { send(["type": "terminal.resize", "cols": cols, "rows": rows]) }
    }

    /// Hands the pane back (its size returns to herdr's own clients), then closes the channel.
    func close() {
        send(["type": "terminal.release"])
        let channel = channel
        Task { try? await Task.sleep(for: .milliseconds(300)); channel.close() }
    }

    private func send(_ object: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: object) else { return }
        d.append(10)
        channel.write(d)
    }
}
#endif
