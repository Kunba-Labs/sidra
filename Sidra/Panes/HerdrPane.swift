import SwiftUI
import SidraDesign
import SidraWorkspace

/// A multiplexer's own client in a terminal, over SSH, under Sidra's spaces bar. The client's sidebar
/// is hidden (see herdr-attach.sh); the bar and the title bar's agent menu replace it.
struct HerdrPane: View {
    let pane: Pane
    let target: TerminalTarget
    let session: String?
    @Environment(AppModel.self) private var app

    var body: some View {
        let adapter = pane.kind.multiplexer?.adapter ?? HerdrAdapter()
        VStack(spacing: 0) {
            MuxSpacesBar(pane: pane)
            TerminalPane(pane: pane, target: target, command: adapter.attachCommand(session: session),
                         prepare: adapter.prepareCommand().map { cmd in { [app, target] in try await app.herdrPrepare(target, cmd) } })
        }
        .task { _ = MuxMonitors.shared.monitor(for: pane, app: app) }
        .onDisappear {
            if !app.allWorkspaces.contains(where: { $0.tabs.contains { $0.panes.contains { $0.id == pane.id } } }) { MuxMonitors.shared.remove(pane.id) }
        }
    }
}

/// The spaces as flat tabs: logo, name and status, a gradient underline on the one shown. Lighter than
/// the title bar's pill tabs on purpose; it switches what one pane shows, not the window.
struct MuxSpacesBar: View {
    let pane: Pane
    @Environment(AppModel.self) private var app
    /// The order shown while a space is dragged, until herdr's next snapshot has the move.
    @State private var order: [String]?
    @State private var dragging: String?
    /// The New space prompt: a name and a folder; `moving` moves the focused pane there instead of a fresh shell.
    @State private var newSpaceShown = false
    @State private var newSpaceMoving = false
    @State private var newSpaceLabel = ""
    @State private var newSpaceFolder = ""
    /// New space: pick an existing folder first (the usual case); a new folder is the picker's secondary action.
    @State private var pickerShown = false
    @State private var broadcastShown = false
    @State private var promptsShown = false
    /// The space whose tabs dropdown is open.
    @State private var tabsOpen: String?

