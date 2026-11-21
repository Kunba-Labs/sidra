import SwiftUI
import SidraDesign
import SidraWorkspace

/// Substrate's electric gradient. Approved exception (Waseem, 2026-11-20): Sidra's gradient stays on the
/// chrome (tab and pane borders, the picked row's underline); this one is used inside the pane only, on the
/// section control, Approve, the "deploys to test" chip, the waiting count and the sign-in.
enum SubstrateStyle {
    static let electric = LinearGradient(colors: [Color(hex: 0x3B5BFF), Color(hex: 0x7B2CFF), Color(hex: 0xC04BFF)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
    static let glow = Color(hex: 0x5B3BFF).opacity(0.33)
    static let side = Color(hex: 0x101318)
    static let main = Color(hex: 0x0f1216)
    static let card = Color(hex: 0x161a20)
    static let chip = Color(hex: 0x1b2028)
    static let well = Color(hex: 0x0b0d10)
}

// MARK: - Pane

struct SubstratePane: View {
    @Bindable var store: SubstrateStore
    let pane: Pane
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if !store.signedIn {
                SubstrateSignIn(store: store)
            } else {
                switch store.section {
                // Its keys only while this pane has focus: hidden tabs stay built, and ↑↓ or ⌘↩ typed
                // in another pane must not approve anything (Waseem, 2026-11-20).
                case .requests: SubstrateRequests(store: store, keysOn: app.workspace.focusedPane?.id == pane.id)
                case .sessions: SubstrateSessions(store: store, keysOn: app.workspace.focusedPane?.id == pane.id)
                case .machines: SubstrateMachines(store: store)
                }
            }
        }
        .background(SubstrateStyle.main)
        .task { store.start() }
    }
}

/// In the pane header: Requests / Sessions / Machines and New session (signed in only).
struct SubstrateHeader: View {
    @Bindable var store: SubstrateStore
    var body: some View {
        if store.signedIn {
            HStack(spacing: 10) {
                HStack(spacing: 2) {
                    ForEach(SubstrateStore.Section.allCases, id: \.self) { s in
                        let on = store.section == s
                        Button { store.section = s } label: {
                            HStack(spacing: 6) {
                                Text(s.rawValue).font(SidraFont.ui(12.5, weight: on ? .bold : .regular))
                                if s == .requests, store.waiting > 0 {
                                    Text(verbatim: "\(store.waiting)").font(SidraFont.mono(10, weight: .semibold))
                                        .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16)
                                        .background(on ? Color.white.opacity(0.2) : SubstrateStyle.well, in: Capsule())
                                        .overlay(Capsule().strokeBorder(on ? .clear : SidraColor.hairline2))
                                }
                            }
                            .foregroundStyle(on ? .white : SidraColor.muted)
                            .padding(.horizontal, 11).frame(height: 26)
                            .background { if on { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SubstrateStyle.electric).shadow(color: SubstrateStyle.glow, radius: 8, y: 2) } }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(3)
                .background(SubstrateStyle.main, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SidraColor.hairline))
                SidraMenu([SidraMenuSection("Signed in as \(store.connection.name ?? store.connection.email)", [
                    SidraMenuItem("Sign out", systemImage: "rectangle.portrait.and.arrow.right") { Task { await store.signOut() } },
                ])]) {
                    Image(systemName: "person.crop.circle").font(.system(size: 14)).foregroundStyle(SidraColor.muted).frame(width: 28, height: 26).contentShape(Rectangle())
                }
                .accessibilityLabel("Substrate account")
                if let u = store.dashboard?.new_session_url ?? store.sessions?.new_session_url, let url = URL(string: u) {
                    SubstrateChip { Text("New session"); Image(systemName: "arrow.up.right.square") }.onTapGesture { Platform.open(url) }
                        .accessibilityAddTraits(.isButton).accessibilityLabel("New session, opens the browser")
                }
            }
        }
    }
}

struct SubstrateFooter: View {
    let store: SubstrateStore?
    var body: some View {
        if let store, store.signedIn {
            let c = store.dashboard?.counts
            FooterItem("\(c?.waiting ?? 0) waiting", color: (c?.waiting ?? 0) > 0 ? SidraColor.gold : SidraColor.dim)
            FooterItem("\(c?.active ?? 0) active")
            if let agents = c?.agents { FooterItem("\(agents) agents" + (store.machines.count == 1 ? " on \(store.machines[0].name)" : "")) }
            Spacer()
            FooterItem(store.section == .sessions ? "↑↓ session  ⌘N new session in the browser" : "↑↓ request  ⌘↩ approve  ⌘⌫ reject  ⌘O open in browser")
        } else {
            FooterItem(store?.connection.host ?? "substrate.gliph.sh")
            Spacer()
            FooterItem("signed out")
        }
    }
}

// MARK: - Requests

struct SubstrateRequests: View {
    @Bindable var store: SubstrateStore
    let keysOn: Bool
    @State private var width: CGFloat = 900
    @Environment(AppModel.self) private var app
    @State private var fullPrompt = false
    @State private var working = false
    @State private var draft = ""
    @State private var why = ""
    /// A held request waiting for "Approve anyway"; `text` is the edit, nil for a plain approve.
    @State private var confirmHeld: (message: Substrate.Message, text: String?)?

