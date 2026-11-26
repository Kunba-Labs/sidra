import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import PhotosUI
import SidraDesign
import SidraTheasa
import SidraWorkspace

struct TheasaProjectView: View {
    let id: Int
    @Environment(TheasaLive.self) private var live
    @Environment(\.theasaOpen) private var open
    @State private var tab = "timeline"

    var body: some View {
        let q = "range=\(live.projectRange)&agent=\(live.agentFilter)\(live.onlyNotes ? "&only=notes" : "")"
        let id = id
        TheasaLoad(key: "project-\(id)-\(q)", load: { c in try await c.get("/api/projects/\(id)?\(q)", as: ProjectDetail.self) }) { d in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(d)
                    Columns(railWidth: 300) {
                        tabs(d)
                        switch tab {
                        case "decisions": DecisionsList(decisions: d.decisions, projectID: d.project.id)
                        case "watch": WatchList(items: d.watch)
                        case "settings": ProjectSettings(project: d.project)
                        default: timelineTab(d)
                        }
                    } rail: {
                        rail(d)
                    }
                }
                .padding(20)
            }
        }
    }

    /// One row: icon, name, where it lives. No title block.
    private func header(_ d: ProjectDetail) -> some View {
        let p = d.project
        return HStack(spacing: 10) {
            ProjectIconView(p, size: 24)
            Text(p.name).font(SidraFont.ui(15, weight: .bold)).foregroundStyle(SidraColor.textBright)
            Text([p.remote ?? "", TFormat.shortPath(p.root ?? "")].filter { !$0.isEmpty }.joined(separator: ", "))
                .font(SidraFont.mono(12)).foregroundStyle(SidraColor.dim).lineLimit(1).truncationMode(.middle)
            Spacer()
        }
    }

    private func tabs(_ d: ProjectDetail) -> some View {
        let items: [(String, String, String)] = [("timeline", "Timeline", "\(d.totals.turns)"),
                                                 ("decisions", "Decisions", "\(d.decisions.filter { $0.status == "active" }.count)"),
                                                 ("watch", "Watch", "\(d.watch.filter { $0.status == "open" }.count)"),
                                                 ("settings", "Settings", "")]
        return HStack(spacing: 22) {
            ForEach(items, id: \.0) { k, l, n in
                Button { tab = k } label: {
                    VStack(spacing: 8) {
                        HStack(spacing: 5) {
                            Text(l).foregroundStyle(tab == k ? SidraColor.text : SidraColor.muted)
                            Text(n).foregroundStyle(SidraColor.dim)
                        }
                        .font(SidraFont.ui(13.5, weight: tab == k ? .bold : .regular))
                        Rectangle().fill(tab == k ? AnyShapeStyle(SidraGradient.horizontal) : AnyShapeStyle(Color.clear)).frame(height: 2)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == k ? .isSelected : [])
                .accessibilityIdentifier("theasa-tab-\(k)")
            }
            Spacer()
        }
        .overlay(alignment: .bottom) { Rectangle().fill(SidraColor.hairline).frame(height: 1) }
    }

    @ViewBuilder private func timelineTab(_ d: ProjectDetail) -> some View {
        @Bindable var live = live
        let hist = d.hist, hmax = max(1, hist.max() ?? 1)
        let nowIdx = live.projectRange == "today" ? Calendar.current.component(.hour, from: Date()) : hist.count - 1
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 32) { projectTotals(d); histogram(hist, hmax, nowIdx) }
            VStack(alignment: .leading, spacing: 16) { projectTotals(d); histogram(hist, hmax, nowIdx) }
        }
        .padding(18)
        .theasaCard()
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                ForEach([("all", "All agents"), ("claude", "Claude Code"), ("codex", "Codex")], id: \.0) { k, l in
                    Button { live.agentFilter = k } label: {
                        HStack(spacing: 6) {
                            if HerdrAgentMark.known.contains(k) { AgentTag(agent: k, size: 16) }   // the real mark, no name
                            else {
                                Text(l).font(SidraFont.ui(12.5, weight: live.agentFilter == k ? .bold : .regular))
                                    .foregroundStyle(live.agentFilter == k ? SidraColor.text : SidraColor.muted)
                            }
                        }
                            .padding(.horizontal, 11).frame(height: 28)
                            .background(live.agentFilter == k ? SidraColor.tabActive : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }.buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(SidraColor.tabStrip, in: RoundedRectangle(cornerRadius: SidraRadius.pill, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SidraRadius.pill, style: .continuous).strokeBorder(SidraColor.hairline))
            Toggle(isOn: $live.onlyNotes) { Text("Only turns with decisions or watch items").font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted) }
                .toggleStyle(GradientToggleStyle()).frame(maxWidth: 380)
        }
        if d.turns.isEmpty {
            TBox { Muted("No turns in this range" + (live.agentFilter != "all" || live.onlyNotes ? " with these filters." : ".")) }
        }
        ForEach(SidraTheasa.timeline(d.turns, open: live.openFolds)) { day in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(TFormat.dayLabel(day.day)).font(SidraFont.ui(13, weight: .bold)).foregroundStyle(SidraColor.text)
                    Text("\(day.count)").font(SidraFont.ui(13)).foregroundStyle(SidraColor.dim)
                }
                .padding(.top, 12).padding(.bottom, 4)
                ForEach(day.rows) { row in   // the log: plain cards, as on the turn screen
                    switch row {
                    case .turn(let t): TurnRow(turn: t, root: d.project.root).theasaPlainCards()
                    case .fold(let key, let n):
                        Button { live.openFolds.insert(key) } label: { Text("Show \(n) more quiet turns").font(SidraFont.ui(13)).foregroundStyle(SidraColor.dim) }
                            .buttonStyle(.plain).padding(.leading, 104).padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func projectTotals(_ d: ProjectDetail) -> some View {
        HStack(alignment: .top, spacing: 28) {
            Stat(value: "\(d.totals.turns)", key: "turns")
            Stat(value: TFormat.dur(d.totals.agent_ms), key: "agent time")
            Stat(value: TFormat.tok(d.totals.tokens), key: "tokens")
            Stat(value: TFormat.money(d.totals.cost), key: "est. cost")
        }
        .fixedSize()
    }

    private func histogram(_ hist: [Int], _ hmax: Int, _ nowIdx: Int) -> some View {
        @Bindable var live = live
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Agent minutes per \(live.projectRange == "today" ? "hour" : "day")").font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
                Spacer()
                RangePicker(range: $live.projectRange)
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(hist.enumerated()), id: \.offset) { i, m in
                    RoundedRectangle(cornerRadius: 1).fill(i == nowIdx ? SidraColor.text : Color(hex: 0x4A4A52))
                        .frame(height: max(2, CGFloat(m) / CGFloat(hmax) * 40)).frame(maxWidth: .infinity)
                }
            }
            .frame(height: 40, alignment: .bottom)
        }
        .frame(minWidth: 260)
    }

    @ViewBuilder private func rail(_ d: ProjectDetail) -> some View {
        let openWatch = d.watch.filter { $0.status == "open" }
        let active = d.decisions.filter { $0.status == "active" }
        TSection(title: "Open watch items", count: "\(openWatch.count)") {
            if openWatch.isEmpty { Muted("Nothing open.") }
            ItemRows(data: Array(openWatch.prefix(5))) { w in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 8) {
                        Dot(TColor.impact(w.impact)).padding(.top, 6)
                        Button { open(.turn(w.turn_id)) } label: { Text(w.text).font(SidraFont.ui(13.5)).foregroundStyle(SidraColor.text).multilineTextAlignment(.leading) }.buttonStyle(.plain)
                    }
                    HStack { Text("\(w.impact), \(TFormat.ago(w.created_at))"); Spacer(); TLink("Mark done") { Task { await live.act("/api/watch/\(w.id)/done", done: "Marked done.") } } }
                        .font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim).padding(.leading, 15)
                }
            }
        }
        TSection(title: "Decisions", count: "\(active.count)") {
            if active.isEmpty { Muted("None yet.") }
            ItemRows(data: Array(active.prefix(3))) { x in
                VStack(alignment: .leading, spacing: 4) {
                    Button { open(.turn(x.turn_id)) } label: { Text(x.text).font(SidraFont.ui(13.5)).foregroundStyle(SidraColor.text).multilineTextAlignment(.leading) }.buttonStyle(.plain)
                    HStack(spacing: 6) { AgentTag(agent: x.agent ?? "", size: 12); Text(TFormat.ago(x.created_at)) }.font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
                }
            }
            if active.count > 3 { TLink("All \(active.count) decisions") { tab = "decisions" } }
        }
        TSection(title: "Sessions") {
            if d.sessions.isEmpty { Muted("None.") }
            ForEach(d.sessions, id: \.session_id) { s in
                HStack(spacing: 8) {
                    Dot(s.active ? TColor.clean : TColor.none)
                    Text(String(s.session_id.prefix(8))).font(SidraFont.mono(12)).foregroundStyle(SidraColor.text)
                    Text(s.machine ?? "").font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
                    Spacer()
                    AgentTag(agent: s.agent)
                    Text(TFormat.ago(s.last_at)).font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
                }
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) { Rectangle().fill(SidraColor.hairline).frame(height: 1) }
            }
        }
        TSection(title: "Machines") {
            ForEach(d.machines, id: \.machine) { m in
                HStack { Text(m.machine ?? "unknown").foregroundStyle(SidraColor.text); Spacer(); Text(TFormat.plural(m.n, "turn")).font(SidraFont.mono(12)).foregroundStyle(SidraColor.muted) }
                    .font(SidraFont.ui(13)).padding(.vertical, 6)
                    .overlay(alignment: .bottom) { Rectangle().fill(SidraColor.hairline).frame(height: 1) }
            }
        }
    }
}