    var body: some View {
        if let m = MuxMonitors.shared.byPane[pane.id], let s = m.snapshot {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        // One chip per space; a space with several tabs opens a dropdown of them (2026-11-16).
                        // Spaces with the same name and folder share a chip (MuxSnapshot.chips).
                        ForEach(Array(s.chips(shown(s)).enumerated()), id: \.element[0].id) { i, g in
                            reorder(tab(g, m: m, s: s), g[0], m, s)
                                .overlay(alignment: .topLeading) {
                                    // Held ⌃ in this pane: the key that picks each space (Waseem, 2026-11-19).
                                    if ModifierHold.shared.control, app.workspace.focusedPane?.id == pane.id, let k = TabKeys.label(i) { KeyHint("⌃" + k).offset(x: -2, y: -2) }
                                }
                                .animation(.easeOut(duration: 0.12), value: ModifierHold.shared.control)
                        }
                        // The space's tabs scroll with the spaces, so a narrow pane never pushes them off its edge.
                        if let ws = s.focused_workspace_id { tabsBar(m, s, space: ws) }
                    }
                    .padding(.horizontal, 6)
                    .sheet(isPresented: $promptsShown) { QuickPromptsSheet(pane: pane.id).environment(app) }
                }
                .sheet(isPresented: $broadcastShown) { BroadcastSheet(monitor: m).environment(app) }   // its own view: two sheets on one view clash
                if s.focused_workspace_id == nil {
                    // No space yet (a fresh herdr): the first one is made here.
                    Button { pickerShown = true } label: {
                        Label("New space", systemImage: "rectangle.stack.badge.plus").font(SidraFont.ui(12.5))
                    }
                    .buttonStyle(.sidraSecondary).padding(.horizontal, 10)
                }
                if !s.workspaces.isEmpty {
                    Button { promptsShown = true } label: {
                        Image(systemName: "text.bubble").font(.system(size: 13, weight: .semibold)).foregroundStyle(SidraColor.muted)
                            .frame(width: 28, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).padding(.horizontal, 8)
                    .accessibilityLabel("Prompts").accessibilityIdentifier("herdr-quick-prompts")
                }
            }
            .frame(height: 36)
            .background(SidraColor.ground2)
            .overlay(alignment: .top) { Rectangle().fill(SidraColor.hairline).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(SidraColor.hairline).frame(height: 1) }
            .background { spaceShortcuts(m, s) }
            .sheet(isPresented: $pickerShown) {
                NewSpacePicker(monitor: m, snapshot: s) { newSpaceMoving = false; newSpaceLabel = ""; newSpaceFolder = m.projectRoot + "/"; newSpaceShown = true }
                    .environment(app)
            }
            .alert(newSpaceMoving ? "Move to space" : "New space", isPresented: $newSpaceShown) {
            TextField("Name", text: Binding(get: { newSpaceLabel }, set: { v in
                // The folder follows the name until it is edited: <projects folder>/<name>.
                let root = (MuxMonitors.shared.byPane[pane.id]?.projectRoot ?? "~") + "/"
                if !newSpaceMoving, newSpaceFolder == root + newSpaceLabel { newSpaceFolder = root + v }
                newSpaceLabel = v
            }))
            .plainTextEntry().autocorrectionDisabled()
            if !newSpaceMoving {
                TextField("Folder", text: $newSpaceFolder).plainTextEntry().autocorrectionDisabled()
            }
            Button("Create") {
                guard let mon = MuxMonitors.shared.byPane[pane.id] else { return }
                let label = newSpaceLabel.trimmingCharacters(in: .whitespaces), folder = newSpaceFolder, moving = newSpaceMoving
                guard !label.isEmpty else { return }
                Task {
                    let ok = moving ? await mon.moveFocusedPaneToNewSpace(app, label: label) : await mon.newSpace(app, label: label, folder: folder)
                    if !ok { app.toast("herdr did not make the space") }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(newSpaceMoving ? "herdr's focused pane moves into a space of its own."
                 : "herdr opens a shell in that folder; it is made if missing." + (CodingAgent.startOnNewSpace.map { k in " Then it starts \(CodingAgent.all.first { $0.id == k }?.name ?? k)." } ?? ""))
        }
        } else {
            // Same height before the first snapshot and when herdr can't be read, so the terminal doesn't jump.
            let m = MuxMonitors.shared.byPane[pane.id]
            HStack(spacing: 8) {
                if let e = m?.error {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(SidraColor.yellow)
                    Text(e).font(SidraFont.ui(12)).foregroundStyle(SidraColor.yellow).lineLimit(1)
                } else {
                    GradientSpinner(size: 11)
                    Text("Reading spaces…").font(SidraFont.ui(12)).foregroundStyle(SidraColor.muted)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(SidraColor.ground2)
            .overlay(alignment: .top) { Rectangle().fill(SidraColor.hairline).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(SidraColor.hairline).frame(height: 1) }
        }
    }

    /// The + for a new tab, a split, a space or a prompt. The tabs themselves are chips in the spaces row.
    private func tabsBar(_ m: MuxMonitor, _ s: MuxSnapshot, space: String) -> some View {
        HStack(spacing: 4) {
            Rectangle().fill(SidraColor.hairline2).frame(width: 1, height: 18).padding(.horizontal, 6)
            SidraMenu([
                SidraMenuSection("Tab", [
                    SidraMenuItem("New tab", systemImage: "plus.rectangle.on.rectangle") { Task { await m.newTab(app, in: space) } },
                    SidraMenuItem("Split right", systemImage: "rectangle.split.2x1", identifier: "herdr-split-right") {
                        Task { if await !m.splitFocusedPane(app, down: false) { app.toast("herdr did not split the pane") } }
                    },
                    SidraMenuItem("Split down", systemImage: "rectangle.split.1x2", identifier: "herdr-split-down") {
                        Task { if await !m.splitFocusedPane(app, down: true) { app.toast("herdr did not split the pane") } }
                    },
                    SidraMenuItem("Move to tab", systemImage: "rectangle.portrait.and.arrow.forward") {
                        Task { if await !m.moveFocusedPane(app, to: nil) { app.toast("herdr did not move the pane") } }
                    },
                ]),
                SidraMenuSection("Space", [
                    SidraMenuItem("New space", systemImage: "rectangle.stack.badge.plus") { pickerShown = true },
                    SidraMenuItem("Move to space", systemImage: "arrow.up.right.square") { newSpaceMoving = true; newSpaceLabel = ""; newSpaceShown = true },
                ]),
                SidraMenuSection("Agents", [
                    SidraMenuItem("Broadcast", systemImage: "dot.radiowaves.left.and.right", identifier: "herdr-broadcast") { broadcastShown = true },
                ]),
            ]) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(SidraColor.muted).frame(width: 28, height: 24).contentShape(Rectangle())
            }
            .accessibilityLabel("New herdr tab or space")
            .accessibilityIdentifier("herdr-new-tab")
        }
        .fixedSize()

    }

    private func shown(_ s: MuxSnapshot) -> [MuxSnapshot.Workspace] {
        guard let order else { return s.workspaces }
        return s.workspaces.sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
    }

    /// Dragging any of a space's chips moves the whole space.
    // ponytail: a merged chip drags only its first space; the others stay put in herdr's order.
    private func reorder(_ chip: some View, _ ws: MuxSnapshot.Workspace, _ m: MuxMonitor, _ s: MuxSnapshot) -> some View {
        chip.reorderable(ws.id, dragging: $dragging) { dragged, over in
            var ids = shown(s).map(\.id)
            guard let from = ids.firstIndex(of: dragged), let to = ids.firstIndex(of: over) else { return }
            ids.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
            order = ids
        } commit: { dragged in
            guard let index = order?.firstIndex(of: dragged) else { return }
            Task {
                if await !m.moveSpace(app, dragged, to: index) { app.toast("herdr did not move the space") }
                order = nil
            }
        }
    }

    /// A space's chip (or several same-named spaces' one chip). With several tabs it shows their count and
    /// opens a dropdown: each tab, its stage, and Move here.
    @ViewBuilder private func tab(_ group: [MuxSnapshot.Workspace], m: MuxMonitor, s: MuxSnapshot) -> some View {
        let ws = group[0]
        let at = group.firstIndex { $0.id == s.focused_workspace_id }
        let on = at != nil
        let withAgents = group.filter { !s.agents(in: $0.id).isEmpty }
        let tabs = group.flatMap { s.tabs(in: $0.id) }
        // The pill is always the tab count, so the chip keeps its width when picked (2026-11-16); VoiceOver names the tab up.
        let up = on ? tabs.first { $0.focused && $0.workspace_id == s.focused_workspace_id } : nil
        let pill = tabs.count < 2 ? nil : "\(tabs.count)"
        let label = chip(ws, pill: pill, on: on, status: withAgents.isEmpty ? nil : MuxStatus.worst(withAgents.map(\.agent_status)), m: m)
        Group {
            if tabs.count > 1 {
                Button { tabsOpen = ws.id } label: { label }
                    .buttonStyle(.plain)
                    .popover(isPresented: Binding(get: { tabsOpen == ws.id }, set: { if !$0 { tabsOpen = nil } }), arrowEdge: .top) {
                        MuxTabsMenu(space: ws, tabs: tabs, shown: s.focused_workspace_id, logo: m.logo(for: ws)) { t in
                            tabsOpen = nil
                            Task {
                                // A tab of another space in the chip: herdr shows that space first.
                                if t.workspace_id != s.focused_workspace_id, let w = group.first(where: { $0.id == t.workspace_id }) { await m.focus(app, w) }
                                await m.focusTab(app, t.id)
                            }
                        }
                        .presentationCompactAdaptation(.popover)
                    }
            } else {
                // An older herdr reports no tabs: a merged chip steps through its spaces.
                Button { Task { await m.focus(app, group[((at ?? -1) + 1) % group.count]) } } label: { label }.buttonStyle(.plain)
            }
        }
        .accessibilityLabel("\(ws.label)\(tabs.count > 1 ? ", \(tabs.count) tabs" : "")\(up.map { t in ", showing " + (t.label.flatMap { $0.isEmpty ? nil : $0 } ?? "tab \(t.number)") } ?? ""), \(withAgents.isEmpty ? "no agents" : HerdrStatusIcon.label(MuxStatus.worst(withAgents.map(\.agent_status))))")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("herdr-space-\(ws.label)")
    }

    private func chip(_ ws: MuxSnapshot.Workspace, pill: String?, on: Bool, status: MuxStatus?, m: MuxMonitor) -> some View {
        HStack(spacing: 7) {
            HerdrLogoView(name: ws.label, image: m.logo(for: ws), size: 18.5)   // 16 + 15% (2026-11-17)
            Text(ws.label).font(SidraFont.ui(12.5, weight: on ? .bold : .regular))
                .foregroundStyle(on ? SidraColor.text : SidraColor.muted).lineLimit(1)
            if let pill {
                // The tab pill (small, dark, round), then the dropdown chevron.
                Text(pill).font(SidraFont.ui(10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(on ? SidraColor.text : SidraColor.muted).lineLimit(1)
                    .padding(.horizontal, pill.count > 1 ? 5 : 0).frame(minWidth: 16, minHeight: 16)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .overlay(Capsule().strokeBorder(SidraColor.hairline2))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(SidraColor.muted)
            }
            if let status, status != .unknown { HerdrStatusIcon(status: status, size: 9) }
        }
        .padding(.horizontal, 12).frame(height: 36)
        .overlay(alignment: .bottom) {
            if on { UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2).fill(SidraGradient.horizontal).frame(height: 2).padding(.horizontal, 10) }
        }
        .contentShape(Rectangle())
    }

    /// While this pane has focus: ⌃1–9, ⌃0, ⌃- and ⌃= (and the same with ⌥⌘) jump to a space in the bar's order, ⌃Tab / ⌃⇧Tab step
    /// through the spaces (⌘1–9 stay Sidra's own tabs).
    @ViewBuilder private func spaceShortcuts(_ m: MuxMonitor, _ s: MuxSnapshot) -> some View {
        if app.workspace.focusedPane?.id == pane.id {
            let spaces = s.chips(shown(s)).map { $0[0] }   // one stop per chip, in the bar's order
            ForEach(Array(spaces.prefix(TabKeys.keys.count).enumerated()), id: \.element.id) { i, ws in
                let key = KeyEquivalent(TabKeys.keys[i])
                Button("") { Task { await m.focus(app, ws) } }.keyboardShortcut(key, modifiers: .control).opacity(0).accessibilityHidden(true)
                Button("") { Task { await m.focus(app, ws) } }.keyboardShortcut(key, modifiers: [.command, .option]).opacity(0).accessibilityHidden(true)
            }
            if spaces.count > 1 {
                let at = s.chips(shown(s)).firstIndex { $0.contains { $0.id == s.focused_workspace_id } } ?? 0
                Button("") { Task { await m.focus(app, spaces[(at + 1) % spaces.count]) } }
                    .keyboardShortcut(.tab, modifiers: .control).opacity(0).accessibilityHidden(true)
                Button("") { Task { await m.focus(app, spaces[(at + spaces.count - 1) % spaces.count]) } }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift]).opacity(0).accessibilityHidden(true)
            }
        }
    }
}

