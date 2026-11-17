import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import SidraDesign
import SidraWorkspace
import SidraSSH

/// One connection's pipelines (GitLab or GitHub): recent runs grouped by namespace on the left, the
/// picked run on the right (stages, then the job log with the failing section open at the error).
struct PipelinesPane: View {
    let pane: Pane
    let store: PipelinesStore
    @Environment(AppModel.self) private var app

    @State private var width: CGFloat = 1000
    @State private var showList = false
    private var selected: Int? { get { store.selected } nonmutating set { store.selected = newValue } }
    private var expanded: Set<String> { get { store.expanded } nonmutating set { store.expanded = newValue } }
    /// Below this the list and the run take turns: a split pane can be as narrow as 160 pt.
    private var narrow: Bool { width < 640 }

    var body: some View {
        Group {
            if !store.connected {
                VStack(spacing: 10) {
                    ProcessIcon(.pipelines, size: 34)
                    Text("\(store.connection.title) needs its token again").font(SidraFont.ui(15, weight: .bold)).foregroundStyle(SidraColor.text)
                    Text("Sidra reads your pipelines and job logs with a personal access token, kept in the Keychain.")
                        .font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted).multilineTextAlignment(.center).frame(maxWidth: 380)
                    Button("Connect…") { app.sheet = .pipelinesEdit(store.connection.id) }.buttonStyle(.sidraPrimary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    let run = store.pipelines.first(where: { $0.id == selected })
                    if !narrow || showList || run == nil {
                        list.frame(width: narrow ? nil : min(300, width * 0.4)).frame(maxWidth: narrow ? .infinity : nil)
                    }
                    if !narrow { Rectangle().fill(SidraColor.hairline).frame(width: 1) }
                    if let p = run, !(narrow && showList) {
                        VStack(spacing: 0) {
                            if narrow {
                                Button { showList = true } label: { Label("Pipelines", systemImage: "chevron.left").font(SidraFont.ui(12.5)) }
                                    .buttonStyle(.plain).foregroundStyle(SidraColor.muted)
                                    .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                            }
                            PipelineRun(pipeline: p, store: store).id(p.id)
                        }
                    } else if !narrow {
                        Text(store.loading && store.pipelines.isEmpty ? "Reading pipelines…" : "Pick a pipeline")
                            .font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .overlay(alignment: .top) { Rectangle().fill(SidraColor.hairline).frame(height: 1) }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background { keys }
        .onAppear { store.visiblePanes += 1; Task { await store.refresh() } }
        .onDisappear { store.visiblePanes -= 1 }
        .onChange(of: store.reveal, initial: true) { _, _ in takeReveal() }
        .onChange(of: store.pipelines.map(\.id), initial: true) { _, ids in
            // A pipeline asked for from the title bar wins once it has loaded; it stays pending until then.
            if takeReveal() { return }
            // Open the newest failure on first sight; keep the user's pick otherwise.
            if !ids.isEmpty, selected == nil || !ids.contains(selected!) { selected = store.latestPerProject.first { $0.status == "failed" }?.id ?? ids.first }
        }
    }

    // MARK: List

    private struct Bucket: Identifiable { let id: String; var pipelines: [GitLabPipeline] }
    /// Running pipelines sit on top, above a divider; the groups below hold the rest.
    private var running: [GitLabPipeline] { store.running }
    private var groups: [Bucket] {
        var by: [String: [GitLabPipeline]] = [:]
        for p in store.pipelines where !p.isActive { by[store.projects[p.project_id]?.group ?? "?", default: []].append(p) }
        return by.map { Bucket(id: $0.key, pipelines: $0.value) }.sorted { $0.pipelines[0].updated_at > $1.pipelines[0].updated_at }
    }
    private var flat: [GitLabPipeline] { running + groups.flatMap { g in expanded.contains(g.id) ? g.pipelines : Array(g.pipelines.prefix(5)) } }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let e = store.error { Text(e).font(SidraFont.ui(12)).foregroundStyle(SidraColor.yellow).padding(12) }
                    else if store.pipelines.isEmpty {
                        Text(store.loading || store.lastRefresh == nil ? "Reading pipelines…" : "No pipelines in your projects yet.")
                            .font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted).padding(14)
                    }
                    if !running.isEmpty {
                        HStack(spacing: 8) {
                            // Spins only while something runs; pending and queued alone show a clock.
                            if running.contains(where: { $0.status == "running" }) { GradientSpinner(size: 13) }
                            else { Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(SidraColor.dim) }
                            Text("ACTIVE").font(SidraFont.ui(11.5, weight: .bold)).foregroundStyle(SidraColor.muted).tracking(0.5)
                            Spacer()
                            Text("\(running.count)").font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.dim)
                        }
                        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
                        ForEach(running) { p in row(p).id(p.id) }
                        if !groups.isEmpty { Rectangle().fill(SidraColor.hairline2).frame(height: 1).padding(.horizontal, 14).padding(.vertical, 8) }
                    }
                    ForEach(groups) { g in
                        HStack(spacing: 8) {
                            PipelineAvatar(image: store.avatar(group: g.id), name: g.id, size: 16)
                            Text(g.id.uppercased()).font(SidraFont.ui(11.5, weight: .bold)).foregroundStyle(SidraColor.muted).tracking(0.5)
                            Spacer()
                            Text("\(g.pipelines.count)").font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.dim)
                        }
                        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
                        let shown = expanded.contains(g.id) ? g.pipelines : Array(g.pipelines.prefix(5))
                        ForEach(shown) { p in row(p).id(p.id) }
                        if g.pipelines.count > 5 {
                            Button(expanded.contains(g.id) ? "Fewer" : "\(g.pipelines.count - 5) more") {
                                if expanded.contains(g.id) { expanded.remove(g.id) } else { expanded.insert(g.id) }
                            }
                            .buttonStyle(.plain).font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.dim).padding(.leading, 44).padding(.vertical, 4)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: selected) { _, id in if let id { withAnimation { proxy.scrollTo(id) } } }
        }
        .background(SidraColor.ground2)
    }

    private func row(_ p: GitLabPipeline) -> some View {
        let on = p.id == selected
        let project = store.projects[p.project_id]
        return Button { selected = p.id; showList = false } label: {
            HStack(spacing: 9) {
                PipelineStatusIcon(status: p.status, size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        PipelineAvatar(image: store.avatar(project: p.project_id), name: project?.name ?? "?", size: 14)
                        Text(project?.name ?? "project \(p.project_id)").font(SidraFont.ui(13, weight: .bold)).foregroundStyle(SidraColor.text).lineLimit(1)
                    }
                    Text("\(p.ref)  \(p.shortSHA)").font(SidraFont.mono(11)).foregroundStyle(SidraColor.dim).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(Self.ago(p.updated_at)).font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.muted)
            }
            .padding(.horizontal, 14).frame(height: 46)
            .background(on ? SidraColor.tabActive : .clear)
            .overlay(alignment: .leading) {
                if on { UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3).fill(SidraGradient.horizontal).frame(width: 3).padding(.vertical, 6) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(project?.name ?? "") \(p.ref), \(p.status)")
        .accessibilityIdentifier("pipeline-\(p.id)")
    }

    /// ↑↓ move through the list, ⌘R refreshes, ⌘O opens the pipeline on the web; only while this pane has focus.
    @ViewBuilder private var keys: some View {
        if app.workspace.focusedPane?.id == pane.id, store.connected {
            Group {
                Button("") { step(-1) }.keyboardShortcut(.upArrow, modifiers: [])
                Button("") { step(1) }.keyboardShortcut(.downArrow, modifiers: [])
                Button("") { Task { await store.refresh() } }.keyboardShortcut("r", modifiers: .command)
                Button("") { if let p = store.pipelines.first(where: { $0.id == selected }), let u = URL(string: p.web_url) { Platform.open(u) } }
                    .keyboardShortcut("o", modifiers: .command)
            }
            .opacity(0).accessibilityHidden(true)
        }
    }

    @discardableResult private func takeReveal() -> Bool {
        guard let id = store.reveal, store.pipelines.contains(where: { $0.id == id }) else { return false }
        selected = id; showList = false; store.reveal = nil
        return true
    }

    private func step(_ d: Int) {
        let ids = flat.map(\.id)
        guard !ids.isEmpty else { return }
        let i = selected.flatMap { ids.firstIndex(of: $0) } ?? -d
        selected = ids[max(0, min(ids.count - 1, i + d))]
    }

    static func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "\(max(s, 0))s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
    static func duration(_ s: Double?) -> String {
        guard let s else { return "" }
        let i = Int(s)
        return i < 60 ? "\(i)s" : i < 3600 ? "\(i / 60)m \(i % 60)s" : "\(i / 3600)h \(i % 3600 / 60)m"
    }
}

