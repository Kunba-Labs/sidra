import SwiftUI
import SidraDesign
import SidraWorkspace
import SidraSSH

/// What a new tab can be. Each kind runs its own setup the first time: there is no global onboarding.
enum NewTabKind: String, CaseIterable, Identifiable {
    case herdr, ssh, theasa, pipelines, substrate, hackertab, chess
    var id: String { rawValue }

    var icon: ProcessIcon.Kind {
        switch self {
        case .herdr: .herdr
        case .ssh: .ssh
        case .theasa: .theasa
        case .pipelines: .pipelines
        case .substrate: .substrate
        case .hackertab: .hackertab
        case .chess: .chess
        }
    }

    var title: String {
        switch self {
        case .herdr: "herdr"
        case .ssh: "SSH host"
        case .theasa: "Theasa"
        case .pipelines: "Pipelines"
        case .substrate: "Substrate"
        case .hackertab: "HackerTab"
        case .chess: "Chess"
        }
    }

    var detail: String {
        switch self {
        case .herdr: "Your coding agents in herdr on another machine. Spaces and agents show as tabs."
        case .ssh: "A terminal on a machine you reach over SSH, with mosh when the host has it."
        case .theasa: "The pulse of your Claude Code agents, from a Theasa server you run."
        case .pipelines: "GitLab or GitHub pipelines of your projects, with the log of each failed job."
        case .substrate: "Approve what testers send your agents, and follow each fix to deploy."
        case .hackertab: "Hacker News, comments first."
        case .chess: "A game against Sidra's own engine, on this device."
        }
    }
}

extension AppModel {
    /// Starts a tab of `kind`: opens it at once, or the setup it needs first.
    func startTab(_ kind: NewTabKind) {
        switch kind {
        case .herdr: sheet = .herdr
        case .theasa: sheet = .theasa
        case .pipelines: sheet = .pipelines   // the saved connections, or a form for the first
        case .substrate:
            // One account today: its tab comes to the front, or opens and signs in there.
            let c = SubstrateHub.shared.connections.first ?? SubstrateHub.shared.add()
            if let t = workspace.tabs.first(where: { $0.panes.contains { $0.kind == .substrate(connection: c.id) } }) { workspace.select(tab: t.id) }
            else { openTab(kind: .substrate(connection: c.id)) }
        case .hackertab: openSingle(.hackertab)
        case .chess: openSingle(.chess)
        case .ssh: break   // NewTabSheet shows the host list
        }
    }

    /// HackerTab and Chess open once: the menu brings an open one to the front.
    func openSingle(_ kind: PaneKind) {
        if let t = workspace.tabs.first(where: { $0.icon == kind.icon }) { workspace.select(tab: t.id) } else { openTab(kind: kind) }
    }
}

/// The "+" sheet: one card per kind; SSH continues to a host list here.
struct NewTabSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var pickingHost = false
    @State private var editing: SSHHostProfile?
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if pickingHost {
                    Button { pickingHost = false } label: { Image(systemName: "chevron.left").foregroundStyle(SidraColor.muted) }
                        .buttonStyle(.plain).accessibilityLabel("Back")
                }
                Text(pickingHost ? "SSH host" : "New tab").font(SidraFont.ui(19, weight: .bold)).foregroundStyle(SidraColor.text)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.sidraSecondary)
            }
            if pickingHost { hostList } else { ScrollView { NewTabCards(onPick: pick) }.scrollIndicators(.hidden) }   // a phone is shorter than the cards
        }
        .padding(24)
        .frame(maxWidth: 640)
        .sidraSheetBackground()
        .sheet(item: $editing) { h in
            HostEditor(profile: h, password: $password) { saved, pw in
                app.hosts.upsert(saved, password: pw.isEmpty ? nil : pw)
                editing = nil
                openHost(saved.id)
            }
            .environment(app)   // a sheet on a Mac does not inherit it
        }
    }

    private func pick(_ kind: NewTabKind) {
        if kind == .ssh {
            if app.hosts.hosts.isEmpty { editing = .blank } else { pickingHost = true }
            return
        }
        // A kind with its own sheet replaces this one; the rest open a tab and close it.
        switch kind {
        case .herdr, .theasa, .pipelines: app.startTab(kind)
        default: dismiss(); app.startTab(kind)
        }
    }

    private func openHost(_ id: UUID) {
        dismiss()
        app.openTab(kind: .terminal(.ssh(hostID: id)))
    }

    private var hostList: some View {
        VStack(spacing: 8) {
            ForEach(app.hosts.hosts) { h in
                Button { openHost(h.id) } label: {
                    HStack(spacing: 12) {
                        ProcessIcon(.ssh, size: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.alias).font(SidraFont.ui(14, weight: .bold)).foregroundStyle(SidraColor.text)
                            Text("\(h.user)@\(h.host)\(h.port == 22 ? "" : ":\(h.port)")").font(SidraFont.ui(12)).foregroundStyle(SidraColor.muted)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: SidraRadius.card, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("newtab-host-\(h.alias)")
            }
            Button("Add host") { editing = .blank }.buttonStyle(.sidraSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

extension SSHHostProfile {
    /// A new host's starting values.
    static var blank: SSHHostProfile { SSHHostProfile(alias: "", host: "", user: "", auth: .key, startupCommand: "", trustOnFirstUse: false) }
}

/// The kinds as cards: in the "+" sheet, and over an empty workspace.
struct NewTabCards: View {
    @Environment(AppModel.self) private var app
    var onPick: ((NewTabKind) -> Void)?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: SidraSpace.gap)], spacing: SidraSpace.gap) {
            ForEach(NewTabKind.allCases) { k in
                Button { if let onPick { onPick(k) } else if k == .ssh { app.sheet = .newTab } else { app.startTab(k) } } label: {
                    HStack(alignment: .top, spacing: 12) {
                        ProcessIcon(k.icon, size: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(k.title).font(SidraFont.ui(14.5, weight: .bold)).foregroundStyle(SidraColor.text)
                            Text(k.detail).font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted)
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
                    .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: SidraRadius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: SidraRadius.card, style: .continuous).strokeBorder(SidraColor.hairline))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("newtab-\(k.rawValue)")
            }
        }
        .frame(maxWidth: 600)
    }
}
