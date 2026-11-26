import SwiftUI
import SidraDesign
import SidraTheasa
import SidraWorkspace

struct TheasaAgentsView: View {
    @Environment(TheasaLive.self) private var live
    @Environment(TheasaNav.self) private var nav

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                content
            }
            .padding(20)
        }
        .refreshable { await live.loadAgents() }
        .onChange(of: nav.highlightAgent, initial: true) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .top) } } }
        // The agents may load after the highlight is set: scroll again once they arrive.
        .onChange(of: live.agents?.agents.map(\.pane_id)) { _, _ in if let id = nav.highlightAgent { proxy.scrollTo(id, anchor: .top) } }
        .onChange(of: nav.scrollTo) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .center) }; nav.scrollTo = nil } }
        }
    }

    @ViewBuilder private var content: some View {
        if live.needsToken {
            TheasaEmpty(title: "Add the token to see agents", detail: "Run theasa token on the server and paste it into the connection.",
                        action: ("Add the token", { TheasaStore.shared.showConnections() }))
        } else if let L = live.agents {
            if !L.available {
                TheasaEmpty(title: "No live agents", detail: (L.error.map { $0 + ". " } ?? "") + "Run herdr on the Mac with Theasa.",
                            retry: { Task { await live.loadAgents() } })
            } else if L.agents.isEmpty {
                TBox { Muted("No agents open in herdr.") }
            } else {
                // Working first (2026-11-14: "put working on top"), then what waits for you.
                let g = AgentLogic.groups(L.agents)
                group("Working", g.working, note: nil)
                group("Needs you", g.needs, note: nil)
                // Only the idle agents lose the gradient border; working and needs-you keep it (2026-11-14).
                group("Your turn", g.yourTurn, note: nil).theasaPlainCards()
            }
        } else {
            TheasaEmpty(title: "No connection to Theasa", detail: "Check that the server runs and this iPad can reach it.",
                        retry: { Task { await live.loadAgents() } })
        }
    }

    @ViewBuilder private func group(_ title: String, _ list: [LiveAgent], note: String?) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                TSection(title: title, count: "\(list.count)") { if let note { Muted(note) } }
                AgentGrid(agents: list)
            }
        }
    }
}

struct AgentGrid: View {
    let agents: [LiveAgent]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
            ForEach(agents) { AgentCard(agent: $0).id($0.pane_id) }
        }
    }
}

/// One agent pane. Drafts and picks live on TheasaLive, keyed by pane and session, so a refetch
/// (a live change) redraws the card without touching what is half typed.
struct AgentCard: View {
    let agent: LiveAgent
    @Environment(TheasaLive.self) private var live
    @Environment(\.theasaOpen) private var open
    @Environment(TheasaNav.self) private var nav
    @State private var sending = false
    @State private var missing: Set<Int> = []
    @State private var previewOf: [Int: String] = [:]
    /// The question shown when an ask has several: one per page.
    @State private var page = 0

    var body: some View {
        let a = agent
        let picked = nav.highlightAgent == a.pane_id
        VStack(alignment: .leading, spacing: 12) {
            head(a)
            if let ask = a.ask { askBody(a, ask) }
            else if let screen = a.screen { screenBody(a, screen) }
            else if a.status == "done" || a.status == "idle" { replyBody(a) }
            else if a.status == "working", let last = a.last, let h = last.headline {
                Button { open(.turn(last.turn_id)) } label: {
                    Text("\(Text("Last turn: ").foregroundStyle(SidraColor.dim))\(Text(inlineMD(h)).foregroundStyle(SidraColor.text))").font(SidraFont.ui(13)).multilineTextAlignment(.leading)
                }.buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The card ⌥⌘N picked gets the lighter fill of an active tab.
        .theasaCard(fill: picked ? SidraColor.tabActive : SidraColor.raised)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityIdentifier("theasa-agent-\(a.pane_id)")
    }

    private func head(_ a: LiveAgent) -> some View {
        let name = a.logProject?.name ?? a.cwd ?? a.pane_id
        let when = a.status != "blocked" && a.status != "working" && a.last != nil ? a.last?.ended_at : a.since
        return HStack(spacing: 10) {
            ProjectIconView(iconURL: a.logProject?.icon_url, initial: a.logProject?.initial, size: 22)
            Button { if let id = a.logProject?.id { open(.project(id)) } } label: {
                Text(name).font(SidraFont.ui(14, weight: .bold)).foregroundStyle(SidraColor.text).lineLimit(1)
            }.buttonStyle(.plain).disabled(a.logProject?.id == nil)
            if let t = a.title, t.lowercased() != (a.logProject?.name ?? "").lowercased() {
                Text(t).font(SidraFont.ui(13)).foregroundStyle(SidraColor.dim).lineLimit(1)
            }
            AgentTag(agent: a.agent)
            Spacer(minLength: 4)
            Dot(TColor.status(a.status), label: AgentLogic.label(a.status)).font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted)
            Text(TFormat.ago(when)).font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim).lineLimit(1)
        }
    }