// MARK: - Run

struct PipelineRun: View {
    let pipeline: GitLabPipeline
    let store: PipelinesStore
    @State private var jobs: [GitLabJob] = []
    @State private var loadingJobs = true
    private var job: Int? { get { store.selectedJob[pipeline.id] } nonmutating set { store.selectedJob[pipeline.id] = newValue } }
    @State private var log: JobLog?
    @State private var logError: String?
    @State private var open: Set<Int> = []
    @State private var showAll: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(SidraColor.hairline).frame(height: 1)
            stages
            Rectangle().fill(SidraColor.hairline).frame(height: 1)
            logView
        }
        .background(SidraColor.pane)
        .task(id: pipeline.updated_at) { await load() }
    }

    private var header: some View {
        let project = store.projects[pipeline.project_id]
        let name = HStack(spacing: 8) {
            PipelineAvatar(image: store.avatar(project: pipeline.project_id), name: project?.name ?? "?", size: 22)
            Text(project?.name ?? "").font(SidraFont.ui(15, weight: .bold)).foregroundStyle(SidraColor.text).lineLimit(1)
        }
        let open = Button { if let u = URL(string: pipeline.web_url) { Platform.open(u) } } label: {
            Label("Open in \(store.connection.provider.name)", systemImage: "arrow.up.forward.square").labelStyle(.titleAndIcon)
        }
        .buttonStyle(.sidraDark)
        // Wide: every chip on one row. Narrow: name and status, then the open button alone.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                name.fixedSize()
                PipelineStatusChip(status: pipeline.status)
                chip("#\(pipeline.id)", bold: true)
                chip(pipeline.ref)
                chip(pipeline.shortSHA)
                Spacer(minLength: 8)
                open.fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { name; PipelineStatusChip(status: pipeline.status).fixedSize() }
                HStack(spacing: 8) { chip("#\(pipeline.id)", bold: true).fixedSize(); chip(pipeline.ref) }
                open.labelStyle(.iconOnly)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func chip(_ s: String, bold: Bool = false) -> some View {
        Text(s).font(bold ? SidraFont.ui(12, weight: .bold) : SidraFont.mono(11.5)).foregroundStyle(bold ? SidraColor.text : SidraColor.muted).lineLimit(1)
            .padding(.horizontal, 8).frame(height: 24)
            .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(SidraColor.hairline))
    }

    private var stageNames: [String] {
        var seen = Set<String>()
        return jobs.map(\.stage).filter { seen.insert($0).inserted }
    }

    private var stages: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                if jobs.isEmpty { Text(loadingJobs ? "Reading jobs…" : "This pipeline has no jobs.").font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted) }
                ForEach(stageNames, id: \.self) { stage in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(stage.uppercased()).font(SidraFont.ui(11, weight: .bold)).foregroundStyle(SidraColor.muted).tracking(0.5)
                        ForEach(jobs.filter { $0.stage == stage }) { j in jobChip(j) }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func jobChip(_ j: GitLabJob) -> some View {
        let on = j.id == job
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button { job = j.id; Task { await loadLog() } } label: {
            HStack(spacing: 8) {
                PipelineStatusIcon(status: j.status, size: 15)
                Text(j.name).font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.text).lineLimit(1)
                Spacer(minLength: 8)
                Text(PipelinesPane.duration(j.duration)).font(SidraFont.mono(10.5)).foregroundStyle(SidraColor.dim)
            }
            .padding(.horizontal, 10).frame(minWidth: 150).frame(height: 30)
            .background(on ? SidraColor.tabActive : SidraColor.raised, in: shape)
            .overlay { if on { shape.strokeBorder(SidraGradient.horizontal, lineWidth: 1.2) } else { shape.strokeBorder(SidraColor.hairline) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(j.name), \(j.status)")
    }

    @ViewBuilder private var logView: some View {
        if let logError {
            Text(logError).font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.yellow).padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let log {
            ScrollViewReader { proxy in
                ScrollView([.vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(log.sections) { s in section(s) }
                    }
                    .padding(.vertical, 8)
                }
                .onAppear { scrollToError(proxy, log) }
                .onChange(of: job) { _, _ in }
            }
        } else if job != nil {
            HStack(spacing: 8) { GradientSpinner(size: 12); Text("Reading the log…").font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Spacer()
        }
    }

    @ViewBuilder private func section(_ s: JobLog.Section) -> some View {
        let isOpen = s.name.isEmpty || open.contains(s.id)
        if !s.name.isEmpty {
            Button { if open.contains(s.id) { open.remove(s.id) } else { open.insert(s.id) } } label: {
                HStack(spacing: 8) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                    Text(s.title).lineLimit(1)
                    Spacer()
                    if let d = s.duration { Text(PipelinesPane.duration(Double(d))) }
                }
                .font(SidraFont.mono(12.5)).foregroundStyle(s.hasErrors ? SidraColor.red : SidraColor.muted)
                .padding(.horizontal, 16).frame(height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        if isOpen {
            // A long section shows its last 60 lines (the end is where it failed) until asked for all.
            let hidden = showAll.contains(s.id) ? 0 : max(0, s.lines.count - 60)
            if hidden > 0 {
                Button("\(hidden) lines above") { showAll.insert(s.id) }
                    .buttonStyle(.plain).font(SidraFont.mono(12)).foregroundStyle(SidraColor.dim).padding(.leading, 64).frame(height: 20)
            }
            ForEach(s.lines.dropFirst(hidden)) { l in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(l.id)").frame(width: 40, alignment: .trailing).foregroundStyle(l.isError ? SidraColor.red : SidraColor.lineNumber)
                    Text(l.text).foregroundStyle(l.isError ? Color(hex: 0xffb0b0) : SidraColor.terminalText).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(SidraFont.mono(12.5))
                .padding(.horizontal, 16).padding(.vertical, 1)
                .background(l.isError ? Color(hex: 0x2a1719) : .clear)
                .id("line-\(l.id)")
            }
        }
    }

    private func scrollToError(_ proxy: ScrollViewProxy, _ log: JobLog) {
        guard let sid = log.failingSectionID, let s = log.sections.first(where: { $0.id == sid }),
              let first = s.lines.suffix(60).first(where: \.isError) ?? s.lines.last(where: \.isError) else { return }
        DispatchQueue.main.async { proxy.scrollTo("line-\(first.id)", anchor: .center) }
    }

    private func load() async {
        defer { loadingJobs = false }
        do {
            jobs = try await store.jobs(pipeline)
            if job == nil || !jobs.contains(where: { $0.id == job }) {
                job = (jobs.first { $0.status == "failed" } ?? jobs.last { $0.status == "running" } ?? jobs.last)?.id
            }
            await loadLog()
        } catch {
            logError = describeError(error)
        }
    }

    private func loadLog() async {
        guard let j = jobs.first(where: { $0.id == job }) else { return }
        log = nil; logError = nil
        do {
            let l = try await store.log(j, project: pipeline.project_id)
            guard j.id == job else { return }
            open = Set(l.failingSectionID.map { [$0] } ?? (l.sections.last.map { [$0.id] } ?? []))
            // The error scrolled to must be rendered: show the whole section when it sits above the last 60 lines.
            showAll = []
            if let sid = l.failingSectionID, let sec = l.sections.first(where: { $0.id == sid }),
               !sec.lines.suffix(60).contains(where: \.isError), sec.lines.contains(where: \.isError) { showAll.insert(sid) }
            log = l
        } catch {
            guard j.id == job else { return }   // a newer job was picked meanwhile; its own load reports
            logError = describeError(error)
        }
    }
}

// MARK: - Pieces

/// Success jade, failed red, running spins with the gradient, waiting a ring, skipped and canceled grey.
struct PipelineStatusIcon: View {
    let status: String
    var size: CGFloat = 14
    var body: some View {
        switch status {
        case "running", "preparing": GradientSpinner(size: size)
        case "success": glyph("checkmark", SidraColor.jade)
        case "failed": glyph("xmark", SidraColor.red)
        case "skipped", "canceled": glyph(status == "skipped" ? "chevron.forward.2" : "slash.circle", Color(hex: 0x3a414c))
        case "manual": glyph("play.fill", SidraColor.violet)
        default: Circle().strokeBorder(SidraColor.dim, lineWidth: 1.5).frame(width: size, height: size)
        }
    }
    private func glyph(_ name: String, _ c: Color) -> some View {
        Circle().fill(c).frame(width: size, height: size)
            .overlay { Image(systemName: name).font(.system(size: size * 0.5, weight: .heavy)).foregroundStyle(SidraColor.Process.glyph) }
            .accessibilityHidden(true)
    }
}

struct PipelineStatusChip: View {
    let status: String
    var body: some View {
        let c: Color = status == "failed" ? SidraColor.red : status == "success" ? SidraColor.jade : SidraColor.text
        HStack(spacing: 6) {
            PipelineStatusIcon(status: status, size: 13)
            Text(status.replacingOccurrences(of: "_", with: " ").capitalized).font(SidraFont.ui(12)).foregroundStyle(c)
        }
        .padding(.horizontal, 8).frame(height: 24)
        .background(status == "failed" ? Color(hex: 0x2a1719) : SidraColor.raised, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(status == "failed" ? SidraColor.red.opacity(0.3) : SidraColor.hairline))
    }
}

/// The service's own avatar for a project or group, or its first letter.
struct PipelineAvatar: View {
    let image: PlatformImage?
    let name: String
    var size: CGFloat = 18
    var body: some View { HerdrLogoView(name: name, image: image, size: size) }
}

struct PipelinesFooter: View {
    let store: PipelinesStore?
    var body: some View {
        if let store, store.connected {
            FooterChip([.init("\(store.running.count)", label: "running"), .init("\(store.failedCount)", label: "failed", color: store.failedCount > 0 ? SidraColor.red : SidraColor.text),
                        .init("\(store.projects.count)", label: "projects")])
            Spacer()
            FooterChip([.init("↑↓", label: "pipeline"), .init("⌘R", label: "refresh"), .init("⌘O", label: "open in \(store.connection.provider.name)")])
        } else {
            FooterItem("Not connected")
        }
    }
}

// MARK: - Connect

/// Pane header: the connection's name, opening its sheet (replace the token, disconnect).
struct PipelinesConnectionButton: View {
    let connection: PipelineConnection?
    @Environment(AppModel.self) private var app
    var body: some View {
        Button { app.sheet = connection.map { .pipelinesEdit($0.id) } ?? .pipelines } label: {
            Label(connection.map { PipelinesHub.shared.label(for: $0) } ?? "Connect", systemImage: "key").labelStyle(.titleAndIcon).font(SidraFont.ui(12))
        }
        .buttonStyle(.sidraSecondary)
        .accessibilityLabel("\(connection.map { PipelinesHub.shared.label(for: $0) } ?? "Pipelines") connection")
    }
}

/// New tab → Pipelines: the saved connections (open one) and a form for another. Editing a connection
/// (from its tab's header) shows only the form, filled in.
struct PipelinesConnectSheet: View {
    var editing: UUID?
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var provider: PipelineConnection.Provider = .gitlab
    @State private var selfHosted = false
    @State private var url = ""
    @State private var token = ""
    @State private var checking = false
    @State private var error: String?
    @State private var adding = false
    private var hub: PipelinesHub { .shared }
    private var existing: PipelineConnection? { editing.flatMap { id in hub.connections.first { $0.id == id } } }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProcessIcon(.pipelines, size: 30)
                Text(existing.map { "\($0.label) pipelines" } ?? "Pipelines").font(SidraFont.ui(19, weight: .bold)).foregroundStyle(SidraColor.text)
            }
            if existing == nil, !hub.connections.isEmpty, !adding {
                Text("Open a connection, or add another: GitLab and GitHub tabs sit side by side.")
                    .font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted)
                ForEach(hub.connections) { c in
                    Button { dismiss(); app.openPipelines(connection: c.id) } label: {
                        HStack(spacing: 12) {
                            ProviderMark(provider: c.provider)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.label).font(SidraFont.ui(14, weight: .bold)).foregroundStyle(SidraColor.text)
                                Text(c.url).font(SidraFont.ui(12)).foregroundStyle(SidraColor.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(SidraColor.dim)
                        }
                        .padding(12)
                        .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: SidraRadius.card, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pipelines-open-\(c.provider.rawValue)")
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(.sidraSecondary)
                    Button("Add connection") { adding = true }.buttonStyle(.sidraPrimary).accessibilityIdentifier("pipelines-add")
                }
            } else {
                form
            }
        }
        .padding(24)
        }
        .frame(maxWidth: 560)   // narrower on an iPhone
        .frame(maxHeight: 640)
        .background(SidraColor.popup)
        .onAppear {
            guard let c = existing else { return }
            provider = c.provider; selfHosted = !c.isHosted; url = c.isHosted ? "" : c.url
        }
    }

    @ViewBuilder private var form: some View {
        // Which service: a select, then hosted or self-hosted.
        field("Service") {
            SidraMenu([SidraMenuSection(nil, PipelineConnection.Provider.allCases.map { p in
                SidraMenuItem(p.name) { provider = p; error = nil }
            })]) {
                HStack(spacing: 8) {
                    ProviderMark(provider: provider, size: 18)
                    Text(provider.name).font(SidraFont.ui(14)).foregroundStyle(SidraColor.text)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(SidraColor.muted)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .disabled(existing != nil)   // a connection keeps its service; add another for the other one
            .accessibilityLabel("Service, \(provider.name)")
        }
        VStack(alignment: .leading, spacing: 8) {
            radio(provider == .gitlab ? "GitLab.com" : "GitHub.com", on: !selfHosted) { selfHosted = false }
            radio(provider == .gitlab ? "Self-hosted GitLab" : "GitHub Enterprise Server", on: selfHosted) { selfHosted = true }
        }
        if selfHosted {
            field("Server URL") {
                TextField(provider == .gitlab ? "https://gitlab.example.com" : "https://github.example.com", text: $url)
                    .urlKeyboard().plainTextEntry().autocorrectionDisabled().textFieldStyle(.plain)
            }
        }
        field("Token") {
            SecureField(existing != nil ? "Saved; type to replace it" : provider == .gitlab ? "glpat-…" : "github_pat_… or ghp_…", text: $token).textFieldStyle(.plain)
        }
        Text(provider == .gitlab
             ? "A personal access token with the read_api scope."
             : "A fine-grained token with read access to Actions and Metadata on the repositories, or a classic token with the repo scope.")
            .font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted)
        Text("Sidra keeps it in the Keychain and talks to \(provider.name) directly.").font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.dim)
        if let error { Text(error).font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.yellow) }
        HStack {
            if let c = existing { Button("Disconnect") { hub.remove(c.id); dismiss() }.buttonStyle(.sidraSecondary) }
            Spacer()
            Button("Cancel") { if adding { adding = false } else { dismiss() } }.buttonStyle(.sidraSecondary)
            Button(checking ? "Checking…" : "Connect") { Task { await connect() } }
                .buttonStyle(.sidraPrimary).disabled(checking || (selfHosted && url.isEmpty) || (token.isEmpty && existing == nil))
                .accessibilityIdentifier("pipelines-connect")
        }
    }

    private func radio(_ label: String, on: Bool, _ pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().strokeBorder(on ? SidraColor.jade : SidraColor.dim, lineWidth: 1.5).frame(width: 16, height: 16)
                    if on { Circle().fill(SidraColor.jade).frame(width: 8, height: 8) }
                }
                Text(label).font(SidraFont.ui(13.5)).foregroundStyle(SidraColor.text)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func field(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(SidraFont.ui(12, weight: .bold)).foregroundStyle(SidraColor.muted)
            content().font(SidraFont.ui(14)).foregroundStyle(SidraColor.text)
                .padding(.horizontal, 10).frame(height: 36)
                .background(SidraColor.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SidraColor.hairline2))
        }
    }

    private func connect() async {
        checking = true; error = nil
        defer { checking = false }
        do {
            let t = token.isEmpty ? (existing.flatMap { KeychainStore.string(for: $0.tokenKey) } ?? "") : token
            let c = try await hub.save(id: existing?.id, provider: provider, url: selfHosted ? url : provider.hostedURL, token: t)
            dismiss()
            app.openPipelines(connection: c.id)   // show its pipelines right away
        } catch {
            self.error = describeError(error)
        }
    }
}

