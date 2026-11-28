import SwiftUI
import SidraDesign
import SidraWorkspace

/// When each herdr agent last ended a turn (went from working to done, idle or waiting), as seen by this app.
/// The board orders by it (Waseem, 2026-11-27: "turn ends"); new output does not move a square.
@MainActor @Observable
final class AgentActivity {
    static let shared = AgentActivity()
    private(set) var ended: [String: Date] = [:]

    static func key(_ monitorKey: String, _ pane: String) -> String { monitorKey + "|" + pane }

    func note(_ monitorKey: String, old: MuxSnapshot?, new: MuxSnapshot) {
        guard let old else { return }   // the first poll is history, not a change
        let before = Dictionary(old.agents.map { ($0.pane_id, $0.agent_status) }, uniquingKeysWith: { a, _ in a })
        for a in new.agents where before[a.pane_id] == .working && a.agent_status != .working {
            ended[Self.key(monitorKey, a.pane_id)] = Date()
        }
    }
}

/// The activity board (2026-11-27): one square per agent on every herdr machine of this window, the last turn
/// to end first. Squares slide to their new place when the order changes. Working agents carry Sidra's gradient
/// edge, ones that wait for you a gold one. A tap opens that agent's tab and focuses it in herdr.
struct ActivityBoard: View {
    @Environment(AppModel.self) private var app
    @Environment(WorkspaceStore.self) private var store
    private let activity = AgentActivity.shared

    struct Square: Identifiable {
        let id: String
        let tab: UUID
        let monitor: MuxMonitor
        let agent: MuxSnapshot.Agent
        let space: MuxSnapshot.Workspace?
        let machine: String
        let ended: Date?
        @MainActor var model: String? { agent.agent_session?.value.flatMap { monitor.models[$0] }.map(MuxMonitor.modelLabel) }
    }

    /// One monitor per machine and session among this window's herdr tabs.
    private var squares: [Square] {
        var seen = Set<String>(), out: [Square] = []
        for tab in store.tabs {
            for pane in tab.panes {
                guard case .herdr(let target, _) = pane.kind, let m = MuxMonitors.shared.monitor(for: pane, app: app),
                      seen.insert(m.key).inserted, let s = m.snapshot else { continue }
                for a in s.agents {
                    out.append(Square(id: AgentActivity.key(m.key, a.pane_id), tab: tab.id, monitor: m, agent: a,
                                      space: s.workspaces.first { $0.id == a.workspace_id }, machine: app.herdrMachineName(target),
                                      ended: activity.ended[AgentActivity.key(m.key, a.pane_id)]))
                }
            }
        }
        // Turns seen ending first, newest first; before any is seen, herdr's own order of state changes.
        // ponytail: those numbers count per machine, so two machines interleave by number until their turns end here.
        return out.sorted {
            switch ($0.ended, $1.ended) {
            case let (a?, b?): a > b
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): ($0.agent.state_change_seq ?? 0) > ($1.agent.state_change_seq ?? 0)
            }
        }
    }

    var body: some View {
        let list = squares
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Last activity").font(SidraFont.ui(15, weight: .bold)).foregroundStyle(SidraColor.text)
                    Text(list.count == 1 ? "1 agent" : "\(list.count) agents").font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.dim)
                }
                if list.isEmpty {
                    Text("No agents yet. Open a herdr tab: its agents show here, the last turn to end first.")
                        .font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted).padding(.top, 20)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Platform.isPhone ? 150 : 190), spacing: 12)], spacing: 12) {
                    ForEach(list) { sq in
                        AgentSquare(square: sq) { open(sq) }
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: list.map(\.id))
            }
            .padding(Platform.isPhone ? 4 : 16)
        }
        .scrollIndicators(.hidden)
        // The model each agent runs (Waseem, 2026-11-28): read from the machines while the board is open.
        .task(id: list.count) {   // again when agents come or go, so a new one gets its model at once
            while !Task.isCancelled {
                var seen = Set<String>()
                for sq in squares where seen.insert(sq.monitor.key).inserted { await sq.monitor.loadModels(app) }
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SidraColor.pane, in: RoundedRectangle(cornerRadius: SidraRadius.pane, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SidraRadius.pane, style: .continuous).strokeBorder(SidraColor.hairline))
    }

    private func open(_ sq: Square) {
        store.select(tab: sq.tab)   // closes the board
        Task { await sq.monitor.focusAgent(app, pane: sq.agent.pane_id) }
    }
}

private struct AgentSquare: View {
    let square: ActivityBoard.Square
    let action: () -> Void

    var body: some View {
        let a = square.agent
        let status = a.agent_status
        let name = square.space?.label ?? a.workspace_id
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    HerdrLogoView(name: name, image: square.space.flatMap { square.monitor.logo(for: $0) }, size: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(SidraFont.ui(14.5, weight: .bold)).foregroundStyle(SidraColor.text).lineLimit(1)
                        Text(square.machine).font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim).lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    HerdrStatusIcon(status: status, size: 8)
                    Text(HerdrStatusIcon.label(status)).font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.muted)
                }
                .padding(.horizontal, 8).frame(height: 22)
                .background(SidraColor.tabActive, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(a.terminal_title_stripped.flatMap { $0.isEmpty ? nil : $0 } ?? a.agent)
                    .font(SidraFont.mono(12)).foregroundStyle(SidraColor.muted).lineLimit(3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                HStack(spacing: 6) {
                    HerdrAgentMark(agent: a.agent, size: 13)
                    if let m = square.model { Text(m).font(SidraFont.ui(11.5, weight: .semibold)).foregroundStyle(SidraColor.muted).lineLimit(1) }
                    Spacer(minLength: 4)
                    if let e = square.ended { Text(e, style: .relative).font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.dim).monospacedDigit().lineLimit(1) }
                }
            }
            .padding(14)
            .aspectRatio(1, contentMode: .fit)
            .background(SidraColor.raised, in: shape)
            // Working: Sidra's gradient (Waseem, 2026-11-27). Waiting for you: gold. Else a hairline.
            .gradientBorder(radius: 14, active: status == .working, inactive: status == .blocked ? SidraColor.gold.opacity(0.6) : SidraColor.hairline)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(square.machine), \(square.model.map { $0 + ", " } ?? "")\(HerdrStatusIcon.label(status))")
    }
}