    // MARK: ask: questions with options, own answer, Send answers

    private func pickKey(_ a: LiveAgent, _ qi: Int) -> String { a.draftKey("\(qi)") }
    private func ownKey(_ a: LiveAgent, _ qi: Int) -> String { a.draftKey("o\(qi)") }

    @ViewBuilder private func askBody(_ a: LiveAgent, _ ask: [LiveAgent.Question]) -> some View {
        @Bindable var live = live
        if let x = a.ask_extras { AskExtrasView(extras: x) }
        let cur = min(page, ask.count - 1)
        if ask.count > 1 { pager(a, ask, cur) }
        ForEach(Array(ask.enumerated()).filter { ask.count == 1 || $0.offset == cur }, id: \.offset) { qi, q in
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let h = q.header, !h.isEmpty { KindChip(h.uppercased()) }
                    Text(inlineMD(q.question)).font(SidraFont.ui(15)).foregroundStyle(SidraColor.text)
                    if q.multiSelect == true { Text("pick any").font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim) }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 6, alignment: .top)], alignment: .leading, spacing: 6) {
                    ForEach(q.options, id: \.label) { o in
                        let on = (live.picks[pickKey(a, qi)] ?? []).contains(o.label)
                        OptionButton(label: o.label, detail: o.description == o.label ? nil : o.description, on: on, hasPreview: o.preview != nil) {
                            live.picks[pickKey(a, qi)] = AgentLogic.toggle(live.picks[pickKey(a, qi)] ?? [], o.label, multi: q.multiSelect == true)
                        }
                        // Leaving an option hands the preview back to the picked one.
                        .onHover { inside in
                            if inside { if o.preview != nil { previewOf[qi] = o.label } } else if previewOf[qi] == o.label { previewOf[qi] = nil }
                        }
                    }
                }
                // One preview panel per question: the hovered option's, else the picked one's, else the first.
                let shown = q.options.first { $0.label == previewOf[qi] && $0.preview != nil }
                    ?? q.options.first { (live.picks[pickKey(a, qi)] ?? []).contains($0.label) && $0.preview != nil }
                    ?? q.options.first { $0.preview != nil }
                if let o = shown, let preview = o.preview { OptionPreview(label: o.label, text: preview) }
                DraftField(placeholder: "Your own answer (replaces the picks)", key: ownKey(a, qi), axis: .horizontal) { send(a, ask) }
                    .accessibilityLabel("Your own answer to: \(q.question)")
                if missing.contains(qi) {
                    Text("Pick an option or type an answer.").font(SidraFont.ui(12)).foregroundStyle(TColor.broken)
                }
            }
            .padding(missing.contains(qi) ? 6 : 0)
            .overlay { if missing.contains(qi) { RoundedRectangle(cornerRadius: 6).strokeBorder(TColor.broken, lineWidth: 1).padding(-0) } }
            .id(a.draftKey("q\(qi)"))
            // A sideways swipe pages; the card's vertical scroll is left alone.
            .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { g in
                guard ask.count > 1, abs(g.translation.width) > abs(g.translation.height) * 2 else { return }
                withAnimation(.snappy) { page = max(0, min(ask.count - 1, cur + (g.translation.width < 0 ? 1 : -1))) }
            })
        }
        HStack(spacing: 10) {
            if ask.count > 1, cur > 0 {
                Button("Back") { withAnimation(.snappy) { page = cur - 1 } }.buttonStyle(.sidraSecondary)
                    .accessibilityIdentifier("theasa-ask-back")
            }
            if ask.count > 1, cur < ask.count - 1 {
                Button("Next") { withAnimation(.snappy) { page = cur + 1 } }.buttonStyle(.sidraPrimary)
                    .accessibilityIdentifier("theasa-ask-next")
                // Every question answered: no need to page to the end to send.
                if missingNow(a, ask).isEmpty {
                    Button(sending ? "Sending…" : "Send answers") { send(a, ask) }.buttonStyle(.sidraSecondary).disabled(sending)
                        .accessibilityIdentifier("theasa-send-answers")
                }
            } else {
                Button(sending ? "Sending…" : (ask.count > 1 ? "Send answers" : "Send answer")) { send(a, ask) }
                    .buttonStyle(.sidraPrimary).disabled(sending)
                    .accessibilityIdentifier("theasa-send-answers")
            }
            Text("Your answers go to the agent as your next message.").font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
        }
    }

    private func missingNow(_ a: LiveAgent, _ ask: [LiveAgent.Question]) -> [Int] {
        AgentLogic.missing(ask, picks: Dictionary(uniqueKeysWithValues: ask.indices.map { ($0, live.picks[pickKey(a, $0)] ?? []) }),
                           own: Dictionary(uniqueKeysWithValues: ask.indices.map { ($0, live.drafts[ownKey(a, $0)] ?? "") }))
    }

    /// One chip per question: its header (or number), a check once answered, the gradient border on the
    /// one shown. A tap shows that question.
    private func pager(_ a: LiveAgent, _ ask: [LiveAgent.Question], _ cur: Int) -> some View {
        let open = Set(missingNow(a, ask))
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ask.indices, id: \.self) { i in
                    let h = ask[i].header.flatMap { $0.isEmpty ? nil : $0 } ?? "Question \(i + 1)"
                    Button { withAnimation(.snappy) { page = i } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: open.contains(i) ? "circle" : "checkmark.circle.fill")
                                .foregroundStyle(open.contains(i) ? SidraColor.dim : SidraColor.jade)
                            Text("\(i + 1)").foregroundStyle(SidraColor.dim)
                            Text(h).foregroundStyle(i == cur ? SidraColor.text : SidraColor.muted).lineLimit(1)
                        }
                        .font(SidraFont.ui(12.5, weight: i == cur ? .bold : .regular))
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(i == cur ? SidraColor.tabActive : SubstrateStyle.chip, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(i == cur ? AnyShapeStyle(SidraGradient.horizontal) : AnyShapeStyle(SidraColor.hairline2), lineWidth: i == cur ? 1.5 : 1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Question \(i + 1) of \(ask.count): \(h)\(open.contains(i) ? "" : ", answered")")
                    .accessibilityAddTraits(i == cur ? .isSelected : [])
                    .accessibilityIdentifier("theasa-ask-page-\(i)")
                }
                Text("\(cur + 1) of \(ask.count)").font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim).padding(.leading, 4)
            }
        }
    }

    private func send(_ a: LiveAgent, _ ask: [LiveAgent.Question]) {
        let picks = Dictionary(uniqueKeysWithValues: ask.indices.map { ($0, live.picks[pickKey(a, $0)] ?? []) })
        let own = Dictionary(uniqueKeysWithValues: ask.indices.map { ($0, live.drafts[ownKey(a, $0)] ?? "") })
        // Nothing goes out while a question has neither a pick nor typed text (theasa e4e3a29).
        missing = Set(AgentLogic.missing(ask, picks: picks, own: own))
        if let first = missing.min() {
            live.say(AgentLogic.missingMessage(missing.sorted(), of: ask.count))
            page = first
            nav.scrollTo = a.draftKey("q\(first)")
            return
        }
        let text = AgentLogic.answerText(ask, picks: picks, own: own)
        Task {
            sending = true
            defer { sending = false }
            // A failure (409: the dialog did not close) keeps the picks and typed answers for a retry.
            if await live.act(TheasaClient.promptPath(a), ["text": text], done: "Answers sent.") != nil {
                for i in ask.indices { live.picks[pickKey(a, i)] = nil; live.drafts[ownKey(a, i)] = nil }
                page = 0
            }
        }
    }

    // MARK: screen: the dialog text, option keys, arrows

    @ViewBuilder private func screenBody(_ a: LiveAgent, _ s: LiveAgent.Screen) -> some View {
        ScrollView {
            Text(s.text).font(SidraFont.mono(11.5)).foregroundStyle(SidraColor.terminalText)
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .frame(maxHeight: 340)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .background(SidraColor.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SidraColor.hairline))
        if !s.options.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(s.options, id: \.self) { o in
                    let num = o.keys.first.flatMap { Int($0) != nil ? $0 + ". " : nil } ?? ""
                    OptionButton(label: num + o.label, detail: nil, on: o.selected == true) { keys(a, o.keys) }
                }
            }
        }
        HStack(spacing: 6) {
            ForEach([("up", "↑"), ("down", "↓"), ("enter", "Enter"), ("esc", "Esc")], id: \.0) { k, l in
                Button(l) { keys(a, [k]) }.buttonStyle(.sidraSecondary).accessibilityLabel("Press \(k)")
            }
        }
    }

    private func keys(_ a: LiveAgent, _ k: [String]) {
        Task { await live.act(TheasaClient.keysPath(a), ["keys": k], done: "Sent.") }
    }

    // MARK: done / idle: last headline, the question, a message

    @ViewBuilder private func replyBody(_ a: LiveAgent) -> some View {
        let q = a.last?.question
        if let last = a.last {
            VStack(alignment: .leading, spacing: 8) {
                Button { open(.turn(last.turn_id)) } label: {
                    Text(last.headline.map(inlineMD) ?? AttributedString("Last turn"))
                        .font(SidraFont.ui(14, weight: last.headline == nil ? .regular : .bold))
                        .foregroundStyle(last.headline == nil ? SidraColor.muted : SidraColor.text).multilineTextAlignment(.leading)
                }.buttonStyle(.plain)
                if let q {
                    MarkdownView(text: q, compact: true)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(SubstrateStyle.chip, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SidraColor.hairline2))
                }
            }
        } else {
            Muted("No turn from this session yet.")
        }
        VStack(alignment: .leading, spacing: 6) {
            DraftField(placeholder: q != nil ? "Answer the agent" : "Next message for the agent", key: a.draftKey("reply"), axis: .vertical) { sendReply(a) }
                .accessibilityLabel("Message for \(a.title ?? a.pane_id)")
            HStack(spacing: 10) {
                Button(sending ? "Sending…" : "Send") { sendReply(a) }.buttonStyle(.sidraSecondary).disabled(sending)
                Text("⌘ Return sends").font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
            }
        }
    }

    private func sendReply(_ a: LiveAgent) {
        let k = a.draftKey("reply")
        let text = (live.drafts[k] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { live.say("Type a message first."); return }
        Task {
            sending = true
            defer { sending = false }
            if await live.act(TheasaClient.promptPath(a), ["text": text], done: "Sent.") != nil { live.drafts[k] = nil }
        }
    }
}