    private var groups: [(String, [Substrate.Message], Color)] {
        guard let d = store.dashboard else { return [] }
        return [("Needs you", d.waiting, SidraColor.gold), ("Active", d.active, SidraColor.orange), ("History", d.history, SidraColor.dim)]
    }
    private var all: [Substrate.Message] { groups.flatMap(\.1) }
    private var picked: Substrate.Message? { store.pickedMessage.flatMap(store.message) ?? all.first }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.0) { name, items, color in
                        SubstrateGroupLabel(name, count: (name == "Needs you" ? store.dashboard?.counts.waiting : name == "Active" ? store.dashboard?.counts.active : nil) ?? items.count, color: color)
                        ForEach(items) { m in row(m, faded: name == "History") }
                        if items.isEmpty, name != "History" {
                            // An empty group says what it holds: requests, not the herdr agents at work (2026-11-20).
                            let working = store.dashboard?.counts.working ?? 0
                            Text(name == "Needs you" ? "Nothing waits for you."
                                 : "No requests with an agent." + (working > 0 ? " \(working) \(working == 1 ? "agent" : "agents") working in herdr." : ""))
                                .font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
                                .padding(.horizontal, 14).padding(.bottom, 6)
                        }
                    }
                    if store.dashboard == nil {
                        SubstrateEmpty(text: store.error ?? "Reading Substrate…", error: store.error != nil) { Task { await store.refresh() } }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(width: min(300, width * 0.42))   // HackerTab's index column (2026-11-20)
            .background(SubstrateStyle.side)
            Rectangle().fill(SidraColor.hairline).frame(width: 1)
            Group {
                if let m = picked { detail(m) } else if store.dashboard != nil { SubstrateEmpty(text: "Nothing waits for you.") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background { if keysOn { keys } }
        .task(id: picked?.conversation_id) { if let c = picked?.conversation_id { await store.loadConversation(c) } }
        .onChange(of: picked?.id) { _, _ in fullPrompt = false }
        .onChange(of: store.editing) { _, id in if let id, let m = store.message(id) { draft = m.proposal?.text ?? m.text; why = m.proposal?.why ?? "" } }
        .confirmationDialog("This request is held: \(confirmHeld?.message.risk ?? "flagged as risky").",
                            isPresented: Binding(get: { confirmHeld != nil }, set: { if !$0 { confirmHeld = nil } }), titleVisibility: .visible) {
            Button(confirmHeld?.text == nil ? "Approve anyway" : "Approve edited message anyway") {
                if let c = confirmHeld { act(c.message, approve: true, text: c.text ?? c.message.text, confirmed: true) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(_ m: Substrate.Message, faded: Bool) -> some View {
        let on = m.id == picked?.id
        return Button { store.pickedMessage = m.id } label: {
            HStack(alignment: .top, spacing: 10) {   // avatar stays on the first line when the text wraps (2026-11-20)
                SubstrateAvatar(name: m.sender?.name ?? "?", url: m.sender?.avatar_url, project: m.project)
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.text).font(SidraFont.ui(13, weight: on ? .bold : .medium)).foregroundStyle(on ? SidraColor.text : SidraColor.text.opacity(0.85))
                        .lineLimit(3).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)   // up to 3 lines (2026-11-20)
                    Text([m.sender?.name, m.project?.name, Substrate.stageLabel(m)].compactMap { $0 }.joined(separator: " · "))
                        .font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.dim).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(Substrate.ago(m.updated_at ?? m.created_at)).font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.muted)
            }
            .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 52)
            .overlay(alignment: .bottom) {
                if on { UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2).fill(SidraGradient.horizontal).frame(height: 2).padding(.horizontal, 14) }
            }
            .opacity(faded && !on ? 0.75 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        // Picked: the gradient underline alone, no fill (a full-width grey slab read oddly, 2026-11-20).
    }

    private func detail(_ m: Substrate.Message) -> some View {
        let conversation = m.conversation_id.flatMap { store.conversations[$0] }
        let prompt = m.prompt ?? conversation?.messages.first { $0.id == m.id }?.prompt
        let reviewing = m.stage == "reviewing"
        let waiting = m.stage == "pending_approval" || m.stage == "held"
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    SubstrateAvatar(name: m.sender?.name ?? "?", url: m.sender?.avatar_url)
                    Text(m.sender?.name ?? "Someone").font(SidraFont.ui(15, weight: .semibold)).foregroundStyle(SidraColor.text)
                    if let k = Substrate.agentKind(m.client) { HStack(spacing: 5) { Text("via"); AgentTag(agent: k) }.font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted) }
                    else { Text("via " + (m.client ?? "session")).font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted).lineLimit(1) }
                    if let p = m.project { SubstrateChip { SubstrateProjectLogo(project: p, size: 16); Text(p.name) } }
                    if reviewing { SubstrateChip(tone: .electric) { Text("in review with your agent") } }
                    else if waiting { SubstrateChip(tone: .warn) { Circle().fill(SidraColor.gold).frame(width: 7, height: 7); Text(m.held ? "held: \(m.risk ?? "")" : "waiting for you") } }
                    else { SubstrateChip { Text(Substrate.stageLabel(m)) } }
                    if let allow = m.deploy_allow, allow != "none" { SubstrateChip(tone: .electric) { Text("deploys to \(allow)") } }
                    Spacer(minLength: 0)
                    SubstrateChip { Text(Substrate.ago(m.created_at, long: true)) }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                Divider().overlay(SidraColor.hairline)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        SubstrateAvatar(name: m.sender?.name ?? "?", url: m.sender?.avatar_url, size: 24)
                        Text(m.sender?.name ?? "Someone").font(SidraFont.ui(12.5, weight: .semibold)).foregroundStyle(SidraColor.text)
                        Text("· tester").font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted)
                    }
                    Text(m.text).font(SidraFont.ui(14.5)).foregroundStyle(SidraColor.text).textSelection(.enabled)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SubstrateStyle.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SidraColor.hairline))
                .padding(.horizontal, 18).padding(.top, 16)
                if let p = m.proposal { proposal(p) }
                if reviewing {
                    Text("In review with your agent. Talk it over in the agent's session. Approve it here when the agent sends it back.")
                        .font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted)
                        .padding(.horizontal, 18).padding(.top, 12)
                }
                if let prompt {
                    Text(prompt).font(SidraFont.mono(12)).foregroundStyle(Color(hex: 0x8b93a0)).textSelection(.enabled)
                        .lineLimit(fullPrompt ? nil : 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(SubstrateStyle.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SidraColor.hairline))
                        .padding(.horizontal, 18).padding(.top, 10)
                }
                HStack(spacing: 8) {
                    if waiting {
                        Button { act(m, approve: true) } label: { Label(m.proposal == nil ? "Approve" : "Approve adjusted", systemImage: "checkmark") }
                            .buttonStyle(SubstrateButtonStyle(electric: true)).disabled(working)
                            .help("Approve (⌘↩)")
                        Button { act(m, approve: false) } label: { Label("Reject", systemImage: "xmark") }
                            .buttonStyle(SubstrateButtonStyle()).disabled(working)
                            .help("Reject (⌘⌫)")
                    }
                    if reviewing {
                        Button { act(m, approve: false) } label: { Label("Reject", systemImage: "xmark") }
                            .buttonStyle(SubstrateButtonStyle()).disabled(working)
                    }
                    if waiting, store.editing != m.id {
                        Button { draft = m.proposal?.text ?? m.text; why = m.proposal?.why ?? ""; store.editing = m.id } label: { Label("Edit before approving", systemImage: "pencil") }
                            .buttonStyle(SubstrateButtonStyle()).disabled(working)
                    }
                    if waiting || reviewing {
                        Button { review(m) } label: { Label(reviewing || m.proposal != nil ? "Review again" : "Review with agent", systemImage: "bubble.left.and.bubble.right") }
                            .buttonStyle(SubstrateButtonStyle()).disabled(working)
                            .help("Send it to the project's agent, review only, and go over it in the agent's session")
                    }
                    if prompt != nil {
                        Button(fullPrompt ? "Show less of the prompt" : "Show the full prompt") { fullPrompt.toggle() }
                            .buttonStyle(.plain).font(SidraFont.ui(13, weight: .semibold)).foregroundStyle(SidraColor.muted).padding(.horizontal, 8)
                    }
                    Spacer()
                    if let agent = store.agent(for: m.project) {
                        Button { openInHerdr(agent) } label: { Label("Open in herdr", systemImage: "arrow.up.right.square") }
                            .buttonStyle(.plain).font(SidraFont.ui(13, weight: .semibold)).foregroundStyle(SidraColor.muted)
                    }
                }
                .padding(.horizontal, 18).padding(.top, 14)
                if waiting, store.editing == m.id { editor(m) }
                if let track = Substrate.track(m.deploy_stage ?? conversation?.deploy_stage) {
                    SubstrateTrack(states: track).padding(.horizontal, 18).padding(.top, 16)
                }
                if let events = conversation?.events, !events.isEmpty {
                    SubstrateGroupLabel("Timeline").padding(.top, 10).padding(.horizontal, 4)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(events.enumerated()), id: \.offset) { _, e in SubstrateEventLine(event: e, web: m.web_url.flatMap(URL.init(string:))) }
                    }
                    .padding(.horizontal, 18)
                }
            }
            .padding(.bottom, 18)
        }
    }

    /// "Adjusted in review" (2026-11-21): what the agent and the developer agreed; Approve sends this.
    private func proposal(_ p: Substrate.Proposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Adjusted in review").font(SidraFont.ui(12.5, weight: .semibold)).foregroundStyle(SidraColor.jade)
            Text(p.text).font(SidraFont.ui(14.5)).foregroundStyle(SidraColor.text).textSelection(.enabled)
            if let w = p.why, !w.isEmpty { Text("Why: \(w)").font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted).textSelection(.enabled) }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SubstrateStyle.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SidraColor.jade.opacity(0.35)))
        .padding(.horizontal, 18).padding(.top, 10)
    }

    /// "Edit before approving" (2026-11-20): the tester's text, prefilled; the agent gets the edited version.
    private func editor(_ m: Substrate.Message) -> some View {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let tooLong = draft.count > 8000
        return VStack(alignment: .leading, spacing: 10) {
            Text("The agent gets this text in place of \(m.sender?.name ?? "the tester")'s. They see that you edited it.")
                .font(SidraFont.ui(12)).foregroundStyle(SidraColor.muted)
            TextEditor(text: $draft)
                .font(SidraFont.ui(14)).foregroundStyle(SidraColor.text)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 110, maxHeight: 260)
                .padding(8)
                .background(SubstrateStyle.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SidraColor.hairline2))
            TextField("Why (optional, \(m.sender?.name ?? "the tester") sees it)", text: $why)
                .textFieldStyle(.plain).font(SidraFont.ui(13)).foregroundStyle(SidraColor.text)
                .padding(8)
                .background(SubstrateStyle.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SidraColor.hairline2))
            HStack(spacing: 8) {
                Button { act(m, approve: true, text: text) } label: { Label("Approve edited message", systemImage: "checkmark") }
                    .buttonStyle(SubstrateButtonStyle(electric: true)).disabled(working || text.isEmpty || tooLong)
                Button("Cancel") { store.editing = nil }.buttonStyle(SubstrateButtonStyle())
                Spacer()
                if tooLong { Text("\(draft.count) of 8000 characters").font(SidraFont.mono(11.5)).foregroundStyle(SidraColor.red) }
            }
        }
        .padding(14)
        .background(SubstrateStyle.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SidraColor.hairline))
        .padding(.horizontal, 18).padding(.top, 12)
    }

    /// `text`: an edit; the same text as the tester's goes as a plain approve. A held request asks first, as on the web.
    private func act(_ m: Substrate.Message, approve: Bool, text: String? = nil, confirmed: Bool = false) {
        // Unchanged from what Approve would send (the proposal, else the tester's text) goes as a plain approve.
        let edit = text == (m.proposal?.text ?? m.text) ? nil : text
        if approve, m.held, !confirmed { confirmHeld = (m, edit); return }
        working = true
        Task {
            do { if approve { try await store.approve(m.id, text: edit, why: edit == nil ? nil : why.trimmingCharacters(in: .whitespacesAndNewlines)) } else { try await store.reject(m.id) } }
            catch { app.toast(error.localizedDescription) }
            working = false
        }
    }

    private func review(_ m: Substrate.Message) {
        working = true
        Task {
            do { try await store.review(m.id) } catch { app.toast(error.localizedDescription) }
            working = false
        }
    }

    /// The herdr tab showing this agent comes forward, on its space and tab.
    private func openInHerdr(_ agent: Substrate.Agent) {
        for tab in app.workspace.tabs {
            for pane in tab.panes {
                guard case .herdr = pane.kind, let m = MuxMonitors.shared.monitor(for: pane, app: app),
                      m.snapshot?.agents.contains(where: { $0.pane_id == agent.pane_id }) == true else { continue }
                app.workspace.select(tab: tab.id)
                app.workspace.focus(pane: pane.id)
                Task { await m.focusAgent(app, pane: agent.pane_id) }
                return
            }
        }
        app.toast("No herdr tab shows \(agent.title ?? agent.project?.name ?? "that agent")")
    }

    private var keys: some View {
        Group {
            Button("") { step(-1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { step(1) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { if let m = picked, ["pending_approval", "held"].contains(m.stage) { act(m, approve: true) } }.keyboardShortcut(.return, modifiers: .command)
            Button("") { if let m = picked, ["pending_approval", "held"].contains(m.stage) { act(m, approve: false) } }.keyboardShortcut(.delete, modifiers: .command)
            Button("") { if let u = picked?.web_url.flatMap(URL.init(string:)) { Platform.open(u) } }.keyboardShortcut("o", modifiers: .command)
        }
        .opacity(0).accessibilityHidden(true)
    }

    private func step(_ d: Int) {
        let list = all
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == picked?.id } ?? -d
        store.pickedMessage = list[max(0, min(list.count - 1, i + d))].id
    }
}

// MARK: - Sessions

struct SubstrateSessions: View {
    @Bindable var store: SubstrateStore
    let keysOn: Bool
    @State private var width: CGFloat = 900
    private var sessions: [Substrate.Session] { store.sessions?.sessions ?? [] }
    private var picked: Substrate.Session? {
        let id = store.pickedSession ?? sessions.first?.id
        return id.flatMap { id in store.sessionDetails[id] ?? sessions.first { $0.id == id } }
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SubstrateGroupLabel("Sessions", count: sessions.count)
                    ForEach(sessions) { row($0) }
                    if store.sessions == nil { SubstrateEmpty(text: store.error ?? "Reading sessions…", error: store.error != nil) { Task { await store.refresh() } } }
                    SubstrateGroupLabel("Machines", trailing: "read-only").padding(.top, 8)
                    ForEach(store.machines) { SubstrateMachineRow(machine: $0, compact: true) }
                }
                .padding(.vertical, 6)
            }
            .frame(width: min(300, width * 0.42))   // HackerTab's index column (2026-11-20)
            .background(SubstrateStyle.side)
            Rectangle().fill(SidraColor.hairline).frame(width: 1)
            Group {
                if let s = picked { detail(s) } else if store.sessions != nil { SubstrateEmpty(text: "No sessions yet. Make one in the browser with New session.") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background { if keysOn { keys } }
        .task(id: picked?.id) { if let id = picked?.id { await store.loadSession(id) } }
    }

    private func row(_ s: Substrate.Session) -> some View {
        let on = s.id == picked?.id
        let revoked = s.active == false
        return Button { store.pickedSession = s.id } label: {
            HStack(spacing: 10) {
                SubstrateAvatar(name: s.name, url: s.avatar_url)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(s.name).font(SidraFont.ui(13, weight: on ? .bold : .medium)).foregroundStyle(on ? SidraColor.text : SidraColor.text.opacity(0.85)).lineLimit(1)
                        if let w = s.waiting, w > 0 { SubstrateChip(tone: .warn, small: true) { Text("\(w) waiting") } }
                    }
                    Text([(s.projects ?? []).map(\.name).joined(separator: ", "), revoked ? "revoked" : s.last_used_at.map { "used \(Substrate.ago($0, long: true))" }]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.dim).lineLimit(1)
                }
                Spacer(minLength: 6)
                if !revoked, let e = s.expires_at { Text(e.formatted(.dateTime.month(.abbreviated).day())).font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.muted) }
            }
            .padding(.horizontal, 14).frame(minHeight: 52)
            .overlay(alignment: .bottom) {
                if on { UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2).fill(SidraGradient.horizontal).frame(height: 2).padding(.horizontal, 14) }
            }
            .opacity(revoked && !on ? 0.6 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func detail(_ s: Substrate.Session) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    SubstrateAvatar(name: s.name, url: s.avatar_url)
                    Text(s.name).font(SidraFont.ui(15, weight: .semibold)).foregroundStyle(SidraColor.text)
                    let p = s.permissions
                    if p?.replies == true { SubstrateChip { Text("replies") } }
                    if p?.deploys == true { SubstrateChip { Text("deploys") } }
                    if p?.files == true { SubstrateChip { Text("files") } }
                    if p?.no_approval == true { SubstrateChip(tone: .warn) { Text("no approval") } }
                    if p?.deploy_production == true { SubstrateChip(tone: .electric) { Text("deploys to production") } }
                    else if p?.deploy_test == true { SubstrateChip(tone: .electric) { Text("deploys to test") } }
                    Spacer(minLength: 0)
                    if let u = s.web_url.flatMap(URL.init(string:)) {
                        SubstrateChip { Text("Revoke and edit in the browser"); Image(systemName: "arrow.up.right.square") }
                            .onTapGesture { Platform.open(u) }.accessibilityAddTraits(.isButton)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                Divider().overlay(SidraColor.hairline)
                if let c = s.counts {
                    HStack(spacing: 10) {
                        stat("Messages", c.messages)
                        stat("Waiting for you", c.waiting, color: SidraColor.gold)
                        stat("With the agent", c.active)
                        stat("Completed", c.completed, electric: true)
                        stat("Deployed", c.deployed)
                    }
                    .padding(.horizontal, 18).padding(.top, 14)
                }
                if let history = s.history, !history.isEmpty {
                    SubstrateGroupLabel("History").padding(.top, 10).padding(.horizontal, 4)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(history) { h in
                            HStack(spacing: 8) {
                                if let p = h.project { SubstrateProjectLogo(project: p, size: 18) }
                                Text(h.title ?? "Request").font(SidraFont.ui(13.5, weight: .semibold)).foregroundStyle(SidraColor.text)
                                Spacer()
                                Text(Substrate.ago(h.events?.first?.time)).font(SidraFont.mono(11.5)).foregroundStyle(SidraColor.dim)
                            }
                            .padding(.top, 8)
                            if let t = Substrate.track(h.deploy_stage) { SubstrateTrack(states: t) }
                            ForEach(Array((h.events ?? []).prefix(3).enumerated()), id: \.offset) { _, e in SubstrateEventLine(event: e) }
                        }
                    }
                    .padding(.horizontal, 18)
                }
            }
            .padding(.bottom, 18)
        }
    }

    private func stat(_ title: String, _ value: Int?, color: Color = SidraColor.text, electric: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.muted)
            let v = Text(verbatim: "\(value ?? 0)").font(SidraFont.ui(24, weight: .semibold))
            if electric { v.foregroundStyle(SubstrateStyle.electric) } else { v.foregroundStyle(color) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SubstrateStyle.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(SidraColor.hairline))
    }

    private var keys: some View {
        Group {
            Button("") { step(-1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { step(1) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { if let u = store.sessions?.new_session_url.flatMap(URL.init(string:)) { Platform.open(u) } }.keyboardShortcut("n", modifiers: .command)
        }
        .opacity(0).accessibilityHidden(true)
    }

    private func step(_ d: Int) {
        guard !sessions.isEmpty else { return }
        let i = sessions.firstIndex { $0.id == picked?.id } ?? -d
        store.pickedSession = sessions[max(0, min(sessions.count - 1, i + d))].id
    }
}

// MARK: - Machines (read-only)

struct SubstrateMachines: View {
    let store: SubstrateStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SubstrateGroupLabel("Machines", trailing: "read-only")
                if store.machines.isEmpty { SubstrateEmpty(text: "No machine runs Substrate's relay yet.") }
                ForEach(store.machines) { SubstrateMachineRow(machine: $0, compact: false) }
            }
            .padding(.vertical, 6).padding(.horizontal, 4)
        }
    }
}

