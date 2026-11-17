import SwiftUI
import SidraDesign
import SidraWorkspace
import SidraTheasa

/// Theasa's meanings, kept in Sidra: colour only on dots and agent tags.
enum TColor {
    static let watch = Color(hex: 0xF0B429)
    static let clean = Color(hex: 0x4CC38A)
    static let broken = Color(hex: 0xEF6B6B)
    static let claude = Color(hex: 0xE8926B)
    static let codex = Color(hex: 0x7AA7FF)
    static let none = Color(hex: 0x5A5A62)

    static func verdict(_ v: Verdict?) -> Color {
        switch v { case .clean: clean; case .watch: watch; case .broken: broken; case nil: none }
    }
    static func agent(_ a: String) -> Color { a == "claude" ? claude : a == "codex" ? codex : SidraColor.muted }
    static func impact(_ i: String) -> Color { i == "high" ? broken : watch }
    static func status(_ s: String) -> Color {
        ["blocked": watch, "done": clean, "idle": SidraColor.muted, "working": codex][s] ?? none
    }
}

enum TheasaRoute: Hashable {
    case agents
    case project(Int)
    case turn(Int)
    case search(String)
}

private struct OpenKey: EnvironmentKey { static let defaultValue: (TheasaRoute) -> Void = { _ in } }
extension EnvironmentValues {
    /// Pushes a screen onto the pane's stack; every link between screens goes through it.
    var theasaOpen: (TheasaRoute) -> Void {
        get { self[OpenKey.self] }
        set { self[OpenKey.self] = newValue }
    }
}

/// The pane body: a Sidra-styled nav row over a NavigationStack whose bar is hidden.
struct TheasaPane: View {
    let pane: Pane
    let connectionID: UUID
    @State private var store = TheasaStore.shared
    @Environment(WorkspaceStore.self) private var workspace

    var body: some View {
        if let live = store.live(connectionID) {
            let nav = store.nav(pane.id)   // one Theasa screen stack per window (each has its own Theasa pane)
            // Hosted in a UIKit controller that owns Esc (TheasaKeyHost); the environment is passed on by hand.
            TheasaKeyHosted(nav: nav, paneFocused: workspace.focusedPane?.id == pane.id, typing: nav.typing) {
                TheasaRootView(live: live, nav: nav).environment(workspace)
            }
            .id(pane.id)   // per pane state: another tab of this view type must not inherit this one's screens or data
            .task(id: pane.id) { nav.hostPane = pane.id }   // fields focus this pane, not the nav's key
        } else {
            TheasaEmpty(title: "This Theasa connection is gone", detail: "Add it again from New tab, Theasa.")
        }
    }
}