/// A text field bound to a draft on TheasaLive. ⌘↩ submits.
struct DraftField: View {
    let placeholder: String
    let key: String
    var axis: Axis = .vertical
    let submit: () -> Void
    @Environment(TheasaLive.self) private var live
    @Environment(TheasaNav.self) private var nav
    @Environment(WorkspaceStore.self) private var workspace
    var body: some View {
        TextField(placeholder, text: Binding(get: { live.drafts[key] ?? "" }, set: { live.drafts[key] = $0 }), axis: axis)
            .lineLimit(axis == .vertical ? 2...8 : 1...1)
            .font(SidraFont.ui(14)).foregroundStyle(SidraColor.text)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(SidraColor.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SidraColor.hairline2))
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                submit(); return .handled
            }
            .theasaField(nav: nav, workspace: workspace, submit: submit)
    }
}

struct OptionButton: View {
    let label: String
    let detail: String?
    let on: Bool
    var hasPreview = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(label).font(SidraFont.ui(14)).foregroundStyle(SidraColor.text)
                    if hasPreview { Image(systemName: "rectangle.on.rectangle").font(.system(size: 10)).foregroundStyle(SidraColor.dim).accessibilityLabel("has a preview") }
                }
                if let detail, !detail.isEmpty { Text(detail).font(SidraFont.ui(12)).foregroundStyle(SidraColor.muted) }
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            // Picked: an active tab's fill and the selection gradient, as Sidra marks every selection.
            .background(on ? SidraColor.tabActive : SubstrateStyle.chip, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .gradientBorder(radius: 8, active: on, inactive: SidraColor.hairline2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct KindChip: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(SidraFont.mono(10)).kerning(0.5).foregroundStyle(SidraColor.dim)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(SidraColor.hairline2))
    }
}

