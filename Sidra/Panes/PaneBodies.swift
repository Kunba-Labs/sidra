import SwiftUI
import SidraDesign
import SidraWorkspace
import SidraHackerTab
import SidraChess

/// Maps a pane to its body.
enum PaneBodies {
    @MainActor
    static func body(for pane: Pane) -> PaneBody {
        switch pane.kind {
        case .terminal(let target):
            return PaneBody {
                TerminalPane(pane: pane, target: target)
            } footer: {
                TerminalFooter(target: target)
            }
        case .herdr(let target, let session):
            return PaneBody {
                HerdrPane(pane: pane, target: target, session: session)
            } extra: {
                EmptyView()
            } footer: {
                HerdrFooter(pane: pane)
            }
        case .pipelines:
            return PaneBody {
                PipelinesPane(pane: pane)
            } extra: {
                PipelinesConnectionButton()
            } footer: {
                PipelinesFooter()
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