/// New space in a folder that is already there: the folders in the machine's projects folder (see
/// MuxMonitor.projectRoot), searchable, each with its project's logo,
/// with the ones that already have a space marked; or any path. Making a new folder is the secondary action.
/// A row's › opens it, for a space in a subfolder like kvk/xxx (Waseem, 2026-11-19).
struct NewSpacePicker: View {
    let monitor: MuxMonitor
    let snapshot: MuxSnapshot
    let newFolder: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [String]?
    @State private var query = ""
    @State private var path = ""
    @State private var working = false
    /// The subfolders opened with ›, below the projects folder.
    @State private var sub: [String] = []
    private var dir: String { ([monitor.projectRoot] + sub).joined(separator: "/") }

    private var withSpace: Set<String> {
        Set(snapshot.workspaces.compactMap { snapshot.folder(of: $0.id).map { ($0 as NSString).lastPathComponent } })
    }
    private var shown: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return (folders ?? []).filter { q.isEmpty || $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("New space").font(SidraFont.ui(17, weight: .bold)).foregroundStyle(SidraColor.text)
                Spacer()
                Button("New folder…") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { newFolder() } }
                    .buttonStyle(.sidraSecondary).accessibilityIdentifier("new-space-new-folder")
            }
            Text("Pick a folder on \(app.herdrMachineName(monitor.target)); the space opens a shell there.")
                .font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted)
            StartAgentRow()
            HStack(spacing: 8) {
            TextField("Search \(dir)", text: $query)
                .plainTextEntry().autocorrectionDisabled()
                .font(SidraFont.ui(14)).padding(.horizontal, 10).frame(height: 36)
                .background(SidraColor.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SidraColor.hairline2))
                .accessibilityIdentifier("new-space-search")
                if monitor.projectRoots.count > 1 {
                    SidraMenu([SidraMenuSection("Projects folder", monitor.projectRoots.map { r in
                        SidraMenuItem(r, systemImage: r == monitor.projectRoot ? "checkmark" : nil) { monitor.projectRoot = r }
                    })]) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder").font(.system(size: 12))
                            Text(monitor.projectRoot).font(SidraFont.mono(12.5)).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(SidraColor.muted).padding(.horizontal, 10).frame(height: 36)
                        .background(SidraColor.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SidraColor.hairline2))
                    }
                    .accessibilityLabel("Projects folder, \(monitor.projectRoot)")
                }
            }
            if !sub.isEmpty {
                Button { sub.removeLast(); query = "" } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text(dir).font(SidraFont.mono(12.5)).lineLimit(1).truncationMode(.head)
                    }
                    .foregroundStyle(SidraColor.muted).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Back, in \(dir)").accessibilityIdentifier("new-space-up")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if folders == nil { HStack(spacing: 8) { GradientSpinner(size: 12); Text("Reading folders…").font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted) }.padding(10) }
                    else if shown.isEmpty { Text("No folder matches.").font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted).padding(10) }
                    ForEach(shown, id: \.self) { name in
                        HStack(spacing: 0) {
                            Button { Task { await create(label: name, folder: dir + "/" + name) } } label: {
                                HStack(spacing: 10) {
                                    HerdrLogoView(name: name, image: monitor.folderLogos[dir]?[name], size: 22)
                                    Text(name).font(SidraFont.ui(13.5, weight: .bold)).foregroundStyle(SidraColor.text).lineLimit(1)
                                    Spacer()
                                    if withSpace.contains(name) { Text("has a space").font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.dim) }
                                }
                                .padding(.leading, 10).frame(height: 40).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).disabled(working)
                            .accessibilityIdentifier("new-space-folder-\(name)")
                            // › opens the folder, for a space in one of its subfolders.
                            Button { sub.append(name); query = "" } label: {
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(SidraColor.muted)
                                    .frame(width: 40, height: 40).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).disabled(working)
                            .accessibilityLabel("Open \(name)").accessibilityIdentifier("new-space-open-\(name)")
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
            HStack(spacing: 8) {
                TextField("Or a path, e.g. ~/src/tool", text: $path)
                    .plainTextEntry().autocorrectionDisabled()
                    .font(SidraFont.mono(12.5)).padding(.horizontal, 10).frame(height: 32)
                    .background(SidraColor.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SidraColor.hairline2))
                Button("Open") {
                    let p = path.trimmingCharacters(in: .whitespaces)
                    Task { await create(label: (p as NSString).lastPathComponent, folder: p) }
                }
                .buttonStyle(.sidraPrimary).disabled(path.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(20)
        .frame(maxWidth: 520)
        .background(SidraColor.popup)
        .task(id: dir) {
            if monitor.projectRoots.isEmpty { await monitor.findProjectRoots(app) }
            folders = nil
            let root = dir
            folders = await monitor.folders(app, under: root)
            await monitor.loadFolderLogos(app, under: root)
        }
        .onChange(of: monitor.projectRoot) { sub = [] }
    }

    private func create(label: String, folder: String) async {
        working = true
        defer { working = false }
        if await monitor.newSpace(app, label: label, folder: folder) { dismiss() } else { app.toast("herdr did not make the space") }
    }
}