// MARK: - What the agent showed with its question

/// The agent's text before the question (collapsed to about six lines), then what it sent: image
/// thumbnails that open a viewer, file chips, artifact chips that open claude.ai.
struct AskExtrasView: View {
    let extras: LiveAgent.AskExtras
    @Environment(TheasaLive.self) private var live
    @Environment(\.openURL) private var openURL
    @State private var expanded = false
    @State private var viewer: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let c = extras.context, !c.isEmpty {
                let long = c.count > 420 || c.components(separatedBy: "\n").count > 6
                VStack(alignment: .leading, spacing: 6) {
                    MarkdownView(text: c, compact: true)
                        .frame(maxHeight: long && !expanded ? 128 : nil, alignment: .top)
                        .clipped()
                    if long { TLink(expanded ? "Show less" : "Show more") { expanded.toggle() } }
                }
            }
            let images = extras.attachments.filter(\.isImage)
            let others = extras.attachments.filter { !$0.isImage }
            if !extras.attachments.isEmpty {
                SectionLabel("Attachments")
                if !images.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(images.enumerated()), id: \.element.id) { i, a in
                                Button { viewer = i } label: {
                                    TheasaImage(src: a.src ?? "", id: a.id, fit: false)
                                        .frame(width: 180, height: 120).clipped()
                                        .theasaCard(fill: SidraColor.ground, radius: 8)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(a.basename)
                                .accessibilityIdentifier("theasa-thumb-\(i)")
                            }
                        }
                        .padding(2)
                    }
                }
                if !others.isEmpty {
                    TheasaChipRow(items: others.map { a in
                        (a.kind == "artifact" ? "ARTIFACT" : "FILE", a.kind == "artifact" ? a.name : a.basename, a.artifactLink)
                    }) { openURL($0) }
                }
            }
        }
        .fullScreenSheet(item: Binding(get: { viewer.map { ViewerStart(index: $0) } }, set: { viewer = $0?.index })) { start in
            TheasaImageViewer(images: images.map { ViewerImage(id: $0.id, src: $0.src ?? "", name: $0.basename) }, start: start.index).environment(live)
        }
    }

    private var images: [LiveAgent.AskAttachment] { extras.attachments.filter(\.isImage) }
    private struct ViewerStart: Identifiable { let index: Int; var id: Int { index } }
}

