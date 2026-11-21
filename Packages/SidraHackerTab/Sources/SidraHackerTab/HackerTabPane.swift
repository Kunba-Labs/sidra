import SwiftUI

/// HackerTab: a comments-first Hacker News reader as a Sidra pane. The index, the article
/// (reader or web) and the discussion, side by side when the pane is wide enough.
///
/// Keys work while this pane has the keyboard focus, and never while a text field has it,
/// so they do not take letters from Sidra's terminals and editors:
/// ↑↓ story · j/k comment · n/p thread · u parent · space collapse · f focus · a/d article or discussion · / find · esc back out.
public struct HackerTabPane: View {
    /// One model for the app's life: HackerTab is a single tab, and coming back to it shows the same
    /// feed, story, scroll and article instead of loading them again.
    @State private var model = AppModel.kept
    @FocusState private var keys: Bool
    public init() {}

    public var body: some View {
        PadRoot()
            .environment(model)
            .background(T.bg)
            .focusable()
            .focused($keys)
            .focusEffectDisabled()
            .onAppear { keys = true }
            .simultaneousGesture(TapGesture().onEnded { if !model.typing { keys = true } })
            .onKeyPress(phases: .down) { press in handle(press) ? .handled : .ignored }
            .task {
                if model.stories.isEmpty { await model.loadFeed() }
                #if DEBUG
                // For UI tests: `-hackertab.demo article|discussion` opens the busiest of the top ten stories.
                if let d = UserDefaults.standard.string(forKey: "hackertab.demo"), let s = model.stories.prefix(10).max(by: { $0.descendants < $1.descendants }) {
                    model.open(s)
                    if d == "article" { model.setPane(.article); model.right = .article }
                }
                #endif
            }
    }

    private func handle(_ press: KeyPress) -> Bool {
        guard !model.typing, press.modifiers.subtracting(.shift).isEmpty else { return false }
        let has = !model.comments.isEmpty
        switch press.key {
        case .downArrow: model.stepStory(1)
        case .upArrow: model.stepStory(-1)
        case .escape: model.escape()
        case .space where has: model.toggleCurrent()
        default:
            switch press.characters {
            case "j" where has: model.step(1)
            case "k" where has: model.step(-1)
            case "n" where has: model.stepThread(1)
            case "p" where has: model.stepThread(-1)
            case "u" where has: model.toParent()
            case "f" where has: model.toggleFocus()
            case "a": model.right = .article; if model.pane == .discussion { model.pane = .three }
            case "d": model.right = .discussion; if model.pane == .article { model.pane = .three }
            case "/": model.right = .discussion; model.finding = true
            default: return false
            }
        }
        return true
    }
}

/// Watches the top stories for the tab's blue dot: `fresh` turns on when a story reaches the
/// top 30 that was not there when HackerTab was last looked at.
@MainActor @Observable public final class HackerNews {
    public static let shared = HackerNews()
    public private(set) var fresh = false
    // Numbers or, from a launch argument such as `-hackertab.seenTop (1)`, strings.
    private var seen: Set<Int> = Set((UserDefaults.standard.array(forKey: "hackertab.seenTop") ?? []).compactMap { ($0 as? Int) ?? Int("\($0)") })
    private var latest: [Int] = []
    private var timer: Task<Void, Never>?

    /// Checks every five minutes while Sidra runs.
    /// ponytail: polling in the foreground only; a background refresh task if the dot should be right on launch.
    public func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                if let ids = try? await HN.ids(.top) { self?.update(Array(ids.prefix(30))) }
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    /// HackerTab is in front: what is in the top 30 now counts as seen.
    public func markSeen() { saw(latest) }

    func saw(_ ids: [Int]) {
        guard !ids.isEmpty else { return }
        seen = Set(ids)
        UserDefaults.standard.set(ids, forKey: "hackertab.seenTop")
        fresh = false
    }

    func update(_ ids: [Int]) {
        latest = ids
        if seen.isEmpty { saw(ids) } else { fresh = HackerNews.isFresh(ids, seen: seen) }
    }

    nonisolated static func isFresh(_ ids: [Int], seen: Set<Int>) -> Bool { !Set(ids).isSubset(of: seen) }
}

// MARK: iPad: the workspace