struct TheasaRootView: View {
    @Bindable var live: TheasaLive
    @Bindable var nav: TheasaNav
    @Environment(WorkspaceStore.self) private var workspace
    /// Inside a popover the size class is always compact, so this checks the device.
    private var compactWidth: Bool { Platform.isPhone }
    @State private var query = ""
    private var path: [TheasaRoute] {
        get { nav.path }
        nonmutating set { nav.path = newValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            navRow
            Rectangle().fill(SidraColor.hairline).frame(height: 1)
            NavigationStack(path: $nav.path) {
                // Pulse and Agents are the two roots (no back); project, turn and search push.
                Group { if nav.root == .agents { TheasaAgentsView() } else { TheasaPulseView() } }
                    .navigationDestination(for: TheasaRoute.self) { r in
                        Group {
                            switch r {
                            case .agents: TheasaAgentsView()
                            case .project(let id): TheasaProjectView(id: id)
                            case .turn(let id): TheasaTurnView(id: id)
                            case .search(let q): TheasaSearchView(query: q)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(SidraColor.pane)
                        .hiddenNavigationBar()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SidraColor.pane)
                    .hiddenNavigationBar()
            }
            .environment(\.theasaOpen) { path.append($0) }
        }
        .environment(live)
        .environment(nav)
        // Another pane or tab took focus: no Theasa field keeps the keyboard (notes's hidden find field did).
        .onChange(of: workspace.focusedPane?.id) { _, id in if id != nav.focusTarget { nav.resign += 1 } }
        // Tabs stay built when hidden (Views.swift), so a tab switch, not onDisappear, takes the keyboard back.
        .onChange(of: workspace.activeTabID) { _, _ in nav.resign += 1 }
        .onDisappear { nav.resign += 1; nav.typing = false }
        .background(SidraColor.pane)
        .overlay(alignment: .bottom) {
            if let t = live.toast {
                Text(t).font(SidraFont.ui(13)).foregroundStyle(SidraColor.text)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: SidraRadius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: SidraRadius.card, style: .continuous).strokeBorder(SidraColor.hairline2))
                    .padding(.bottom, 16).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: live.toast)
        .task { await live.loadAgents() }
    }

    private var navRow: some View {
        let agents = live.agents?.available == true ? live.agents!.agents : []
        let need = agents.filter { $0.status == "blocked" }.count
        let working = agents.filter { $0.status == "working" }.count
        return HStack(spacing: 8) {
            if !path.isEmpty {
                IconButton("chevron.left", label: "Back", size: 30) { path.removeLast() }
            }
            navPill("Pulse", on: nav.root == .pulse) { nav.show(.pulse) }
            navPill("Agents", on: nav.root == .agents) { nav.show(.agents) }
            if !compactWidth { searchField }
            Spacer(minLength: 8)
            // The range lives here on Pulse, so the screen saves a row.
            if nav.root == .pulse && path.isEmpty { RangePicker(range: $live.range, short: compactWidth).fixedSize() }
            if compactWidth {
                // Phone: the title-bar pill already shows the counts.
            } else if need > 0 {
                Button { nav.show(.agents) } label: { Dot(TColor.watch, label: "\(need) need\(need == 1 ? "s" : "") you") }
                    .buttonStyle(.plain)
            }
            if !compactWidth {
                Button { nav.show(.agents) } label: {
                    Dot(working > 0 ? TColor.clean : TColor.none, label: working > 0 ? TFormat.plural(working, "agent") + " working" : "No agent working")
                }
                .buttonStyle(.plain)
            }
            if !live.connected {
                FooterChip([.init("offline", icon: "wifi.slash", color: SidraColor.yellow)])
                    .accessibilityLabel("Live updates are off, reconnecting")
            }
        }
        .font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted)
        .padding(.horizontal, 12).frame(height: 44)
        // Phone: search gets its own row, so Back, the pills and the range never squeeze it shut.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if compactWidth { searchField.frame(maxWidth: .infinity).padding(.horizontal, 12).padding(.bottom, 8) }
        }
    }

    private var searchField: some View {
            HStack(spacing: 6) {
                // Also a button, so search never depends on Return alone.
                Button { let q = query.trimmingCharacters(in: .whitespaces); if !q.isEmpty { path.append(.search(q)) } } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(query.isEmpty ? SidraColor.dim : SidraColor.text)
                        .frame(width: 24, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Search").accessibilityIdentifier("theasa-search-go")
                TextField("Search turns, decisions, files", text: $query)
                    .font(SidraFont.ui(13)).foregroundStyle(SidraColor.text)
                    .plainTextEntry().autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { let q = query.trimmingCharacters(in: .whitespaces); if !q.isEmpty { path.append(.search(q)) } }
                    .theasaField(nav: nav, workspace: workspace, focusOn: nav.focusSearch)
                    .accessibilityIdentifier("theasa-search")
            }
            .padding(.horizontal, 10).frame(height: 30).frame(maxWidth: compactWidth ? .infinity : 340)
            .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: SidraRadius.pill, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SidraRadius.pill, style: .continuous).strokeBorder(SidraColor.hairline))
    }

    private func navPill(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(SidraFont.ui(13, weight: on ? .bold : .regular)).fixedSize()
                .foregroundStyle(on ? SidraColor.text : SidraColor.muted)
                .padding(.horizontal, 12).frame(height: 30)
                .background(on ? SidraColor.tabActive : .clear, in: RoundedRectangle(cornerRadius: SidraRadius.pill, style: .continuous))
                .gradientBorder(radius: SidraRadius.pill, active: on, inactive: .clear)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Footer for the Theasa pane: server address and the live-update state.
struct TheasaFooter: View {
    let connectionID: UUID
    @State private var store = TheasaStore.shared
    var body: some View {
        let live = store.live(connectionID)
        FooterItem(live?.connected == true ? "●" : "○", color: live?.connected == true ? SidraColor.jade : SidraColor.dim)
        FooterChip([.init(store.connection(connectionID)?.url ?? "no server", label: "Theasa"),
                    .init(live?.connected == true ? "live" : "reconnecting", color: live?.connected == true ? SidraColor.jade : SidraColor.yellow)])
        Spacer()
        FooterItem(store.connection(connectionID).map { store.token($0) == nil ? "read only" : "token in Keychain" } ?? "")
    }
}

// MARK: - Loading

/// Fetches on appear, on every live change and on Retry. A first failure shows the error with
/// Retry; a failed refetch keeps what is shown (the nav row says offline).
struct TheasaLoad<T: Sendable, Content: View>: View {
    let key: String
    let load: @Sendable (TheasaClient) async throws -> T
    @ViewBuilder let content: (T) -> Content
    @Environment(TheasaLive.self) private var live
    @State private var value: T?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let value {
                content(value)
            } else if let error {
                TheasaEmpty(title: "This screen didn't load", detail: error, retry: { self.error = nil; attempt += 1 })
            } else {
                VStack(spacing: 10) { GradientSpinner(size: 18); Text("Loading…").font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(key)#\(live.tick)#\(attempt)") {
            do {
                let v = try await load(live.client)
                value = v; error = nil
            } catch is CancellationError {
            } catch {
                if value == nil { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            }
        }
    }
}

struct TheasaEmpty: View {
    let title: String
    let detail: String
    var retry: (() -> Void)? = nil
    var action: (label: String, run: () -> Void)? = nil
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "eye.slash").font(.system(size: 26)).foregroundStyle(SidraColor.dim)
            Text(title).font(SidraFont.ui(15, weight: .bold)).foregroundStyle(SidraColor.text)
            Text(detail).font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted).multilineTextAlignment(.center).frame(maxWidth: 460)
            if let retry { Button("Retry", action: retry).buttonStyle(.sidraPrimary).padding(.top, 4).accessibilityIdentifier("theasa-retry") }
            if let action { Button(action.label, action: action.run).buttonStyle(.sidraPrimary).padding(.top, 4).accessibilityIdentifier("theasa-empty-action") }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pieces shared by the screens

struct Dot: View {
    let color: Color
    var label: String? = nil
    var size: CGFloat = 7
    init(_ color: Color, label: String? = nil, size: CGFloat = 7) { self.color = color; self.label = label; self.size = size }
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: size, height: size)
            if let label { Text(label).lineLimit(1) }
        }
    }
}