/// File and artifact chips; an artifact with a claude.ai link opens it.
struct TheasaChipRow: View {
    let items: [(kind: String, name: String, link: URL?)]
    let open: (URL) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                Button { if let l = it.link { open(l) } } label: {
                    HStack(spacing: 6) {
                        KindChip(it.kind)
                        Text(it.name).font(SidraFont.mono(12)).foregroundStyle(it.link != nil ? SidraColor.text : Color(hex: 0xC4C4CA))
                            .underline(it.link != nil).lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(SubstrateStyle.chip, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SidraColor.hairline2))
                }
                .buttonStyle(.plain).disabled(it.link == nil)
            }
        }
    }
}

/// An option's preview (mockup, code, markdown) in monospace: line breaks kept, scrolls both ways.
struct OptionPreview: View {
    let label: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview: \(label)").font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
            ScrollView([.horizontal, .vertical]) {
                Text(text).font(SidraFont.mono(12)).foregroundStyle(SidraColor.terminalText)
                    .fixedSize().padding(12).textSelection(.enabled)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            .background(SidraColor.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SidraColor.hairline2))
            .accessibilityIdentifier("theasa-option-preview")
        }
    }
}

/// Images the agents sent, loaded with the token (AsyncImage cannot send it) and kept per id.
@MainActor enum TheasaImageCache {
    static let shared = NSCache<NSString, PlatformImage>()
}

