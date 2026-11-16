import SwiftUI
import SidraDesign
import SidraWorkspace
import SidraHackerTab

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(WorkspaceStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var renameText = ""

    @State private var keyboard = KeyboardDock()   // per window: each window has its own keyboard geometry

    var body: some View {
        @Bindable var app = app
        // Each slot carries the environment itself: on a Mac (Designed for iPad) menu contents are built for the
        // menu bar outside this view tree, and the project menu crashed at launch without AppModel.
        WorkspaceView(store: store, provider: provider, newTabMenu: slot(newTabButton), emptyHero: slot(NewTabCards()),
                      compactTrailing: slot(HStack(spacing: 6) { TheasaPill(compact: true); HerdrTitleCounts(); commandMenu }),
                      // Title bar design B (design/html/13-title-bar.html): what needs you as labelled pills.
                      machine: slot(HStack(spacing: 2) { commandMenu })) {
            TheasaPill()
            HerdrTitleCounts()
        }
        // A floating or undocked keyboard sits over the panes; only a docked one makes room.
        .ignoresSafeArea(.keyboard, edges: keyboard.floating ? .all : [])   // a floating keyboard dragged near the top must not push from above either
        .background { KeyboardGuideProbe(dock: keyboard).ignoresSafeArea().allowsHitTesting(false) }
        .overlay(alignment: .top) { PlatformBanners() }
        .overlay(alignment: .bottom) {
            if let msg = app.toastMessage {
                Text(msg)
                    .font(SidraFont.ui(13))
                    .foregroundStyle(SidraColor.text)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: SidraRadius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: SidraRadius.card, style: .continuous).strokeBorder(SidraColor.hairline2))
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: app.toastMessage)
        .sidraAlert($app.alert)
        .sheet(item: $app.sheet, onDismiss: { app.afterSheetDismiss?(); app.afterSheetDismiss = nil }) { sheet in
            Group { switch sheet {
            case .settings: SettingsSheet()
            case .shortcuts: ShortcutsSheet()
            case .herdr: HerdrConnectSheet()
            case .theasa: TheasaConnectSheet()
            case .pipelines: PipelinesConnectSheet()
            case .newTab: NewTabSheet()
            } }
            // Handed on explicitly: on a Mac (Designed for iPad) a sheet's content did not inherit them, and
            // the first-run setup sheet crashed at launch with "No Observable object of type AppModel".
            .environment(app).environment(store)
        }
        // A tab closed while hidden never runs its terminals' handlers: end their sessions here.
        .onChange(of: Set(app.allWorkspaces.flatMap { $0.tabs.flatMap { $0.panes.map(\.id) } })) { _, live in TerminalLink.prune(live: live) }
        .onAppear {
            store.isBusy = { BusyPanes.shared.isBusy($0) }
            store.isHiddenTab = TheasaStore.isTheasaTab   // the Theasa tab's only handle is its pill
            #if DEBUG
            DemoMode.install(app)
            #endif
            TheasaStore.shared.openFromLaunchArguments(app)
            store.tabDetail = { tab in AnyView(TabActivity(tab: tab)) }
            store.attention = { [app] in MuxMonitors.shared.count(.blocked, live: Set(app.allWorkspaces.flatMap { $0.tabs.flatMap { $0.panes.map(\.id) } })) }
            PipelinesStore.shared.start()
            if UserDefaults.standard.bool(forKey: "hackertab.open") { app.openSingle(.hackertab) }
        }
    }

    private func slot(_ v: some View) -> AnyView { AnyView(v.environment(app).environment(store)) }

    private var provider: PaneProvider {
        PaneProvider(body: { pane in PaneBodies.body(for: pane) },
                     newPaneForSplit: { pane in app.newPane(kind: pane.kind) },
                     needsCloseConfirmation: { pane in BusyPanes.shared.isBusy(pane.id) })
    }

    /// "+" opens the new-tab cards; each kind walks through its own setup there.
    private var newTabButton: some View {
        Button { app.sheet = .newTab } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(SidraColor.muted)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New tab")
    }

    private var commandMenu: some View {
        Menu {
            Button("New Window", systemImage: "macwindow.badge.plus") { openWindow(id: "main") }
            Button("Keyboard Shortcuts…", systemImage: "keyboard") { app.sheet = .shortcuts }
            Button("Settings…", systemImage: "gearshape") { app.sheet = .settings }
        } label: {
            Image(systemName: "command")
                .font(.system(size: 17))
                .foregroundStyle(SidraColor.muted)
                .frame(width: 30, height: 30)
        }
        .accessibilityLabel("Sidra menu")
    }
}

/// Whether the software keyboard floats (or is undocked or split) rather than docking at the bottom of
/// this window. iPadOS reports a floating keyboard as a full-width frame at the bottom, so the frame alone
/// can't tell. UIKit's keyboard layout guide can: it only rises for a docked keyboard. Floating = the
/// reported frame covers clearly more of this window than the guide does.
@MainActor @Observable
final class KeyboardDock {
    fileprivate(set) var floating = false
}

/// Full-window view whose hidden marker spans from the keyboard layout guide's top to the window bottom;
/// it also reads the keyboard notifications in its own window's coordinates.
private struct KeyboardGuideProbe: UIViewRepresentable {
    let dock: KeyboardDock
    func makeUIView(context: Context) -> Probe { Probe(dock: dock) }
    func updateUIView(_ uiView: Probe, context: Context) {}

    final class Probe: UIView {
        private let dock: KeyboardDock
        private let marker = UIView()
        private var reported: CGFloat = 0
        private var guide: CGFloat = 0

        init(dock: KeyboardDock) {
            self.dock = dock
            super.init(frame: .zero)
            NotificationCenter.default.addObserver(self, selector: #selector(frameChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, marker.superview == nil else { return }
            keyboardLayoutGuide.usesBottomSafeArea = false
            marker.isHidden = true
            marker.translatesAutoresizingMaskIntoConstraints = false
            addSubview(marker)
            NSLayoutConstraint.activate([
                marker.leadingAnchor.constraint(equalTo: leadingAnchor), marker.trailingAnchor.constraint(equalTo: trailingAnchor),
                marker.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor), marker.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        @objc private func frameChanged(_ note: Notification) {
            guard let window, let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let kb = window.convert(end, from: window.screen.coordinateSpace)
            let w = window.bounds
            // An empty, narrow or raised frame floats outright; a full-width one is checked against the guide.
            reported = kb.isEmpty || kb.width < w.width * 0.9 || kb.maxY < w.maxY - 1 ? .infinity : max(0, w.maxY - kb.minY)
            recompute()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if guide != marker.frame.height { guide = marker.frame.height; recompute() }
        }

        private func recompute() {
            let f = reported - guide > 40
            if dock.floating != f { dock.floating = f }
        }
    }
}