/// One turn on the timeline: time and agent in the gutter, a dot on the rail, then a card,
/// a one-line headline, or the pending/failed state.
struct TurnRow: View {
    let turn: Turn
    let root: String?
    @Environment(TheasaLive.self) private var live
    @Environment(\.theasaOpen) private var open

    var body: some View {
        let t = turn
        let color = t.isPending ? SidraColor.dim : TColor.verdict(t.verdict)
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(TFormat.clock(t.started_at)).font(SidraFont.mono(13)).foregroundStyle(Color(hex: 0xD4D4D8))
                AgentTag(agent: t.agent)
            }
            .frame(width: 64, alignment: .trailing)
            Circle().strokeBorder(color, lineWidth: 2).background(Circle().fill(t.isPending ? SubstrateStyle.main : color))
                .frame(width: 10, height: 10).padding(.top, 6).frame(width: 34)
            Button { open(.turn(t.id)) } label: { inner(t).contentShape(Rectangle()) }
                .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("theasa-turn-\(t.id)")
    }

    @ViewBuilder private func inner(_ t: Turn) -> some View {
        if t.isPending || t.isFailed || t.headline == nil {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(t.isPending ? "\(agentName(t.agent)) is writing the summary." : t.isFailed ? "The summary failed." : t.summary_status == "skipped" ? "Imported without a summary." : "No summary yet.")
                        .font(SidraFont.ui(13.5)).foregroundStyle(SidraColor.muted)
                    if t.isFailed { TLink("Try again") { Task { await live.act("/api/turns/\(t.id)/resummarize", done: "Summary requested.") } } }
                    Text(TFormat.turnMeta(t)).font(SidraFont.mono(12)).foregroundStyle(SidraColor.dim)
                }
                Text("You asked: “\(String(t.prompt.prefix(220)))”").font(SidraFont.ui(13)).foregroundStyle(SidraColor.dim).lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if t.isHeavy {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(inlineMD(t.headline ?? "")).font(SidraFont.ui(15, weight: .bold)).foregroundStyle(SidraColor.textBright).multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    VerdictLabel(verdict: t.verdict)
                }
                Text(TFormat.turnMeta(t)).font(SidraFont.mono(12)).foregroundStyle(SidraColor.dim)
                let bits = FileKind.changeBits(t, root: root)
                if !bits.isEmpty { Text(bits.joined(separator: "   ")).font(SidraFont.mono(12)).foregroundStyle(SidraColor.muted) }
                let rest = Array((t.summary ?? []).dropFirst())
                if !rest.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(rest.enumerated()), id: \.offset) { _, l in
                            HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•").foregroundStyle(SidraColor.dim); Text(inlineMD(l)) }
                        }
                    }
                    .font(SidraFont.ui(13.5)).foregroundStyle(Color(hex: 0xC4C4CA)).padding(.top, 4)
                }
                ForEach(t.notes ?? [], id: \.self) { n in
                    VStack(spacing: 0) {
                        Rectangle().fill(SidraColor.hairline).frame(height: 1).padding(.vertical, 6)
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            HStack(spacing: 6) {
                                if n.kind == "watch" { Dot(n.status == "done" ? TColor.none : TColor.impact(n.impact ?? ""), size: 6) }
                                Text(n.kind == "watch" ? "WATCH" : "DECIDED").font(SidraFont.ui(11, weight: .bold)).kerning(0.8).foregroundStyle(SidraColor.dim)
                            }
                            .frame(width: 76, alignment: .leading)
                            Text(inlineMD(n.text)).font(SidraFont.ui(13.5))
                                .strikethrough(n.status == "done" || n.status == "superseded")
                                .foregroundStyle(n.status == "done" || n.status == "superseded" ? SidraColor.dim : SidraColor.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Text("You asked: “\(String(t.prompt.prefix(220)))\(t.prompt.count > 220 ? "…" : "")”").font(SidraFont.ui(13)).foregroundStyle(SidraColor.dim).lineLimit(4).padding(.top, 6)
            }
            .multilineTextAlignment(.leading)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .theasaCard()
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(inlineMD(t.headline ?? "")).font(SidraFont.ui(13.5)).foregroundStyle(Color(hex: 0xC4C4CA)).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Text(TFormat.turnMeta(t)).font(SidraFont.mono(12)).foregroundStyle(SidraColor.dim).lineLimit(1)
            }
            .padding(.top, 1)
        }
    }
}