struct SubstrateMachineRow: View {
    let machine: Substrate.Machine
    let compact: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProcessIcon(.ssh, size: 30)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(machine.online == true ? SidraColor.jade : SidraColor.dim).frame(width: 7, height: 7)
                    Text(machine.name).font(SidraFont.ui(13, weight: .semibold)).foregroundStyle(SidraColor.text)
                    if !compact {
                        Text([machine.platform, machine.relay_version.map { "relay \($0)" }, machine.online == true ? "online" : machine.last_seen.map { "seen \(Substrate.ago($0, long: true))" }]
                            .compactMap { $0 }.joined(separator: " · ")).font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.dim)
                    }
                }
                if compact {
                    HStack(spacing: 6) {
                        ForEach(machine.agents.prefix(5)) { a in agentMark(a) }
                        if machine.agents.count > 5 { Text("+\(machine.agents.count - 5)").font(SidraFont.ui(11)).foregroundStyle(SidraColor.dim) }
                    }
                } else {
                    ForEach(machine.agents) { a in
                        HStack(spacing: 8) {
                            agentMark(a)
                            Text(a.project?.name ?? a.title ?? a.pane_id).font(SidraFont.ui(12.5, weight: .semibold)).foregroundStyle(SidraColor.text)
                            if let k = a.agent { AgentTag(agent: k, size: 12) }
                            Text([a.workspace, a.status].compactMap { $0 }.joined(separator: " · ")).font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.dim)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func agentMark(_ a: Substrate.Agent) -> some View {
        SubstrateProjectLogo(project: a.project ?? .init(id: a.pane_id, name: a.title ?? "?"), size: 20)
            .overlay(alignment: .bottomTrailing) {
                if let s = a.status.flatMap(MuxStatus.init(rawValue:)), s != .unknown, s != .idle {
                    HerdrStatusIcon(status: s, size: 8).padding(2).background(SubstrateStyle.side, in: Circle()).offset(x: 5, y: 5)
                }
            }
    }
}

// MARK: - Sign in

struct SubstrateSignIn: View {
    let store: SubstrateStore
    @State private var email = ""
    @State private var code = ""
    @State private var sent = false
    @State private var working = false
    @State private var error: String?
    @FocusState private var focus: Field?
    enum Field { case email, code }

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(hex: 0x0E1A6B), Color(hex: 0x070A2A), SubstrateStyle.main], center: UnitPoint(x: 0.5, y: 0.38), startRadius: 0, endRadius: 560)
            VStack(spacing: 0) {
                Circle()
                    .fill(AngularGradient(colors: [Color(hex: 0x05061A), Color(hex: 0x0B1BFF), Color(hex: 0x05061A), Color(hex: 0xC04BFF), Color(hex: 0x05061A), Color(hex: 0x7FF0FF), Color(hex: 0x05061A)],
                                          center: UnitPoint(x: 0.55, y: 0.6), angle: .degrees(180)))
                    .frame(width: 84, height: 84)
                    .shadow(color: Color(hex: 0x5B3BFF).opacity(0.55), radius: 20)
                    .padding(.bottom, 18)
                Text("Sign in to Substrate").font(SidraFont.ui(22, weight: .semibold)).foregroundStyle(SidraColor.text).padding(.bottom, 6)
                Text("We send a 6-digit code to your email. Type it here; no link to open.")
                    .font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted).multilineTextAlignment(.center).padding(.bottom, 18)
                HStack {
                    TextField("you@example.com", text: $email)
                        .plainTextEntry().autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).textContentType(.emailAddress)
                        #endif
                        .focused($focus, equals: .email)
                        .onSubmit(sendCode)
                        .disabled(sent)
                    if sent { Image(systemName: "checkmark").foregroundStyle(SidraColor.jade) }
                }
                .font(SidraFont.ui(14)).foregroundStyle(SidraColor.text)
                .padding(.horizontal, 12).frame(height: 40)
                .background(SubstrateStyle.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SidraColor.hairline2))
                .padding(.bottom, 12)
                if sent { codeBoxes.padding(.bottom, 16) }
                Button(sent ? "Sign in" : "Send code", action: sent ? verify : sendCode)
                    .buttonStyle(SubstrateButtonStyle(electric: true, wide: true))
                    .disabled(working || (sent ? code.count != 6 : !email.contains("@")))
                if let error {
                    Text(error).font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.red).multilineTextAlignment(.center).padding(.top, 12)
                }
                if sent {
                    // Two centred lines: the note, then its two actions (one wrapped row read badly, 2026-11-20).
                    VStack(spacing: 6) {
                        Text("Code sent to \(email). It works for 10 minutes.").foregroundStyle(SidraColor.dim).multilineTextAlignment(.center)
                        HStack(spacing: 6) {
                            Button("Send again") { code = ""; sendCode() }.buttonStyle(.plain)
                            Text("·").foregroundStyle(SidraColor.dim)
                            Button("Other email") { sent = false; code = ""; focus = .email }.buttonStyle(.plain)
                        }
                        .foregroundStyle(SidraColor.muted)
                    }
                    .font(SidraFont.ui(12)).padding(.top, 14)
                }
            }
            .padding(28)
            .frame(width: 440)
            .background(Color(hex: 0x14181e), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(SidraColor.hairline2))
            .shadow(color: .black.opacity(0.6), radius: 40, y: 30)
        }
        .onAppear {
            email = store.connection.email
            if let e = store.error { error = e }
            focus = .email
        }
    }

    /// Six boxes over one hidden field, so typing and pasting a code both work.
    private var codeBoxes: some View {
        ZStack {
            TextField("", text: $code)
                .focused($focus, equals: .code)
                #if os(iOS)
                .keyboardType(.numberPad).textContentType(.oneTimeCode)
                #endif
                .onChange(of: code) { _, v in
                    let digits = String(v.filter(\.isNumber).prefix(6))
                    if digits != v { code = digits }
                    if digits.count == 6 { verify() }
                }
                .onSubmit(verify)
                .opacity(0.02)
                .accessibilityLabel("Six-digit code")
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    let chars = Array(code)
                    let on = focus == .code && i == min(chars.count, 5)
                    Text(i < chars.count ? String(chars[i]) : "")
                        .font(SidraFont.mono(22, weight: .semibold)).foregroundStyle(SidraColor.text)
                        .frame(width: 46, height: 54)
                        .background(SubstrateStyle.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(on ? AnyShapeStyle(SubstrateStyle.electric) : AnyShapeStyle(SidraColor.hairline2), lineWidth: on ? 1.5 : 1)
                        }
                }
            }
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { focus = .code }
    }

    private func sendCode() {
        let e = email.trimmingCharacters(in: .whitespaces)
        guard e.contains("@"), !working else { return }
        working = true; error = nil
        Task {
            do { try await store.requestCode(email: e); sent = true; focus = .code }
            catch { self.error = error.localizedDescription }
            working = false
        }
    }

    private func verify() {
        guard code.count == 6, !working else { return }
        working = true; error = nil
        Task {
            do { try await store.verify(code: code) }
            catch { self.error = error.localizedDescription; code = "" }
            working = false
        }
    }
}

