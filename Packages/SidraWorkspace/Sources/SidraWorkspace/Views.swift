import SwiftUI
import SidraDesign

/// What the app supplies for a pane: body, header extras, footer items.
public struct PaneBody {
    public var content: AnyView
    public var extra: AnyView
    public var footer: AnyView

    public init<C: View, E: View, F: View>(@ViewBuilder content: () -> C,
                                           @ViewBuilder extra: () -> E = { EmptyView() },
                                           @ViewBuilder footer: () -> F = { EmptyView() }) {
        self.content = AnyView(content())
        self.extra = AnyView(extra())
        self.footer = AnyView(footer())
    }
}

/// Supplies pane bodies and new panes for splits. Lives in the app so this package stays
/// independent of editor, terminal and AI packages.
public struct PaneProvider {
    public var body: (Pane) -> PaneBody
    public var newPaneForSplit: (Pane) -> Pane
    /// True when closing the pane would kill a running process; the card then asks first.
    public var needsCloseConfirmation: (Pane) -> Bool
    public init(body: @escaping (Pane) -> PaneBody, newPaneForSplit: @escaping (Pane) -> Pane,
                needsCloseConfirmation: @escaping (Pane) -> Bool = { _ in false }) {
        self.body = body
        self.newPaneForSplit = newPaneForSplit
        self.needsCloseConfirmation = needsCloseConfirmation
    }
}

/// The whole window: title bar over the pane tree of the active tab.
public struct WorkspaceView<TitleTrailing: View>: View {
    @Bindable var store: WorkspaceStore
    let provider: PaneProvider
    let newTabMenu: AnyView
    let hostMenu: AnyView?
    let emptyHero: AnyView?
    /// The title bar's pills at compact width (iPhone): only what fits beside the project name.
    let compactTrailing: AnyView?
    /// The machine's quiet icons (VM, board, ⌘), grouped with Hide bar at the bar's end.
    let machine: AnyView?
    @ViewBuilder let titleTrailing: () -> TitleTrailing
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The top bar hidden into the floating orb, until Show bar; kept across launches.
    @AppStorage("sidra.barHidden") private var barHidden = false

    public init(store: WorkspaceStore, provider: PaneProvider,
                newTabMenu: AnyView, hostMenu: AnyView? = nil, emptyHero: AnyView? = nil, compactTrailing: AnyView? = nil, machine: AnyView? = nil,
                @ViewBuilder titleTrailing: @escaping () -> TitleTrailing) {
        self.compactTrailing = compactTrailing
        self.machine = machine
        self.store = store
        self.provider = provider
        self.newTabMenu = newTabMenu
        self.hostMenu = hostMenu
        self.emptyHero = emptyHero
        self.titleTrailing = titleTrailing
    }

    public var body: some View {
        #if os(macOS)
        regular
        #else
        if sizeClass == .compact {
            PhoneWorkspace(store: store, provider: provider, newTabMenu: newTabMenu, hostMenu: hostMenu, trailing: compactTrailing, emptyHero: emptyHero)
                .alert("Close \(store.pendingClose?.title ?? "")?", isPresented: Binding(get: { store.pendingClose != nil }, set: { if !$0 { store.pendingClose = nil } })) {
                    Button("Close", role: .destructive) { store.confirmPendingClose() }
                    Button("Cancel", role: .cancel) { store.pendingClose = nil }
                } message: { Text("A process is still running in it and will be killed.") }
        } else {
            regular
        }
        #endif
    }

