import SwiftUI
import SidraDesign
import SidraWorkspace

/// "Substrate · 2 waiting" in the title bar while requests wait for approval; opens the Requests list.
struct SubstratePill: View {
    @Environment(AppModel.self) private var app
    private let hub = SubstrateHub.shared

    var body: some View {
        let waiting = hub.waiting
        if waiting > 0 {
            Button { open() } label: {
                HStack(spacing: 7) {
                    ProcessIcon(.substrate, size: 18)
                    Text("Substrate:").font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted)
                    Text(verbatim: "\(waiting)").font(SidraFont.ui(12.5, weight: .bold)).foregroundStyle(SidraColor.gold)
                    Text("waiting").font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.text)
                }
                .padding(.leading, 6).padding(.trailing, 12).frame(height: 28)
                .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: SidraRadius.pill, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: SidraRadius.pill, style: .continuous).strokeBorder(SidraColor.gold.opacity(0.35)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Substrate, \(waiting) waiting for approval")
            .accessibilityIdentifier("substrate-pill")
        }
    }

    private func open() {
        if let c = hub.connections.first(where: { (hub.store($0.id)?.waiting ?? 0) > 0 }) { hub.store(c.id)?.section = .requests }
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