// MARK: - Pieces

extension Substrate {
    /// The agent mark for a chat client's name (the server's `brand()` rules): Claude, or Codex for OpenAI's clients.
    static func agentKind(_ client: String?) -> String? {
        let n = (client ?? "").lowercased()
        if n.contains("claude") || n.contains("anthropic") { return "claude" }
        if n.contains("codex") || n.contains("openai") || n.contains("chatgpt") { return "codex" }
        return nil
    }
    static func stageLabel(_ m: Message) -> String {
        switch m.deploy_stage {
        case "ci_running", "fix_committed": return "CI running"
        case "ci_failed": return "CI failed"
        case "deploying": return "deploying"
        case "deployed", "verified", "ready_to_retest": return "live"
        case "deploy_failed": return "deploy failed"
        default: break
        }
        switch m.stage {
        case "pending_approval": return m.deploy_allow.map { $0 == "none" ? "waiting" : "deploys to \($0)" } ?? "waiting"
        case "held": return "held"
        case "reviewing": return "in review"
        case "approved", "dispatched", "accepted", "submitted": return "sent to the agent"
        case "working": return "working"
        case "awaiting_sender": return "waiting for the tester"
        default: return m.stage.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// "2m", "1h", "3d"; long: "2m ago", "2 Nov".
    static func ago(_ date: Date?, long: Bool = false) -> String {
        guard let date else { return "" }
        let s = max(0, Date().timeIntervalSince(date))
        let short: String
        if s < 60 { short = "now" }
        else if s < 3600 { short = "\(Int(s / 60))m" }
        else if s < 86400 { short = "\(Int(s / 3600))h" }
        else if s < 86400 * 7 { short = "\(Int(s / 86400))d" }
        else { return date.formatted(.dateTime.day().month(.abbreviated)) }
        return long && short != "now" ? short + " ago" : short
    }
}

struct SubstrateGroupLabel: View {
    let text: String
    var count: Int?
    var trailing: String?
    var color: Color?
    init(_ text: String, count: Int? = nil, trailing: String? = nil, color: Color? = nil) {
        self.text = text; self.count = count; self.trailing = trailing; self.color = color
    }
    var body: some View {
        HStack(spacing: 8) {
            if let color, color != SidraColor.dim {
                if text == "Active" {
                    if (count ?? 0) > 0 { GradientSpinner(size: 10) } else { Circle().strokeBorder(SidraColor.dim, lineWidth: 1.5).frame(width: 10, height: 10) }   // spins only while something runs
                } else { RoundedRectangle(cornerRadius: 2).fill((count ?? 0) > 0 ? color : SidraColor.dim).frame(width: 8, height: 8) }
            }
            Text(text.uppercased()).font(SidraFont.ui(11.5, weight: .semibold)).tracking(0.5)
            Spacer()
            if let count { Text(verbatim: "\(count)").font(SidraFont.ui(11.5)) }
            if let trailing { Text(trailing.uppercased()).font(SidraFont.ui(11.5)).tracking(0.5) }
        }
        .foregroundStyle(color == SidraColor.dim ? SidraColor.dim : SidraColor.muted)
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
    }
}

struct SubstrateChip<Content: View>: View {
    enum Tone { case plain, warn, electric }
    var tone: Tone = .plain
    var small = false
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 6) { content() }
            .font(SidraFont.ui(small ? 10.5 : 12))
            .foregroundStyle(tone == .electric ? .white : tone == .warn ? SidraColor.gold : Color(hex: 0xaab2bd))
            .padding(.horizontal, small ? 6 : 9).frame(height: small ? 18 : 24)
            .background {
                let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
                switch tone {
                case .electric: shape.fill(SubstrateStyle.electric)
                case .warn: shape.fill(Color(hex: 0x231f15)).overlay(shape.strokeBorder(SidraColor.gold.opacity(0.25)))
                case .plain: shape.fill(SubstrateStyle.chip).overlay(shape.strokeBorder(SidraColor.hairline))
                }
            }
            .fixedSize()
    }
}

