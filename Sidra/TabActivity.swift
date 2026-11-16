import SwiftUI
import SidraDesign
import SidraWorkspace
import SidraHackerTab

/// A tab's activity for its long-press details on iPhone: one line per pane saying what runs there.
struct TabActivity: View {
    let tab: WorkspaceTab

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(tab.panes) { pane in
                HStack(spacing: 8) {
                    let (text, color) = line(pane)
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(text).font(SidraFont.ui(13)).foregroundStyle(SidraColor.text).lineLimit(2)
                }
            }
        }
    }

    private func line(_ pane: Pane) -> (String, Color) {
        switch pane.kind {
        case .herdr:
            guard let s = MuxMonitors.shared.byPane[pane.id]?.snapshot else { return ("herdr, not read yet", SidraColor.dim) }
            let blocked = s.count(.blocked), working = s.count(.working)
            var parts = ["\(s.workspaces.count) spaces", "\(s.agents.count) agents"]
            if blocked > 0 { parts.append("\(blocked) need you") }
            if working > 0 { parts.append("\(working) working") }
            return (parts.joined(separator: ", "), blocked > 0 ? SidraColor.gold : working > 0 ? SidraColor.orange : SidraColor.dim)
        case .pipelines:
            let p = PipelinesStore.shared
            guard p.connected else { return ("Not connected", SidraColor.dim) }
            return ("\(p.running.count) running, \(p.failedCount) failed", p.failedCount > 0 ? SidraColor.red : p.running.isEmpty ? SidraColor.jade : SidraColor.orange)
        case .hackertab:
            return HackerNews.shared.fresh ? ("New stories in the top 30", SidraColor.blue) : ("Nothing new", SidraColor.dim)
        case .terminal:
            let busy = BusyPanes.shared.isBusy(pane.id)
            return ("\(pane.title)\(pane.project.map { ", \($0)" } ?? ""): \(busy ? "running" : "idle")", busy ? SidraColor.jade : SidraColor.dim)
        default:
            return (pane.title + (pane.project.map { ", \($0)" } ?? ""), SidraColor.dim)
        }
    }
}