struct HerdrFooter: View {
    let pane: Pane
    var body: some View {
        if let m = MuxMonitors.shared.byPane[pane.id] {
            if let s = m.snapshot {
                FooterChip([.init("\(s.workspaces.count)", label: "spaces"), .init("\(s.agents.count)", label: "agents")]
                           + (s.count(.blocked) > 0 ? [.init("\(s.count(.blocked))", label: "needs you", color: SidraColor.gold)] : []))
            } else if m.error != nil {
                FooterItem("\(m.adapter.name) not reachable", color: SidraColor.yellow)
            }
            Spacer()
            FooterChip(m.adapter.keyHints.map { .init($0.key, label: $0.label) })
        }
    }
}

/// Needs you / working across multiplexer panes, beside the other title bar pills. Tapping opens
/// every agent grouped by project; a row opens it in Theasa, its arrow shows it in the pane.
struct HerdrTitleCounts: View {
    @Environment(AppModel.self) private var app
    @State private var open = false
    private var live: Set<UUID> { Set(app.allWorkspaces.flatMap { $0.tabs.flatMap { $0.panes.map(\.id) } }) }

    var body: some View {
        counts.onChange(of: live) { _, ids in MuxMonitors.shared.prune(live: ids) }
    }

    @ViewBuilder private var counts: some View {
        let monitors = MuxMonitors.shared
        let live = live
        let working = monitors.count(.working, live: live)
        let hub = PipelinesHub.shared                       // every connection: GitLab, GitHub, self-hosted
        let pipelines = hub.runningCount                    // their own count: a pipeline is no agent
        let failed = hub.unseenFailedCount                  // only failures you have not opened yet
        // Waiting agents keep the menu reachable even with nothing working and GitLab off (their count is on the Theasa pill).
        let waiting = monitors.count(.blocked, live: live) > 0
        if working > 0 || pipelines > 0 || hub.connected || waiting {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    // No separate waiting pill: the Theasa pill shows "N waiting" (2026-11-14).
                    // One working pill for agents and pipelines; its dropdown has a tab for each. With nothing
                    // running but GitLab connected, just the pipelines icon opens the same dropdown (no "0 working").
                    if working + pipelines > 0 || hub.connected || waiting {
                        HStack(spacing: 6) {
                            if working + pipelines > 0 {
                                HerdrStatusIcon(status: .working, size: 10)
                                Text("\(working + pipelines)").font(SidraFont.ui(12.5, weight: .bold)).foregroundStyle(SidraColor.text)
                                Text("working").font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted)
                            } else if hub.connected {
                                ProcessIcon(.pipelines, size: 14)
                            } else {
                                HerdrStatusIcon(status: .blocked, size: 9)
                            }
                            if failed > 0 { Circle().fill(SidraColor.red).frame(width: 7, height: 7) }   // a pipeline failed this week and you have not opened it
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(SidraColor.dim)
                        }
                        .pillBox()
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(working) agents and \(pipelines) pipelines working, \(failed) new failed pipelines")
            .accessibilityIdentifier("mux-agents")
            .popover(isPresented: $open, arrowEdge: .top) {
                MuxAgentsMenu(live: live) { open = false }.environment(app).presentationCompactAdaptation(.popover)
            }
        }
    }
}

/// Every agent across open multiplexer panes, grouped by project (space), most urgent first.
struct MuxAgentsMenu: View {
    let live: Set<UUID>
    let close: () -> Void
    @Environment(AppModel.self) private var app
    enum Section { case agents, pipelines }
    /// Agents first when there are any, else pipelines.
    @State private var section: Section?
    private static let order: [MuxStatus] = [.blocked, .working, .done, .idle, .unknown]
    private static func rank(_ s: MuxStatus) -> Int { order.firstIndex(of: s) ?? order.count }

    /// One monitor per machine and session; two panes on the same herdr list its agents once.
    private var sources: [(pane: UUID, monitor: MuxMonitor, snapshot: MuxSnapshot)] {
        var seen = Set<String>()
        return MuxMonitors.shared.byPane.sorted { $0.key.uuidString < $1.key.uuidString }.compactMap { id, m in
            guard live.contains(id), let s = m.snapshot, !s.agents.isEmpty, seen.insert(m.key).inserted else { return nil }
            return (id, m, s)
        }
    }

