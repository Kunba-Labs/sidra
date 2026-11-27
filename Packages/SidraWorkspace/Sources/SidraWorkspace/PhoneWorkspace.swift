#if os(iOS) || os(visionOS)   // the compact iPhone layout
import SwiftUI
import SidraDesign

/// The workspace at compact width (iPhone, design 2 of `design/html/10-iphone.html`): a title row with
/// the project and the working pills, one pane at a time (a split's panes are pages to swipe), and a
/// dock of tabs at the bottom in thumb reach. Long-press a tab for its details and activity.
struct PhoneWorkspace: View {
    @Bindable var store: WorkspaceStore
    let provider: PaneProvider
    let newTabMenu: AnyView
    /// Projects, as on the iPad's title bar: tapping the name switches.
    var hostMenu: AnyView? = nil
    let trailing: AnyView?
    let emptyHero: AnyView?

    private var host: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(store.hostName).font(SidraFont.ui(17, weight: .bold)).foregroundStyle(SidraColor.text).lineLimit(1)
                if hostMenu != nil { Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(SidraColor.muted) }
            }
            if !store.hostDetail.isEmpty { Text(store.hostDetail).font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.muted).lineLimit(1) }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if let hostMenu { Menu { hostMenu } label: { host }.accessibilityLabel("Project \(store.hostName)") } else { host }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 16).frame(height: 44)

            Group {
                if store.boardOpen, let board = store.board {
                    board()
                } else if let tab = store.activeTab, let root = tab.root {
                    let panes = root.panes
                    if panes.count == 1 || tab.maximizedPaneID != nil {
                        PaneCardHost(pane: tab.maximizedPaneID.flatMap(root.pane) ?? panes[0], tab: tab, store: store, provider: provider)
                    } else {
                        // A split on a phone: its panes side by side would be too narrow, so they are pages.
                        TabView(selection: Binding(get: { tab.focusedPaneID ?? panes[0].id }, set: { store.focus(pane: $0) })) {
                            ForEach(panes) { p in
                                PaneCardHost(pane: p, tab: tab, store: store, provider: provider).tag(p.id).padding(.bottom, 24)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .always))
                    }
                } else {
                    EmptyWorkspace(newTabMenu: newTabMenu, hero: emptyHero)
                }
            }
            .padding(.horizontal, 8)

            if !store.dockHidden { dock }
        }
        .background(SidraColor.ground.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var dock: some View {
        HStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if store.board != nil { BoardButton(store: store, size: 38) }
                        ForEach(store.visibleTabs) { tab in dockTab(tab).id(tab.id) }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: store.activeTabID) { _, id in if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } } }
            }
            newTabMenu
        }
        .padding(.horizontal, 10).padding(.bottom, 4)
    }

    private func dockTab(_ tab: WorkspaceTab) -> some View {
        let on = tab.id == store.activeTabID && !store.boardOpen
        let shape = RoundedRectangle(cornerRadius: SidraRadius.pill, style: .continuous)
        return Button { store.select(tab: tab.id) } label: {
            HStack(spacing: 8) {
                ProcessIcon(tab.shownIcon, size: 24)
                if on { Text(tab.title).font(SidraFont.ui(14, weight: .bold)).foregroundStyle(SidraColor.text).lineLimit(1) }
                if store.tabDot?(tab) == true { Circle().fill(SidraColor.blue).frame(width: 7, height: 7) }
            }
            .padding(.leading, 6).padding(.trailing, on ? 12 : 6).frame(height: 38)
            .background(on ? SidraColor.tabActive : SidraColor.raised, in: shape)
            .overlay { if on { shape.strokeBorder(SidraGradient.horizontal, lineWidth: 1) } else { shape.strokeBorder(SidraColor.hairline) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title + (tab.subtitle.map { ", \($0)" } ?? ""))
        .accessibilityAddTraits(on ? .isSelected : [])
        // Long-press: the tab's details and activity, with the tab's actions.
        .contextMenu {
            Button { store.select(tab: tab.id) } label: { Label("Show", systemImage: "eye") }
            if let i = store.tabs.firstIndex(where: { $0.id == tab.id }) {
                if i > 0 { Button { store.moveTab(tab.id, to: store.tabs[i - 1].id) } label: { Label("Move left", systemImage: "arrow.left") } }
                if i < store.tabs.count - 1 { Button { store.moveTab(tab.id, to: store.tabs[i + 1].id) } label: { Label("Move right", systemImage: "arrow.right") } }
            }
            Button(role: .destructive) { store.requestCloseTab(tab.id) } label: { Label("Close tab", systemImage: "xmark") }
        } preview: {
            TabDetails(tab: tab, extra: store.tabDetail?(tab))
        }
    }
}

/// What a long-pressed tab shows: its title, its panes and what runs in them (the app adds activity).
struct TabDetails: View {
    let tab: WorkspaceTab
    let extra: AnyView?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProcessIcon(tab.shownIcon, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.title).font(SidraFont.ui(16, weight: .bold)).foregroundStyle(SidraColor.text)
                    if let s = tab.subtitle { Text(s).font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted) }
                }
            }
            if let extra { extra }
            if tab.panes.count > 1 {
                Text("\(tab.panes.count) panes: " + tab.panes.map(\.title).joined(separator: ", "))
                    .font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .background(SidraColor.popup)
    }
}
#endif
