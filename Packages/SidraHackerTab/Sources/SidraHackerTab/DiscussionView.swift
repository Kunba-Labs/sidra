import SwiftUI

struct DiscussionView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var findFocused: Bool
    var phone = false
    var showMap = false
    var footer = true
    var onExpand: (() -> Void)?

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if !phone {
                HStack(spacing: 12) {
                    Text(verbatim: "\(model.selected?.descendants ?? 0) comments").font(T.mono(12, bold: true)).foregroundStyle(T.text)
                    if model.newCount > 0 {
                        MonoButton(label: "+\(model.newCount) new", on: true) {
                            if let c = model.comments.first(where: model.isNew) { model.jump(to: c.id) }
                        }
                    }
                    Spacer(minLength: 0)
                    MonoButton(label: "find", on: model.finding) { model.finding.toggle() }
                    if let onExpand {
                        Button(action: onExpand) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 13)).foregroundStyle(T.dim).frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel("Expand discussion")
                    }
                }
                .frame(height: 44).padding(.leading, 14).padding(.trailing, 4)
                Rule()
            }
            if model.finding {
                HStack {
                    TextField("find in thread", text: $model.find)
                        .font(T.mono(13)).foregroundStyle(T.text).tint(T.accent).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($findFocused).onAppear { findFocused = true }
                        .onChange(of: findFocused) { model.typing = findFocused }
                        .onDisappear { model.typing = false }
                        // The field takes Esc before any key command does.
                        .onKeyPress(.escape) { model.escape(); return .handled }
                    if !model.find.isEmpty { Text(verbatim: "\(model.rows.count) found").font(T.mono(11.5)).foregroundStyle(T.dim) }
                    MonoButton(label: "done") { model.finding = false }
                }
                .padding(.horizontal, 14).frame(height: 44).background(T.panel)
                Rule()
            }
            if !model.comments.isEmpty { Crumbs(); Rule() }
            HStack(spacing: 0) {
                CommentList(phone: phone)
                if showMap && !model.roots.isEmpty { VRule(color: T.hair); Minimap() }
            }
            if footer && !model.comments.isEmpty {
                Rule()
                HStack(spacing: 0) {
                    if model.focus != nil { MonoButton(label: "‹ exit focus") { model.focus = nil }.frame(maxWidth: .infinity) }
                    MonoButton(label: "parent") { model.toParent() }.frame(maxWidth: .infinity)
                    MonoButton(label: "collapse") { model.toggleCurrent() }.frame(maxWidth: .infinity)
                    MonoButton(label: "prev") { model.stepThread(-1) }.frame(maxWidth: .infinity)
                    Button { model.stepThread(1) } label: {
                        Text("next thread").font(T.mono(12, bold: true)).foregroundStyle(T.text).frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8).background(T.deep)
            }
        }
        .background(T.bg)
        .task(id: model.comments.count) { model.markSeen() }
    }
}

/// Where the reader is: the ancestors of the comment at the top of the screen, and the thread number.
private struct Crumbs: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 7) {
            if let c = model.current {
                let all = model.ancestors(of: c)
                if model.focus != nil { MonoButton(label: "all threads") { model.focus = nil }; Text("›") }
                if all.count > 3 { Text("… ›") }
                ForEach(all.suffix(3)) { a in
                    Button { model.jump(to: a.id) } label: { Text(a.author).foregroundStyle(T.rails[a.depth % 4]).frame(minHeight: 40).contentShape(Rectangle()) }.buttonStyle(.plain)
                    Text("›")
                }
                Text(c.author).bold().foregroundStyle(T.text)
                Spacer(minLength: 8)
                Text(verbatim: "\(c.root + 1)/\(model.roots.count)").accessibilityLabel("Thread \(c.root + 1) of \(model.roots.count)")
            }
        }
        .lineLimit(1).font(T.mono(11.5)).foregroundStyle(T.dim)
        .frame(height: 40).padding(.horizontal, 14).background(T.panel)
    }
}

private struct CommentList: View {
    @Environment(AppModel.self) private var model
    let phone: Bool

