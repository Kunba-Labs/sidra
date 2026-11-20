import SwiftUI
import SidraDesign
import SidraTheasa

struct PulseData: Sendable { let pulse: Pulse; let projects: [ProjectRow]; let anyProjects: Bool }

struct TheasaPulseView: View {
    @Environment(TheasaLive.self) private var live
    @Environment(\.theasaOpen) private var open

    var body: some View {
        @Bindable var live = live
        let range = live.range
        TheasaLoad(key: "pulse-\(range)", load: { c in
            async let p = c.get("/api/pulse?range=\(range)", as: Pulse.self)
            async let pr = c.get("/api/projects?range=\(range)", as: [ProjectRow].self)
            let (pulse, rows) = try await (p, pr)
            let any = pulse.totals.turns > 0 || !pulse.attention.isEmpty ? true : !(try await c.get("/api/projects?range=all", as: [ProjectRow].self)).isEmpty
            return PulseData(pulse: pulse, projects: rows, anyProjects: any)
        }) { d in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    waiting
                    totals(d.pulse)
                    Columns {
                        days(d)
                        projectsTable(d.projects)
                    } rail: {
                        rail(d.pulse)
                    }
                }
                .padding(20)
            }
        }
    }

    private var rangeWord: String { ["today": "today", "week": "in the last 7 days", "month": "in the last 30 days"][live.range] ?? "" }

    @ViewBuilder private var waiting: some View {
        let all = live.agents?.available == true ? live.agents!.agents : []
        let needs = AgentLogic.waiting(all)
        if !needs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TSection(title: "Waiting for you", count: "\(needs.count)") { EmptyView() }
                    Spacer()
                    let rest = AgentLogic.moreReady(all)
                    TLink("All agents" + (rest > 0 ? " (\(rest) more ready)" : "")) { open(.agents) }
                }
                AgentGrid(agents: needs)
            }
        }
    }

    private func totals(_ p: Pulse) -> some View {
        let t = p.totals
        let codex = t.by_agent["codex"] ?? 0
        // A grid, so the four numbers wrap to two rows on a phone.
        let stats = LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 24, alignment: .topLeading)], alignment: .leading, spacing: 14) {
                Stat(value: "\(t.turns)", key: "turns" + (codex > 0 ? " (\(t.by_agent["claude"] ?? 0) Claude, \(codex) Codex)" : ""))
                Stat(value: TFormat.dur(t.agent_ms), key: "agent time")
                Stat(value: TFormat.tok(t.tokens), key: "tokens, \(Int((t.cache_share * 100).rounded()))% from cache")
                Stat(value: TFormat.money(t.cost), key: "at API list price" + (t.priced < t.turns ? ", \(t.turns - t.priced) turns without a price" : ""))
            }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 36) { stats.frame(minWidth: 640); TokenBars(bars: p.bars) }
            VStack(alignment: .leading, spacing: 16) { stats; TokenBars(bars: p.bars) }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .theasaCard()
    }

    @ViewBuilder private func days(_ d: PulseData) -> some View {
        if d.pulse.totals.turns == 0 && d.pulse.attention.isEmpty {
            TBox {
                if d.anyProjects { Muted("No turns \(rangeWord). Pick a longer range.") }
                else {
                    Text("No turns yet.").font(SidraFont.ui(15, weight: .bold)).foregroundStyle(SidraColor.text)
                    Muted("Run theasa install on each machine with Claude Code or Codex. Run theasa backfill to import old transcripts.")
                }
            }
        } else if d.pulse.days.isEmpty {
            TBox { Muted("No turns \(rangeWord).") }
        } else {
            ForEach(d.pulse.days, id: \.day) { day in
                VStack(alignment: .leading, spacing: 18) {
                    Text(TFormat.dayLabel(day.day)).font(SidraFont.ui(13, weight: .bold)).foregroundStyle(SidraColor.dim)
                    ForEach(Array(day.items.enumerated()), id: \.offset) { _, it in PulseItemView(item: it) }
                }
                .padding(.bottom, 14)
            }
        }
    }

    @ViewBuilder private func projectsTable(_ rows: [ProjectRow]) -> some View {
        let shown = rows.filter { $0.hidden != true && $0.last_at != nil }
        if !shown.isEmpty {
            TSection(title: "All projects", count: "\(shown.count)") {
                ScrollView(.horizontal, showsIndicators: false) {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
                        GridRow {
                            ForEach(["Project", "Machines", "Last turn", "Turns", "Tokens", "Agent time", "Est. cost", "Open watch"], id: \.self) { h in
                                Text(h).font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
                            }
                        }
                        .padding(.vertical, 8)
                        ForEach(shown) { p in
                            Divider().overlay(SidraColor.hairline)
                            GridRow {
                                Button { open(.project(p.id)) } label: {
                                    HStack(spacing: 8) { ProjectIconView(iconURL: p.icon_url, initial: p.initial, size: 20); Text(p.name).font(SidraFont.ui(13, weight: .bold)).foregroundStyle(SidraColor.text) }
                                }.buttonStyle(.plain)
                                Text(p.machines.joined(separator: ", ")).foregroundStyle(SidraColor.muted)
                                Text(TFormat.ago(p.last_at)).foregroundStyle(SidraColor.muted)
                                Text("\(p.turns)").font(SidraFont.mono(12.5)).gridColumnAlignment(.trailing)
                                Text(TFormat.tok(p.tokens)).font(SidraFont.mono(12.5)).gridColumnAlignment(.trailing)
                                Text(TFormat.dur(p.agent_ms)).font(SidraFont.mono(12.5)).gridColumnAlignment(.trailing)
                                Text(TFormat.money(p.cost)).font(SidraFont.mono(12.5)).gridColumnAlignment(.trailing)
                                Group { if p.open_watch > 0 { Dot(TColor.watch, label: "\(p.open_watch) open") } else { Text("None").foregroundStyle(SidraColor.dim) } }
                            }
                            .font(SidraFont.ui(13)).foregroundStyle(SidraColor.text)
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .theasaCard()
            }
        }
    }

    @ViewBuilder private func rail(_ p: Pulse) -> some View {
        TSection(title: "Needs attention", count: "\(p.open_watch)") {
            if p.attention.isEmpty { Muted("Nothing open.") }
            ItemRows(data: p.attention) { a in
                HStack(alignment: .top, spacing: 10) {
                    Dot(TColor.impact(a.impact)).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 4) {
                        Button { open(.turn(a.turn_id)) } label: { Text(a.text).font(SidraFont.ui(13.5)).foregroundStyle(SidraColor.text).multilineTextAlignment(.leading) }.buttonStyle(.plain)
                        HStack(spacing: 6) {
                            ProjectIconView(a.project, size: 14)
                            Text("\(a.project?.name ?? "") · \(a.impact)")
                            Spacer()
                            Text(TFormat.ago(a.created_at))
                            TLink("Done") { Task { await live.act("/api/watch/\(a.id)/done", done: "Marked done.") } }
                                .accessibilityIdentifier("theasa-watch-done-\(a.id)")
                        }
                        .font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
                    }
                }
            }
        }
        TSection(title: live.range == "today" ? "Decided today" : "Decided in this range", count: "\(p.decisions_count)") {
            if p.decisions.isEmpty { Muted("No decisions \(rangeWord).") }
            ItemRows(data: p.decisions) { x in
                VStack(alignment: .leading, spacing: 4) {
                    Button { open(.turn(x.turn_id)) } label: { Text(x.text).font(SidraFont.ui(13.5)).foregroundStyle(SidraColor.text).multilineTextAlignment(.leading) }.buttonStyle(.plain)
                    HStack(spacing: 6) { ProjectIconView(x.project, size: 14); Text(x.project?.name ?? ""); Spacer(); Text(TFormat.ago(x.created_at)) }
                        .font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
                }
            }
        }
        TSection(title: "Summaries") {
            let w = p.worker
            Muted("\(w.written) written \(rangeWord). \(w.queued) waiting\(w.running > 0 ? ", \(w.running) running" : ""), \(w.failed) failed.\(w.median_delay_s.map { " Median delay \(TFormat.dur($0 * 1000))." } ?? "") They used \(TFormat.tok(w.tokens)) tokens, about \(TFormat.money(w.cost)).")
            if w.failed > 0 {
                Button("Retry \(w.failed) failed") {
                    Task {
                        if let r = await live.act("/api/jobs/retry-failed") { live.say(TFormat.plural(r["retried"] as? Int ?? 0, "summary", "summaries") + " back in the queue.") }
                    }
                }
                .buttonStyle(.sidraSecondary)
            }
        }
    }
}