struct TheasaImage: View {
    let src: String
    let id: Int
    var fit = true
    @Environment(TheasaLive.self) private var live
    @State private var image: PlatformImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image {
                Image(platformImage: image).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
            } else if live.client.token == nil {
                // Sent files and pasted images need the token (theasa 7cb7a95).
                Text("Add the token to see images.").font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
                    .multilineTextAlignment(.center).padding(8).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if failed {
                Image(systemName: "photo").foregroundStyle(SidraColor.dim).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GradientSpinner(size: 14).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Keyed by the credential: an image first shown without a token loads once one is added, and
        // another account on the same server never sees the previous account's images.
        .task(id: "\(src)|\(live.client.base.absoluteString)|\(live.client.token?.hashValue ?? 0)") {
            failed = false
            image = nil
            guard let token = live.client.token else { return }
            let key = "\(live.client.base.absoluteString)|\(token.hashValue)|\(id)|\(src)" as NSString
            if let hit = TheasaImageCache.shared.object(forKey: key) { image = hit; return }
            if let d = try? await live.client.data(src), let img = PlatformImage(data: d) {
                TheasaImageCache.shared.setObject(img, forKey: key); image = img
            } else { failed = true }
        }
    }
}

/// Full-size images: swipe between them, pinch to zoom, Done.
/// One image for the viewer: question attachments and turn attachments both map to it.
struct ViewerImage: Identifiable, Hashable { let id: Int; let src: String; let name: String }

struct TheasaImageViewer: View {
    let images: [ViewerImage]
    @State var index: Int
    @Environment(\.dismiss) private var dismiss
    init(images: [ViewerImage], start: Int) { self.images = images; _index = State(initialValue: start) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(images.indices.contains(index) ? images[index].name : "").font(SidraFont.ui(14, weight: .bold)).foregroundStyle(SidraColor.text).lineLimit(1)
                Text("\(index + 1) of \(images.count)").font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.dim)
                Spacer()
                #if os(macOS)
                // No swipe on a Mac: arrow buttons and the ← → keys page through.
                if images.count > 1 {
                    Button("Previous", systemImage: "chevron.left") { index = max(0, index - 1) }
                        .labelStyle(.iconOnly).buttonStyle(.sidraSecondary).keyboardShortcut(.leftArrow, modifiers: []).disabled(index == 0)
                    Button("Next", systemImage: "chevron.right") { index = min(images.count - 1, index + 1) }
                        .labelStyle(.iconOnly).buttonStyle(.sidraSecondary).keyboardShortcut(.rightArrow, modifiers: []).disabled(index >= images.count - 1)
                }
                #endif
                Button("Done") { dismiss() }.buttonStyle(.sidraPrimary).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).frame(height: 52)
            #if os(macOS)
            if images.indices.contains(index) { ZoomableImage(src: images[index].src, id: images[index].id).id(images[index].id) }
            #else
            TabView(selection: $index) {
                ForEach(Array(images.enumerated()), id: \.element.id) { i, a in
                    ZoomableImage(src: a.src, id: a.id).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .always : .never))
            #endif
        }
        .background(SidraColor.ground.ignoresSafeArea())
        .accessibilityIdentifier("theasa-viewer")
    }
}

private struct ZoomableImage: View {
    let src: String
    let id: Int
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1
    var body: some View {
        // Sized from the viewer itself: in Split View or a small window the screen is wider than it.
        GeometryReader { g in
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                TheasaImage(src: src, id: id)
                    .frame(width: g.size.width * scale, height: g.size.height * scale)
            }
        }
        .gesture(MagnifyGesture()
            .onChanged { v in scale = min(max(base * v.magnification, 1), 6) }
            .onEnded { _ in base = scale })
        .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5; base = scale } }
    }
}
