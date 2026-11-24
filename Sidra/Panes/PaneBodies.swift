import SwiftUI
import SidraDesign
import SidraWorkspace
import SidraHackerTab
import SidraChess
import SidraTerminal

/// Maps a pane to its body.
enum PaneBodies {
    @MainActor
    static func body(for pane: Pane) -> PaneBody {
        switch pane.kind {
        case .terminal(let target):
            return PaneBody {
                TerminalPane(pane: pane, target: target)
            } footer: {
                SelectModeButton(paneID: pane.id)
                TerminalFooter(target: target)
            }
        case .herdr(let target, let session):
            return PaneBody {
                HerdrPane(pane: pane, target: target, session: session)
            } extra: {
                EmptyView()
            } footer: {
                SelectModeButton(paneID: pane.id)
                HerdrFooter(pane: pane)
            }
        case .pipelines(let id):
            let store = PipelinesHub.shared.store(id)
            return PaneBody {
                if let store { PipelinesPane(pane: pane, store: store) } else { PipelinesNoConnection() }
            } extra: {
                PipelinesConnectionButton(connection: store?.connection)
            } footer: {
                PipelinesFooter(store: store)
            }
        case .hackertab:
            return PaneBody {
                HackerTabPane()
            } footer: {
                FooterItem("news.ycombinator.com, keys while focused: ↑↓ j k n p u space f a d / esc")
            }
        case .chess:
            return PaneBody {
                ChessPane()
            } footer: {
                FooterItem("Sidra's own engine, on this device")
            }
        case .substrate(let id):
            return PaneBody {
                if let store = SubstrateHub.shared.store(id) { SubstratePane(store: store, pane: pane) } else { PlaceholderPane(text: "This Substrate account was removed.") }
            } extra: {
                if let store = SubstrateHub.shared.store(id) { SubstrateHeader(store: store) }
            } footer: {
                SubstrateFooter(store: SubstrateHub.shared.store(id))
            }
        case .theasa(let id):
            return PaneBody {
                TheasaPane(pane: pane, connectionID: id)
            } footer: {
                TheasaFooter(connectionID: id)
            }
        }
    }
}

struct PlaceholderPane: View {
    let text: String
    var body: some View {
        Text(text)
            .font(SidraFont.mono(13))
            .foregroundStyle(SidraColor.terminalText)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 16)
            .padding(.top, 4)
    }
}

/// Turns on select mode in a pane's terminal: finger drags select until its Done pill (iPad, iPhone).
struct SelectModeButton: View {
    let paneID: UUID
    var body: some View {
        #if os(iOS) || os(visionOS)
        Button {
            if let io = TerminalLink.of(paneID).session, let view = TerminalPaneView.ghostty(for: io) { view.selectMode.toggle() }
        } label: {
            Label("Select", systemImage: "character.cursor.ibeam").labelStyle(.titleAndIcon).font(SidraFont.ui(11.5, weight: .semibold))
                .foregroundStyle(SidraColor.muted).padding(.horizontal, 8).frame(height: 20)
                .background(Color(hex: 0x1b2028), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select text")
        .accessibilityHint("Drags select text until you tap Done selecting")
        #endif
    }
}

struct TerminalFooter: View {
    let target: TerminalTarget
    @Environment(AppModel.self) private var app
    var body: some View {
        switch target {
        case .ssh(let id):
            FooterItem(app.hosts.host(id).map { "\($0.user)@\($0.host):\($0.port)" } ?? "ssh")
            if app.hosts.host(id)?.mosh != nil { FooterChip([.init("mosh-compatible", color: SidraColor.jade)]) }
        }
        Spacer()
        FooterItem(app.terminalEngine == .ghostty || Platform.isMac ? "libghostty-vt" : "SwiftTerm")
    }
}
