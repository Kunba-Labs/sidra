import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import SidraWorkspace

/// The Theasa menu: registered with every other command, so the keys work from any focus, list
/// when ⌘ is held, and show in the palette and the shortcuts sheet. All are ⌥⌘ chords, none
/// plain letters, so typing in a field never triggers one. ⌘F (search) and ⌘. (back) are shared
/// keys routed in Commands.swift while the Theasa tab is in front; Esc goes back through `TheasaKeyHost`.
enum TheasaCommands {
    /// Theasa's screens and the active connection; selects the Theasa tab if another is in front. Without a
    /// connection: the connect sheet, and nil.
    @MainActor static func target(_ app: AppModel) -> (nav: TheasaNav, live: TheasaLive)? {
        let store = TheasaStore.shared
        guard let live = store.activeLive else { store.open(app); return nil }
        if !store.presented { store.open(app) }
        return (store.nav(in: app), live)
    }

    /// The Theasa tab is in front (for the shared keys ⌘F, ⌘. and ⌘↩).
    @MainActor static func focused(_ app: AppModel) -> Bool { TheasaStore.shared.presented }

    /// The key host holds first responder while nothing types; it lets go first, or SwiftUI cannot
    /// move the keyboard into the search field (⌘F did nothing while the host held the keys).
    @MainActor static func search(_ app: AppModel) {
        guard let n = target(app)?.nav else { return }
        n.releaseKeys?()
        DispatchQueue.main.async { n.focusSearch += 1 }
    }
    /// ⌘. and Esc: leave the field if one types, else go back.
    @MainActor static func back(_ app: AppModel) { TheasaStore.shared.nav(in: app).escape() }

    @MainActor static func all(_ app: AppModel) -> [SidraCommand] {
        [
            .init("theasa.pulse", "Pulse", area: "Substrate", key: "p", modifiers: [.command, .option]) { target(app)?.nav.show(.pulse) },
            .init("theasa.agents", "Agents", area: "Substrate", key: "a", modifiers: [.command, .option]) {
                target(app)?.nav.show(.agents)
            },
            .init("theasa.nextAgent", "Next Agent That Needs You", area: "Substrate", key: "n", modifiers: [.command, .option]) {
                guard let t = target(app) else { return }
                if !t.nav.nextAgent(t.live) { app.toast("No agent needs you.") }
            },
            .init("theasa.search", "Search the Work Log", area: "Substrate", label: "⌘F") { search(app) },
            .init("theasa.back", "Back", area: "Substrate", label: "⎋  ⌘.") { back(app) },
            // A menu key: a multi-line field's text view would take ⌘↩ as a newline before onKeyPress sees it.
            .init("theasa.send", "Send Message", area: "Substrate", key: .return, modifiers: .command) {
                guard focused(app), let t = target(app) else { return }   // elsewhere ⌘↩ does nothing
                if let s = t.nav.submit { s() } else { app.toast("Tap a message field first.") }
            },
            .init("theasa.refresh", "Refresh and Reconnect", area: "Substrate", key: "r", modifiers: [.command, .option]) {
                guard let t = target(app) else { return }
                t.live.reconnect(client: t.live.client)
                t.live.say("Reconnecting.")
            },
        ]
    }
}