struct SubstrateButtonStyle: ButtonStyle {
    var electric = false
    var wide = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SidraFont.ui(13, weight: .semibold))
            .foregroundStyle(electric ? .white : SidraColor.text)
            .padding(.horizontal, 15).frame(height: 34).frame(maxWidth: wide ? .infinity : nil)
            .background {
                let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
                if electric { shape.fill(SubstrateStyle.electric).shadow(color: SubstrateStyle.glow, radius: 9, y: 4) }
                else { shape.fill(SubstrateStyle.chip).overlay(shape.strokeBorder(SidraColor.hairline2)) }
            }
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(Rectangle())
    }
}

/// A person: their avatar, or their initial on a round tile; `project` adds the project's logo at the corner.
struct SubstrateAvatar: View {
    let name: String
    let url: String?
    var project: Substrate.Project?
    var size: CGFloat = 30
    var body: some View {
        Group {
            if let url, let u = URL(string: url) {
                AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { initial }
            } else { initial }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            if let project { SubstrateProjectLogo(project: project, size: 14).padding(1).background(SubstrateStyle.side, in: RoundedRectangle(cornerRadius: 5)).offset(x: 4, y: 4) }
        }
    }
    private var initial: some View {
        Circle().fill(Color(hex: 0x2a2f55)).overlay(Text(String(name.prefix(1)).uppercased()).font(SidraFont.ui(size * 0.4, weight: .bold)).foregroundStyle(.white))
    }
}

