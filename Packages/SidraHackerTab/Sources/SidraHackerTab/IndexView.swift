import SwiftUI
import SidraDesign

/// Favicons come straight from each site (no third-party service). A miss shows a letter tile.
/// ponytail: only /favicon.ico is tried. Read <link rel="icon"> from the page if too many sites miss.
actor Favicons {
    static let shared = Favicons()
    private var cache: [String: UIImage?] = [:]
    private var tasks: [String: Task<UIImage?, Never>] = [:]

    func image(_ host: String) async -> UIImage? {
        if let hit = cache[host] { return hit }
        if let t = tasks[host] { return await t.value }
        let t = Task<UIImage?, Never> {
            guard let url = URL(string: "https://\(host)/favicon.ico"),
                  let (data, resp) = try? await URLSession.shared.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return UIImage(data: data)
        }
        tasks[host] = t
        let img = await t.value
        cache[host] = .some(img)
        tasks[host] = nil
        return img
    }
}

struct Favicon: View {
    let host: String?
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().interpolation(.high)
            } else {
                (host == nil ? T.accent : T.tiles[(host ?? "").unicodeScalars.reduce(0) { $0 + Int($1.value) } % T.tiles.count])
                Text(host?.first.map { String($0).uppercased() } ?? "Y").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(T.bg)
            }
        }
        .frame(width: 16, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: host) {
            image = nil
            if let host { image = await Favicons.shared.image(host) }
        }
        .accessibilityHidden(true)
    }
}

struct FeedTabs: View {
    @Environment(AppModel.self) private var model
    var feeds = Feed.remote
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(feeds) { f in MonoButton(label: f.rawValue, on: model.feed == f) { model.show(f) } }
            }
        }
    }
}

