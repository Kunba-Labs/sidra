import SwiftUI
import SidraDesign

/// Host block, pill tabs, status pills, new tab. No traffic lights: iPadOS has none.
struct TitleBar<Trailing: View>: View {
    @Bindable var store: WorkspaceStore
    let newTabMenu: AnyView
    var hostMenu: AnyView? = nil
    var onHide: (() -> Void)? = nil
    /// The machine (VM, board, ⌘): quiet icons in one group with Hide bar, after the labelled pills that need you.
    var machine: AnyView? = nil
    @ViewBuilder let trailing: () -> Trailing
    @State private var dragging: UUID?

    var body: some View {
        HStack(spacing: 10) {
            if let hostMenu {
                Menu { hostMenu } label: { host }
                    .menuStyle(.button).buttonStyle(.plain)
                    .accessibilityLabel("Project menu")
            }
            tabStrip
            Spacer(minLength: 8)
            trailing()
            HStack(spacing: 2) {
                if let machine { machine }
                if let onHide {
                    Button(action: onHide) {
                        Image(systemName: "chevron.up").font(.system(size: 13, weight: .semibold)).foregroundStyle(SidraColor.muted)
                            .frame(width: 30, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide bar")
                    .accessibilityIdentifier("hide-bar")
                }
            }
            .padding(3)
            .background(SidraColor.tabStrip, in: RoundedRectangle(cornerRadius: SidraRadius.tabStrip, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SidraRadius.tabStrip, style: .continuous).strokeBorder(SidraColor.hairline))
            .fixedSize()
        }
        .padding(.horizontal, 16)
        #if os(macOS)
        // The traffic lights sit at the bar's left (WindowChrome); the empty bar drags the window.
        .padding(.leading, WindowChrome.trafficLightsWidth)
        .background { Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()).onTapGesture(count: 2) { WindowChrome.zoomOnDoubleClick() } }
        #endif
        .frame(height: SidraSpace.titleBarHeight)
    }

    private var host: some View {
        HStack(spacing: 9) {
            // The project menu: which project Sidra works in and where it runs (2026-11-14: "not sure what that is").
            Image(systemName: "folder")
                .font(.system(size: 15))
                .foregroundStyle(SidraColor.muted)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(store.hostName).font(SidraFont.ui(13.5, weight: .bold)).foregroundStyle(SidraColor.text)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(SidraColor.dim)
                }
                Text(store.hostDetail).font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.muted)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.trailing, 4)
    }

    /// The tabs' own width: the strip grows to fit them and scrolls only when the bar has no more room (2026-11-20).
    @State private var tabsWidth: CGFloat = 0

    private var tabStrip: some View {
        // Clipped and scrollable: more tabs than fit scroll inside the strip instead of running
        // under the status pills; the active tab is scrolled into view when it changes. New tab sits at its end.
        HStack(spacing: 0) {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(store.visibleTabs.enumerated()), id: \.element.id) { i, tab in
                        // A subtitle that repeats the title (a Theasa connection named Theasa) says nothing.
                        PillTab(icon: tab.shownIcon, title: tab.title, subtitle: tab.subtitle == tab.title ? nil : tab.subtitle,
                                active: tab.id == store.activeTabID, dot: store.tabDot?(tab) == true, accessory: store.tabAccessory?(tab) ?? nil,
                                action: { store.select(tab: tab.id) },
                                close: { store.requestCloseTab(tab.id) })
                            .overlay(alignment: .topLeading) {
                                // Held ⌘: the key that picks each tab (Waseem, 2026-11-19).
                                if ModifierHold.shared.command, let k = TabKeys.label(i), !(Platform.isMac && i >= 9) { KeyHint("⌘" + k).offset(x: -2, y: -2) }
                            }
                            .animation(.easeOut(duration: 0.12), value: ModifierHold.shared.command)
                            .id(tab.id)
                            .reorderable(tab.id, dragging: $dragging) { store.moveTab($0, to: $1) }
                    }
                }
                .padding(4)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabsWidth = $0 }
            }
            .frame(maxWidth: tabsWidth > 0 ? tabsWidth : nil)
            .onChange(of: store.activeTabID) { _, id in if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } } }
        }
            newTabMenu.padding(.trailing, 4)
        }
        .background(SidraColor.tabStrip, in: RoundedRectangle(cornerRadius: SidraRadius.tabStrip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SidraRadius.tabStrip, style: .continuous).strokeBorder(SidraColor.hairline))
        .clipShape(RoundedRectangle(cornerRadius: SidraRadius.tabStrip, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(-1)
    }
}