/// A project's icon, or its first letter on a tile.
struct SubstrateProjectLogo: View {
    let project: Substrate.Project
    let size: CGFloat
    var body: some View {
        Group {
            if let u = project.icon_url.flatMap(URL.init(string:)) {
                AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { letter }
            } else { letter }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
    }
    private var letter: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).fill(SubstrateStyle.chip)
            .overlay(Text(String(project.name.prefix(1)).uppercased()).font(SidraFont.ui(size * 0.55, weight: .bold)).foregroundStyle(SidraColor.muted))
    }
}

/// Commit › Checks › Push › CI › Deploy › Live.
struct SubstrateTrack: View {
    let states: [Substrate.StepState]
    var body: some View {
        HStack(spacing: 7) {
            ForEach(Array(Substrate.steps.enumerated()), id: \.offset) { i, name in
                if i > 0 { Text("›").foregroundStyle(SidraColor.dim) }
                let s = states[i]
                HStack(spacing: 5) {
                    ZStack {
                        switch s {
                        case .done: Circle().fill(SidraColor.jade.opacity(0.14)); Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(SidraColor.jade)
                        case .running: Circle().fill(SubstrateStyle.electric); Image(systemName: "gearshape.fill").font(.system(size: 9)).foregroundStyle(.white)
                        case .failed: Circle().fill(SidraColor.red.opacity(0.16)); Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(SidraColor.red)
                        case .waiting: Circle().fill(SubstrateStyle.chip)
                        }
                    }
                    .frame(width: 20, height: 20)
                    Text(name).foregroundStyle(s == .done ? SidraColor.jade : s == .failed ? SidraColor.red : s == .running ? SidraColor.text : SidraColor.dim)
                }
            }
        }
        .font(SidraFont.ui(12))
        .accessibilityElement(children: .combine)
    }
}

