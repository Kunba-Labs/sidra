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
                      compactTrailing: slot(HStack(spacing: 6) { SubstratePill(compact: true); HerdrTitleCounts(); commandMenu }),
                      // Title bar design B (design/html/13-title-bar.html): what needs you as labelled pills.
                      machine: slot(HStack(spacing: 2) { commandMenu })) {
            SubstratePill()
            HerdrTitleCounts()
        }
        // A floating or undocked keyboard sits over the panes; only a docked one makes room.
        .ignoresSafeArea(.keyboard, edges: keyboard.floating ? .all : [])   // a floating keyboard dragged near the top must not push from above either
        #if os(iOS) || os(visionOS)
        .background { KeyboardGuideProbe(dock: keyboard).ignoresSafeArea().allowsHitTesting(false) }
        #endif
        .overlay(alignment: .top) { PlatformBanners() }
        // The floating green mic: hold to talk into the focused terminal (iPad and Mac).
        #if os(iOS) || os(visionOS)
        .overlay { FloatingKeyboardLayer() }   // under the mic, so dictation's card draws over the keys
        #endif
        .overlay(alignment: .bottomTrailing) { FloatingMic(showMic: focusedIsTerminal) }
        #if os(iOS)
        // iPhone: the compose bar over Apple's keyboard (ComposeBar.swift).
        .safeAreaInset(edge: .bottom, spacing: 0) { if Compose.enabled && Compose.shared.open { ComposeBar() } }
        .onChange(of: Compose.shared.open, initial: true) { _, open in store.dockHidden = open }
        #endif
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
                    .allowsHitTesting(false)   // a toast over the keyboard or key row must not swallow taps
            }
        }
        .animation(.easeOut(duration: 0.2), value: app.toastMessage)
        .sidraAlert($app.alert)
        #if DEBUG
        .modifier(SubstrateEditorDemo())
        #endif
        #if os(iOS) || os(visionOS)
        // A screenshot arriving closes whatever sheet is up: the Send screenshot card covers the window.
        .onChange(of: ScreenshotInbox.shared.pending, initial: true) { _, image in if image != nil { app.sheet = nil } }
        // Only the window in front shows it (every window presented it, and a background window's copy being
        // dismissed cleared the screenshot), and only Cancel or Send clears it: iPadOS closing the cover while
        // Sidra came to the front cleared it too, so the card flashed and went away (2026-11-20).
        .fullScreenCover(isPresented: Binding(get: { ScreenshotInbox.shared.pending != nil && app.sheet == nil && app.workspace === store },
                                              set: { _ in })) {
            if let image = ScreenshotInbox.shared.pending { ScreenshotSendSheet(image: image).environment(app) }
        }
        #endif
        .sheet(item: $app.sheet, onDismiss: { app.afterSheetDismiss?(); app.afterSheetDismiss = nil }) { sheet in
            Group { switch sheet {
            case .settings: SettingsSheet()
            case .shortcuts: ShortcutsSheet()
            case .herdr: HerdrConnectSheet()
            case .theasa: TheasaConnectSheet()
            case .pipelines: PipelinesConnectSheet()
            case .pipelinesEdit(let id): PipelinesConnectSheet(editing: id)
            case .newTab: NewTabSheet()
            } }
            // Handed on explicitly: on a Mac (Designed for iPad) a sheet's content did not inherit them, and
            // the first-run setup sheet crashed at launch with "No Observable object of type AppModel".
            .environment(app).environment(store)
        }
        // A tab closed while hidden never runs its terminals' handlers: end their sessions here.
        .onChange(of: Set(app.allWorkspaces.flatMap { $0.tabs.flatMap { $0.panes.map(\.id) } })) { _, live in TerminalLink.prune(live: live) }
        .onAppear {
            app.openNewWindow = { [openWindow] in openWindow(id: "main") }
            store.isBusy = { BusyPanes.shared.isBusy($0) }
            #if os(iOS)
            Compose.install()
            SidraToast.show = { [app] in app.toast($0) }
            #endif
            store.isHiddenTab = TheasaStore.isTheasaTab   // the Substrate tab's only handle is its pill
            #if DEBUG
            DemoMode.install(app)
            #endif
            TheasaStore.shared.openFromLaunchArguments(app)
            store.tabDetail = { tab in AnyView(TabActivity(tab: tab)) }
            store.tabAccessory = { tab in SubstrateTabMark.accessory(for: tab) }
            store.attention = { [app] in MuxMonitors.shared.count(.blocked, live: Set(app.allWorkspaces.flatMap { $0.tabs.flatMap { $0.panes.map(\.id) } })) }
            PipelinesHub.shared.start()
            // Your words for swipe and voice: each line sent with Sidra's keys, and your Theasa prompts once a day.
            #if os(iOS) || os(visionOS)
            FloatingKeyboard.shared.onLine = { WordModel.shared.learn($0) }
            #endif
            Task { await WordModel.shared.refreshFromTheasa() }
            if UserDefaults.standard.bool(forKey: "hackertab.open") { app.openSingle(.hackertab) }
        }
    }

    /// A terminal or herdr pane has focus: there is a cursor for dictated words. The iPad's SwiftTerm
    /// fallback engine takes no dictation (only the Ghostty view does), so no mic there.
    private var focusedIsTerminal: Bool {
        if !Platform.isMac, app.terminalEngine == .swiftTerm { return false }
        switch store.focusedPane?.kind {
        case .terminal, .herdr: return true
        default: return false
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
            Button("Keyboard Shortcuts…", systemImage: "keyboard") { app.sheet = .shortcuts }
            Button("Settings…", systemImage: "gearshape") { app.sheet = .settings }
        } label: {
            // 28 high like the status pills; plain, so iPadOS draws no big glass button around it.
            Image(systemName: "command")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SidraColor.muted)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain)
        .menuIndicator(.hidden)
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

#if os(iOS) || os(visionOS)
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
            #if os(visionOS)
            let kb = CGRect.zero   // visionOS's keyboard floats apart from the window
            _ = end
            #else
            let kb = window.convert(end, from: window.screen.coordinateSpace)
            #endif
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
#endif
