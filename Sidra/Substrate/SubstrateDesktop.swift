#if os(macOS)
import AppKit
import SwiftUI
import LocalAuthentication
import SidraDesign

/// Substrate approvals as Sidra's own cards on the Mac desktop (Waseem, 2026-11-20): inbox2's desktop card
/// stack in the Substrate pane's look. A borderless panel top-right over every app, Sidra in front or not;
/// the newest card at the bottom, older ones folded to title and buttons, at most four.
/// Settings → Notifications picks these cards (default), the system banner, or nothing.
@MainActor @Observable final class SubstrateDesktop {
    static let shared = SubstrateDesktop()

    enum Mode: String, CaseIterable { case cards, system, off }
    static let modeKey = "sidra.substrateNotices"
    static var mode: Mode { Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .cards }

    struct Card: Identifiable {
        enum State: Equatable { case waiting, working, done(String), failed(String) }
        let connection: UUID
        let message: Substrate.Message
        var state = State.waiting
        var shown = Date()
        var id: String { message.id }
    }

    static let maxCards = 4
    /// inbox2's "high" dwell. A held request stays until it is acted on.
    static let dwell: TimeInterval = 14

    var cards: [Card] = [] { didSet { DispatchQueue.main.async { self.fit() } } }
    var hovering = false { didSet { if !hovering { for i in cards.indices { cards[i].shown = Date() } } } }
    private var panel: NSPanel?
    private var ticker: Task<Void, Never>?
    private var lastSound = Date.distantPast

    func show(_ m: Substrate.Message, connection: UUID) {
        guard !cards.contains(where: { $0.id == m.id }) else { return }
        cards.append(Card(connection: connection, message: m))
        if Date().timeIntervalSince(lastSound) > 2 { NSSound(named: "Glass")?.play(); lastSound = Date() }   // once per batch
        present()
    }

    /// Requests decided elsewhere (the web, another device, the pane) leave the stack.
    func prune(_ connection: UUID, keep: Set<String>) {
        cards.removeAll { $0.connection == connection && $0.state == .waiting && !keep.contains($0.id) }
    }

    func dismiss(_ id: String) {
        cards.removeAll { $0.id == id }
    }

    func dismissHidden() {
        cards.removeFirst(max(0, cards.count - Self.maxCards))
    }

    /// Approve or Reject: Touch ID or the login password first, as the iPad's notification asks for Face ID.
    func act(_ id: String, approve: Bool) {
        guard let card = cards.first(where: { $0.id == id }), let store = SubstrateHub.shared.store(card.connection) else { return dismiss(id) }
        Task {
            let ctx = LAContext()
            let reason = approve ? "approve \(card.message.sender?.name ?? "this")'s request" : "reject \(card.message.sender?.name ?? "this")'s request"
            guard (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true else { return }
            set(id, .working)
            do {
                if approve { try await store.approve(id) } else { try await store.reject(id) }
                set(id, .done(approve ? "Approved. The agent has it." : "Rejected."))
                try? await Task.sleep(for: .seconds(1.5))
                dismiss(id)
            } catch {
                set(id, .failed(error.localizedDescription))
            }
        }
    }

    /// Sidra comes forward on the request; `edit` opens "Edit before approving".
    func open(_ id: String, edit: Bool = false) {
        guard let card = cards.first(where: { $0.id == id }) else { return }
        if edit { SubstrateHub.shared.store(card.connection)?.editing = id }
        Notifier.pending = .substrate(card.connection, id)
        NSApp.activate()
        NSApp.windows.first { $0.canBecomeMain && $0.isVisible }?.makeKeyAndOrderFront(nil)
        dismiss(id)
    }

    /// -sidra.demoNotices (screenshots, a look without a live request): two sample cards, one held.
    func demoIfAsked() {
        guard CommandLine.arguments.contains("-sidra.demoNotices") else { return }
        let c = UUID()
        show(Substrate.Message(id: "demo-1", text: "Run the migration that drops invoices.legacy_total and deploy to production.", stage: "held",
                               deploy_allow: "production", risk: "destructive migration", client: "claude-code",
                               sender: .init(name: "Ayla Demir"), project: .init(id: "p1", name: "billing-api"), created_at: Date().addingTimeInterval(-120)), connection: c)
        show(Substrate.Message(id: "demo-2", text: "Cmd-[ and Cmd-] should switch herdr tabs across spaces, wrapping at the ends. Move pane focus to Cmd-Option-[ and ].",
                               stage: "pending_approval", client: "codex", sender: .init(name: "Waseem"), project: .init(id: "p2", name: "sidra"), created_at: Date()), connection: c)
    }

    private func set(_ id: String, _ state: Card.State) {
        if let i = cards.firstIndex(where: { $0.id == id }) { cards[i].state = state; cards[i].shown = Date() }
    }

    private func present() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 1), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false   // each card draws its own
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = true
            p.contentView = NSHostingView(rootView: SubstrateDesktopStack(desk: self))
            panel = p
        }
        panel?.orderFrontRegardless()
        ticker = ticker ?? Task { [weak self] in
            while let self, !self.cards.isEmpty {
                if !self.hovering {
                    self.cards.removeAll { $0.state == .waiting && !$0.message.held && Date().timeIntervalSince($0.shown) >= Self.dwell }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            self?.ticker = nil
        }
    }

    /// The panel takes exactly the stack's size, top-right of the screen, so it never blocks clicks beside it.
    private func fit() {
        guard let p = panel, let host = p.contentView else { return }
        if cards.isEmpty { p.orderOut(nil); return }
        guard let screen = NSScreen.main else { return }
        let size = host.fittingSize
        let f = screen.visibleFrame
        p.setFrame(NSRect(x: f.maxX - size.width - 8, y: f.maxY - size.height - 8, width: size.width, height: size.height), display: true)
    }
}