struct SubstrateEventLine: View {
    let event: Substrate.Event
    /// The conversation on the web, where a held note is released (2026-11-20: release is web-only).
    var web: URL?
    var body: some View {
        HStack(alignment: event.kind == "note" ? .top : .center, spacing: 9) {
            Group {
                switch event.actor {
                case "human", "developer": SubstrateAvatar(name: event.name ?? "?", url: event.avatar_url, size: 20)
                case "deploy": Image(systemName: "shippingbox").font(.system(size: 10)).foregroundStyle(SidraColor.muted).frame(width: 20, height: 20).background(SubstrateStyle.chip, in: Circle())
                case "agent": Image(systemName: "sparkle").font(.system(size: 10)).foregroundStyle(SidraColor.orange).frame(width: 20, height: 20).background(SubstrateStyle.chip, in: Circle())
                default: ProcessIcon(.substrate, size: 20).clipShape(Circle())
                }
            }
            if event.kind == "note" { note } else {
                Text(event.text ?? event.name ?? event.kind ?? "").font(SidraFont.ui(12.5)).foregroundStyle(Color(hex: 0xaab2bd))
            }
            Spacer()
            if let t = event.time { Text(t.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())).font(SidraFont.mono(11.5)).foregroundStyle(SidraColor.dim) }
        }
        .frame(minHeight: 26)
    }
}