struct VerdictLabel: View {
    let verdict: Verdict?
    var body: some View {
        if let v = verdict {
            Dot(TColor.verdict(v), label: ["clean": "Clean", "watch": "Watch", "broken": "Broken"][v.rawValue])
                .font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted)   // colour on the dot only
        }
    }
}

struct AgentTag: View {
    let agent: String
    var body: some View {
        HStack(spacing: 4) {
            // The agent's real mark (asset catalog) before its name; an unknown agent stays text only.
            if HerdrAgentMark.known.contains(agent) { HerdrAgentMark(agent: agent, size: 12) }
            Text(agent == "claude" ? "CLAUDE" : agent == "codex" ? "CODEX" : agent.uppercased())
                .font(SidraFont.mono(10)).kerning(0.6).foregroundStyle(TColor.agent(agent))
        }
    }
}

func agentName(_ a: String) -> String { a == "claude" ? "Claude Code" : a == "codex" ? "Codex" : a }

/// Project icon from the server, or a letter tile with `initial`.
struct ProjectIconView: View {
    let iconURL: String?
    let initial: String?
    var size: CGFloat = 24
    @Environment(TheasaLive.self) private var live
    var body: some View {
        let r = size * 0.25
        Group {
            if let p = iconURL, let u = live.client.url(p) {
                AsyncImage(url: u) { img in img.resizable().scaledToFit() } placeholder: { tile }
            } else { tile }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
        .accessibilityHidden(true)
    }
    private var tile: some View {
        ZStack {
            Color(hex: 0x2A2A30)
            Text(initial ?? "?").font(SidraFont.ui(size * 0.5, weight: .bold)).foregroundStyle(Color(hex: 0xD4D4D8))
        }
    }
}

extension ProjectIconView {
    init(_ p: Project?, size: CGFloat = 24) { self.init(iconURL: p?.icon_url, initial: p?.initial, size: size) }
}

/// Inline Markdown (bold, code, links).
func inlineMD(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

/// Section title: "Needs attention 3".
struct TSection<Content: View>: View {
    let title: String
    var count: String? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(SidraFont.ui(13, weight: .bold)).foregroundStyle(SidraColor.text)
                if let count { Text(count).font(SidraFont.ui(13)).foregroundStyle(SidraColor.dim) }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A raised card in Sidra's look.
struct TBox<Content: View>: View {
    var caps: String? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let caps { SectionLabel(caps) }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .theasaCard()
    }
}

extension View {
    /// Every Theasa box and card: a solid raised fill under Sidra's gradient border (the one on the
    /// active tab and the focused pane). Theasa-local over `gradientBorder`, so SidraDesign stays as is.
    /// Under `.theasaPlainCards()` (the turn log) the border is a plain hairline instead.
    func theasaCard(fill: Color = SidraColor.raised, radius: CGFloat = SidraRadius.card) -> some View {
        modifier(TheasaCardStyle(fill: fill, radius: radius))
    }
    /// The agent log reads as one surface: no gradient borders (2026-11-14: "In agent log we don't want these borders").
    func theasaPlainCards() -> some View { environment(\.theasaPlainCards, true) }
}

private struct PlainCardsKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var theasaPlainCards: Bool {
        get { self[PlainCardsKey.self] }
        set { self[PlainCardsKey.self] = newValue }
    }
}

private struct TheasaCardStyle: ViewModifier {
    let fill: Color
    let radius: CGFloat
    @Environment(\.theasaPlainCards) private var plain
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if plain {
            content.background(fill, in: shape).overlay(shape.strokeBorder(SidraColor.hairline))
        } else {
            content.background(fill, in: shape).gradientBorder(radius: radius, active: true)
        }
    }
}