/// GitLab's or GitHub's own logo, from the asset catalog.
struct ProviderMark: View {
    let provider: PipelineConnection.Provider
    var size: CGFloat = 24
    var body: some View {
        Image(provider == .gitlab ? "brand-gitlab" : "brand-github").resizable().scaledToFit().frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension AppModel {
    /// A Pipelines tab for `connection` (nil: the first): brings an open one to the front, else opens it.
    /// `reveal` picks a pipeline once it has loaded. With no connection at all, the connect sheet.
    func openPipelines(connection id: UUID? = nil, reveal pipeline: Int? = nil) {
        let hub = PipelinesHub.shared
        guard let c = hub.connection(id) else { sheet = .pipelines; return }
        if let pipeline { hub.store(c.id)?.reveal = pipeline }
        let first = hub.connections.first?.id
        for store in allWorkspaces {
            for tab in store.tabs {
                if let p = tab.panes.first(where: { if case .pipelines(let cid) = $0.kind { (cid ?? first) == c.id } else { false } }) {
                    open(.pane(p.id)); return
                }
            }
        }
        openTab(kind: .pipelines(connection: c.id))
    }
}

/// A Pipelines tab whose connection was removed: one button to set one up.
struct PipelinesNoConnection: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        VStack(spacing: 10) {
            ProcessIcon(.pipelines, size: 34)
            Text("No pipelines connection").font(SidraFont.ui(15, weight: .bold)).foregroundStyle(SidraColor.text)
            Button("Connect GitLab or GitHub…") { app.sheet = .pipelines }.buttonStyle(.sidraPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