// MARK: - Views

struct SubstrateDesktopStack: View {
    let desk: SubstrateDesktop

    var body: some View {
        let hidden = max(0, desk.cards.count - SubstrateDesktop.maxCards)
        let shown = Array(desk.cards.suffix(SubstrateDesktop.maxCards))
        VStack(spacing: 10) {
            if hidden > 0 { more(hidden) }
            ForEach(shown) { card in
                SubstrateDesktopCard(desk: desk, card: card, newest: card.id == shown.last?.id)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(16)   // room for the cards' shadows
        .frame(width: 452)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeOut(duration: 0.18), value: desk.cards.map(\.id))
        .onHover { desk.hovering = $0 }
        .preferredColorScheme(.dark)
    }

    private func more(_ n: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(n) more waiting in Substrate").font(SidraFont.ui(13.5, weight: .semibold)).foregroundStyle(SidraColor.text)
            Spacer()
            Button("Open the queue") { if let first = desk.cards.first { desk.open(first.id) } }.buttonStyle(SubstrateButtonStyle())
            Button("Dismiss") { desk.dismissHidden() }.buttonStyle(SubstrateButtonStyle())
        }
        .padding(14)
        .modifier(SubstrateDesktopCardShape(newest: false))
    }
}

struct SubstrateDesktopCard: View {
    let desk: SubstrateDesktop
    let card: SubstrateDesktop.Card
    let newest: Bool