    private var regular: some View {
        VStack(spacing: 0) {
            // The design's status bar is 26 pt, iPadOS 26's safe area 32: the title bar's own 11 pt of air absorbs the rest.
            if !barHidden {
                TitleBar(store: store, newTabMenu: newTabMenu, hostMenu: hostMenu, onHide: { withAnimation(.easeOut(duration: 0.2)) { barHidden = true } }, machine: machine, trailing: titleTrailing)
                    .padding(.top, -6)
            }
            Group {
                if let tab = store.activeTab, let root = tab.root {
                    if let maxID = tab.maximizedPaneID, let pane = root.pane(maxID) {
                        paneCard(pane, in: tab)
                    } else {
                        NodeView(node: root, tab: tab, store: store, provider: provider)
                    }
                } else {
                    EmptyWorkspace(newTabMenu: newTabMenu, hero: emptyHero)
                }
            }
            .padding(SidraSpace.workspaceInset)
            .padding(.top, barHidden ? 8 : 0)
            .environment(\.paneHeaderTrailingInset, barHidden ? 56 : 0)   // ponytail: every pane header, not only the one under the orb
        }
        .overlay {
            if barHidden {
                FloatingOrb(store: store, newTabMenu: newTabMenu, pills: { titleTrailing(); if let machine { machine } }) { withAnimation(.easeOut(duration: 0.2)) { barHidden = false } }   // machine holds the ⌘ menu: keep it when the bar is hidden
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)   // the home indicator sits in the 14 pt workspace inset, as designed
        .background(SidraColor.ground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .alert("Close \(store.pendingClose?.title ?? "")?", isPresented: Binding(get: { store.pendingClose != nil }, set: { if !$0 { store.pendingClose = nil } })) {
            Button("Close", role: .destructive) { store.confirmPendingClose() }
            Button("Cancel", role: .cancel) { store.pendingClose = nil }
        } message: {
            Text("A process is still running in it and will be killed.")
        }
    }

    private func paneCard(_ pane: Pane, in tab: WorkspaceTab) -> some View {
        PaneCardHost(pane: pane, tab: tab, store: store, provider: provider)
    }
}

/// Recursive split renderer with draggable dividers.
struct NodeView: View {
    let node: PaneNode
    let tab: WorkspaceTab
    let store: WorkspaceStore
    let provider: PaneProvider

    var body: some View {
        switch node {
        case .leaf(let pane):
            PaneCardHost(pane: pane, tab: tab, store: store, provider: provider)
        case .split(let id, let axis, let ratio, let first, let second):
            GeometryReader { geo in
                let gap = SidraSpace.gap
                let total = (axis == .horizontal ? geo.size.width : geo.size.height) - gap
                // Neither side collapses below the minimum; a drag past it stops there.
                let minLen = min(SidraSpace.minPaneLength, max(total / 2, 0))
                let firstLen = min(max(total * ratio, minLen), max(total - minLen, 0))
                let secondLen = max(total - firstLen, 0)
                let layout = axis == .horizontal
                    ? AnyLayout(HStackLayout(spacing: 0))
                    : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    NodeView(node: first, tab: tab, store: store, provider: provider)
                        .frame(width: axis == .horizontal ? firstLen : nil, height: axis == .vertical ? firstLen : nil)
                    Divider(axis: axis) { delta in
                        let newRatio = (firstLen + delta) / max(total, 1)
                        store.setRatio(newRatio, forSplit: id)
                    }
                    .frame(width: axis == .horizontal ? gap : nil, height: axis == .vertical ? gap : nil)
                    NodeView(node: second, tab: tab, store: store, provider: provider)
                        .frame(width: axis == .horizontal ? secondLen : nil, height: axis == .vertical ? secondLen : nil)
                }
            }
        }
    }
}

/// Invisible drag handle in the gap between panes.
struct Divider: View {
    let axis: SplitAxis
    let onDrag: (CGFloat) -> Void
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering ? SidraColor.hairline2 : .clear)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        onDrag(axis == .horizontal ? v.translation.width : v.translation.height)
                    }
            )
            .accessibilityLabel("Pane divider")
            .accessibilityHint("Drag to resize")
    }
}

struct PaneCardHost: View {
    let pane: Pane
    let tab: WorkspaceTab
    let store: WorkspaceStore
    let provider: PaneProvider

    var body: some View {
        let body = provider.body(pane)
        PaneCard(icon: pane.kind.icon, title: pane.title, project: pane.project,
                 focused: tab.focusedPaneID == pane.id,
                 maximized: tab.maximizedPaneID == pane.id,
                 actions: .init(
                    splitRight: { store.split(pane.id, axis: .horizontal, newPane: provider.newPaneForSplit(pane)) },
                    splitDown: { store.split(pane.id, axis: .vertical, newPane: provider.newPaneForSplit(pane)) },
                    maximize: { store.toggleMaximize(pane: pane.id) },
                    close: { store.requestClose(pane: pane.id) }),
                 onFocus: { store.focus(pane: pane.id) },
                 content: { body.content },
                 extra: { body.extra },
                 footer: { body.footer })
    }
}

struct EmptyWorkspace: View {
    let newTabMenu: AnyView
    let hero: AnyView?
    var body: some View {
        VStack(spacing: 16) {
            if let hero { hero } else {   // the hero offers its own way in
                Text("No panes open").font(SidraFont.ui(15)).foregroundStyle(SidraColor.muted)
                newTabMenu
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

