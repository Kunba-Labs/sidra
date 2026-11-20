import SwiftUI
import SidraDesign
import SidraTheasa

struct TheasaTurnView: View {
    let id: Int
    @Environment(TheasaLive.self) private var live
    @Environment(\.theasaOpen) private var open
    @State private var showRaw = false
    @State private var raw: String?
    @State private var replyOpen = false

    var body: some View {
        let id = id
        TheasaLoad(key: "turn-\(id)", load: { c in try await c.get("/api/turns/\(id)", as: TurnDetail.self) }) { d in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    top(d)
                    Columns(railWidth: 300) {
                        summary(d)
                        watch(d)
                        decisions(d)
                        changes(d)
                        shared(d)
                        reply(d)
                        steps(d)
                        rawLog
                    } rail: {
                        rail(d)
                    }
                    .padding(.top, 14)
                }
                .padding(20)
            }
            .theasaPlainCards()
        }
    }

    private func top(_ d: TurnDetail) -> some View {
        let t = d.turn, p = d.project
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { open(.project(p.id)) } label: {
                    HStack(spacing: 6) { ProjectIconView(p, size: 18); Text(p.name).font(SidraFont.ui(13, weight: .bold)).foregroundStyle(SidraColor.muted) }
                }.buttonStyle(.plain).accessibilityIdentifier("theasa-turn-project")
                if let v = t.verdict {
                    Dot(TColor.verdict(v), label: ["clean": "Clean: nothing to check.", "watch": "Watch: something to check.", "broken": "Broken: something fails at the end."][v.rawValue])
                        .font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted).padding(.leading, 8)
                }
                Spacer()
                if let prev = d.prev { Button("Previous turn") { open(.turn(prev)) }.buttonStyle(.sidraSecondary) }
                if let next = d.next { Button("Next turn") { open(.turn(next)) }.buttonStyle(.sidraSecondary) }
            }
            Text(t.headline.map(inlineMD) ?? AttributedString(t.isPending ? "Summary waiting" : "Turn at " + TFormat.clock(t.started_at)))
                .font(SidraFont.ui(18, weight: .bold)).foregroundStyle(SidraColor.textBright).frame(maxWidth: 920, alignment: .leading)
            let meta = [t.model ?? "", TFormat.stamp(t.started_at) + " to " + TFormat.clock(t.ended_at), TFormat.dur(t.duration_ms),
                        TFormat.tok(t.tokens.totalIn) + " in / " + TFormat.tok(t.tokens.output) + " out", TFormat.money(t.cost), t.machine ?? "",
                        t.branch.map { $0 + (t.head.map { " @ " + $0 } ?? "") } ?? ""].filter { !$0.isEmpty }
            HStack(spacing: 10) { AgentTag(agent: t.agent); Text(meta.joined(separator: "   ")) }
                .font(SidraFont.mono(12)).foregroundStyle(SidraColor.dim)
            VStack(alignment: .leading, spacing: 6) {
                Text("You asked").font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
                Text(t.prompt).font(SidraFont.ui(14)).foregroundStyle(Color(hex: 0xD4D4D8)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                let inAtt = d.attachments.filter { $0.dir == "in" }
                if !inAtt.isEmpty { AttachmentStrip(items: inAtt, root: p.root, label: { $0.kind == "image" ? "IMAGE" : $0.kind == "document" ? "DOC" : "FILE" }) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .theasaCard()
        }
    }


    @ViewBuilder private func summary(_ d: TurnDetail) -> some View {
        let t = d.turn
        let resum = { Task { await live.act("/api/turns/\(t.id)/resummarize", done: "Summary requested.") } }
        TBox(caps: "Summary") {
            if t.isPending {
                Muted("\(agentName(t.agent)) is writing the summary.")
            } else if t.isFailed {
                Muted("The summary failed after 3 tries: " + String((t.summary_error ?? "").prefix(300)))
                Button("Try again") { _ = resum() }.buttonStyle(.sidraSecondary)
            } else if (t.summary ?? []).isEmpty {
                Muted(t.summary_status == "skipped" ? "Imported without a summary." : "No summary yet.")
                Button("Write the summary") { _ = resum() }.buttonStyle(.sidraSecondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array((t.summary ?? []).enumerated()), id: \.offset) { _, l in
                        HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•").foregroundStyle(SidraColor.dim); Text(inlineMD(l)).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                .font(SidraFont.ui(15)).foregroundStyle(SidraColor.text)
                HStack(alignment: .firstTextBaseline) {
                    Text(writtenBy(d)).font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
                    Spacer()
                    TLink("Write it again") { _ = resum() }
                }
            }
        }
    }

    private func writtenBy(_ d: TurnDetail) -> String {
        let t = d.turn
        var s = "Written by \(agentName(t.agent))" + (d.job?.model.map { " (\($0))" } ?? "")
        if let f = TFormat.date(d.job?.finished_at), let e = TFormat.date(t.ended_at), f.timeIntervalSince(e) < 3600 {
            s += ", \(TFormat.dur(max(0, Int(f.timeIntervalSince(e) * 1000)))) after the turn"
        }
        s += "."
        if d.job_count > 1 { s += " Written \(d.job_count) times." }
        return s
    }

    @ViewBuilder private func watch(_ d: TurnDetail) -> some View {
        if !d.watch.isEmpty {
            let imp = ["high": 0, "medium": 1, "low": 2]
            let sorted = d.watch.sorted { (($0.status == "done" ? 1 : 0), imp[$0.impact] ?? 3) < (($1.status == "done" ? 1 : 0), imp[$1.impact] ?? 3) }
            TBox(caps: "Watch  ·  \(d.watch.filter { $0.status == "open" }.count) open") {
                ForEach(Array(sorted.enumerated()), id: \.element.id) { i, w in
                    let done = w.status == "done"
                    if i > 0 { Rectangle().fill(SidraColor.hairline).frame(height: 1) }
                    HStack(alignment: .top, spacing: 10) {
                        Dot(done ? TColor.none : TColor.impact(w.impact)).padding(.top, 7)
                        Text("\(Text(inlineMD(w.text)).font(SidraFont.ui(15)))  \(Text("(\(w.impact))").font(SidraFont.ui(13)).foregroundStyle(SidraColor.dim))")
                            .strikethrough(done).foregroundStyle(done ? SidraColor.dim : SidraColor.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if done {
                            Button("Open again") { Task { await live.act("/api/watch/\(w.id)/open") } }.buttonStyle(.sidraSecondary)
                                .accessibilityIdentifier("theasa-watch-toggle-\(w.id)")
                        } else {
                            Button("Mark done") { Task { await live.act("/api/watch/\(w.id)/done", done: "Marked done.") } }.buttonStyle(.sidraSecondary)
                                .accessibilityIdentifier("theasa-watch-toggle-\(w.id)")
                        }
                    }
                }
            }
        }
    }

    @State private var superseding: Decision?
    @ViewBuilder private func decisions(_ d: TurnDetail) -> some View {
        if !d.decisions.isEmpty {
            TBox(caps: "Decided") {
                ForEach(Array(d.decisions.enumerated()), id: \.element.id) { i, x in
                    if i > 0 { Rectangle().fill(SidraColor.hairline).frame(height: 1) }
                    DecisionRow(decision: x, big: true, supersede: { superseding = x })
                }
            }
            .sheet(item: $superseding) { x in SupersedeSheet(decision: x, projectID: d.project.id).environment(live) }
        }
    }

    @ViewBuilder private func changes(_ d: TurnDetail) -> some View {
        let t = d.turn
        if let files = t.files, !files.isEmpty {
            let diffs = t.diffs ?? [:]
            TBox(caps: "Changes") {
                Muted(diffs.isEmpty ? "No diffs for this turn." : "Tap a file for its diff.")
                ForEach(FileKind.group(files, root: d.project.root), id: \.0) { kind, fs in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(kind.label).font(SidraFont.ui(13, weight: .bold)).foregroundStyle(SidraColor.text)
                            Spacer()
                            Text(FileKind.filesLine(fs)).font(SidraFont.mono(12)).foregroundStyle(SidraColor.dim)
                        }
                        .padding(.vertical, 6)
                        ForEach(fs, id: \.path) { f in FileDiffRow(file: f, diff: diffs[f.path], root: d.project.root) }
                    }
                }
                Text("Edits made with shell commands (sed -i, echo >) don't show.").font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
            }
        }
    }

    @ViewBuilder private func shared(_ d: TurnDetail) -> some View {
        let out = d.attachments.filter { $0.dir == "out" }
        if !out.isEmpty {
            let artifacts = out.filter { $0.kind == "artifact" }, sent = out.filter { $0.kind == "sent" }
            TBox(caps: "Shared with you") {
                ForEach(artifacts) { a in
                    let label = (a.name.hasPrefix("http") || a.name.isEmpty) ? (a.url ?? a.name) : a.name
                    HStack(spacing: 8) {
                        KindChip("ARTIFACT")
                        if let u = a.artifactLink { Link(label, destination: u).font(SidraFont.ui(13.5)).underline().foregroundStyle(SidraColor.text).lineLimit(1) }
                        else { Text(label).font(SidraFont.ui(13.5)).foregroundStyle(SidraColor.text).lineLimit(1) }
                        Spacer()
                        Text((a.count ?? 1) > 1 ? "published \(a.count!) times" : "published").font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
                    }
                    .padding(.vertical, 4)
                }
                if !sent.isEmpty { AttachmentStrip(items: sent, root: d.project.root, label: { _ in "SENT" }) }
            }
        }
    }

    @ViewBuilder private func reply(_ d: TurnDetail) -> some View {
        if let text = d.turn.final_text, !text.isEmpty {
            let long = text.count > 2400
            TBox(caps: "The agent's reply") {
                MarkdownView(text: long && !replyOpen ? String(text.prefix(2400)) + "…" : text)
                if long && !replyOpen { TLink("Show the whole reply") { replyOpen = true } }
            }
        }
    }

    @ViewBuilder private func steps(_ d: TurnDetail) -> some View {
        let t = d.turn
        if let steps = t.steps, !steps.isEmpty {
            TBox {
                HStack { SectionLabel("Steps"); Spacer(); Text("time from the prompt").font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim) }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                        let c = s.tone == "good" ? TColor.clean : s.tone == "problem" ? TColor.watch : Color(hex: 0x6E6E78)
                        HStack(alignment: .top, spacing: 0) {
                            Text(s.at).font(SidraFont.mono(12)).foregroundStyle(SidraColor.dim).frame(width: 56, alignment: .trailing).padding(.top, 2)
                            Circle().fill(c).frame(width: 9, height: 9).padding(.top, 6).frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).font(SidraFont.ui(13.5, weight: .bold)).foregroundStyle(SidraColor.text)
                                Text(s.text).font(SidraFont.ui(13.5)).foregroundStyle(SidraColor.muted).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                .background(alignment: .leading) { Rectangle().fill(Color(hex: 0x26262B)).frame(width: 1).padding(.leading, 72).padding(.vertical, 10) }
                let tools = (t.tools ?? [:]).sorted { $0.value > $1.value }.map { "\($0.key)(\($0.value))" }.joined(separator: ", ")
                Text((tools.isEmpty ? "no tool calls" : tools) + " · " + TFormat.plural(t.model_calls ?? 0, "model call"))
                    .font(SidraFont.mono(12)).foregroundStyle(SidraColor.dim).padding(.leading, 88)
            }
        }
    }

    @ViewBuilder private var rawLog: some View {
        Button {
            showRaw.toggle()
            if showRaw, raw == nil { Task { raw = (try? await live.client.text("/api/turns/\(id)/digest")) ?? "The log didn't load." } }
        } label: {
            HStack {
                Text("Raw turn log").foregroundStyle(SidraColor.text)
                Text("secrets masked").foregroundStyle(SidraColor.dim)
                Spacer()
                Image(systemName: showRaw ? "minus" : "plus").foregroundStyle(SidraColor.muted)
            }
            .font(SidraFont.ui(13.5))
            .padding(.horizontal, 18).frame(height: 46)
            .theasaCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(showRaw ? .isSelected : [])
        if showRaw {
            ScrollView {
                Text(raw ?? "Loading…").font(SidraFont.mono(12)).foregroundStyle(Color(hex: 0xC4C4CA))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(14)
            }
            .frame(maxHeight: 600)
            .theasaCard(fill: SidraColor.ground)
        }
    }

    @ViewBuilder private func rail(_ d: TurnDetail) -> some View {
        let t = d.turn
        let toolMs = t.tool_ms ?? 0, total = max(1, t.duration_ms ?? 0), modelMs = max(0, (t.duration_ms ?? 0) - toolMs)
        TSection(title: "Time") {
            GeometryReader { g in
                HStack(spacing: 2) {
                    Rectangle().fill(Color(hex: 0xD4D4D8)).frame(width: max(0, (g.size.width - 2) * CGFloat(modelMs) / CGFloat(total)))
                    Rectangle().fill(Color(hex: 0x6E6E78))
                }
            }
            .frame(height: 8).clipShape(Capsule())
            kv("Model and waiting", TFormat.dur(modelMs), swatch: Color(hex: 0xD4D4D8))
            kv("Tools", TFormat.dur(toolMs), swatch: Color(hex: 0x6E6E78))
        }
        TSection(title: "Tokens") {
            kv("Input", TFormat.tok(t.tokens.input))   // the meta line's format: 13.6M, 57k
            kv("Cache read", TFormat.tok(t.tokens.cache_read))
            kv("Cache write", TFormat.tok(t.tokens.cache_write))
            kv("Output", TFormat.tok(t.tokens.output))
            kv("Est. cost", TFormat.money(t.cost))
            Text(TFormat.plural(t.model_calls ?? 0, "model call") + ". Cost is an estimate at API list price.").font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
        }
        TSection(title: "Session") {
            Muted("Turn \(d.session.index) of \(d.session.count) in session \(t.session_id.prefix(8))." + (d.session.first_at.map { " Started " + TFormat.ago($0) + "." } ?? ""))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(d.resume).font(SidraFont.mono(12)).foregroundStyle(Color(hex: 0xD4D4D8)).padding(10).textSelection(.enabled)
            }
            .background(SidraColor.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SidraColor.hairline))
            Button("Copy resume command") { Platform.pasteString = d.resume; live.say("Copied.") }.buttonStyle(.sidraSecondary)
                .accessibilityIdentifier("theasa-copy-resume")
        }
    }

    private func kv(_ k: String, _ v: String, swatch: Color? = nil) -> some View {
        HStack(spacing: 8) {
            if let swatch { RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 8, height: 8) }
            Text(k).foregroundStyle(SidraColor.muted)
            Spacer()
            Text(v).font(SidraFont.mono(12.5)).foregroundStyle(SidraColor.text)
        }
        .font(SidraFont.ui(13)).padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(SidraColor.hairline).frame(height: 1) }
    }
}