/// Small text button.
struct TLink: View {
    let title: String
    var color: Color = SidraColor.muted
    let action: () -> Void
    init(_ title: String, color: Color = SidraColor.muted, action: @escaping () -> Void) { self.title = title; self.color = color; self.action = action }
    var body: some View {
        Button(action: action) { Text(title).font(SidraFont.ui(12.5)).underline().foregroundStyle(color) }
            .buttonStyle(.plain)
    }
}

/// Range picker: Today, 7 days, 30 days.
struct RangePicker: View {
    @Binding var range: String
    var short = false
    var body: some View {
        HStack(spacing: 2) {
            ForEach([("today", "Today"), ("week", short ? "7d" : "7 days"), ("month", short ? "30d" : "30 days")], id: \.0) { k, l in
                Button { range = k } label: {
                    Text(l).font(SidraFont.ui(12.5, weight: range == k ? .bold : .regular))
                        .foregroundStyle(range == k ? SidraColor.text : SidraColor.muted)
                        .padding(.horizontal, 11).frame(height: 28)
                        .background(range == k ? SidraColor.tabActive : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(range == k ? .isSelected : [])
            }
        }
        .padding(2)
        .background(SidraColor.tabStrip, in: RoundedRectangle(cornerRadius: SidraRadius.pill, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SidraRadius.pill, style: .continuous).strokeBorder(SidraColor.hairline))
    }
}

/// Main column with a rail beside it when the pane is wide, under it when narrow.
struct Columns<Main: View, Rail: View>: View {
    var railWidth: CGFloat = 320
    @ViewBuilder let main: () -> Main
    @ViewBuilder let rail: () -> Rail
    @State private var width: CGFloat = 1000
    var body: some View {
        Group {
            if width >= 860 {
                HStack(alignment: .top, spacing: 32) {
                    VStack(alignment: .leading, spacing: 16) { main() }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 26) { rail() }.frame(width: railWidth)
                }
            } else {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 16) { main() }
                    rail()
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// Big number over a muted key, for the totals strips.
struct Stat: View {
    let value: String
    let key: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(SidraFont.mono(21, weight: .medium)).foregroundStyle(SidraColor.textBright)
            Text(key).font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
        }
    }
}

/// Lines for a list.
struct ItemRows<Data: RandomAccessCollection, Row: View>: View where Data.Element: Identifiable {
    let data: Data
    @ViewBuilder let row: (Data.Element) -> Row
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(data) { x in
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(SidraColor.hairline).frame(height: 1)
                    row(x).padding(.vertical, 10)
                }
            }
        }
    }
}

struct Muted: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted).fixedSize(horizontal: false, vertical: true) }
}

// MARK: - Keyboard

extension View {
    /// Every Theasa text field: gaining focus focuses its pane (so ⌘W, ⌘F and the Theasa commands
    /// hit this pane), Esc leaves the field, and the pane losing focus or hiding takes the keyboard back.
    func theasaField(nav: TheasaNav, workspace: WorkspaceStore, focusOn: Int? = nil, submit: (() -> Void)? = nil) -> some View {
        modifier(TheasaFieldFocus(nav: nav, workspace: workspace, focusOn: focusOn, submit: submit))
    }
}

private struct TheasaFieldFocus: ViewModifier {
    let nav: TheasaNav
    let workspace: WorkspaceStore
    let focusOn: Int?
    let submit: (() -> Void)?
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            // No .onKeyPress here: on a focused iPad TextField it swallowed Return, so onSubmit never ran
            // (2026-11-14, proven with a responder probe). Esc in a field is the key host's Back command.
            .onChange(of: focused) { _, on in
                nav.typing = on
                nav.submit = on ? submit : nil
                if on, workspace.focusedPane?.id != nav.focusTarget { workspace.focus(pane: nav.focusTarget) }
            }
            .onChange(of: nav.resign) { _, _ in focused = false }
            .onChange(of: focusOn) { _, _ in if focusOn != nil { focused = true } }
            .onDisappear { if focused { nav.typing = false; nav.submit = nil } }
    }
}