extension SubstrateEventLine {
    /// The developer's talk with the agent, as the agent summed it up (`substrate note`). Held: it looked
    /// like a secret, so the tester does not see it until it is released on the web.
    private var note: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(event.text ?? "").font(SidraFont.ui(12.5)).foregroundStyle(Color(hex: 0xaab2bd)).textSelection(.enabled)
            HStack(spacing: 8) {
                Text("\(event.name ?? "Developer") · summarized by the agent").font(SidraFont.ui(11)).foregroundStyle(SidraColor.dim)
                if event.held == true {
                    SubstrateChip(tone: .warn, small: true) { Text("held: the tester can't see it") }
                    if let web { Link("Release on the web", destination: web).font(SidraFont.ui(11, weight: .semibold)).foregroundStyle(SidraColor.muted) }
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct SubstrateEmpty: View {
    let text: String
    var error = false
    var retry: (() -> Void)?
    var body: some View {
        VStack(spacing: 10) {
            Text(text).font(SidraFont.ui(13)).foregroundStyle(error ? SidraColor.red : SidraColor.muted).multilineTextAlignment(.center)
            if error, let retry { Button("Try again", action: retry).buttonStyle(.sidraSecondary) }
        }
        .padding(24).frame(maxWidth: .infinity)
    }
}