    var body: some View {
        let sources = sources
        let pipes = PipelinesHub.shared
        let shown = section ?? (sources.isEmpty && pipes.connected ? .pipelines : .agents)
        VStack(alignment: .leading, spacing: 6) {
            if pipes.connected {
                HStack(spacing: 4) {
                    sectionButton("Agents", icon: .agent, count: sources.reduce(0) { $0 + $1.snapshot.agents.count }, on: shown == .agents) { section = .agents }
                    sectionButton("Pipelines", icon: .pipelines, count: pipes.runningCount, on: shown == .pipelines) { section = .pipelines }
                    Spacer()
                }
                .padding(.horizontal, 4)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if shown == .pipelines { allPipelines } else { agents(sources) }
                }
            }
        }
        .frame(maxHeight: 560)
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .frame(width: 420)
        .background(SidraColor.popup)
    }

    private func sectionButton(_ title: String, icon: ProcessIcon.Kind, count: Int, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ProcessIcon(icon, size: 16)
                Text(title).font(SidraFont.ui(12.5, weight: on ? .bold : .regular)).foregroundStyle(on ? SidraColor.text : SidraColor.muted)
                if count > 0 { Text("\(count)").font(SidraFont.ui(11, weight: .bold)).foregroundStyle(SidraColor.muted) }
            }
            .padding(.leading, 6).padding(.trailing, 10).frame(height: 28)
            .background(on ? SidraColor.tabActive : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay { if on { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SidraGradient.horizontal, lineWidth: 1) } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("section-\(title.lowercased())")
    }

    /// Running pipelines of every connection on top, a divider, then the recent finished ones: per
    /// connection (when there are several), grouped by namespace like the pipelines TUI, five per group.
    @ViewBuilder private var allPipelines: some View {
        let hub = PipelinesHub.shared
        let stores = hub.all.filter(\.connected)
        let running = stores.flatMap { s in s.running.map { RunningRow(store: s, pipeline: $0) } }.sorted { $0.pipeline.updated_at > $1.pipeline.updated_at }
        if stores.allSatisfy({ $0.pipelines.isEmpty }) {
            Text(hub.loading ? "Reading pipelines…" : stores.compactMap(\.error).first ?? "No pipelines yet.")
                .font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted).padding(10)
        }
        if !running.isEmpty {
            HStack(spacing: 8) {
                // Spins only while something runs; pending and queued alone show a clock.
                if running.contains(where: { $0.pipeline.status == "running" }) { GradientSpinner(size: 13) }
                else { Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(SidraColor.dim) }
                Text("ACTIVE").font(SidraFont.ui(11, weight: .bold)).foregroundStyle(SidraColor.muted).tracking(0.5)
                Spacer()
                Text("\(running.count)").font(SidraFont.ui(11)).foregroundStyle(SidraColor.dim)
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
            // Keyed by connection and pipeline: ids repeat across services. With several connections each
            // running row carries its service's mark, as the finished ones sit under its name.
            ForEach(running, id: \.key) { r in pipelineRow(r.pipeline, r.store, mark: stores.count > 1) }
            if stores.contains(where: { $0.pipelines.contains { !$0.isActive } }) {
                Rectangle().fill(SidraColor.hairline2).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 8)
            }
        }
        ForEach(stores, id: \.connection.id) { store in
            if stores.count > 1, store.pipelines.contains(where: { !$0.isActive }) {
                HStack(spacing: 8) {
                    ProviderMark(provider: store.connection.provider, size: 14)
                    Text(hub.label(for: store.connection)).font(SidraFont.ui(12, weight: .bold)).foregroundStyle(SidraColor.text)
                }
                .padding(.horizontal, 10).padding(.top, 12)
            }
            pipelineGroups(store)
        }
    }

    @ViewBuilder private func pipelineGroups(_ store: PipelinesStore) -> some View {
        let groups = Dictionary(grouping: store.pipelines.filter { !$0.isActive }) { store.projects[$0.project_id]?.group ?? "?" }
            .sorted { $0.value[0].updated_at > $1.value[0].updated_at }
        ForEach(groups, id: \.key) { name, list in
            HStack(spacing: 8) {
                PipelineAvatar(image: store.avatar(group: name), name: name, size: 16)
                Text(name.uppercased()).font(SidraFont.ui(11, weight: .bold)).foregroundStyle(SidraColor.muted).tracking(0.5)
                Spacer()
                Text("\(list.count)").font(SidraFont.ui(11)).foregroundStyle(SidraColor.dim)
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
            ForEach(list.prefix(5)) { p in pipelineRow(p, store) }
        }
    }

    private struct RunningRow { let store: PipelinesStore; let pipeline: GitLabPipeline
        var key: String { "\(store.connection.id.uuidString)-\(pipeline.id)" } }

    private func pipelineRow(_ p: GitLabPipeline, _ store: PipelinesStore, mark: Bool = false) -> some View {
        let project = store.projects[p.project_id]?.name ?? "project \(p.project_id)"
        return Button { close(); app.openPipelines(connection: store.connection.id, reveal: p.id) } label: {
            HStack(spacing: 9) {
                PipelineStatusIcon(status: p.status, size: 14)
                if mark {   // which connection: its mark and name, as two connections can share a service
                    ProviderMark(provider: store.connection.provider, size: 13)
                    Text(PipelinesHub.shared.label(for: store.connection)).font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.dim)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 110, alignment: .leading)
                }
                PipelineAvatar(image: store.avatar(project: p.project_id), name: project, size: 14)
                Text(project).font(SidraFont.ui(13, weight: .bold)).foregroundStyle(SidraColor.text).lineLimit(1)
                Text(p.ref).font(SidraFont.mono(11)).foregroundStyle(SidraColor.dim).lineLimit(1)
                Spacer(minLength: 6)
                Text(PipelinesPane.ago(p.updated_at)).font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.muted)
            }
            .padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mark ? PipelinesHub.shared.label(for: store.connection) + ", " : "")\(project) \(p.ref), \(p.status), open in Pipelines")
    }

    @ViewBuilder private func agents(_ sources: [(pane: UUID, monitor: MuxMonitor, snapshot: MuxSnapshot)]) -> some View {
                if sources.isEmpty {
                    Text("No agents in open herdr tabs.").font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted).padding(10)
                }
                ForEach(sources, id: \.pane) { src in
                    HStack(spacing: 6) {
                        Text("Agents on").foregroundStyle(SidraColor.muted)
                        Text(app.herdrMachineName(src.monitor.target)).fontWeight(.bold).foregroundStyle(SidraColor.text)
                    }
                    .font(SidraFont.ui(12)).padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
                    let spaces = src.snapshot.workspaces.filter { !src.snapshot.agents(in: $0.id).isEmpty }
                        .sorted { Self.rank($0.agent_status) < Self.rank($1.agent_status) }
                    ForEach(spaces) { ws in
                        group(ws, src: src)
                    }
                }
    }

    @ViewBuilder private func group(_ ws: MuxSnapshot.Workspace, src: (pane: UUID, monitor: MuxMonitor, snapshot: MuxSnapshot)) -> some View {
        let agents = src.snapshot.agents(in: ws.id).sorted { Self.rank($0.agent_status) < Self.rank($1.agent_status) }
        HStack(spacing: 8) {
            HerdrLogoView(name: ws.label, image: src.monitor.logo(for: ws), size: 18)
            Text(ws.label).font(SidraFont.ui(12, weight: .bold)).foregroundStyle(SidraColor.text).lineLimit(1)
            Spacer()
            Text(agents.count == 1 ? "1 agent" : "\(agents.count) agents").font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.muted)
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
        ForEach(agents) { a in
            HStack(spacing: 10) {
                let choices = app.theasaConnections(for: src.monitor.target)
                let row = HStack(spacing: 10) {
                    HerdrAgentMark(agent: a.agent, size: 14)
                    Text(a.terminal_title_stripped.flatMap { $0.isEmpty ? nil : $0 } ?? a.agent)
                        .font(SidraFont.ui(13)).foregroundStyle(SidraColor.text).lineLimit(1)
                    Spacer(minLength: 6)
                    HerdrStatusChip(status: a.agent_status)
                }
                .contentShape(Rectangle())
                Group {
                    if choices.count > 1 {
                        // Several Theasa servers and none is this machine's: ask which.
                        Menu {
                            ForEach(choices) { c in Button(c.name + (URL(string: c.url)?.host.map { ", \($0)" } ?? "")) { close(); app.openAgentInTheasa(a.pane_id, connection: c.id) } }
                        } label: { row }
                    } else {
                        Button { close(); app.openAgentInTheasa(a.pane_id, connection: choices.first?.id) } label: { row }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(a.terminal_title_stripped ?? a.agent), \(HerdrStatusIcon.label(a.agent_status)), open in Theasa")
                .accessibilityIdentifier("mux-agent-\(a.pane_id)")
                Button {
                    close()
                    app.open(.pane(src.pane))
                    Task { await src.monitor.focusAgent(app, pane: a.pane_id) }
                } label: {
                    Image(systemName: "arrow.up.forward.square").font(.system(size: 13)).foregroundStyle(SidraColor.muted).frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show in \(src.monitor.adapter.name)")
            }
            .padding(.leading, 36).padding(.trailing, 6).frame(height: 36)
        }
    }
}

extension AppModel {
    /// Opens Theasa's Agents screen on this agent: in an open Theasa pane, else a new tab on the first
    /// saved connection, else the connect sheet. Theasa reads the same herdr, so pane ids match.
    /// The Theasa connections that can show this machine's agents: those whose host matches the
    /// machine's host or alias (first label, so devbox matches devbox.tailnet.ts.net); all when none matches.
    func theasaConnections(for target: TerminalTarget) -> [TheasaConnection] {
        let all = TheasaStore.shared.connections
        func label(_ s: String) -> String { String(s.lowercased().prefix { $0 != "." }) }
        var names: Set<String> = [label(herdrMachineName(target))]
        if case .ssh(let id) = target, let h = hosts.host(id) { names.insert(label(h.host)); names.insert(label(h.alias)) }
        let matched = all.filter { c in URL(string: c.url)?.host.map { names.contains(label($0)) } ?? false }
        return matched.isEmpty ? all : matched
    }

    /// Opens Theasa's popover on that connection's Agents screen at this agent; without a connection, the connect sheet.
    func openAgentInTheasa(_ agentPane: String, connection: UUID?) {
        TheasaStore.shared.openAgent(agentPane, connection: connection, app: self)   // Theasa's popover, on Agents at this card
    }
}

private extension View {
    func pillBox() -> some View {
        padding(.horizontal, 10).frame(height: 28)
            .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: SidraRadius.pill, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SidraRadius.pill, style: .continuous).strokeBorder(SidraColor.hairline))
    }
}

