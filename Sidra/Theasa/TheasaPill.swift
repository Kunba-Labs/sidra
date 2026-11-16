import SwiftUI
import SidraDesign
import SidraWorkspace

/// Theasa in the title bar, between the board and herdr's counts. The pill is the handle of the Theasa
/// tab, which the tab strip, dock and orb never show (2026-11-14: "the pill is a tab, so clicking
/// on it opens the same tab as before but theasa pill acts as its tab, plus it needs its icon back").
/// A tap selects the tab, or opens the connect sheet when no server is saved; while the tab is in front
/// the pill is drawn as an active tab. The eye icon, the dot, and "N waiting" when an agent waits (the title bar's only waiting count)
/// (2026-11-14: "dont add the working counter in theasa tab": working is a green dot only).
struct TheasaPill: View {
    /// iPhone title bar: the icon and the dot only, on a 44 pt target.
    var compact = false
    @Environment(AppModel.self) private var app
    @State private var store = TheasaStore.shared

    var body: some View {
        let live = store.activeLive
        let agents = live?.agents?.available == true ? live!.agents!.agents : []
        let need = agents.filter { $0.status == "blocked" }.count
        let working = agents.filter { $0.status == "working" }.count
        let (dot, value): (Color, String?) =
            live == nil ? (SidraColor.dim, nil)
            : !live!.connected ? (SidraColor.dim, "offline")
            : live!.needsToken ? (SidraColor.dim, nil)   // no token: no counts
            : need > 0 ? (TColor.watch, "\(need) waiting")   // the only place the waiting count shows (2026-11-14)
            : working > 0 ? (SidraColor.jade, nil)   // the count lives in the title bar's own working pill
            : (SidraColor.muted, nil)
        let on = store.presented
        let shape = RoundedRectangle(cornerRadius: SidraRadius.pill, style: .continuous)
        Button { store.open(app) } label: {
            if compact {
                HStack(spacing: 5) {
                    ProcessIcon(.theasa, size: 18)
                    Circle().fill(dot).frame(width: 7, height: 7)
                }
                .padding(.horizontal, 6)
                .frame(minWidth: 44, minHeight: 44)
                .background(on ? SidraColor.tabActive : .clear, in: shape)
                .gradientBorder(radius: SidraRadius.pill, active: on, inactive: .clear)
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 7) {
                    ProcessIcon(.theasa, size: 18)
                    Circle().fill(dot).frame(width: 7, height: 7)
                    Text("Theasa").font(SidraFont.ui(12.5, weight: on ? .bold : .regular)).foregroundStyle(value == nil || on ? SidraColor.text : SidraColor.muted)
                    if let value { Text(value).font(SidraFont.ui(12.5, weight: .bold)).foregroundStyle(SidraColor.text) }
                }
                .padding(.leading, 6).padding(.trailing, 12)
                .frame(height: 28)
                // Inactive: the title bar's status pill. Active: an active tab (fill and the gradient border).
                .background(on ? SidraColor.tabActive : SidraColor.raised, in: shape)
                .gradientBorder(radius: SidraRadius.pill, active: on, inactive: SidraColor.hairline)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("theasa-pill")
        .accessibilityLabel("Theasa" + (value.map { ", \($0)" } ?? ""))
        .accessibilityAddTraits(on ? .isSelected : [])
        .task(id: store.active?.id) { await live?.loadAgents() }
    }
}