/// A changed file; with a kept diff it expands. Expansion lives on TheasaLive so a live refetch keeps it.
struct FileDiffRow: View {
    let file: FileChange
    let diff: String?
    let root: String?
    @Environment(TheasaLive.self) private var live

    var body: some View {
        let name = root.map { file.path.replacingOccurrences(of: $0 + "/", with: "") } ?? file.path
        let isOpen = live.openFiles.contains(file.path)
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(SidraColor.hairline).frame(height: 1)
            Button {
                guard diff != nil else { return }
                if isOpen { live.openFiles.remove(file.path) } else { live.openFiles.insert(file.path) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(diff == nil ? .clear : SidraColor.dim).frame(width: 10)
                    Text(name).foregroundStyle(Color(hex: 0xD4D4D8)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("+\(file.add)").foregroundStyle(TColor.clean)
                    Text("-\(file.del)").foregroundStyle(TColor.broken)
                }
                .font(SidraFont.mono(12.5)).padding(.vertical, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name), \(file.add) added, \(file.del) removed")
            .accessibilityAddTraits(isOpen ? .isSelected : [])
            if isOpen, let diff { DiffBlock(text: diff).padding(.bottom, 10) }
        }
    }
}

struct DiffBlock: View {
    let text: String
    @State private var width: CGFloat = 0
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            // Lines never wrap; each row's tint spans at least the visible width.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, l in
                    let k = diffLineKind(l)
                    Text(l.isEmpty ? " " : l)
                        .font(SidraFont.mono(12))
                        .foregroundStyle(k == .add ? Color(hex: 0xB7EBCF) : k == .del ? Color(hex: 0xF5BDBD) : k == .hunk ? SidraColor.dim : Color(hex: 0x9A9AA2))
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .frame(minWidth: width, minHeight: 18, alignment: .leading)
                        .background(k == .add ? Color(hex: 0x13211C) : k == .del ? Color(hex: 0x261718) : k == .hunk ? Color(hex: 0x141418) : .clear)   // solid: clean or broken at 12% over the diff ground
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(Color(hex: 0x0B0B0D), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SidraColor.hairline))
    }
}