#if os(macOS)
/// On the Mac, Esc reaches a hidden button's shortcut, so the pane needs no key-owning host.
struct TheasaKeyHosted<Content: View>: View {
    let nav: TheasaNav
    let paneFocused: Bool
    let typing: Bool
    var overlay = false
    @ViewBuilder let content: Content
    var body: some View {
        content.background {
            if paneFocused && !typing && !nav.path.isEmpty {
                Button("Back") { nav.escape() }.keyboardShortcut(.cancelAction).hidden()
            }
        }
    }
}
#else
/// Esc goes back in the Theasa pane's stack when none of its fields has the keyboard. Esc never
/// reaches SwiftUI menu shortcuts on iPad, and the app delegate is not in the responder chain under the
/// SwiftUI lifecycle (notes found it dead on a real iPad), so the pane is hosted in this controller: it
/// owns Esc as a UIKit key command and becomes first responder while its pane has focus and no field is
/// typing. `canPerformAction` is checked per press (UIKit caches keyCommands).
final class TheasaKeyHost<Content: View>: UIHostingController<Content> {
    var nav: TheasaNav?
    var paneFocused: () -> Bool = { false }
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        claimKeys()
        // Overlay hosts only: a presentation settles after viewDidAppear and UIKit can hand the keys back behind it.
        if overlay { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.claimKeys() } }
    }

    /// Takes first responder so Esc and ⌘F reach this host once the Theasa pane has focus: from the
    /// terminal or editor that had it before (else their keys win), never from one of Theasa's own fields.
    var overlay = false
    func claimKeys() {
        guard paneFocused(), nav?.typing == false, let w = view.window else { return }
        if let r = w.firstResponderView {
            guard !r.isDescendant(of: view) else { return }
            r.resignFirstResponder()   // the editor's text view would keep ⌘F for its own find
        }
        becomeFirstResponder()
    }

    override var keyCommands: [UIKeyCommand]? {
        let esc = UIKeyCommand(title: "Back", action: #selector(escape), input: UIKeyCommand.inputEscape, modifierFlags: [])
        esc.wantsPriorityOverSystemBehavior = true
        // While this host has the keys, UIKit's own find would take ⌘F before the menu.
        let find = UIKeyCommand(title: "Search the Work Log", action: #selector(findTheasa), input: "f", modifierFlags: .command)
        find.wantsPriorityOverSystemBehavior = true
        // No ⌘↩ here: a host key command on Return took plain Return from the search field (its submit
        // never fired). ⌘↩ is the Theasa menu's Send Message.
        return [esc, find]
    }
    @objc func findTheasa() {
        guard let n = nav else { return }
        n.releaseKeys?()
        DispatchQueue.main.async { n.focusSearch += 1 }
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(findTheasa) { return overlay ? TheasaStore.shared.presented : paneFocused() }
        if action == #selector(escape) { return paneFocused() && (nav?.typing == true || nav?.path.isEmpty == false) }   // else Esc goes on
        return super.canPerformAction(action, withSender: sender)
    }
    @objc func escape() { nav?.escape(); DispatchQueue.main.async { self.claimKeys() } }
}

struct TheasaKeyHosted<Content: View>: UIViewControllerRepresentable {
    let nav: TheasaNav
    let paneFocused: Bool
    let typing: Bool   // read here so leaving a field re-claims Esc
    var overlay = false
    @ViewBuilder let content: Content
    func makeUIViewController(context: Context) -> TheasaKeyHost<Content> {
        let c = TheasaKeyHost(rootView: content)
        c.nav = nav
        c.overlay = overlay
        nav.releaseKeys = { [weak c] in if c?.isFirstResponder == true { _ = c?.resignFirstResponder() } }
        c.view.backgroundColor = .clear
        c.safeAreaRegions = []
        return c
    }
    func updateUIViewController(_ c: TheasaKeyHost<Content>, context: Context) {
        c.rootView = content
        let focused = paneFocused
        c.paneFocused = { focused }
        // Claim Esc only when the pane gains focus or a field gives the keyboard up, never while a
        // field is about to take it (⌘F), or the host would win the race for first responder.
        // `focused` is false for a pane in a hidden tab (tabs stay built in Sidra), so a hidden Theasa
        // tab never claims, and gives keys up the moment its tab or pane loses focus.
        let gained = focused && !context.coordinator.focused, stopped = !typing && context.coordinator.typing
        let lost = !focused && context.coordinator.focused
        context.coordinator.focused = focused; context.coordinator.typing = typing
        if gained || stopped { DispatchQueue.main.async { c.claimKeys() } }
        if lost, c.isFirstResponder { c.resignFirstResponder() }
    }
    func makeCoordinator() -> State { State() }
    final class State { var focused = false; var typing = false }
}

private extension UIView {
    var firstResponderView: UIView? {
        if isFirstResponder { return self }
        for v in subviews { if let r = v.firstResponderView { return r } }
        return nil
    }
}
#endif