// MARK: - Small pieces

/// Working spins with the gradient (it is progress); needs you is gold, done jade, idle a ring.
struct HerdrStatusIcon: View {
    let status: MuxStatus
    var size: CGFloat = 10
    var body: some View {
        switch status {
        case .working: GradientSpinner(size: size)
        case .blocked: Circle().fill(SidraColor.gold).frame(width: size - 1, height: size - 1)
        case .done: Circle().fill(SidraColor.jade).frame(width: size - 1, height: size - 1)
        case .idle, .unknown: Circle().strokeBorder(SidraColor.dim, lineWidth: 1.5).frame(width: size - 1, height: size - 1)
        }
    }
    static func label(_ s: MuxStatus) -> String {
        switch s {
        case .working: "Working"
        case .blocked: "Needs you"
        case .done: "Done"
        case .idle: "Idle"
        case .unknown: "No agent"
        }
    }
}

struct HerdrStatusChip: View {
    let status: MuxStatus
    var body: some View {
        let color: Color = switch status { case .blocked: SidraColor.gold; case .done: SidraColor.jade; case .working: SidraColor.text; default: SidraColor.muted }
        HStack(spacing: 5) {
            HerdrStatusIcon(status: status, size: 9)
            Text(HerdrStatusIcon.label(status)).font(SidraFont.ui(11.5)).foregroundStyle(color)
        }
        .padding(.horizontal, 7).frame(height: 22)
        .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(status == .blocked ? SidraColor.gold.opacity(0.3) : SidraColor.hairline))
    }
}

/// The project's own logo, or its first letter when the folder has none.
struct HerdrLogoView: View {
    let name: String
    let image: PlatformImage?
    var size: CGFloat = 20
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        Group {
            if let image {
                Image(platformImage: image).resizable().scaledToFill()
            } else {
                Text(String(name.first(where: { $0.isLetter || $0.isNumber }) ?? "?").uppercased())
                    .font(SidraFont.ui(size * 0.5, weight: .bold)).foregroundStyle(SidraColor.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(hex: 0x2a3039))
            }
        }
        .frame(width: size, height: size).clipShape(shape)
        .accessibilityHidden(true)
    }
}