/// Thumbnails of raster attachments (`src`), then name chips for the rest.
struct AttachmentStrip: View {
    let items: [Attachment]
    let root: String?
    let label: (Attachment) -> String
    @Environment(TheasaLive.self) private var live
    @State private var viewer: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let images = items.filter { $0.src != nil }
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        // Loaded with the token (theasa 7cb7a95), so not AsyncImage; a tap opens the viewer.
                        ForEach(Array(images.enumerated()), id: \.element.id) { i, a in
                            Button { viewer = i } label: {
                                TheasaImage(src: a.src ?? "", id: a.id, fit: false)
                                    .frame(width: 180, height: 120).clipped()
                                    .background(SidraColor.panel)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SidraColor.hairline2))
                            }
                            .buttonStyle(.plain).accessibilityLabel(a.name)
                            .disabled(live.client.token == nil)
                        }
                    }
                }
            }
            let rest = items.filter { $0.src == nil }
            if !rest.isEmpty {
                TheasaChips(items: rest.map { a in (label(a), TFormat.shortPath(root.map { r in a.name.replacingOccurrences(of: r + "/", with: "") } ?? a.name)) })
            }
        }
        .fullScreenSheet(item: Binding(get: { viewer.map { ViewerStart(index: $0) } }, set: { viewer = $0?.index })) { start in
            TheasaImageViewer(images: items.filter { $0.src != nil }.map { ViewerImage(id: $0.id, src: $0.src ?? "", name: TFormat.shortPath($0.name)) }, start: start.index)
                .environment(live)
        }
    }
    private struct ViewerStart: Identifiable { let index: Int; var id: Int { index } }
}

struct TheasaChips: View {
    let items: [(String, String)]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                HStack(spacing: 6) { KindChip(it.0); Text(it.1).font(SidraFont.mono(12)).foregroundStyle(Color(hex: 0xC4C4CA)).lineLimit(1).truncationMode(.middle) }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SidraColor.hairline2))
            }
        }
    }
}