struct DecisionsList: View {
    let decisions: [Decision]
    let projectID: Int
    @Environment(TheasaLive.self) private var live
    @Environment(\.theasaOpen) private var open
    @State private var superseding: Decision?

    var body: some View {
        if decisions.isEmpty { TBox { Muted("No decisions yet.") } }
        ItemRows(data: decisions) { x in DecisionRow(decision: x, supersede: { superseding = x }) }
            .sheet(item: $superseding) { x in SupersedeSheet(decision: x, projectID: projectID).environment(live) }
    }
}

struct DecisionRow: View {
    let decision: Decision
    var big = false
    let supersede: () -> Void
    @Environment(TheasaLive.self) private var live
    @Environment(\.theasaOpen) private var open
    var body: some View {
        let x = decision
        let off = x.status != "active"
        VStack(alignment: .leading, spacing: 6) {
            if off && big { SectionLabel(x.status == "dismissed" ? "Marked as not a real decision" : "Later replaced") }
            Button { if !big { open(.turn(x.turn_id)) } } label: {
                Text(inlineMD(x.text)).font(SidraFont.ui(big ? 15 : 13.5, weight: big ? .bold : .regular)).strikethrough(off)
                    .foregroundStyle(off ? SidraColor.dim : SidraColor.text).multilineTextAlignment(.leading)
            }.buttonStyle(.plain)
            if big, x.why != nil || x.alternative != nil {
                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
                    if let w = x.why { GridRow { Text("Why").foregroundStyle(SidraColor.dim).frame(width: 90, alignment: .leading); Text(inlineMD(w)) } }
                    if let a = x.alternative { GridRow { Text("Not chosen").foregroundStyle(SidraColor.dim).frame(width: 90, alignment: .leading); Text(inlineMD(a)) } }
                }
                .font(SidraFont.ui(13.5)).foregroundStyle(Color(hex: 0xC4C4CA))
            } else if let w = x.why {
                Text("Why: \(w)").font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted)
            }
            HStack(spacing: 16) {
                if !big { HStack(spacing: 6) { AgentTag(agent: x.agent ?? "", size: 12); Text(TFormat.ago(x.created_at) + (x.status == "superseded" ? ", replaced by a later decision" : "")) }.foregroundStyle(SidraColor.dim) }
                if x.status == "active" {
                    TLink("Not a real decision") { Task { await live.act("/api/decisions/\(x.id)/dismiss") } }
                    TLink("Replaced by a later one", action: supersede)
                } else {
                    TLink("Make it active again") { Task { await live.act("/api/decisions/\(x.id)/restore") } }
                }
            }
            .font(SidraFont.ui(12))
        }
    }
}