    var body: some View {
        @Bindable var model = model
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.threadLoading {
                    Skeleton()
                } else if let e = model.threadError {
                    MonoButton(label: e + " · tap to retry") { model.reloadThread() }.frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    if model.focus == nil && !model.finding { SummaryBlock() }
                    if let f = model.comment(model.focus) { context(f) }
                    if model.comments.isEmpty { Text("no comments yet").font(T.mono(11.5)).foregroundStyle(T.dim).frame(maxWidth: .infinity, minHeight: 120) }
                    ForEach(model.rows) { c in
                        CommentRow(c: c, size: phone ? 15 : (model.focus == nil ? 13.5 : 15))
                    }
                }
            }
            .scrollTargetLayout()
            .frame(maxWidth: 700).frame(maxWidth: .infinity)
        }
        .scrollPosition(id: $model.cursor, anchor: .top)
        .refreshable { model.reloadThread() }
    }

    /// In focus, the comments above the focused one are shown short, so the subthread keeps its context.
    private func context(_ f: Comment) -> some View {
        let all = model.ancestors(of: f)
        return VStack(alignment: .leading, spacing: 6) {
            Text(all.isEmpty ? "focused on one thread · \(f.subtree + 1) comments" : "context · \(all.count) above").font(T.mono(11)).foregroundStyle(T.dim)
            ForEach(all) { a in
                Button { model.focus = a.id } label: {
                    (Text(a.author + "  ").font(T.mono(11.5, bold: true)).foregroundStyle(T.rails[a.depth % 4]) + Text(a.plain).font(T.sans(14)).foregroundStyle(T.body))
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(T.panel).overlay(RoundedRectangle(cornerRadius: 6).stroke(T.rule)).clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(10)
    }
}

private struct CommentRow: View {
    @Environment(AppModel.self) private var model
    let c: Comment
    let size: CGFloat

    var body: some View {
        let folded = model.collapsed.contains(c.id)
        // Indent stops at four levels. A deeper comment names its parent instead.
        let shown = model.focus.flatMap { model.comment($0)?.depth }.map { c.depth - $0 } ?? c.depth
        let rails = min(shown, 4)
        VStack(alignment: .leading, spacing: 2) {
            Button { model.toggle(c.id) } label: {
                HStack(spacing: 10) {
                    let op = c.author == model.selected?.by
                    Text(op ? c.author + " [op]" : c.author).font(T.mono(11.5, bold: true)).foregroundStyle(op ? T.accent : T.text)
                    Text(HN.age(c.time))
                    if shown > 4, let p = c.parent, model.comments.indices.contains(p) { Text("› " + model.comments[p].author) }
                    if model.isNew(c) {
                        Text("new").font(T.mono(10, bold: true)).foregroundStyle(T.bg).padding(.horizontal, 4).background(T.accent, in: RoundedRectangle(cornerRadius: 3))
                    }
                    Spacer(minLength: 0)
                    Text(folded ? "[+\(c.subtree + 1)]" : "[–]")
                }
                .lineLimit(1).font(T.mono(11.5)).foregroundStyle(T.dim).frame(minHeight: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(c.author), \(HN.age(c.time)) ago, \(folded ? "collapsed, \(c.subtree) replies" : "expanded")")
            .accessibilityAddTraits(model.keyed && model.cursor == c.id ? .isSelected : [])
            if !folded {
                Text(c.text).font(T.sans(size)).foregroundStyle(T.body).lineSpacing(size * 0.3).tint(T.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, shown == 0 ? 7 : 2).padding(.bottom, shown == 0 ? 8 : 6)
        .padding(.leading, CGFloat(rails) * 15 + 8)
        .background(alignment: .leading) {
            HStack(spacing: 13) { ForEach(0..<rails, id: \.self) { T.rails[$0].frame(width: 2) } }.padding(.leading, 6)
        }
        .padding(.leading, 6).padding(.trailing, 12)
        .overlay(alignment: .top) { if shown == 0 { Rule() } }
        .overlay(alignment: .leading) { if model.keyed && model.cursor == c.id { T.accent.frame(width: 3) } }
        .contextMenu {
            if c.subtree > 0 { Button("Focus on this thread", systemImage: "scope") { model.focus = c.id; model.cursor = c.id } }
            Button("Copy text", systemImage: "doc.on.doc") { UIPasteboard.general.string = c.plain }
            ShareLink(item: URL(string: "https://news.ycombinator.com/item?id=\(c.id)")!)
        }
    }
}

/// Shown while the thread loads. The thread appears once, in HN's order, and does not reorder.
private struct Skeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<9, id: \.self) { i in
                let depth = [0, 1, 2, 1, 0, 1, 0, 0, 1][i]
                VStack(alignment: .leading, spacing: 7) {
                    RoundedRectangle(cornerRadius: 2).fill(T.rule).frame(width: 110, height: 9)
                    ForEach(0..<[3, 2, 1, 2, 3, 1, 2, 1, 2][i], id: \.self) { _ in RoundedRectangle(cornerRadius: 2).fill(T.hair).frame(height: 10) }
                    RoundedRectangle(cornerRadius: 2).fill(T.hair).frame(width: 160, height: 10)
                }
                .padding(.vertical, 10).padding(.leading, CGFloat(depth) * 15 + 14).padding(.trailing, 12)
                .overlay(alignment: .top) { if depth == 0 { Rule() } }
            }
        }
        .accessibilityElement().accessibilityLabel("Loading the discussion")
    }
}

/// The on-device summary: its state in one line, and the text behind a fold.
struct SummaryBlock: View {
    @Environment(AppModel.self) private var model
    @AppStorage("hackertab.summaryOpen") private var open = true

    var body: some View {
        let s = model.summary
        if s.phase != .idle || s.result != nil {
            VStack(alignment: .leading, spacing: 0) {
                Button { open.toggle() } label: {
                    HStack(spacing: 8) {
                        Circle().fill(dot).frame(width: 7, height: 7)
                        Text(title).font(T.mono(11.5, bold: true)).foregroundStyle(T.text)
                        Text(detail).lineLimit(1)
                        Spacer(minLength: 0)
                        if s.result != nil { Text(open ? "[–]" : "[+]") }
                    }
                    .font(T.mono(11.5)).foregroundStyle(T.dim).frame(minHeight: 44).padding(.horizontal, 12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if case .running(let done, let total) = s.phase {
                    ProgressView(value: Double(done), total: Double(max(total, 1))).tint(T.accent).padding(.horizontal, 12).padding(.bottom, 10)
                        .accessibilityLabel("Summary progress")
                } else if s.phase == .waiting {
                    // No percentage to show: the system does not report the model download's progress.
                    ProgressView().progressViewStyle(.linear).tint(T.accent).padding(.horizontal, 12).padding(.bottom, 10)
                        .accessibilityLabel("Waiting for the on-device model to download")
                }
                if open, let r = s.result {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(r.overview).font(T.sans(13.5)).foregroundStyle(T.body).lineSpacing(3).padding(.bottom, 8)
                        ForEach(Array(r.points.enumerated()), id: \.offset) { i, p in
                            Rule()
                            Button { model.jump(to: p.comment) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(String(format: "%02d", i + 1)).font(T.mono(11, bold: true)).foregroundStyle(T.accent)
                                    Text(p.text).font(T.sans(13)).foregroundStyle(T.body).multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 10).frame(minHeight: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).accessibilityHint("Goes to the thread")
                        }
                        Rule()
                        Text(verbatim: "generated on this \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone") · may be wrong · nothing left the device")
                            .font(T.mono(10.5)).foregroundStyle(T.dim).padding(.top, 8)
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
            }
            .background(T.panel).overlay(RoundedRectangle(cornerRadius: 6).stroke(T.rule)).clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 10).padding(.vertical, 10)
        }
    }

    private var dot: Color {
        switch model.summary.phase {
        case .ready: T.ok
        case .running, .waiting: T.accent
        default: T.idle
        }
    }
    private var title: String {
        switch model.summary.phase {
        case .running: "summarizing"
        case .waiting: "summary soon"
        case .unavailable: "summary off"
        case .failed: "summary failed"
        default: "summary"
        }
    }
    private var detail: String {
        switch model.summary.phase {
        case .running(let done, let total): "on device · thread \(done)/\(total)"
        case .waiting: "the on-device model is downloading; it starts when the model is in"
        case .unavailable(let why), .failed(let why): why
        default: model.summary.result.map { "on device · \($0.comments) comments · \($0.seconds)s" } ?? ""
        }
    }
}

/// One bar for each top-level thread, as tall as the thread is long. Tap a bar to go there.
private struct Minimap: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        GeometryReader { geo in
            let roots = model.roots
            let gap: CGFloat = roots.count > 60 ? 1 : 3
            let weights = roots.map { CGFloat(model.comments[$0].subtree + 1).squareRoot() }
            let unit = max(0, geo.size.height - 16 - gap * CGFloat(roots.count)) / max(weights.reduce(0, +), 1)
            let here = model.current?.root
            VStack(spacing: gap) {
                // Keyed by comment id, not position, so a replaced thread cannot be read with old positions.
                ForEach(Array(roots.enumerated()), id: \.element) { n, r in
                    let c = model.comments[r]
                    let fresh = model.baseline != nil && model.comments[r...(r + c.subtree)].contains(where: model.isNew)
                    RoundedRectangle(cornerRadius: 2).fill(n == here ? T.accent : fresh ? T.warm : T.idle)
                        .frame(height: max(2, min(60, unit * weights[n])))
                        .contentShape(Rectangle().inset(by: -4))
                        .onTapGesture { model.jump(to: c.id) }
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 6)
        }
        .frame(width: 22)
        .accessibilityElement().accessibilityLabel("Thread map, \(model.roots.count) threads")
    }
}