    private var m: Substrate.Message { card.message }
    private var who: String { m.sender?.name ?? "Someone" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if newest { header; Divider().overlay(SidraColor.hairline) }
            Button { desk.open(m.id) } label: { content.contentShape(Rectangle()) }.buttonStyle(.plain)
            footer
        }
        .overlay(alignment: .bottomLeading) { if case .waiting = card.state, !m.held { bar } }
        .modifier(SubstrateDesktopCardShape(newest: newest))
    }

    private var header: some View {
        HStack(spacing: 8) {
            ProcessIcon(.substrate, size: 16)
            switch card.state {
            case .failed: label("Not sent", SidraColor.red)
            default:
                if m.held { label("Held · \(m.risk ?? "risky")", SidraColor.gold) }
                else { Text("NEEDS APPROVAL").font(SidraFont.ui(11, weight: .bold)).tracking(0.8).foregroundStyle(SubstrateStyle.electric) }
            }
            Spacer()
            Text(Substrate.ago(m.created_at)).font(SidraFont.mono(11)).foregroundStyle(SidraColor.muted)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func label(_ s: String, _ c: Color) -> some View {
        Text(s.uppercased()).font(SidraFont.ui(11, weight: .bold)).tracking(0.8).foregroundStyle(c).lineLimit(1)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            if case .failed = card.state {
                Text("Substrate did not take it").font(SidraFont.ui(15, weight: .semibold)).foregroundStyle(SidraColor.text)
            } else {
                Text(m.held ? "Held: \(m.project?.name ?? "a project")" : "\(who) asks \(m.project?.name ?? "an agent")")
                    .font(SidraFont.ui(15, weight: .semibold)).foregroundStyle(SidraColor.text).lineLimit(1)
            }
            if newest {
                Text([who, m.client, m.deploy_allow.flatMap { $0 == "none" ? nil : "deploys to \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(SidraFont.mono(11.5)).foregroundStyle(SidraColor.muted).lineLimit(1)
                if case .failed(let why) = card.state {
                    Text(why).font(SidraFont.ui(13)).foregroundStyle(Color(hex: 0xaab2bd)).padding(.top, 4)
                } else {
                    Text(m.text).font(SidraFont.ui(13)).foregroundStyle(Color(hex: 0xaab2bd)).lineLimit(3).padding(.top, 4)
                    if m.held, let risk = m.risk {
                        SubstrateChip(tone: .warn) { Text(risk) }.padding(.top, 6)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, newest ? 12 : 8)
    }

    @ViewBuilder private var footer: some View {
        switch card.state {
        case .done(let text):
            Label(text, systemImage: "checkmark").font(SidraFont.ui(13.5, weight: .semibold)).foregroundStyle(SidraColor.jade)
                .padding(.horizontal, 16).padding(.bottom, 14)
        case .failed:
            HStack(spacing: 8) {
                Button("Open in Sidra") { desk.open(m.id) }.buttonStyle(SubstrateButtonStyle())
                Button("Dismiss") { desk.dismiss(m.id) }.buttonStyle(SubstrateButtonStyle())
            }
            .padding(.horizontal, 14).padding(.bottom, 14)
        case .waiting, .working:
            HStack(spacing: 8) {
                Button { desk.act(m.id, approve: true) } label: { Label(m.held ? "Approve anyway" : m.proposal != nil ? "Approve adjusted" : "Approve", systemImage: "checkmark").lineLimit(1) }
                    .buttonStyle(SubstrateButtonStyle(electric: true)).fixedSize()
                Button { desk.act(m.id, approve: false) } label: { Label("Reject", systemImage: "xmark").lineLimit(1) }
                    .buttonStyle(SubstrateButtonStyle()).fixedSize()
                Button("Edit") { desk.open(m.id, edit: true) }.buttonStyle(SubstrateButtonStyle()).fixedSize()
                Spacer(minLength: 0)
                Button { desk.open(m.id) } label: { Image(systemName: "arrow.up.right.square").font(.system(size: 15)).frame(width: 30, height: 34).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(SidraColor.muted).help("Open in Sidra").accessibilityLabel("Open in Sidra")
            }
            .disabled(card.state == .working)
            .padding(.horizontal, 14).padding(.top, newest ? 10 : 0).padding(.bottom, 14)
            .overlay(alignment: .top) { if newest { Rectangle().fill(SidraColor.hairline).frame(height: 1) } }
        }
    }

    /// The dwell left, in the electric gradient; it stops while the pointer is over the stack.
    private var bar: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: desk.hovering)) { t in
            let left = desk.hovering ? 1 : max(0, 1 - t.date.timeIntervalSince(card.shown) / SubstrateDesktop.dwell)
            GeometryReader { g in
                Capsule().fill(SubstrateStyle.electric).frame(width: (g.size.width - 28) * left, height: 3).padding(.leading, 14)
            }
            .frame(height: 3)
        }
    }
}

/// Solid card in the Substrate pane's colours; the newest takes the electric border.
struct SubstrateDesktopCardShape: ViewModifier {
    let newest: Bool
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: SidraRadius.pane, style: .continuous)
        content
            .background(SubstrateStyle.card, in: shape)
            .overlay {
                if newest { shape.strokeBorder(SubstrateStyle.electric, lineWidth: 1.5) }
                else { shape.strokeBorder(SidraColor.hairline2) }
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(0.55), radius: 18, y: 10)
    }
}
#endif