struct PulseItemView: View {
    let item: Pulse.Item
    @Environment(\.theasaOpen) private var open
    var body: some View {
        let it = item
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProjectIconView(it.project, size: 24)
                Button { open(.project(it.project.id)) } label: { Text(it.project.name).font(SidraFont.ui(16, weight: .bold)).foregroundStyle(SidraColor.textBright) }.buttonStyle(.plain)
                VerdictLabel(verdict: it.health)
                Text("\(TFormat.plural(it.turns, "turn")) · \(it.agents.map(agentName).joined(separator: ", ")) · \(TFormat.ago(it.last_at))")
                    .font(SidraFont.ui(13)).foregroundStyle(SidraColor.dim).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 4) {
                if it.bullets.isEmpty {
                    Muted(it.pending > 0 ? "Writing the summaries." : "Imported without summaries.")
                }
                ForEach(it.bullets, id: \.turn_id) { b in
                    Button { open(.turn(b.turn_id)) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(SidraColor.dim)
                            Text(inlineMD(b.text)).multilineTextAlignment(.leading)
                        }
                        .font(SidraFont.ui(13.5)).foregroundStyle(Color(hex: 0xD4D4D8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 34)
            let foot = [it.decisions > 0 ? TFormat.plural(it.decisions, "decision") : "", it.watch > 0 ? TFormat.plural(it.watch, "watch item") : "",
                        it.files > 0 ? TFormat.plural(it.files, "file") + " changed" : "", it.pending > 0 ? TFormat.plural(it.pending, "summary", "summaries") + " waiting" : ""]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            if !foot.isEmpty { Text(foot).font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.dim).padding(.leading, 34) }
        }
    }
}