/// A space's tabs, in Sidra's popup style: the project's logo, the tab, and its stage; the one showing in the gradient.
/// Rows only switch tabs. No "Move here" into an existing tab (2026-11-16: leave it out); + > Move to tab remains.
struct MuxTabsMenu: View {
    let space: MuxSnapshot.Workspace
    let tabs: [MuxSnapshot.Tab]
    /// The space herdr shows; its focused tab is the one up.
    let shown: String?
    let logo: PlatformImage?
    let pick: (MuxSnapshot.Tab) -> Void

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { i, t in
                let on = t.workspace_id == shown && t.focused
                let n = i + 1   // counted across the chip: merged spaces each start at tab 1
                Button { pick(t) } label: {
                    HStack(spacing: 10) {
                        HerdrLogoView(name: space.label, image: logo, size: 20)
                        let name = Text(t.label.flatMap { $0.isEmpty || Int($0) != nil ? nil : $0 } ?? "\(space.label) \(n)")
                            .font(SidraFont.ui(13.5, weight: on ? .bold : .regular))
                        if on {
                            // The tab showing: its name in the gradient, a blinking caret after it.
                            HStack(spacing: 0) { name.foregroundStyle(SidraGradient.horizontal).lineLimit(1); BlinkCaret(font: SidraFont.ui(13.5, weight: .bold)) }
                        } else {
                            name.foregroundStyle(SidraColor.muted).lineLimit(1)
                        }
                        Spacer(minLength: 16)
                        if t.agent_status != .unknown { HerdrStatusIcon(status: t.agent_status, size: 10) }
                        Text(HerdrStatusIcon.label(t.agent_status)).font(SidraFont.ui(12)).foregroundStyle(SidraColor.muted)
                    }
                    .padding(.horizontal, 10).frame(height: 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(space.label) tab \(n), \(HerdrStatusIcon.label(t.agent_status))")
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("herdr-tab-\(space.label)-\(n)")
            }
        }
        }
        .frame(maxHeight: 480).fixedSize(horizontal: false, vertical: true)   // many tabs scroll instead of running off the screen
        .padding(6)
        .frame(width: 280)
        .background(SidraColor.popup)
    }
}

/// HackerTab's block cursor (BlinkTitle): " ▌" in orange, blinking; steady with Reduce Motion.
struct BlinkCaret: View {
    var font: Font
    @Environment(\.accessibilityReduceMotion) private var still
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.53)) { t in
            let lit = still || Int(t.date.timeIntervalSinceReferenceDate / 0.53) % 2 == 0
            Text(verbatim: " ▌").font(font).foregroundStyle(lit ? SidraColor.orange : .clear)
        }
        .accessibilityHidden(true)
    }
}

/// The coding agent a new space starts in its first pane (the agents Sidra has official marks for).
enum CodingAgent {
    static let all: [(id: String, name: String)] = [("claude", "Claude Code"), ("codex", "Codex"), ("amp", "Amp"), ("pi", "Pi")]
    static let onKey = "sidra.newSpace.startAgent", kindKey = "sidra.newSpace.agent"
    /// The executable to run in a new space, or nil when the toggle is off. On, Claude Code, by default.
    static var startOnNewSpace: String? {
        let d = UserDefaults.standard
        guard d.object(forKey: onKey) == nil || d.bool(forKey: onKey) else { return nil }
        return d.string(forKey: kindKey) ?? "claude"
    }
}

/// Start coding agent: a toggle and the agent, each with its own logo. Read by every New space path.
struct StartAgentRow: View {
    @AppStorage(CodingAgent.onKey) private var on = true
    @AppStorage(CodingAgent.kindKey) private var kind = "claude"
    var body: some View {
        // Side by side when it fits, stacked on a narrow sheet.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { toggle; Spacer(); picker }
            VStack(alignment: .leading, spacing: 8) { toggle; picker }
        }
    }
    private var toggle: some View {
            Toggle("Start coding agent", isOn: $on).toggleStyle(GradientToggleStyle())
                .font(SidraFont.ui(13)).foregroundStyle(SidraColor.text).fixedSize()
                .accessibilityIdentifier("new-space-start-agent")
    }
    private var picker: some View {
            Menu {
                ForEach(CodingAgent.all, id: \.id) { a in
                    Button { kind = a.id } label: { Label { Text(a.name) } icon: { Image("agent-\(a.id)").renderingMode(.original) } }
                }
            } label: {
                HStack(spacing: 6) {
                    HerdrAgentMark(agent: kind, size: 16)
                    Text(CodingAgent.all.first { $0.id == kind }?.name ?? kind).font(SidraFont.ui(13, weight: .bold)).foregroundStyle(SidraColor.text)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(SidraColor.muted)
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(SidraColor.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SidraColor.hairline2))
            }
            .disabled(!on).opacity(on ? 1 : 0.45)
            .accessibilityIdentifier("new-space-agent")
    }
}

/// An agent's own mark (official files from herdr.dev), or its initial for agents without one.
struct HerdrAgentMark: View {
    let agent: String
    var size: CGFloat = 14
    static let known: Set<String> = ["claude", "codex", "pi", "amp"]
    var body: some View {
        if Self.known.contains(agent) {
            Image("agent-\(agent)").resizable().scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
        } else {
            Text(String(agent.prefix(1)).uppercased()).font(SidraFont.ui(size * 0.7, weight: .bold)).foregroundStyle(SidraColor.muted)
                .frame(width: size, height: size).background(SidraColor.raised, in: RoundedRectangle(cornerRadius: 3))
                .accessibilityHidden(true)
        }
    }
}

/// One command typed into many agents at once (2026-11-14): `/remote-control` after switching
/// claude.ai accounts (each session drops Remote Control and needs it again), `/exit`, or any prompt.
/// All agents are picked by default; herdr's `agent prompt` types the text and presses Return in each.
struct BroadcastSheet: View {
    let monitor: MuxMonitor
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text = "/remote-control"
    @State private var off: Set<String> = []
    @State private var confirm = false
    @State private var sending = false

