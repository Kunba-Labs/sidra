import SwiftUI
import SidraDesign

/// The top bar hidden (design 1 of `design/html/11-floating-bar.html`): an orb in the top-right corner
/// with the shown tab's icon and a gold badge for agents that need you. Tap: every tab, New tab, the
/// status pills and Show bar. Tap and hold: the tabs fan out from the corner; slide to one and let go.
struct FloatingOrb<Pills: View>: View {
    @Bindable var store: WorkspaceStore
    let newTabMenu: AnyView
    @ViewBuilder let pills: () -> Pills
    let showBar: () -> Void
    @State private var open = false
    @State private var fanning = false
    @State private var finger: CGPoint?
    @State private var held = false   // a hold just ended: its lift is no tap
    @State private var size: CGSize = .zero

    private let orbSize: CGFloat = 48
    private let inset = CGSize(width: 14, height: 6)

    private var center: CGPoint { CGPoint(x: size.width - inset.width - orbSize / 2, y: inset.height + orbSize / 2) }
    private var radius: CGFloat { max(170, CGFloat(store.visibleTabs.count + 1) * 34) }

    /// Tab positions on a quarter circle down and left of the orb, then New tab further out.
    private func spot(_ i: Int, of n: Int) -> CGPoint {
        let a = Double.pi / 2 + (Double.pi / 2) * (n > 1 ? Double(i) / Double(n - 1) : 0.5)
        return CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
    }
    private func picked(_ p: CGPoint?) -> UUID? {
        guard let p else { return nil }
        let n = store.visibleTabs.count
        return store.visibleTabs.enumerated().map { ($0.element.id, spot($0.offset, of: n)) }
            .filter { hypot($0.1.x - p.x, $0.1.y - p.y) < 34 }.first?.0
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if fanning { fan }
            orb.position(center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: "orb")
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
    }

    private var orb: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let hold = LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("orb")))
            .onChanged { v in
                if case .second(true, let drag) = v { held = true; withAnimation(.spring(duration: 0.25)) { fanning = true }; finger = drag?.location }
            }
            .onEnded { v in
                if case .second(true, let drag) = v, let id = picked(drag?.location) { store.select(tab: id) }
                withAnimation(.easeOut(duration: 0.15)) { fanning = false }
                finger = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { held = false }
            }
        return ZStack(alignment: .topTrailing) {
            shape.fill(SidraColor.raised)
                .overlay(shape.strokeBorder(SidraGradient.horizontal, lineWidth: 1.2))
                .overlay { ProcessIcon(store.activeTab?.shownIcon ?? .code, size: 28) }
                .frame(width: orbSize, height: orbSize)
                .shadow(color: .black.opacity(0.55), radius: 14, y: 8)
            if let n = store.attention?(), n > 0 {
                Text("\(n)").font(SidraFont.ui(11, weight: .bold)).foregroundStyle(SidraColor.Process.glyph)
                    .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                    .background(SidraColor.gold, in: Capsule()).overlay(Capsule().strokeBorder(SidraColor.ground, lineWidth: 2))
                    .offset(x: 6, y: -6)
            }
        }
        .contentShape(shape)
        .onTapGesture { if held { held = false } else { open = true } }
        .simultaneousGesture(hold)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tabs and status, \(store.activeTab?.title ?? "no tab") shown")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open = true }
        .accessibilityIdentifier("tab-orb")
        .popover(isPresented: $open, arrowEdge: .top) { dropdown.presentationCompactAdaptation(.popover) }
    }

    private var fan: some View {
        let n = store.visibleTabs.count
        let over = picked(finger)
        return ZStack(alignment: .topLeading) {
            Color.black.opacity(0.45).ignoresSafeArea().allowsHitTesting(false)
            ForEach(Array(store.visibleTabs.enumerated()), id: \.element.id) { i, tab in
                let p = spot(i, of: n), on = tab.id == over || (over == nil && tab.id == store.activeTabID)
                let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
                VStack(spacing: 4) {
                    shape.fill(on ? SidraColor.tabActive : SidraColor.raised)
                        .overlay { if on { shape.strokeBorder(SidraGradient.horizontal, lineWidth: 1.2) } else { shape.strokeBorder(SidraColor.hairline2) } }
                        .overlay { ProcessIcon(tab.shownIcon, size: 26) }
                        .frame(width: 46, height: 46)
                        .scaleEffect(tab.id == over ? 1.15 : 1)
                    Text(tab.title).font(SidraFont.ui(11, weight: .bold)).foregroundStyle(SidraColor.text).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(SidraColor.popup, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .fixedSize()
                .position(x: p.x, y: p.y + 12)
                .allowsHitTesting(false)
            }
        }
        .transition(.opacity)
    }

    private var dropdown: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Tabs").font(SidraFont.ui(12, weight: .bold)).foregroundStyle(SidraColor.muted)
                Spacer()
                Button { open = false; showBar() } label: { Label("Show bar", systemImage: "pin").font(SidraFont.ui(12)) }
                    .buttonStyle(.sidraSecondary).accessibilityIdentifier("show-bar")
            }
            .padding(.horizontal, 8).padding(.bottom, 6)
            ForEach(store.visibleTabs) { tab in
                let on = tab.id == store.activeTabID
                Button { store.select(tab: tab.id); open = false } label: {
                    HStack(spacing: 10) {
                        ProcessIcon(tab.shownIcon, size: 22)
                        Text(tab.title).font(SidraFont.ui(13.5, weight: .bold)).foregroundStyle(SidraColor.text).lineLimit(1)
                        if let s = tab.subtitle, s != tab.title { Text(s).font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted).lineLimit(1) }
                        Spacer(minLength: 6)
                        if store.tabDot?(tab) == true { Circle().fill(SidraColor.blue).frame(width: 7, height: 7) }
                    }
                    .padding(.horizontal, 10).frame(height: 40)
                    .background(on ? SidraColor.tabActive : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(alignment: .leading) {
                        if on { UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3).fill(SidraGradient.horizontal).frame(width: 3).padding(.vertical, 7) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack { newTabMenu; Text("New tab").font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted) }.padding(.horizontal, 6)
            Rectangle().fill(SidraColor.hairline).frame(height: 1).padding(.vertical, 6)
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) { pills() } }.padding(.horizontal, 6)
        }
        .padding(8)
        .frame(width: 440)
        .background(SidraColor.popup)
    }
}