/// Tokens per day (or hour), Claude Code under Codex, stacked.
struct TokenBars: View {
    let bars: [Pulse.Bar]
    var body: some View {
        let mx = max(1, bars.map { $0.claude + $0.codex }.max() ?? 1)
        let every = bars.count > 12 ? (bars.count == 24 ? 6 : 5) : 1
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tokens per \(bars.count == 24 ? "hour" : "day")")
                Spacer()
                HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(TColor.claude).frame(width: 8, height: 8); AgentTag(agent: "claude", size: 12) }
                HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(TColor.codex).frame(width: 8, height: 8); AgentTag(agent: "codex", size: 12) }
            }
            .font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, b in
                    VStack(spacing: 1) {
                        Spacer(minLength: 0)
                        if b.codex > 0 { Rectangle().fill(TColor.codex).frame(height: CGFloat(b.codex) / CGFloat(mx) * 62) }
                        Rectangle().fill(TColor.claude).frame(height: CGFloat(b.claude) / CGFloat(mx) * 62)
                    }
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2))
                    .frame(maxWidth: .infinity)
                    .accessibilityElement().accessibilityLabel("\(b.label): \(TFormat.tok(b.claude + b.codex)) tokens")
                }
            }
            .frame(height: 64)
            HStack(spacing: 4) {
                ForEach(Array(bars.enumerated()), id: \.offset) { i, b in
                    Text(i % every == 0 ? b.label : "").font(SidraFont.ui(11)).foregroundStyle(SidraColor.dim).lineLimit(1).frame(maxWidth: .infinity)
                }
            }
        }
        .frame(minWidth: 220, maxWidth: .infinity)
    }
}