    private var agents: [MuxSnapshot.Agent] { monitor.snapshot?.agents ?? [] }
    private var picked: [String] { agents.map(\.pane_id).filter { !off.contains($0) } }
    private var command: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Broadcast command").font(SidraFont.ui(17, weight: .bold)).foregroundStyle(SidraColor.text)
            Text("Types the command into each picked agent on \(app.herdrMachineName(monitor.target)) and presses Return.")
                .font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted)
            TextField("/remote-control", text: $text)
                .plainTextEntry().autocorrectionDisabled()
                .font(SidraFont.mono(14)).padding(.horizontal, 10).frame(height: 36)
                .background(SidraColor.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SidraColor.hairline2))
                .accessibilityIdentifier("broadcast-text")
            HStack(spacing: 6) {
                ForEach(["/remote-control", "/exit"], id: \.self) { c in
                    Button(c) { text = c }.buttonStyle(.sidraSecondary).font(SidraFont.mono(12))
                }
                Spacer()
                Button(off.isEmpty ? "None" : "All") { off = off.isEmpty ? Set(agents.map(\.pane_id)) : [] }
                    .buttonStyle(.sidraSecondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if agents.isEmpty { Text("No agents are running.").font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted).padding(10) }
                    ForEach(agents) { a in row(a) }
                }
            }
            .frame(maxHeight: 360)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.sidraSecondary)
                Button(picked.count == 1 ? "Send to 1 agent" : "Send to \(picked.count) agents") { confirm = true }
                    .buttonStyle(.sidraPrimary).disabled(command.isEmpty || picked.isEmpty || sending)
                    .accessibilityIdentifier("broadcast-send")
            }
        }
        .padding(20)
        .frame(maxWidth: 520)
        .background(SidraColor.popup)
        .confirmationDialog("Send \(command) to \(picked.count) agent\(picked.count == 1 ? "" : "s")?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Send", role: command.hasPrefix("/exit") || command.hasPrefix("/quit") ? .destructive : nil) { Task { await send() } }
        }
    }

    private func row(_ a: MuxSnapshot.Agent) -> some View {
        let ws = monitor.snapshot?.workspaces.first { $0.id == a.workspace_id }
        let on = !off.contains(a.pane_id)
        return Button { if on { off.insert(a.pane_id) } else { off.remove(a.pane_id) } } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? SidraColor.jade : SidraColor.dim)
                if let ws { HerdrLogoView(name: ws.label, image: monitor.logo(for: ws), size: 20) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(ws?.label ?? a.pane_id).font(SidraFont.ui(13.5, weight: .bold)).foregroundStyle(SidraColor.text).lineLimit(1)
                    Text([a.agent, a.terminal_title_stripped].compactMap { $0 }.joined(separator: " · ")).font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.muted).lineLimit(1)
                }
                Spacer()
                HerdrStatusIcon(status: a.agent_status, size: 9)
            }
            .padding(.horizontal, 10).frame(height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("broadcast-agent-\(a.pane_id)")
    }

    private func send() async {
        sending = true
        defer { sending = false }
        let panes = picked
        guard let failed = await monitor.broadcast(app, command, to: panes) else { app.toast("Could not reach \(app.herdrMachineName(monitor.target))"); return }
        app.toast(failed.isEmpty ? "Sent \(command) to \(panes.count) agent\(panes.count == 1 ? "" : "s")"
                                 : "Sent to \(panes.count - failed.count) of \(panes.count); herdr refused \(failed.count)")
        dismiss()
    }
}

/// Short prompts typed over and over ("status", "what's left"): tap one and it goes into this pane's
/// terminal with Return. The list is kept on this device and edited here.
struct QuickPromptsSheet: View {
    let pane: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sidra.quickPrompts") private var stored = ""
    @State private var adding = false
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    static let defaults = ["status", "what's left", "issues you found"]
    private var prompts: [String] {
        get { stored.isEmpty ? Self.defaults : ((try? JSONDecoder().decode([String].self, from: Data(stored.utf8))) ?? Self.defaults) }
    }
    private func save(_ list: [String]) { stored = String(decoding: (try? JSONEncoder().encode(list)) ?? Data("[]".utf8), as: UTF8.self) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Quick prompt").font(SidraFont.ui(17, weight: .bold)).foregroundStyle(SidraColor.text)
                Spacer()
                Button { adding = true; draft = ""; draftFocused = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.sidraSecondary).accessibilityLabel("Add a prompt").accessibilityIdentifier("quick-prompt-add")
            }
            Text("Tap one to type it into this pane and press Return. Hold one to remove it.")
                .font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted)
            if adding {
                HStack(spacing: 8) {
                    TextField("New prompt", text: $draft)
                        .plainTextEntry().autocorrectionDisabled()
                        .focused($draftFocused).onSubmit(add)
                        .font(SidraFont.mono(14)).padding(.horizontal, 10).frame(height: 36)
                        .background(SidraColor.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SidraColor.hairline2))
                        .accessibilityIdentifier("quick-prompt-text")
                    Button("Add", action: add).buttonStyle(.sidraPrimary)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if prompts.isEmpty { Text("No prompts yet. Add one with +.").font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted).padding(10) }
                    ForEach(Array(prompts.enumerated()), id: \.offset) { i, p in
                        Button { send(p) } label: {
                            HStack(spacing: 10) {
                                Text(p).font(SidraFont.mono(14)).foregroundStyle(SidraColor.text).lineLimit(2).multilineTextAlignment(.leading)
                                Spacer()
                                Image(systemName: "return").foregroundStyle(SidraColor.dim)
                            }
                            .padding(.horizontal, 12).frame(minHeight: 44)
                            .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SidraColor.hairline))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { var l = prompts; l.remove(at: i); save(l) } label: { Label("Remove", systemImage: "trash") }
                        }
                        .accessibilityIdentifier("quick-prompt-\(i)")
                    }
                }
            }
            .frame(maxHeight: 360)
            HStack { Spacer(); Button("Close") { dismiss() }.buttonStyle(.sidraSecondary) }
        }
        .padding(20)
        .frame(maxWidth: 520)
        .background(SidraColor.popup)
    }

    private func add() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        save(prompts + [t])
        draft = ""; adding = false
    }

    /// The text, then Return a moment later: a TUI such as Claude Code reads text and Return arriving
    /// together as a paste and would put a newline in the prompt instead of sending it.
    private func send(_ text: String) {
        guard let s = TerminalLink.of(pane).session else { app.toast("This pane is not connected"); return }
        s.write(Data(text.utf8))
        Task { try? await Task.sleep(for: .milliseconds(120)); s.write(Data("\r".utf8)) }
        dismiss()
    }
}
