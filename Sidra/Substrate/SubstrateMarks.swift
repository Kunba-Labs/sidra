import SwiftUI
import SidraDesign
import SidraWorkspace

/// Substrate in the title bar: the handle of the Substrate tab, which the tab strip, dock and orb never show
/// (2026-11-26, Waseem: Theasa's screens move into Substrate, and the tab leaves the normal tab flow).
/// Its mark, a status dot, and "N waiting": requests to approve plus agents that need you. While the tab is
/// in front it is drawn as an active tab. A tap brings the tab up, on what waits if anything does.
struct SubstratePill: View {
    /// iPhone title bar: the mark and the dot only, on a 44 pt target.
    var compact = false
    @Environment(AppModel.self) private var app
    private let hub = SubstrateHub.shared
    @State private var theasa = TheasaStore.shared

    var body: some View {
        let live = theasa.activeLive
        let agents = live?.agents?.available == true ? live!.agents!.agents : []
        let blocked = agents.filter { $0.status == "blocked" }.count
        let working = agents.contains { $0.status == "working" }
        let waiting = hub.waiting + blocked
        let dot = waiting > 0 ? SidraColor.gold : working ? SidraColor.jade : SidraColor.muted
        let on = app.workspace.activeTab.map(TheasaStore.isTheasaTab) ?? false
        let shape = RoundedRectangle(cornerRadius: SidraRadius.pill, style: .continuous)
        Button { open(blocked: blocked) } label: {
            if compact {
                HStack(spacing: 5) {
                    ProcessIcon(.substrate, size: 18)
                    Circle().fill(dot).frame(width: 7, height: 7)
                }
                .padding(.horizontal, 6).frame(minWidth: 44, minHeight: 44)
                .background(on ? SidraColor.tabActive : .clear, in: shape)
                .gradientBorder(radius: SidraRadius.pill, active: on, inactive: .clear)
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 7) {
                    ProcessIcon(.substrate, size: 18)
                    Circle().fill(dot).frame(width: 7, height: 7)
                    Text("Substrate").font(SidraFont.ui(12.5, weight: on ? .bold : .regular)).foregroundStyle(waiting == 0 || on ? SidraColor.text : SidraColor.muted)
                    if waiting > 0 { Text("\(waiting) waiting").font(SidraFont.ui(12.5, weight: .bold)).foregroundStyle(SidraColor.text) }
                }
                .padding(.leading, 6).padding(.trailing, 12).frame(height: 28)
                .background(on ? SidraColor.tabActive : SidraColor.raised, in: shape)
                .gradientBorder(radius: SidraRadius.pill, active: on, inactive: SidraColor.hairline)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("substrate-pill")
        .accessibilityLabel("Substrate" + (waiting > 0 ? ", \(waiting) waiting" : ""))
        .accessibilityAddTraits(on ? .isSelected : [])
        .task(id: theasa.active?.id) { await live?.loadAgents() }
    }

    private func open(blocked: Int) {
        let c = hub.connections.first(where: { (hub.store($0.id)?.waiting ?? 0) > 0 }) ?? hub.connections.first ?? hub.add()
        let s = hub.store(c.id)
        if (s?.waiting ?? 0) > 0 { s?.section = .requests } else if blocked > 0 { s?.section = .agents }
        app.startTab(.substrate)
    }
}

enum SubstrateTabMark {
    /// On the Substrate tab: its waiting count in the electric gradient. On a herdr tab: Substrate's mark
    /// while one of its agents has a request waiting.
    @MainActor static func accessory(for tab: WorkspaceTab) -> AnyView? {
        let hub = SubstrateHub.shared
        for pane in tab.panes {
            switch pane.kind {
            case .substrate(let id):
                guard let n = hub.store(id)?.waiting, n > 0 else { return nil }
                return AnyView(Text(verbatim: "\(n)").font(SidraFont.mono(10.5, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                    .background(SubstrateStyle.electric, in: Capsule())
                    .shadow(color: Color(hex: 0x7B2CFF).opacity(0.5), radius: 5)
                    .accessibilityLabel("\(n) waiting"))
            case .herdr:
                let panes = hub.waitingPanes
                guard !panes.isEmpty, let s = MuxMonitors.shared.byPane[pane.id]?.snapshot,
                      s.agents.contains(where: { panes.contains($0.pane_id) }) else { continue }
                return AnyView(ProcessIcon(.substrate, size: 16).accessibilityLabel("A Substrate request waits for an agent here"))
            default: continue
            }
        }
        return nil
    }
}