struct PadRoot: View {
    @Environment(AppModel.self) private var model
    @AppStorage("hackertab.newspaper") private var newspaper = false
    private var pane: AppModel.Pane { model.pane }
    private var right: Route { model.right }
    private var showIndex: Bool { model.showIndex }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width >= 1100   // a 13-inch iPad in portrait is 1032 wide: too narrow for three columns
            VStack(spacing: 0) {
                if newspaper {
                    WireView { model.open($0); newspaper = false }
                } else if landscape {
                    HStack(spacing: 0) {
                        if pane == .three { index.frame(width: 304); VRule() }
                        if pane != .discussion { articlePane }
                        if pane != .article {
                            if pane != .discussion { VRule() }
                            DiscussionView(showMap: true, footer: false) { model.setPane(.discussion) }
                                .frame(width: pane == .discussion ? nil : 428)
                        }
                    }
                } else if geo.size.width < 500, showIndex {
                    index   // a phone: the index alone; picking a story shows it in the index's place
                        .onChange(of: model.selected?.id) { model.showIndex = false }
                } else {
                    HStack(spacing: 0) {
                        if showIndex { index.frame(width: min(300, geo.size.width * 0.42)); VRule() }
                        portrait(narrow: geo.size.width < 700)
                    }
                }
                if !newspaper { Rule(); hints }
            }
        }
        .background(T.bg)
    }

    private var index: some View {
        IndexView(onArticle: { model.open($0) }, onDiscussion: { model.open($0) })
    }

    private func icon(_ name: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 14)).foregroundStyle(T.dim).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }

    @ViewBuilder private var articlePane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                icon("sidebar.left", pane == .three ? "Hide story index" : "Show story index") { model.pane = pane == .three ? .noIndex : .three }
                if let s = model.selected {
                    (Text(s.host ?? "hacker news") + Text(s.url.map { " " + $0.path() } ?? "").foregroundStyle(T.faint))
                        .font(T.mono(12)).foregroundStyle(T.dim).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if model.selected != nil { ArticleControls() }
                icon("arrow.up.left.and.arrow.down.right", "Expand article") { model.setPane(.article) }
            }
            .frame(height: 44).padding(.horizontal, 4)
            Rule()
            if let s = model.selected { ArticleView(story: s) } else { empty }
        }
        .background(T.article)
    }

    private var empty: some View {
        Text("select a story").font(T.mono(12)).foregroundStyle(T.faint).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Portrait and half-width windows: the index, and one pane that Article and Discussion share.
    private func portrait(narrow: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                icon("sidebar.left", showIndex ? "Hide story index" : "Show story index") { model.showIndex.toggle() }
                Text(model.selected?.title ?? "").font(T.sans(14.5, .semibold)).foregroundStyle(T.text).lineLimit(1)
                Spacer(minLength: 0)
                if model.selected != nil {
                    if right == .article { ArticleControls() }
                    MonoButton(label: "article", on: right == .article) { model.right = .article }
                    MonoButton(label: "discussion", on: right == .discussion) { model.right = .discussion }
                    if right == .discussion { MonoButton(label: "find", on: model.finding) { model.finding.toggle() } }
                }
            }
            .frame(height: 48).padding(.leading, 4).padding(.trailing, 12)
            Rule()
            if let s = model.selected {
                // Both stay alive, so each keeps its scroll position when the other is in front.
                ZStack {
                    ArticleView(story: s).opacity(right == .article ? 1 : 0).allowsHitTesting(right == .article)
                    DiscussionView(phone: true, showMap: !narrow).opacity(right == .discussion ? 1 : 0).allowsHitTesting(right == .discussion)
                }
                // A hidden find field would keep the keyboard and the typing state.
                .onChange(of: right) { if right != .discussion { model.finding = false } }
            } else { empty }
        }
        .onChange(of: model.selected?.id) { if narrow { model.showIndex = false } }
    }

    /// The keys, in full when the row has room, as bare keys otherwise; the position never wraps.
    private var hints: some View {
        HStack(spacing: 22) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 22) {
                    hint("j/k", "comment"); hint("n/p", "thread"); hint("space", "collapse"); hint("u", "parent"); hint("f", "focus")
                    hint("↑↓", "story"); hint("a", "article"); hint("d", "discussion"); hint("/", "find"); hint("esc", "back out")
                }
                HStack(spacing: 22) { hint("j k n p u f ␣ ↑↓ a d /", "") }
            }
            Spacer(minLength: 0)
            if let c = model.current, let i = model.comments.firstIndex(where: { $0.id == c.id }) {
                Text(verbatim: "thread \(c.root + 1)/\(model.roots.count), comment \(i + 1)/\(model.comments.count)").layoutPriority(1)
            }
        }
        .lineLimit(1).font(T.mono(11)).foregroundStyle(T.dim).frame(height: 28).padding(.horizontal, 14).background(T.deep)
    }
    private func hint(_ k: String, _ what: String) -> some View {
        Text(k).foregroundStyle(T.text) + Text(" " + what)
    }
}
enum Route: Hashable { case article, discussion }