struct SupersedeSheet: View {
    let decision: Decision
    let projectID: Int
    @Environment(TheasaLive.self) private var live
    @Environment(\.dismiss) private var dismiss
    @State private var others: [Decision]?
    @State private var pick: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Replaced by which decision?").font(SidraFont.ui(17, weight: .bold)).foregroundStyle(SidraColor.text)
            if let others {
                if others.isEmpty { Muted("No other decision in this project.") }
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(others) { x in
                            OptionButton(label: String(x.text.prefix(120)), detail: TFormat.ago(x.created_at), on: pick == x.id) { pick = x.id }
                        }
                    }
                }
                .frame(maxHeight: 360)
            } else { GradientSpinner(size: 16) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.sidraSecondary)
                Button("Mark as replaced") {
                    guard let pick else { return }
                    Task { if await live.act("/api/decisions/\(decision.id)/supersede", ["by": pick]) != nil { dismiss() } }
                }
                .buttonStyle(.sidraPrimary).disabled(pick == nil)
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
        .sidraSheetBackground()
        .task {
            let d = try? await live.client.get("/api/projects/\(projectID)?range=all", as: ProjectDetail.self)
            others = (d?.decisions ?? []).filter { $0.status == "active" && $0.id != decision.id }
        }
    }
}

struct WatchList: View {
    let items: [WatchItem]
    @Environment(TheasaLive.self) private var live
    @Environment(\.theasaOpen) private var open
    var body: some View {
        if items.isEmpty { TBox { Muted("No watch items yet.") } }
        ItemRows(data: items) { w in
            let done = w.status == "done"
            HStack(alignment: .top, spacing: 10) {
                Dot(done ? TColor.none : TColor.impact(w.impact)).padding(.top, 6)
                VStack(alignment: .leading, spacing: 4) {
                    Button { open(.turn(w.turn_id)) } label: {
                        Text(inlineMD(w.text)).font(SidraFont.ui(13.5)).strikethrough(done).foregroundStyle(done ? SidraColor.dim : SidraColor.text).multilineTextAlignment(.leading)
                    }.buttonStyle(.plain)
                    HStack {
                        Text("\(w.impact), \(TFormat.ago(w.created_at))").font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
                        Spacer()
                        Button(done ? "Open again" : "Mark done") { Task { await live.act("/api/watch/\(w.id)/\(done ? "open" : "done")", done: done ? nil : "Marked done.") } }
                            .buttonStyle(.sidraSecondary)
                            .accessibilityIdentifier("theasa-watch-toggle-\(w.id)")
                    }
                }
            }
        }
    }
}