struct NewspaperButton: View {
    @AppStorage("hackertab.newspaper") private var newspaper = false
    var body: some View {
        Button { newspaper.toggle() } label: {
            Image(systemName: "newspaper").font(.system(size: 16)).foregroundStyle(T.dim).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(newspaper ? "List view" : "Newspaper view")
    }
}

struct IndexView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool
    var phone = false
    var onArticle: (Story) -> Void
    var onDiscussion: (Story) -> Void

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                FeedTabs(feeds: phone ? Feed.remote : Feed.allCases)
                NewspaperButton()
            }
            .padding(.leading, 14).padding(.trailing, 2)
            Rule()
            if model.feed == .search {
                TextField("search stories", text: $model.query)
                    .font(T.mono(13)).foregroundStyle(T.text).tint(T.accent)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    .onSubmit { Task { await model.loadFeed() } }
                    .focused($searchFocused).onAppear { searchFocused = model.stories.isEmpty }
                    .onChange(of: searchFocused) { model.typing = searchFocused }
                    .onKeyPress(.escape) { searchFocused = false; return .handled }
                    .onDisappear { model.typing = false }
                    .padding(.horizontal, 14).frame(height: 44).background(T.panel)
                Rule()
            }
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.stories.enumerated()), id: \.element.id) { i, s in
                        row(i, s)
                            .contextMenu {
                                Button(model.isSaved(s) ? "Remove from saved" : "Save", systemImage: model.isSaved(s) ? "bookmark.slash" : "bookmark") { model.toggleSaved(s) }
                                ShareLink(item: s.url ?? s.hnURL)
                                Link(destination: s.hnURL) { Label("Open on Hacker News", systemImage: "safari") }
                            }
                            .onAppear { if i == model.stories.count - 1 { Task { await model.loadMore() } } }
                        Rule(color: T.hair)
                    }
                    Text(status).font(T.mono(11.5)).foregroundStyle(T.dim).frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .refreshable { await model.loadFeed() }
            .onChange(of: model.selected?.id) { if let id = model.selected?.id { withAnimation { proxy.scrollTo(id) } } }
            }
        }
        .background(T.bg)
    }

    private var status: String {
        if let e = model.feedError { return e }
        if model.loadingFeed { return "loading…" }
        if model.stories.isEmpty {
            switch model.feed {
            case .saved: return "nothing saved · hold a story to save it"
            case .search: return model.query.isEmpty ? "type a query, then press return" : "no results"
            default: return "no stories"
            }
        }
        return Feed.remote.contains(model.feed) ? "…" : ""
    }

    private func meta(_ s: Story) -> some View {
        HStack(spacing: 10) {
            if phone { Favicon(host: s.host) } else { Text(verbatim: "\(s.descendants)c").foregroundStyle(T.accent) }
            if phone { Text(s.host ?? "hn").lineLimit(1).truncationMode(.middle) }
            Text(verbatim: "\(s.score)p")
            Text(s.age)
            if !phone, let h = s.host { Text(h).lineLimit(1).truncationMode(.middle) }
        }
        .font(T.mono(phone ? 11.5 : 11)).foregroundStyle(T.dim)
    }

    @ViewBuilder private func row(_ i: Int, _ s: Story) -> some View {
        let title = Text(s.title).font(T.sans(phone ? 15.5 : 13.5, .medium))
            .foregroundStyle(model.read.contains(s.id) ? T.read : T.text)
        if phone {
            // Two targets: the count opens the discussion, the title opens the article.
            HStack(alignment: .top, spacing: 12) {
                Button { onDiscussion(s) } label: {
                    Text(verbatim: "\(s.descendants)").font(T.mono(15, bold: true)).foregroundStyle(T.accent)
                        .frame(width: 44, alignment: .trailing).frame(minHeight: 44, alignment: .top).padding(.top, 10).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("\(s.descendants) comments, open discussion")
                Button { onArticle(s) } label: {
                    VStack(alignment: .leading, spacing: 4) { title; meta(s) }
                        .padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 6).padding(.trailing, 14)
        } else {
            let on = model.selected?.id == s.id
            Button { onArticle(s) } label: {
                HStack(alignment: .top, spacing: 9) {
                    // Selected: the number turns into a block in Sidra's selection gradient, like a terminal highlight.
                    Text(String(format: "%02d", i + 1)).font(T.mono(11, bold: on)).foregroundStyle(on ? T.bg : T.faint)
                        .padding(.horizontal, 3).background(on ? AnyShapeStyle(SidraGradient.horizontal) : AnyShapeStyle(.clear)).padding(.leading, -3)
                        .frame(width: 20, alignment: .leading)
                    Favicon(host: s.host).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) { on ? AnyView(BlinkTitle(title: title)) : AnyView(title); meta(s) }
                    Spacer(minLength: 0)
                }
                .padding(.init(top: 7, leading: 10, bottom: 8, trailing: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }
}

/// The newspaper view of direction C: "the wire".
struct WireView: View {
    @Environment(AppModel.self) private var model
    var onOpen: (Story) -> Void
    @AppStorage("hackertab.newspaper") private var newspaper = true
    @State private var extra: [Feed: [Story]] = [:]
    @State private var leadThread: [Comment] = []

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 700
            VStack(spacing: 0) {
                HStack(spacing: 18) {
                    Text("the wire").font(T.mono(14, bold: true)).foregroundStyle(T.text)
                    Text(Date().formatted(.iso8601.year().month().day())).font(T.mono(12)).foregroundStyle(T.dim)
                    Spacer(minLength: 0)
                    if wide { FeedTabs().fixedSize() }
                    MonoButton(label: "list view") { newspaper = false }
                }
                Rule()
                if !wide { FeedTabs(); Rule() }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let lead = model.stories.first {
                            let l = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 32)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                            l {
                                leadBlock(lead, wide).frame(maxWidth: .infinity, alignment: .leading)
                                activity(lead).frame(maxWidth: wide ? 340 : .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 22)
                            Rule()
                            let c = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 32)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                            c { ForEach(columns, id: \.name) { column($0).frame(maxWidth: .infinity, alignment: .top) } }
                                .padding(.top, 14).padding(.bottom, 30)
                        } else {
                            Text(model.feedError ?? "loading…").font(T.mono(11.5)).foregroundStyle(T.dim).frame(maxWidth: .infinity, minHeight: 120)
                        }
                    }
                }
                .refreshable { await model.loadFeed() }
            }
            .padding(.horizontal, wide ? 28 : 14)
        }
        .background(T.bg)
        .task {
            for f in [Feed.top, .ask, .show] {
                if let ids = try? await HN.ids(f) { extra[f] = await HN.stories(Array(ids.prefix(6))) }
            }
        }
        .task(id: model.stories.first?.id) {
            leadThread = []
            if let id = model.stories.first?.id { leadThread = (try? await HN.thread(id)) ?? [] }
        }
    }

    private func leadBlock(_ s: Story, _ wide: Bool) -> some View {
        Button { onOpen(s) } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: "01 · \(s.host ?? "hn") · \(s.score)p · \(s.age)").font(T.mono(11.5)).foregroundStyle(T.accent)
                Text(s.title).font(T.sans(wide ? 44 : 28, .bold)).tracking(wide ? -1 : -0.5).foregroundStyle(T.text).multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(.plain)
    }

    /// Comments per hour over the last seven hours, and the opening of the top thread.
    private func activity(_ s: Story) -> some View {
        let now = Int(Date().timeIntervalSince1970)
        let heat = (0..<7).map { h in leadThread.filter { (now - $0.time) / 3600 == 6 - h }.count }
        let peak = max(heat.max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: "\(s.descendants) comments").font(T.mono(11.5, bold: true)).foregroundStyle(T.text)
                Spacer()
                Text("comments per hour, last 7h").font(T.mono(11.5)).foregroundStyle(T.dim)
            }
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(0..<7, id: \.self) { h in
                    UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                        .fill(heat[h] == peak && heat[h] > 0 ? T.accent : T.warm)
                        .frame(height: max(2, 60 * CGFloat(heat[h]) / CGFloat(peak)))
                }
            }
            .frame(height: 64, alignment: .bottom)
            .accessibilityElement().accessibilityLabel("Comments per hour over the last seven hours: " + heat.map(String.init).joined(separator: ", "))
            Rule()
            if let top = leadThread.first {
                Text(top.plain).font(T.sans(14.5)).foregroundStyle(T.body).lineLimit(3).padding(.top, 6)
                (Text(top.author).foregroundStyle(T.text) + Text(" · top thread")).font(T.mono(11)).foregroundStyle(T.dim)
            }
        }
    }

    private var columns: [(name: String, note: String, items: [Story])] {
        let notes: [Feed: String] = [.top: "ranked by HN", .ask: "open questions", .show: "made by readers"]
        var out = [(model.feed.rawValue, notes[model.feed] ?? "ranked by HN", Array(model.stories.dropFirst().prefix(5)))]
        for f in [Feed.top, .ask, .show] where f != model.feed && out.count < 3 {
            out.append((f.rawValue, notes[f] ?? "", Array((extra[f] ?? []).filter { $0.id != model.stories.first?.id }.prefix(5))))
        }
        return out.map { (name: $0.0, note: $0.1, items: $0.2) }
    }

    private func column(_ g: (name: String, note: String, items: [Story])) -> some View {
        let peak = max(columns.flatMap(\.items).map(\.descendants).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(g.name).font(T.mono(11.5, bold: true)).foregroundStyle(T.text)
                Spacer()
                Text(g.note).font(T.mono(11.5)).foregroundStyle(T.dim)
            }
            .padding(.bottom, 6)
            ForEach(g.items) { s in
                Rule(color: T.hair)
                Button { onOpen(s) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.title.replacing(#/^(Ask|Show) HN: /#, with: "")).font(T.sans(15, .semibold))
                            .foregroundStyle(model.read.contains(s.id) ? T.read : T.text)
                        HStack(spacing: 10) {
                            Text(verbatim: "\(s.descendants)c").font(T.mono(11, bold: true)).foregroundStyle(T.accent).frame(width: 44, alignment: .leading)
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(T.hair)
                                    Capsule().fill(T.warm).frame(width: g.size.width * CGFloat(s.descendants) / CGFloat(peak))
                                }
                            }
                            .frame(height: 4)
                            Text(verbatim: "\(s.score)p \(s.age)").font(T.mono(11)).foregroundStyle(T.dim)
                        }
                    }
                    .padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The selected story's title, with a blinking block cursor after its last word. Steady with Reduce Motion.
struct BlinkTitle: View {
    let title: Text
    @Environment(\.accessibilityReduceMotion) private var still
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.53)) { t in
            let lit = still || Int(t.date.timeIntervalSinceReferenceDate / 0.53) % 2 == 0
            title + Text(verbatim: " ▌").foregroundStyle(lit ? T.accent : .clear)
        }
        .accessibilityLabel(title)
    }
}