struct ProjectSettings: View {
    let project: Project
    @Environment(TheasaLive.self) private var live
    @Environment(TheasaNav.self) private var nav
    @Environment(WorkspaceStore.self) private var workspace
    @State private var name = ""
    @State private var iconPick: PhotosPickerItem?
    @State private var uploading = false
    @State private var exportFile: URL?
    @State private var exporting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Name")
                HStack {
                    TextField(project.repo_name ?? "", text: $name)
                        .theasaField(nav: nav, workspace: workspace)
                        .font(SidraFont.ui(14)).foregroundStyle(SidraColor.text)
                        .padding(.horizontal, 10).frame(height: 34)
                        .background(SidraColor.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SidraColor.hairline2))
                    Button("Save") { Task { await live.act("/api/projects/\(project.id)", ["name": name], done: "Name saved.") } }.buttonStyle(.sidraPrimary)
                }
                Text("Leave it empty to use the repo name, \(project.repo_name ?? project.name).").font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Icon")
                HStack(spacing: 12) {
                    ProjectIconView(project, size: 44)
                    PhotosPicker(selection: $iconPick, matching: .images) {
                        Text(uploading ? "Uploading…" : "Upload an icon")
                    }
                    .buttonStyle(.sidraSecondary).disabled(uploading)
                    .accessibilityIdentifier("theasa-icon-upload")
                    if project.icon_locked == true {
                        TLink("Use the repo's icon again") { Task { await live.act("/api/projects/\(project.id)", ["icon_reset": true], done: "The next turn sends the repo's icon.") } }
                    }
                }
                Text(project.icon_locked == true ? "You set this icon. New turns keep it." : "From the repo. An upload replaces it.").font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Visibility")
                Toggle(isOn: Binding(get: { project.hidden == true }, set: { h in Task { await live.act("/api/projects/\(project.id)", ["hidden": h]) } })) {
                    Text("Hide it from Pulse and the project list. The data stays.").font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted)
                }
                .toggleStyle(GradientToggleStyle()).frame(maxWidth: 520)
            }
            // The export needs the token, so Sidra downloads it and hands the file to the share sheet.
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Export")
                if let exportFile {
                    ShareLink(item: exportFile) { Text("Share \(exportFile.lastPathComponent)") }
                        .font(SidraFont.ui(13, weight: .bold)).foregroundStyle(SidraColor.text)
                } else {
                    TLink(exporting ? "Downloading…" : "Download all turns as JSON") { Task { await export() } }
                }
            }
            Text("Key: \(project.key ?? "")\nPath: \(project.root ?? "")").font(SidraFont.mono(11.5)).foregroundStyle(SidraColor.dim).textSelection(.enabled)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.top, 6)
        .onAppear { name = project.name }
        .onChange(of: iconPick) { _, item in if let item { Task { await upload(item) } } }
    }

    /// Scales an image down to `side` px on its long edge with ImageIO, which both platforms share.
    private static func shrink(_ raw: Data, to side: Int) -> (png: Data, jpeg: Data?)? {
        guard let src = CGImageSourceCreateWithData(raw as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: side, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return nil }
        func encode(_ type: UTType, _ opts: [CFString: Any] = [:]) -> Data? {
            let out = NSMutableData()
            guard let dst = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dst, cg, opts as CFDictionary)
            return CGImageDestinationFinalize(dst) ? out as Data : nil
        }
        guard let png = encode(.png) else { return nil }
        return (png, encode(.jpeg, [kCGImageDestinationLossyCompressionQuality: 0.8]))
    }

    /// The server takes an image under 1 MB: a large photo is scaled to 512 px and sent as PNG, or JPEG if still too big.
    private func upload(_ item: PhotosPickerItem) async {
        uploading = true
        defer { uploading = false; iconPick = nil }
        guard let raw = try? await item.loadTransferable(type: Data.self), let small = Self.shrink(raw, to: 512) else {
            live.say("That image didn't load."); return
        }
        var data = small.png, mime = "image/png"
        if data.count >= 1_000_000, let jpg = small.jpeg { data = jpg; mime = "image/jpeg" }
        guard data.count < 1_000_000 else { live.say("Pick a smaller image."); return }
        do {
            try await live.client.uploadIcon(project: project.id, image: data, mime: mime)
            live.say("Icon saved."); live.changed()
        } catch {
            live.say((error as? LocalizedError)?.errorDescription ?? "That didn't work.")
        }

    }
}

extension ProjectSettings {
    func export() async {
        exporting = true
        defer { exporting = false }
        do {
            let data = try await live.client.data("/api/projects/\(project.id)/export")
            let safe = project.name.replacingOccurrences(of: "/", with: "-")
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe.isEmpty ? "project" : safe)-turns.json")
            try data.write(to: file, options: .atomic)
            exportFile = file
        } catch {
            live.say("Export failed: \((error as? LocalizedError)?.errorDescription ?? "the server did not answer").")
        }
    }
}
